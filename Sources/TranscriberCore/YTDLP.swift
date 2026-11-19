import Foundation

/// Metadata mínima de `yt-dlp -J`.
public struct VideoInfo: Decodable, Sendable {
    public let id: String
    public let title: String
    public let language: String?
    public let liveStatus: String?
    public let subtitles: [String: [SubtitleTrack]]?
    public let automaticCaptions: [String: [SubtitleTrack]]?
    public let formats: [Format]?

    public struct SubtitleTrack: Decodable, Sendable {
        public let ext: String?
    }

    /// Lo justo de cada formato para reconocer la pista de audio original entre los doblajes.
    /// Cada campo se lee por separado: un valor raro en un formato no invalida toda la metadata.
    public struct Format: Decodable, Sendable {
        public let acodec: String?
        public let language: String?
        public let languagePreference: Int?
        public let formatNote: String?

        enum CodingKeys: String, CodingKey {
            case acodec, language
            case languagePreference = "language_preference"
            case formatNote = "format_note"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            acodec = try? container.decodeIfPresent(String.self, forKey: .acodec)
            language = try? container.decodeIfPresent(String.self, forKey: .language)
            languagePreference = try? container.decodeIfPresent(Int.self, forKey: .languagePreference)
            formatNote = try? container.decodeIfPresent(String.self, forKey: .formatNote)
        }

        var hasAudio: Bool { acodec != nil && acodec != "none" }

        /// yt-dlp marca la pista original de YouTube con `language_preference` 10 y "original" en la nota.
        var isOriginalAudio: Bool {
            guard hasAudio else { return false }
            return (languagePreference ?? Int.min) >= 10 || (formatNote?.localizedCaseInsensitiveContains("original") ?? false)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, language, subtitles, formats
        case liveStatus = "live_status"
        case automaticCaptions = "automatic_captions"
    }

    /// Idioma de la pista de audio marcada como original, si hay una sola candidata.
    /// Con doblajes automáticos, `language` puede venir vacío o con el idioma de un doblaje.
    public var originalAudioLanguage: String? {
        let languages = Set((formats ?? []).filter(\.isOriginalAudio).compactMap(\.language).filter { !$0.isEmpty })
        return languages.count == 1 ? languages.first : nil
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

    /// Con doblajes, primero la pista en el idioma original: el mp4 combinado puede traer un doblaje.
    static func audioFormatSelector(originalLanguage: String?) -> String {
        guard let language = originalLanguage,
              language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return audioFormatSelector
        }
        let original = audioFormatSelector.split(separator: "/").map { "\($0)[language=\(language)]" }
        return (original + [audioFormatSelector]).joined(separator: "/")
    }

    /// Baja solo el audio y lo convierte a WAV mono 16 kHz (el formato que usa Whisper), sin ffmpeg.
    public func downloadAudio(
        info: VideoInfo,
        infoFile: URL,
        workDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let result = try await run(
            commonArguments + [
                "--load-info-json", infoFile.path,
                "-f", Self.audioFormatSelector(originalLanguage: info.originalAudioLanguage),
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
    /// Con `alwaysUseWhisper` no elige ninguno, así se transcribe el audio.
    public static func chooseSubtitle(for info: VideoInfo, alwaysUseWhisper: Bool = false) -> SubtitleChoice? {
        guard !alwaysUseWhisper else { return nil }
        let manual = (info.subtitles ?? [:]).filter { key, tracks in
            key != "live_chat" && tracks.contains { $0.ext == "vtt" }
        }.keys.sorted()
        let auto = (info.automaticCaptions ?? [:]).filter { _, tracks in
            tracks.contains { $0.ext == "vtt" }
        }.keys.sorted()

        guard let original = originalLanguage(for: info, autoKeys: auto) else {
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

    /// Idioma original del video. Si YouTube agregó doblajes automáticos (varias claves "-orig"),
    /// `language` y el orden de las claves no sirven: solo vale la pista de audio marcada como original.
    static func originalLanguage(for info: VideoInfo, autoKeys: [String]) -> String? {
        if let audio = info.originalAudioLanguage { return audio }
        let origKeys = autoKeys.filter { $0.hasSuffix("-orig") }
        guard origKeys.count <= 1 else { return nil }
        return info.language ?? origKeys.first.map { String($0.dropLast(5)) }
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
