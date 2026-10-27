import Foundation

/// Metadata mínima de `yt-dlp -J`.
public struct VideoInfo: Decodable, Sendable {
    public let id: String
    public let title: String
    public let language: String?
    public let liveStatus: String?
    public let subtitles: [String: [SubtitleTrack]]?
    public let automaticCaptions: [String: [SubtitleTrack]]?

    public struct SubtitleTrack: Decodable, Sendable {
        public let ext: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, language, subtitles
        case liveStatus = "live_status"
        case automaticCaptions = "automatic_captions"
    }
}

public struct SubtitleChoice: Equatable, Sendable {
    public let languageKey: String
    public let isAutomatic: Bool

    /// Código de idioma sin el sufijo "-orig".
    public var language: String {
        languageKey.hasSuffix("-orig") ? String(languageKey.dropLast(5)) : languageKey
    }
}

public struct YTDLP: Sendable {
    public let executable: URL
    /// Directorio que se antepone al PATH (para que yt-dlp encuentre deno).
    public let toolsDirectory: URL?

    /// Fallback para desarrollo (`swift run`), cuando no hay copia administrada por la app.
    public static let homebrewCandidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]

    public init(executable: URL, toolsDirectory: URL?) {
        self.executable = executable
        self.toolsDirectory = toolsDirectory
    }

    /// Usa la copia de yt-dlp que administra la app; si no existe, la de Homebrew.
    public static func locate(managedDirectory: URL?) throws -> YTDLP {
        let fm = FileManager.default
        if let managedDirectory {
            let managed = managedDirectory.appendingPathComponent(ToolInstaller.ytdlpName)
            if fm.isExecutableFile(atPath: managed.path) {
                return YTDLP(executable: managed, toolsDirectory: managedDirectory)
            }
        }
        guard let homebrew = homebrewCandidates.first(where: fm.isExecutableFile(atPath:)) else {
            throw TranscriberError.ytdlpMissing
        }
        return YTDLP(executable: URL(fileURLWithPath: homebrew), toolsDirectory: nil)
    }

    /// Solo la copia administrada se puede autoactualizar (la de Homebrew se actualiza con brew).
    public var isManaged: Bool { toolsDirectory != nil }

    private func run(_ arguments: [String], onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        // Con la copia administrada, solo herramientas propias y del sistema: así se comporta igual en
        // cualquier Mac, aunque tenga un ffmpeg de Homebrew roto o distinto.
        let path = toolsDirectory.map { $0.path + ":" + ProcessRunner.systemPath } ?? ProcessRunner.searchPath
        return try await ProcessRunner.run(executable, arguments: arguments, path: path, onStdoutLine: onStdoutLine)
    }

    private var commonArguments: [String] {
        ["--no-playlist", "--no-warnings", "--ignore-config"]
    }

    /// Actualiza yt-dlp a la última versión estable. Devuelve true si instaló una versión nueva.
    @discardableResult
    public func selfUpdate() async throws -> Bool {
        guard isManaged else { return false }
        let result = try await run(["--ignore-config", "-U"])
        guard result.exitCode == 0 else {
            throw TranscriberError.ytdlpFailed("no se pudo actualizar yt-dlp")
        }
        return Self.didUpdate(output: result.stdout + result.stderr)
    }

    static func didUpdate(output: String) -> Bool {
        output.contains("Updated yt-dlp to")
    }

    /// Descarga la metadata y la deja guardada en `infoFile` para reutilizarla sin volver a extraer.
    public func fetchInfo(url: YouTubeURL, infoFile: URL) async throws -> VideoInfo {
        let result = try await run(commonArguments + ["--dump-single-json", "--skip-download", url.canonical])
        guard result.exitCode == 0 else { throw Self.mapError(stderr: result.stderr) }
        let data = Data(result.stdout.utf8)
        try data.write(to: infoFile)
        do {
            return try JSONDecoder().decode(VideoInfo.self, from: data)
        } catch {
            throw TranscriberError.ytdlpFailed("respuesta inesperada al leer la metadata")
        }
    }

    /// Baja el subtítulo elegido en VTT y devuelve su contenido.
    public func downloadSubtitle(_ choice: SubtitleChoice, infoFile: URL, workDir: URL) async throws -> String? {
        let result = try await run(commonArguments + [
            "--load-info-json", infoFile.path,
            "--skip-download",
            choice.isAutomatic ? "--write-auto-subs" : "--write-subs",
            "--sub-langs", NSRegularExpression.escapedPattern(for: choice.languageKey),
            "--sub-format", "vtt",
            "-o", workDir.appendingPathComponent("subtitle.%(ext)s").path
        ])
        guard result.exitCode == 0 else { throw Self.mapError(stderr: result.stderr) }
        let files = (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let vtt = files.first(where: { $0.pathExtension == "vtt" }) else { return nil }
        return try String(contentsOf: vtt, encoding: .utf8)
    }

    /// Formatos que `afconvert` (incluido en macOS) puede leer: audio AAC en m4a, o el mp4 combinado.
    static let audioFormatSelector = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]"

    /// Baja solo el audio y lo convierte a WAV mono 16 kHz (el formato que usa Whisper), sin ffmpeg.
    public func downloadAudio(
        infoFile: URL,
        workDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let result = try await run(
            commonArguments + [
                "--load-info-json", infoFile.path,
                "-f", Self.audioFormatSelector,
                "--newline",
                "--progress-template", "download:YTPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes,total_bytes_estimate)s",
                "-o", workDir.appendingPathComponent("audio-source.%(ext)s").path
            ],
            onStdoutLine: { line in
                if let fraction = Self.parseProgress(line) { onProgress(fraction) }
            }
        )
        guard result.exitCode == 0 else {
            if result.stderr.contains("Requested format is not available") { throw TranscriberError.noCompatibleAudio }
            throw Self.mapError(stderr: result.stderr)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let source = files.first(where: { $0.lastPathComponent.hasPrefix("audio-source.") && $0.pathExtension != "part" }) else {
            throw TranscriberError.audioNotFound
        }

        let wav = workDir.appendingPathComponent("audio.wav")
        let conversion = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, wav.path]
        )
        guard conversion.exitCode == 0, FileManager.default.fileExists(atPath: wav.path) else {
            throw TranscriberError.audioConversionFailed
        }
        return wav
    }

    static func parseProgress(_ line: String) -> Double? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "YTPROGRESS",
              let done = Double(parts[1]), let total = Double(parts[2]), total > 0 else { return nil }
        return min(done / total, 1)
    }

    /// Elige subtítulos en el idioma original: primero manuales, después automáticos.
    public static func chooseSubtitle(for info: VideoInfo) -> SubtitleChoice? {
        let manual = (info.subtitles ?? [:]).filter { key, tracks in
            key != "live_chat" && tracks.contains { $0.ext == "vtt" }
        }.keys.sorted()
        let auto = (info.automaticCaptions ?? [:]).filter { _, tracks in
            tracks.contains { $0.ext == "vtt" }
        }.keys.sorted()

        let originalFromAuto = auto.first { $0.hasSuffix("-orig") }.map { String($0.dropLast(5)) }
        guard let original = info.language ?? originalFromAuto else {
            // Sin idioma conocido: un único subtítulo manual es casi seguro el original.
            return manual.count == 1 ? SubtitleChoice(languageKey: manual[0], isAutomatic: false) : nil
        }

        if let key = bestMatch(for: original, in: manual) {
            return SubtitleChoice(languageKey: key, isAutomatic: false)
        }
        if let key = auto.first(where: { $0.hasSuffix("-orig") && baseLanguage($0) == baseLanguage(original) }) {
            return SubtitleChoice(languageKey: key, isAutomatic: true)
        }
        if let key = bestMatch(for: original, in: auto.filter { !$0.hasSuffix("-orig") }) {
            return SubtitleChoice(languageKey: key, isAutomatic: true)
        }
        return nil
    }

    /// Coincidencia exacta o por idioma base ("en" ↔ "en-US").
    static func bestMatch(for language: String, in keys: [String]) -> String? {
        if keys.contains(language) { return language }
        let base = baseLanguage(language)
        return keys.first { baseLanguage($0) == base }
    }

    static func baseLanguage(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    static func mapError(stderr: String) -> TranscriberError {
        let text = stderr.lowercased()
        if text.contains("private video") { return .privateVideo }
        if text.contains("members-only") || text.contains("join this channel") { return .membersOnly }
        if text.contains("confirm your age") || text.contains("age-restricted") { return .ageRestricted }
        if text.contains("not a bot") { return .botCheck }
        if text.contains("is live") || text.contains("live event will begin") { return .liveStream }
        if text.contains("video unavailable") || text.contains("video is unavailable") || text.contains("is not available")
            || text.contains("has been removed") {
            return .unavailable
        }
        if text.contains("http error 403") { return .downloadForbidden }
        if text.contains("unable to download webpage") || text.contains("getaddrinfo") || text.contains("timed out")
            || text.contains("network is unreachable") || text.contains("nodename nor servname") {
            return .network
        }
        let lastError = stderr.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
            ?? stderr.split(separator: "\n").last
            ?? "error desconocido"
        return .ytdlpFailed(String(lastError).replacingOccurrences(of: "ERROR: ", with: ""))
    }
}
