import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How to start the helper process.
struct HelperLaunch: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
}

/// One running helper process: requests go to its stdin as JSON lines, and a
/// reader thread hands each answer on stdout to the request with its id.
/// When the process ends, every waiting request fails with
/// ``BridgeError/helperExited(status:)``.
final class HelperConnection: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    /// Held while a request is written: a line longer than the pipe holds goes
    /// in pieces, and another request's pieces mustn't come between them.
    private let writeLock = NSLock()
    // Guarded by `lock`.
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var exitStatus: Int32?
    private var pending = Data()
    /// The end of the helper's standard error, for the error when it stops.
    private var errorTail = Data()
    private static let errorTailLimit = 4096

    init(_ launch: HelperLaunch) throws {
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting
        process.terminationHandler = { [weak self] finished in
            self?.ended(status: finished.terminationStatus)
        }
        try process.run()
        let reader = stdout.fileHandleForReading
        let errors = stderr.fileHandleForReading
        // Read standard error before standard output can report the end, so
        // the error carries what Java printed as it stopped.
        Thread.detachNewThread { [self] in
            while true {
                let chunk = errors.availableData
                if chunk.isEmpty { break }
                lock.lock()
                errorTail.append(chunk)
                if errorTail.count > Self.errorTailLimit { errorTail = errorTail.suffix(Self.errorTailLimit) }
                lock.unlock()
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                received(chunk)
            }
            ended(status: nil)
        }
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus == nil && process.isRunning
    }

    /// Sends one request line and waits for the answer with the same id.
    func send(id: Int, line: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            lock.lock()
            if let status = exitStatus {
                let output = errorOutput
                lock.unlock()
                continuation.resume(throwing: BridgeError.helperExited(status: status, output: output))
                return
            }
            waiting[id] = continuation
            lock.unlock()
            do {
                writeLock.lock()
                defer { writeLock.unlock() }
                try input.write(contentsOf: line + Data([0x0A]))
            } catch {
                fail(id: id, with: BridgeError.helperExited(status: -1))
            }
        }
    }

    /// Fails one waiting request, e.g. after a timeout.
    func fail(id: Int, with error: any Error) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// Stops the helper now. (A SIGTERM could sit blocked: children inherit
    /// the blocked signals of the concurrency thread that launched them.)
    func terminate() {
        guard process.isRunning else { return }
        #if os(Windows)
        process.terminate()
        #else
        kill(process.processIdentifier, SIGKILL)
        #endif
    }

    private func received(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let header = try? JSONDecoder().decode(ResponseHeader.self, from: line), let id = header.id else {
                continue  // not a protocol line; the helper keeps stdout clean, so this is noise
            }
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: Data(line))
        }
    }

    /// Called when stdout closes and again when the process ends; the first
    /// call fails the waiting requests.
    private func ended(status: Int32?) {
        lock.lock()
        let known = status ?? (process.isRunning ? -1 : process.terminationStatus)
        let first = exitStatus == nil
        if first || status != nil { exitStatus = known }
        let stranded = waiting
        waiting = [:]
        lock.unlock()
        if stranded.isEmpty { return }
        // Java's last words can trail the end of standard output a little.
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        let output = errorOutput
        lock.unlock()
        for continuation in stranded.values {
            continuation.resume(throwing: BridgeError.helperExited(status: known, output: output))
        }
    }

    /// The end of standard error as text, from its last whole line. Call with `lock` held.
    private var errorOutput: String {
        var tail = errorTail
        if tail.count == Self.errorTailLimit, let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
