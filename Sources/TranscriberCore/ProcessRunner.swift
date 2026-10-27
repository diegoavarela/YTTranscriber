import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// Ejecuta procesos externos de forma asíncrona y cancelable.
public enum ProcessRunner {
    /// PATH mínimo y predecible, aunque la app se abra desde Finder.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let searchPath = "/opt/homebrew/bin:/usr/local/bin:" + systemPath

    public static func run(
        _ executable: URL,
        arguments: [String],
        path: String = searchPath,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let buffers = OutputBuffers(onStdoutLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            buffers.appendStdout(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            buffers.appendStderr(handle.availableData)
        }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    buffers.appendStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
                    buffers.appendStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    buffers.flush()
                    continuation.resume(returning: buffers.result(exitCode: finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return result
    }
}

/// Acumula stdout/stderr desde los handlers de lectura (que corren en hilos arbitrarios).
private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pendingLine = Data()
    private let onStdoutLine: (@Sendable (String) -> Void)?

    init(onStdoutLine: (@Sendable (String) -> Void)?) {
        self.onStdoutLine = onStdoutLine
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        var completeLines: [String] = []
        lock.lock()
        stdout.append(data)
        if onStdoutLine != nil {
            pendingLine.append(data)
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let lineData = pendingLine[pendingLine.startIndex..<newline]
                completeLines.append(String(decoding: lineData, as: UTF8.self))
                pendingLine.removeSubrange(pendingLine.startIndex...newline)
            }
        }
        lock.unlock()
        completeLines.forEach { onStdoutLine?($0) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let rest = pendingLine
        pendingLine = Data()
        lock.unlock()
        if !rest.isEmpty { onStdoutLine?(String(decoding: rest, as: UTF8.self)) }
    }

    func result(exitCode: Int32) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        return ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}
