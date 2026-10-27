import Foundation
import TranscriberCore
import WhisperKit

/// Envuelve WhisperKit: descarga el modelo la primera vez, lo carga una sola vez y transcribe.
actor WhisperService {
    static let variant = "large-v3-v20240930_turbo"

    private var whisperKit: WhisperKit?

    private let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YTTranscriber/whisper", isDirectory: true)

    private var completeMarker: URL { baseDirectory.appendingPathComponent(".\(Self.variant).complete") }

    /// Carpeta del modelo si ya se descargó completo en una ejecución anterior.
    private var downloadedModelFolder: URL? {
        guard let path = try? String(contentsOf: completeMarker, encoding: .utf8),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isModelDownloaded: Bool { downloadedModelFolder != nil }

    func prepare(
        onDownloadProgress: @escaping @Sendable (Double) -> Void,
        onLoading: @escaping @Sendable () -> Void
    ) async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let folder: URL
        if let existing = downloadedModelFolder {
            folder = existing
        } else {
            do {
                folder = try await WhisperKit.download(
                    variant: Self.variant,
                    downloadBase: baseDirectory,
                    progressCallback: { progress in onDownloadProgress(progress.fractionCompleted) }
                )
            } catch {
                throw TranscriberError.whisperFailed("no se pudo descargar el modelo (\(error.localizedDescription))")
            }
            try folder.path.write(to: completeMarker, atomically: true, encoding: .utf8)
        }

        onLoading()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: baseDirectory,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            let kit = try await WhisperKit(config)
            whisperKit = kit
            return kit
        } catch {
            throw TranscriberError.whisperFailed("no se pudo cargar el modelo (\(error.localizedDescription))")
        }
    }

    /// Transcribe detectando el idioma. Devuelve el texto en párrafos y el idioma más frecuente.
    func transcribe(
        audio: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (text: String, language: String?) {
        guard let whisperKit else { throw TranscriberError.whisperFailed("el modelo no está cargado") }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )

        let poller = Task {
            while !Task.isCancelled {
                onProgress(whisperKit.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poller.cancel() }

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioPath: audio.path, decodeOptions: options)
        } catch {
            throw TranscriberError.whisperFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let lines = results
            .flatMap(\.segments)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = SubtitleParser.paragraphs(from: lines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscription }

        let languageCounts = Dictionary(grouping: results.map(\.language), by: { $0 }).mapValues(\.count)
        let language = languageCounts.max { $0.value < $1.value }?.key
        return (text, language)
    }
}
