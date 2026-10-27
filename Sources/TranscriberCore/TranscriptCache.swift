import Foundation

/// Guarda una transcripción JSON por ID de video.
public struct TranscriptCache: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTTranscriber/transcripts", isDirectory: true)
    }

    public init(directory: URL = TranscriptCache.defaultDirectory) {
        self.directory = directory
    }

    private func fileURL(for videoID: String) -> URL {
        directory.appendingPathComponent("\(videoID).json")
    }

    public func load(videoID: String) -> Transcript? {
        guard let data = try? Data(contentsOf: fileURL(for: videoID)) else { return nil }
        return try? JSONDecoder.cache.decode(Transcript.self, from: data)
    }

    public func save(_ transcript: Transcript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.cache.encode(transcript)
        try data.write(to: fileURL(for: transcript.videoID), options: .atomic)
    }
}

private extension JSONEncoder {
    static var cache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var cache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
