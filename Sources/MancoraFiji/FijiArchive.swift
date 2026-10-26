import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Unpacks Fiji's zip archives with the system's own tool, which keeps
/// what Fiji needs from the archive: executable bits (Java, the launchers),
/// symbolic links (the macOS JDK's `bin` and `lib`), and modification times
/// (which Fiji's checksum cache, `.checksums`, is keyed on).
///
/// macOS has `ditto`; Linux needs `unzip` (or `bsdtar`); Windows 10 and
/// later have `tar.exe` (bsdtar).
enum FijiArchive {
    /// The tool and its arguments for `archive` into `folder`.
    static func command(archive: URL, folder: URL, environment: [String: String]) -> (URL, [String])? {
        #if os(macOS)
        return (URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, folder.path])
        #elseif os(Windows)
        let system = environment["SystemRoot"] ?? environment["SYSTEMROOT"] ?? "C:\\Windows"
        return (URL(fileURLWithPath: system + "\\System32\\tar.exe"), ["-x", "-f", archive.path, "-C", folder.path])
        #else
        if let unzip = find("unzip", environment: environment) {
            return (unzip, ["-q", "-o", archive.path, "-d", folder.path])
        }
        if let bsdtar = find("bsdtar", environment: environment) {
            return (bsdtar, ["-x", "-f", archive.path, "-C", folder.path])
        }
        return nil
        #endif
    }

    static func find(_ tool: String, environment: [String: String]) -> URL? {
        let path = (environment["PATH"] ?? "") + ":/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Unpacks `archive` into `folder` (which must exist); cancelling the task stops the tool.
    static func extract(_ archive: URL, into folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
        async throws
    {
        guard let (tool, arguments) = command(archive: archive, folder: folder, environment: environment) else {
            throw FijiError.noUnzip
        }
        let run = ToolRun(tool: tool, arguments: arguments)
        try await withTaskCancellationHandler {
            try await run.wait()
        } onCancel: {
            run.stop()
        }
        try Task.checkCancellation()
    }
}

/// A tool run to completion, its output kept for the error.
final class ToolRun: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopped = false

    init(tool: URL, arguments: [String]) {
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
    }

    func wait() async throws {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if stopped {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                lock.unlock()
                continuation.resume(throwing: FijiError.extractionFailed("\(process.executableURL?.path ?? ""): \(error)"))
                return
            }
            lock.unlock()
            Thread.detachNewThread { [self] in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        if lock.withLock({ stopped }) { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let tool = process.executableURL?.lastPathComponent ?? "unzip"
            throw FijiError.extractionFailed("\(tool) exited with status \(process.terminationStatus): \(text.suffix(2000))")
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let running = process.isRunning
        lock.unlock()
        guard running else { return }
        #if os(Windows)
        process.terminate()
        #else
        kill(process.processIdentifier, SIGKILL)
        #endif
    }
}
