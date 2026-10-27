import Foundation

/// URL de YouTube validada, reducida al ID del video.
public struct YouTubeURL: Equatable, Sendable {
    public let videoID: String

    /// URL canónica sin parámetros de playlist ni tiempo.
    public var canonical: String { "https://www.youtube.com/watch?v=\(videoID)" }

    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]
    private static let pathPrefixes = ["shorts", "embed", "live", "v", "e"]

    /// Devuelve nil si el texto no es una URL de un video de YouTube.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(),
              Self.hosts.contains(host) else { return nil }

        let pathParts = components.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host.hasSuffix("youtu.be") {
            candidate = pathParts.first
        } else if pathParts.first == "watch" {
            candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else if pathParts.count >= 2, Self.pathPrefixes.contains(pathParts[0]) {
            candidate = pathParts[1]
        }

        guard let id = candidate, Self.isValidID(id) else { return nil }
        videoID = id
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}
