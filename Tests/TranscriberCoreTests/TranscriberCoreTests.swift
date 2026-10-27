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
