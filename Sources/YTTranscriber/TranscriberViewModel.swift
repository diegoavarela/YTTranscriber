import AppKit
import Foundation
import Observation
import TranscriberCore

enum Phase: Equatable {
    case idle
    case updatingTools
    case searchingSubtitles
    case downloadingAudio(Double?)
    case downloadingModel(Double)
    case loadingModel
    case transcribing(Double)
    case done(fromCache: Bool)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
}

@MainActor
@Observable
final class TranscriberViewModel {
    var urlText = ""
    var phase: Phase = .idle
    var title: String?
    var transcript: Transcript?
    var copied = false

    private let cache = TranscriptCache()
    private let whisper = WhisperService()
    private var copyResetTask: Task<Void, Never>?
    private static let lastUpdateCheckKey = "lastYtdlpUpdateCheck"

    /// Si el portapapeles tiene una URL de YouTube y el campo está vacío, la pega.
    /// Desde macOS 15.4 leer el portapapeles puede mostrar un aviso de privacidad: se detecta primero
    /// (eso no avisa) y solo se lee con la API asíncrona, para no bloquear nunca el hilo principal.
    func pasteURLFromClipboardIfPresent() async {
        guard urlText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let text: String?
        if #available(macOS 15.4, *) {
            guard pasteboard.accessBehavior != .alwaysDeny,
                  let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
                  patterns.contains(\.probableWebURL) else { return }
            text = try? await pasteboard.detectedValues(for: [\.probableWebURL]).probableWebURL
        } else {
            text = pasteboard.string(forType: .string)
        }
        guard urlText.isEmpty, let text, YouTubeURL(text) != nil else { return }
        urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Actualiza yt-dlp en segundo plano como mucho una vez por día: YouTube cambia seguido
    /// y una versión vieja deja de poder descargar.
    func updateToolsIfNeeded() {
        if let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        Task {
            do {
                let ytdlp = try await Self.locateYTDLP()
                guard ytdlp.isManaged else { return }
                try await ytdlp.selfUpdate()
                UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
            } catch {
                NSLog("YTTranscriber: no se pudo actualizar yt-dlp: \(error.localizedDescription)")
            }
        }
    }

    func start() {
        guard !phase.isBusy else { return }
        Task { await run() }
    }

    func copyTranscript() {
        guard let text = transcript?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private func run() async {
        title = nil
        transcript = nil
        guard let url = YouTubeURL(urlText) else {
            phase = .failed(TranscriberError.invalidURL.localizedDescription)
            return
        }
        if let cached = cache.load(videoID: url.videoID) {
            show(cached, fromCache: true)
            return
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTTranscriber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        do {
            let ytdlp = try await Self.locateYTDLP()
            let result = try await transcribeUpdatingIfBlocked(url: url, ytdlp: ytdlp, workDir: workDir)
            do {
                try cache.save(result)
            } catch {
                NSLog("YTTranscriber: no se pudo guardar la caché: \(error.localizedDescription)")
            }
            show(result, fromCache: false)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Usa la copia de yt-dlp que viene en el bundle (instalándola si hace falta) o, fuera de un .app, la de Homebrew.
    /// La copia puede mover ~120 MB, así que corre fuera del hilo principal.
    nonisolated private static func locateYTDLP() async throws -> YTDLP {
        try await Task.detached(priority: .userInitiated) {
            var managedDirectory: URL?
            if let helpers = ToolInstaller.bundledHelpers {
                let installer = ToolInstaller(source: helpers)
                try installer.install()
                managedDirectory = installer.destination
            }
            return try YTDLP.locate(managedDirectory: managedDirectory)
        }.value
    }

    /// Si YouTube rechaza a yt-dlp, lo actualiza y reintenta una sola vez.
    private func transcribeUpdatingIfBlocked(url: YouTubeURL, ytdlp: YTDLP, workDir: URL) async throws -> Transcript {
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            return try await transcribe(url: url, ytdlp: ytdlp, workDir: workDir)
        } catch let error as TranscriberError where ytdlp.isManaged && (error == .downloadForbidden || error == .botCheck) {
            phase = .updatingTools
            guard (try? await ytdlp.selfUpdate()) == true else { throw error }
            UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
            try? FileManager.default.removeItem(at: workDir)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            return try await transcribe(url: url, ytdlp: ytdlp, workDir: workDir)
        }
    }

    private func transcribe(url: YouTubeURL, ytdlp: YTDLP, workDir: URL) async throws -> Transcript {
        let infoFile = workDir.appendingPathComponent("info.json")

        phase = .searchingSubtitles
        let info = try await ytdlp.fetchInfo(url: url, infoFile: infoFile)
        title = info.title
        if info.liveStatus == "is_live" || info.liveStatus == "is_upcoming" {
            throw TranscriberError.liveStream
        }

        if let choice = YTDLP.chooseSubtitle(for: info),
           let vtt = try await ytdlp.downloadSubtitle(choice, infoFile: infoFile, workDir: workDir) {
            let text = SubtitleParser.plainText(fromVTT: vtt)
            if !text.isEmpty {
                return Transcript(
                    videoID: info.id,
                    title: info.title,
                    source: choice.isAutomatic ? .autoSubtitles : .manualSubtitles,
                    language: choice.language,
                    text: text
                )
            }
        }

        phase = .downloadingAudio(nil)
        let audio = try await ytdlp.downloadAudio(infoFile: infoFile, workDir: workDir) { fraction in
            Task { @MainActor in
                if case .downloadingAudio = self.phase { self.phase = .downloadingAudio(fraction) }
            }
        }

        if await !whisper.isModelDownloaded { phase = .downloadingModel(0) }
        _ = try await whisper.prepare(
            onDownloadProgress: { fraction in
                Task { @MainActor in
                    if case .downloadingModel = self.phase { self.phase = .downloadingModel(fraction) }
                }
            },
            onLoading: {
                Task { @MainActor in
                    if case .transcribing = self.phase { return }
                    self.phase = .loadingModel
                }
            }
        )

        phase = .transcribing(0)
        let (text, language) = try await whisper.transcribe(audio: audio) { fraction in
            Task { @MainActor in
                if case .transcribing = self.phase { self.phase = .transcribing(fraction) }
            }
        }
        return Transcript(videoID: info.id, title: info.title, source: .whisper, language: language, text: text)
    }

    private func show(_ result: Transcript, fromCache: Bool) {
        title = result.title
        transcript = result
        phase = .done(fromCache: fromCache)
    }
}
