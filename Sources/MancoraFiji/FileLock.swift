import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An advisory lock on a file (`flock`), held until released or the
/// process ends, between processes as well as within one: every running
/// helper holds the installation's lock shared, and changing the
/// installation takes it exclusively.
///
/// On Windows the lock is a no-op that always succeeds: there, updates may
/// be applied while a helper runs.
final class FileLock: @unchecked Sendable {
    enum Mode: Sendable { case shared, exclusive }

    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock on `url` (creating the file), waiting for it with
    /// `wait`, or returns `nil` when another holder has it in a conflicting mode.
    static func acquire(_ url: URL, _ mode: Mode, wait: Bool) throws -> FileLock? {
        #if os(Windows)
        return FileLock(descriptor: -1)
        #else
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FijiError.lockFailed(url.path, errno) }
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | (wait ? 0 : LOCK_NB)
        while flock(fd, operation) != 0 {
            let error = errno
            if error == EINTR { continue }
            close(fd)
            if error == EWOULDBLOCK { return nil }
            throw FijiError.lockFailed(url.path, error)
        }
        return FileLock(descriptor: fd)
        #endif
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        #if !os(Windows)
        if descriptor >= 0 { close(descriptor) }
        #endif
        descriptor = -1
    }

    deinit { release() }
}
