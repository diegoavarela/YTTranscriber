import Foundation

public enum TranscriptSource: String, Codable, Sendable {
    case manualSubtitles
    case autoSubtitles
    case whisper

    public var label: String {
        switch self {
        case .manualSubtitles: return "Subtítulos (manuales)"
        case .autoSubtitles: return "Subtítulos (automáticos)"
        case .whisper: return "Whisper"
        }
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let source: TranscriptSource
    public let language: String?
    public let text: String
    public let createdAt: Date

    public init(videoID: String, title: String, source: TranscriptSource, language: String?, text: String, createdAt: Date = Date()) {
        self.videoID = videoID
        self.title = title
        self.source = source
        self.language = language
        self.text = text
        self.createdAt = createdAt
    }
}

public enum TranscriberError: LocalizedError, Equatable {
    case invalidURL
    case ytdlpMissing
    case privateVideo
    case membersOnly
    case ageRestricted
    case botCheck
    case unavailable
    case liveStream
    case network
    case downloadForbidden
    case ytdlpFailed(String)
    case audioNotFound
    case noCompatibleAudio
    case audioConversionFailed
    case toolsInstallFailed(String)
    case emptyTranscription
    case whisperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "La URL no es de un video de YouTube válido."
        case .ytdlpMissing:
            return "No se encontró yt-dlp. Volvé a instalar YTTranscriber desde el zip."
        case .privateVideo:
            return "El video es privado y no se puede acceder."
        case .membersOnly:
            return "El video es exclusivo para miembros del canal."
        case .ageRestricted:
            return "El video tiene restricción de edad y requiere iniciar sesión."
        case .botCheck:
            return "YouTube pidió verificar que no sos un bot. Probá de nuevo más tarde."
        case .unavailable:
            return "El video no está disponible (eliminado, bloqueado o inexistente)."
        case .liveStream:
            return "Las transmisiones en vivo no se pueden transcribir hasta que terminen."
        case .network:
            return "No se pudo conectar con YouTube. Revisá tu conexión a internet."
        case .downloadForbidden:
            return "YouTube rechazó la descarga (HTTP 403), incluso después de actualizar yt-dlp. Probá de nuevo más tarde."
        case .ytdlpFailed(let message):
            return "yt-dlp falló: \(message)"
        case .audioNotFound:
            return "No se pudo obtener el audio del video."
        case .noCompatibleAudio:
            return "YouTube no ofrece este video en un formato de audio compatible (AAC/MP4)."
        case .audioConversionFailed:
            return "No se pudo convertir el audio a WAV."
        case .toolsInstallFailed(let message):
            return "No se pudieron preparar las herramientas internas: \(message)"
        case .emptyTranscription:
            return "La transcripción quedó vacía (¿el video no tiene voz?)."
        case .whisperFailed(let message):
            return "Whisper falló: \(message)"
        }
    }
}
