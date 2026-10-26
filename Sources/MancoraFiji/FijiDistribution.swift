#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public import Foundation
public import MancoraPlugins
import MancoraUpdate
import MancoraSupport

/// Where Fiji comes from: the archives Fiji publishes at
/// `https://downloads.imagej.net/fiji/latest/`, one per platform, each a
/// `Fiji/` folder with Java bundled, beside its SHA-256 (`<archive>.sha256`,
/// the hex digest alone):
///
///     fiji-latest-macos-arm64-jdk.zip   macOS on Apple silicon
///     fiji-latest-macos64-jdk.zip       macOS on Intel
///     fiji-latest-linux64-jdk.zip       Linux x64
///     fiji-latest-linux-arm64-jdk.zip   Linux arm64
///     fiji-latest-win64-jdk.zip         Windows x64
///     fiji-latest-win-arm64-jdk.zip     Windows arm64
///
/// (`fiji-latest-portable-nojava.zip` holds every platform's launchers and
/// libraries but no Java; `../stable/` holds older releases under other names.)
public struct FijiDistribution: Sendable, Hashable {
    public static let latest = URL(string: "https://downloads.imagej.net/fiji/latest/")!

    /// The folder holding the archives (a `file:` URL works too).
    public var baseURL: URL
    public var platform: String

    public init(baseURL: URL = FijiDistribution.latest, platform: String = Platforms.current) {
        self.baseURL = baseURL
        self.platform = platform
    }

    /// The archive for `platform` (an updater platform name, ``Platforms``), if Fiji publishes one.
    public static func archiveName(platform: String) -> String? {
        ["macos-arm64", "macos64", "linux64", "linux-arm64", "win64", "win-arm64"].contains(platform)
            ? "fiji-latest-\(platform)-jdk.zip" : nil
    }

    public var archiveName: String? { Self.archiveName(platform: platform) }
    public var archiveURL: URL? { archiveName.map { baseURL.appendingPathComponent($0) } }
    public var checksumURL: URL? { archiveName.map { baseURL.appendingPathComponent($0 + ".sha256") } }

    /// The digest in a `.sha256` file: its first word, as `sha256sum` writes it or alone.
    static func parseChecksum(_ text: String) -> String? {
        let word = text.split(whereSeparator: { $0 == " " || $0 == "*" || $0.isNewline }).first.map { $0.lowercased() } ?? ""
        return word.count == 64 && word.allSatisfy(\.isHexDigit) ? word : nil
    }
}

/// Downloads a large file to disk, reporting progress and hashing it as it arrives.
public protocol FijiDownloading: Sendable {
    /// Writes `url`'s contents to `destination` (replacing it), calling
    /// `progress` with the bytes written and the total, when known.
    /// Returns the SHA-256 of what was written. Cancelling the task stops it.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> [UInt8]
}

/// Downloads in ranges of `chunkSize` bytes with `URLSession`, each range
/// retried a few times, so a large archive needs neither memory to match
/// nor a delegate; `file:` URLs are copied the same way.
public struct URLSessionFijiDownloader: FijiDownloading {
    public var userAgent: String
    public var chunkSize: Int64 = 16 << 20
    public var attempts = 3

    public init(userAgent: String) {
        self.userAgent = userAgent
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
        -> [UInt8]
    {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var written: Int64 = 0
        func append(_ data: Data) throws {
            try output.write(contentsOf: data)
            hasher.update([UInt8](data))
            written += Int64(data.count)
        }
        if url.isFileURL {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let total = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(chunkSize)), !data.isEmpty else { break }
                try append(data)
                progress(written, total)
            }
            return hasher.finalize()
        }
        var total: Int64?
        while total == nil || written < total! {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(written)-\(written + chunkSize - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await fetch(request)
            switch response.statusCode {
            case 206:
                total = Self.totalLength(contentRange: response.value(forHTTPHeaderField: "Content-Range")) ?? total
                guard total != nil else { throw UpdateError.invalidResponse("\(url.absoluteString): no Content-Range") }
            case 200 where written == 0:
                // The server sends it all at once.
                total = Int64(data.count)
            default:
                throw UpdateError.httpStatus(response.statusCode, url: url.absoluteString)
            }
            guard !data.isEmpty || written == total else {
                throw UpdateError.invalidResponse("\(url.absoluteString) ended after \(written) bytes")
            }
            try append(data)
            progress(written, total)
        }
        return hasher.finalize()
    }

    /// One request, retried after a pause when the connection fails (not when the server says no).
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateError.invalidResponse("not an HTTP response for \(request.url?.absoluteString ?? "")")
                }
                return (data, http)
            } catch let error as UpdateError {
                throw error
            } catch {
                if error is CancellationError || attempt >= attempts { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                attempt += 1
            }
        }
    }

    /// The total in `bytes 0-99/1234`.
    static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
