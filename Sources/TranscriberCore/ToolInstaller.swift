import Darwin
import Foundation

/// Copia yt-dlp y deno desde `Contents/Helpers` del bundle a una carpeta escribible del usuario.
/// Ahí yt-dlp se puede autoactualizar, y las copias quedan sin el atributo de cuarentena del zip.
public struct ToolInstaller: Sendable {
    public static let ytdlpName = "yt-dlp"
    public static let denoName = "deno"

    public let source: URL
    public let destination: URL

    public static var defaultDestination: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTTranscriber/bin", isDirectory: true)
    }

    /// Helpers del bundle en ejecución; nil cuando se corre fuera de un .app (por ejemplo con `swift run`).
    public static var bundledHelpers: URL? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil
    }

    public init(source: URL, destination: URL = ToolInstaller.defaultDestination) {
        self.source = source
        self.destination = destination
    }

    /// yt-dlp se copia solo si falta, para no pisar una versión autoactualizada.
    /// deno se reemplaza si cambió el que trae el bundle.
    public func install() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try copy(Self.ytdlpName, replacingIfDifferent: false)
            try copy(Self.denoName, replacingIfDifferent: true)
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.toolsInstallFailed(error.localizedDescription)
        }
    }

    private func copy(_ name: String, replacingIfDifferent: Bool) throws {
        let fm = FileManager.default
        let from = source.appendingPathComponent(name)
        let to = destination.appendingPathComponent(name)
        guard fm.fileExists(atPath: from.path) else {
            throw TranscriberError.toolsInstallFailed("falta \(name) en el paquete de la app")
        }
        if fm.isExecutableFile(atPath: to.path) {
            guard replacingIfDifferent, try !sameSize(from, to) else { return }
        }
        // Copia a un nombre temporal y renombra, para no dejar un binario a medio copiar.
        let temporary = destination.appendingPathComponent(".\(name).\(UUID().uuidString)")
        try fm.copyItem(at: from, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        removexattr(temporary.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        if fm.fileExists(atPath: to.path) {
            _ = try fm.replaceItemAt(to, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: to)
        }
    }

    private func sameSize(_ a: URL, _ b: URL) throws -> Bool {
        let fm = FileManager.default
        let sizeA = try fm.attributesOfItem(atPath: a.path)[.size] as? Int
        let sizeB = try fm.attributesOfItem(atPath: b.path)[.size] as? Int
        return sizeA == sizeB
    }
}
