import Foundation
import Testing
@testable import TranscriberCore

@Suite struct YouTubeURLTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&t=42s",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "  https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ\n"
    ])
    func acceptsVideoURLs(_ raw: String) {
        let url = YouTubeURL(raw)
        #expect(url?.videoID == "dQw4w9WgXcQ")
        #expect(url?.canonical == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test(arguments: [
        "",
        "hola",
        "https://vimeo.com/123456",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/playlist?list=PL123",
        "https://evil.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgX!Q",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ extra"
    ])
    func rejectsInvalidURLs(_ raw: String) {
        #expect(YouTubeURL(raw) == nil)
    }
}

@Suite struct SubtitleParserTests {
    @Test func removesTimestampsTagsAndRollingDuplicates() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: es

        00:00:00.000 --> 00:00:02.000 align:start position:0%
        hola<00:00:00.500><c> a</c><00:00:01.000><c> todos</c>

        00:00:02.000 --> 00:00:02.010 align:start position:0%
        hola a todos

        00:00:02.010 --> 00:00:04.000 align:start position:0%
        hola a todos
        esto<00:00:02.500><c> es</c><00:00:03.000><c> una</c><00:00:03.500><c> prueba</c>

        00:00:04.000 --> 00:00:04.010 align:start position:0%
        esto es una prueba
        """
        #expect(SubtitleParser.plainText(fromVTT: vtt) == "hola a todos esto es una prueba")
    }

    @Test func manualSubtitlesWithCueIDsEntitiesAndCRLF() {
        let vtt = "WEBVTT\r\n\r\nNOTE comentario\r\n\r\n1\r\n00:00:01.000 --> 00:00:03.000\r\n<i>Tom &amp; Jerry</i>\r\nvuelven &gt; nunca\r\n\r\n2\r\n00:00:03.000 --> 00:00:05.000\r\n¡Fin!\r\n"
        #expect(SubtitleParser.plainText(fromVTT: vtt) == "Tom & Jerry vuelven > nunca ¡Fin!")
    }

    @Test func doesNotDoubleDecodeEntities() {
        #expect(SubtitleParser.clean("&amp;lt;b&amp;gt;") == "&lt;b&gt;")
    }

    @Test func keepsNonConsecutiveRepeats() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:01.000
        sí

        00:00:01.000 --> 00:00:02.000
        no

        00:00:02.000 --> 00:00:03.000
        sí
        """
        #expect(SubtitleParser.plainText(fromVTT: vtt) == "sí no sí")
    }

    @Test func splitsLongTextIntoParagraphsAtSentenceEnd() {
        let sentence = String(repeating: "palabra ", count: 40).trimmingCharacters(in: .whitespaces) + "."
        let text = SubtitleParser.paragraphs(from: Array(repeating: sentence, count: 4), targetLength: 500)
        let paragraphs = text.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func emptyInputGivesEmptyText() {
        #expect(SubtitleParser.plainText(fromVTT: "WEBVTT\n\n") == "")
    }
}

@Suite struct SubtitleChoiceTests {
    private func info(language: String?, manual: [String] = [], auto: [String] = []) throws -> VideoInfo {
        func tracks(_ keys: [String]) -> String {
            keys.map { "\"\($0)\": [{\"ext\": \"json3\"}, {\"ext\": \"vtt\"}]" }.joined(separator: ",")
        }
        let languageJSON = language.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": "dQw4w9WgXcQ", "title": "T", "language": \(languageJSON),
         "subtitles": {\(tracks(manual))}, "automatic_captions": {\(tracks(auto))}}
        """
        return try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    @Test func prefersManualInOriginalLanguage() throws {
        let choice = YTDLP.chooseSubtitle(for: try info(language: "es", manual: ["en", "es"], auto: ["es-orig", "es", "en"]))
        #expect(choice == SubtitleChoice(languageKey: "es", isAutomatic: false))
    }

    @Test func matchesRegionalVariant() throws {
        let choice = YTDLP.chooseSubtitle(for: try info(language: "en", manual: ["en-US", "fr"]))
        #expect(choice == SubtitleChoice(languageKey: "en-US", isAutomatic: false))
    }

    @Test func fallsBackToOriginalAutoCaptions() throws {
        let choice = YTDLP.chooseSubtitle(for: try info(language: "es", manual: ["en"], auto: ["en", "es", "es-orig"]))
        #expect(choice == SubtitleChoice(languageKey: "es-orig", isAutomatic: true))
        #expect(choice?.language == "es")
    }

    @Test func infersLanguageFromOrigTrack() throws {
        let choice = YTDLP.chooseSubtitle(for: try info(language: nil, auto: ["de", "fr-orig", "fr"]))
        #expect(choice == SubtitleChoice(languageKey: "fr-orig", isAutomatic: true))
    }

    @Test func ignoresLiveChat() throws {
        #expect(YTDLP.chooseSubtitle(for: try info(language: nil, manual: ["live_chat"])) == nil)
    }

    @Test func noSubtitlesMeansWhisper() throws {
        #expect(YTDLP.chooseSubtitle(for: try info(language: "es")) == nil)
        #expect(YTDLP.chooseSubtitle(for: try info(language: nil, manual: ["en", "es"])) == nil)
    }
}

/// Videos con doblajes automáticos de YouTube: muchas claves "-orig" y una pista de audio por idioma.
/// Claves reales de https://www.youtube.com/watch?v=eoSvKRz5mIc (en inglés, 19 doblajes con IA).
@Suite struct DubbedVideoSubtitleTests {
    static let origKeys = [
        "ar-orig", "bn-orig", "nl-NL-orig", "en-orig", "fr-FR-orig", "de-DE-orig", "iw-orig", "hi-orig", "id-orig",
        "it-orig", "ja-orig", "ko-orig", "ml-orig", "pl-orig", "pt-BR-orig", "es-US-orig", "ta-orig", "te-orig", "uk-orig"
    ]
    static let translatedKeys = ["ar", "de", "en", "es", "fr", "it", "ja", "pt"]
    static let manualKeys = ["en-ehkg1hFWq8A"]
    static let dubbedAudio = ["ar", "bn", "de-DE", "es-US", "fr-FR", "hi", "id", "it", "iw", "ja", "ko", "ml", "nl-NL",
                              "pl", "pt-BR", "ta", "te", "uk"]

    /// Formatos de audio como los arma yt-dlp: el original con `language_preference` 10 y "original" en la nota,
    /// los doblajes con -1, y el mp4 combinado (formato 18) con el idioma de un doblaje.
    static func formats(original: String?) -> String {
        var formats = dubbedAudio.enumerated().map { index, language in
            #"{"format_id": "140-\#(index)", "ext": "m4a", "acodec": "mp4a.40.2", "vcodec": "none", "language": "\#(language)", "language_preference": -1, "format_note": "\#(language), medium"}"#
        }
        if let original {
            formats.append(#"{"format_id": "140-18", "ext": "m4a", "acodec": "mp4a.40.2", "vcodec": "none", "language": "\#(original)", "language_preference": 10, "format_note": "English (US) original (default), medium"}"#)
        }
        formats.append(#"{"format_id": "18", "ext": "mp4", "acodec": "mp4a.40.2", "vcodec": "avc1.42001E", "language": "ar", "language_preference": -1, "format_note": "360p"}"#)
        formats.append(#"{"format_id": "sb0", "ext": "mhtml", "acodec": "none", "vcodec": "none", "format_note": "storyboard"}"#)
        return "[" + formats.joined(separator: ",") + "]"
    }

    static func info(
        language: String?, manual: [String] = manualKeys, auto: [String] = origKeys + translatedKeys, formats: String? = nil
    ) throws -> VideoInfo {
        func tracks(_ keys: [String]) -> String {
            keys.map { "\"\($0)\": [{\"ext\": \"json3\"}, {\"ext\": \"vtt\"}]" }.joined(separator: ",")
        }
        let languageJSON = language.map { "\"\($0)\"" } ?? "null"
        let formatsJSON = formats.map { ", \"formats\": \($0)" } ?? ""
        let json = """
        {"id": "eoSvKRz5mIc", "title": "Soldier and citizen, Houdon's Washington", "language": \(languageJSON),
         "subtitles": {\(tracks(manual))}, "automatic_captions": {\(tracks(auto))}\(formatsJSON)}
        """
        return try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    @Test func languageNilUsesOriginalAudioTrackNotAlphabeticalOrig() throws {
        let info = try Self.info(language: nil, formats: Self.formats(original: "en-US"))
        #expect(info.originalAudioLanguage == "en-US")
        #expect(YTDLP.chooseSubtitle(for: info) == SubtitleChoice(languageKey: "en-ehkg1hFWq8A", isAutomatic: false))
    }

    @Test func languageNilWithoutManualPicksEnglishOrig() throws {
        let info = try Self.info(language: nil, manual: [], formats: Self.formats(original: "en-US"))
        let choice = YTDLP.chooseSubtitle(for: info)
        #expect(choice == SubtitleChoice(languageKey: "en-orig", isAutomatic: true))
        #expect(choice?.language == "en")
    }

    @Test func languageNilAndNoOriginalMarkerGoesToWhisper() throws {
        // Sin pista original marcada no hay forma de saber cuál de las 19 "-orig" es la verdadera.
        let withoutFormats = try Self.info(language: nil, manual: [])
        #expect(YTDLP.chooseSubtitle(for: withoutFormats) == nil)
        let onlyDubs = try Self.info(language: nil, manual: [], formats: Self.formats(original: nil))
        #expect(onlyDubs.originalAudioLanguage == nil)
        #expect(YTDLP.chooseSubtitle(for: onlyDubs) == nil)
    }

    @Test func neverPicksArabicForThisVideo() throws {
        for language in [nil, "ar", "en-US"] {
            for formats in [nil, Self.formats(original: nil), Self.formats(original: "en-US")] {
                for manual in [Self.manualKeys, []] {
                    // Sin formatos y con language "ar", yt-dlp no da ninguna otra señal: ese caso no se puede distinguir.
                    if language == "ar" && formats == nil { continue }
                    let choice = YTDLP.chooseSubtitle(for: try Self.info(language: language, manual: manual, formats: formats))
                    #expect(choice.map { YTDLP.baseLanguage($0.language) } != "ar",
                            "language=\(language ?? "nil") formats=\(formats != nil) manual=\(manual) -> \(String(describing: choice))")
                }
            }
        }
    }

    @Test func languageEnUSPicksManualEnglish() throws {
        let info = try Self.info(language: "en-US", formats: Self.formats(original: "en-US"))
        #expect(YTDLP.chooseSubtitle(for: info) == SubtitleChoice(languageKey: "en-ehkg1hFWq8A", isAutomatic: false))
    }

    @Test func wrongLanguageFieldLosesToOriginalAudioTrack() throws {
        // Visto en una corrida real: yt-dlp devolvió language "ar" (el idioma del formato 18, doblado).
        let info = try Self.info(language: "ar", manual: [], formats: Self.formats(original: "en-US"))
        #expect(YTDLP.chooseSubtitle(for: info) == SubtitleChoice(languageKey: "en-orig", isAutomatic: true))
    }

    @Test func languageWithManyOrigKeysButNoOriginalMarkerGoesToWhisper() throws {
        let info = try Self.info(language: "en-US", manual: [], formats: Self.formats(original: nil))
        #expect(YTDLP.chooseSubtitle(for: info) == nil)
    }

    @Test func singleOrigKeyKeepsWorkingWithoutLanguage() throws {
        let info = try Self.info(language: nil, manual: [], auto: ["en", "fr-orig", "fr"])
        #expect(YTDLP.chooseSubtitle(for: info) == SubtitleChoice(languageKey: "fr-orig", isAutomatic: true))
    }

    @Test func alwaysUseWhisperIgnoresSubtitles() throws {
        let info = try Self.info(language: "en-US", formats: Self.formats(original: "en-US"))
        #expect(YTDLP.chooseSubtitle(for: info, alwaysUseWhisper: true) == nil)
        #expect(YTDLP.chooseSubtitle(for: info, alwaysUseWhisper: false) != nil)
        let single = try Self.info(language: "fr", manual: ["fr"], auto: ["fr-orig"])
        #expect(YTDLP.chooseSubtitle(for: single, alwaysUseWhisper: true) == nil)
    }

    @Test func audioSelectorPrefersOriginalLanguage() {
        #expect(YTDLP.audioFormatSelector(originalLanguage: "en-US")
            == "bestaudio[ext=m4a][language=en-US]/bestaudio[acodec^=mp4a][language=en-US]/best[ext=mp4][language=en-US]/"
            + YTDLP.audioFormatSelector)
        #expect(YTDLP.audioFormatSelector(originalLanguage: nil) == YTDLP.audioFormatSelector)
        #expect(YTDLP.audioFormatSelector(originalLanguage: "en]/best") == YTDLP.audioFormatSelector)
    }

    @Test func oddFormatFieldsDoNotBreakMetadata() throws {
        let formats = #"[{"acodec": "mp4a.40.2", "language": null, "language_preference": "x", "format_note": 3}, {"acodec": "opus", "language": "en", "language_preference": 10}]"#
        let info = try Self.info(language: nil, manual: [], formats: formats)
        #expect(info.originalAudioLanguage == "en")
    }
}

@Suite struct TranscriptCacheStalenessTests {
    @Test func ignoresSubtitleTranscriptsFromBeforeTheFix() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = TranscriptCache(directory: directory)
        func legacy(_ id: String, source: String) throws {
            let json = #"{"videoID": "\#(id)", "title": "T", "source": "\#(source)", "language": "ar", "text": "x", "createdAt": "2026-11-01T00:00:00Z"}"#
            try Data(json.utf8).write(to: directory.appendingPathComponent("\(id).json"))
        }
        try legacy("aaaaaaaaaaa", source: "autoSubtitles")
        try legacy("bbbbbbbbbbb", source: "manualSubtitles")
        try legacy("ccccccccccc", source: "whisper")
        #expect(cache.load(videoID: "aaaaaaaaaaa") == nil)
        #expect(cache.load(videoID: "bbbbbbbbbbb") == nil)
        #expect(cache.load(videoID: "ccccccccccc")?.text == "x")

        let fresh = Transcript(
            videoID: "ddddddddddd", title: "T", source: .autoSubtitles, language: "en", text: "hi",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try cache.save(fresh)
        #expect(cache.load(videoID: "ddddddddddd") == fresh)
    }
}

@Suite struct YTDLPErrorTests {
    @Test(arguments: [
        ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access", TranscriberError.privateVideo),
        ("ERROR: [youtube] abc: Video unavailable", .unavailable),
        ("ERROR: [youtube] abc: This video is unavailable", .unavailable),
        ("ERROR: [youtube] abc: Sign in to confirm your age.", .ageRestricted),
        ("ERROR: [youtube] abc: Sign in to confirm you're not a bot.", .botCheck),
        ("ERROR: [youtube] abc: Join this channel to get access to members-only content", .membersOnly),
        ("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>", .network),
        ("ERROR: unable to download video data: HTTP Error 403: Forbidden", .downloadForbidden),
        ("ERROR: algo raro", .ytdlpFailed("algo raro"))
    ])
    func mapsStderr(_ stderr: String, _ expected: TranscriberError) {
        #expect(YTDLP.mapError(stderr: stderr) == expected)
    }

    @Test func parsesProgressLines() {
        #expect(YTDLP.parseProgress("YTPROGRESS 50 200") == 0.25)
        #expect(YTDLP.parseProgress("YTPROGRESS 10 NA") == nil)
        #expect(YTDLP.parseProgress("[download] 10%") == nil)
    }
}

@Suite struct TranscriptCacheTests {
    @Test func roundTripsByVideoID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory)
        #expect(cache.load(videoID: "dQw4w9WgXcQ") == nil)

        let transcript = Transcript(
            videoID: "dQw4w9WgXcQ", title: "T", source: .whisper, language: "es", text: "hola",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try cache.save(transcript)
        #expect(cache.load(videoID: "dQw4w9WgXcQ") == transcript)
    }
}

@Suite struct ToolInstallerTests {
    private func makeSource(ytdlp: String, deno: String) throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try ytdlp.write(to: source.appendingPathComponent(ToolInstaller.ytdlpName), atomically: true, encoding: .utf8)
        try deno.write(to: source.appendingPathComponent(ToolInstaller.denoName), atomically: true, encoding: .utf8)
        return source
    }

    private func read(_ dir: URL, _ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func copiesExecutablesWithoutQuarantine() throws {
        let source = try makeSource(ytdlp: "ytdlp-v1", deno: "deno-v1")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        for name in [ToolInstaller.ytdlpName, ToolInstaller.denoName] {
            let path = source.appendingPathComponent(name).path
            #expect(setxattr(path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0) == 0)
        }

        try ToolInstaller(source: source, destination: destination).install()

        for name in [ToolInstaller.ytdlpName, ToolInstaller.denoName] {
            let path = destination.appendingPathComponent(name).path
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
        }
    }

    @Test func keepsUpdatedYtdlpButRefreshesChangedDeno() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try makeSource(ytdlp: "ytdlp-v1", deno: "deno-v1")
        let second = try makeSource(ytdlp: "ytdlp-v0-bundled", deno: "deno-v2-larger")
        defer {
            [first, second, destination].forEach { try? FileManager.default.removeItem(at: $0) }
        }

        try ToolInstaller(source: first, destination: destination).install()
        // Simula una autoactualización de yt-dlp.
        try "ytdlp-v9-updated".write(to: destination.appendingPathComponent(ToolInstaller.ytdlpName), atomically: true, encoding: .utf8)
        try ToolInstaller(source: second, destination: destination).install()

        #expect(try read(destination, ToolInstaller.ytdlpName) == "ytdlp-v9-updated")
        #expect(try read(destination, ToolInstaller.denoName) == "deno-v2-larger")
    }

    @Test func failsClearlyWhenBundleIsIncomplete() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(throws: TranscriberError.toolsInstallFailed("falta yt-dlp en el paquete de la app")) {
            try ToolInstaller(source: source, destination: destination).install()
        }
    }
}

@Suite struct YTDLPUpdateTests {
    @Test func detectsUpdateOutput() {
        #expect(YTDLP.didUpdate(output: "Current version: 2026.10.21\nUpdated yt-dlp to stable@2026.11.02"))
        #expect(!YTDLP.didUpdate(output: "Latest version: stable@2026.10.21\nyt-dlp is up to date (stable@2026.10.21)"))
    }

    @Test func homebrewCopyIsNotManaged() {
        #expect(!YTDLP(executable: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"), toolsDirectory: nil).isManaged)
    }
}
