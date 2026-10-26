#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public import Foundation
public import MancoraSupport

/// A published GitHub release, as the releases API returns it.
public struct Release: Sendable, Equatable, Decodable {
    public struct Asset: Sendable, Equatable, Decodable {
        public let name: String
        public let downloadURL: URL
        public let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let pageURL: URL
    public let notes: String?
    public let isPrerelease: Bool
    public let isDraft: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, assets
        case tagName = "tag_name"
        case pageURL = "html_url"
        case notes = "body"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }
}

/// Which download in a release belongs to this computer.
public enum UpdatePlatform: Sendable, Equatable {
    case macOS
    case windows
    case linux(architecture: String)

    public static var current: UpdatePlatform {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #else
        #if arch(arm64)
        return .linux(architecture: "aarch64")
        #else
        return .linux(architecture: "x86_64")
        #endif
        #endif
    }

    /// Matches the file names Tools/package produces.
    public func isInstaller(_ assetName: String) -> Bool {
        switch self {
        case .macOS: assetName.hasPrefix("Mancora-") && assetName.hasSuffix("-macOS.dmg")
        case .windows: assetName.hasPrefix("Mancora-") && assetName.hasSuffix("-Windows-x64-Setup.exe")
        case .linux(let arch): assetName.hasPrefix("mancora-") && assetName.hasSuffix("-linux-\(arch).tar.gz")
        }
    }
}

/// A newer release with an installer for this platform.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: SemanticVersion
    public let release: Release
    public let installer: Release.Asset
    public let checksums: Release.Asset?
}

public enum UpdateError: Error, Equatable, Sendable, CustomStringConvertible {
    case httpStatus(Int, url: String)
    case invalidResponse(String)
    case noChecksums(release: String)
    case checksumMissing(file: String)
    case checksumMismatch(file: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .httpStatus(let status, let url): "The update server returned HTTP \(status) for \(url)."
        case .invalidResponse(let detail): "The update server sent an unexpected response: \(detail)"
        case .noChecksums(let release): "Release \(release) has no SHA256SUMS.txt, so its download can't be verified."
        case .checksumMissing(let file): "SHA256SUMS.txt doesn't list \(file)."
        case .checksumMismatch(let file, let expected, let actual):
            "The download of \(file) is corrupt (SHA-256 \(actual), expected \(expected))."
        }
    }
}

/// Fetches URLs. The default goes through URLSession; tests substitute
/// canned responses.
public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> Data
    /// The body and the server's `Last-Modified` time, if it sent one.
    func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?)
}

extension HTTPClient {
    public func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?) {
        (try await data(from: url), nil)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public let userAgent: String

    public init(userAgent: String) {
        self.userAgent = userAgent
    }

    public func data(from url: URL) async throws -> Data {
        try await dataAndLastModified(from: url).data
    }

    public func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, nil) }
        if !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode, url: url.absoluteString)
        }
        return (data, (http.value(forHTTPHeaderField: "Last-Modified")).flatMap(Self.httpDate))
    }

    /// An HTTP-date in any of the forms RFC 7231 §7.1.1.1 has recipients
    /// accept (as Java's `URLConnection` does): `Sun, 06 Nov 1994 08:49:37 GMT`,
    /// RFC 850's `Sunday, 06-Nov-94 08:49:37 GMT` and asctime's
    /// `Sun Nov  6 08:49:37 1994`.
    public static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // asctime pads a one-digit day with a second space.
        let spaced = text.split(separator: " ").joined(separator: " ")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: spaced) { return date }
        }
        return nil
    }
}

/// Looks for newer Mancora releases on GitHub and downloads them, verified
/// against the release's `SHA256SUMS.txt`.
public struct UpdateChecker: Sendable {
    public static let defaultRepository = "anyosag/Mancora"

    public let repository: String
    public let currentVersion: SemanticVersion
    public let platform: UpdatePlatform
    private let client: any HTTPClient

    public init(
        currentVersion: SemanticVersion,
        repository: String = UpdateChecker.defaultRepository,
        platform: UpdatePlatform = .current,
        client: (any HTTPClient)? = nil
    ) {
        self.currentVersion = currentVersion
        self.repository = repository
        self.platform = platform
        self.client = client ?? URLSessionHTTPClient(userAgent: "Mancora/\(currentVersion)")
    }

    /// Pre-releases count as updates while Mancora itself is pre-1.0 or a
    /// pre-release, so preview users keep moving forward.
    public var includesPrereleases: Bool { currentVersion.major == 0 || currentVersion.isPrerelease }

    public func releases() async throws -> [Release] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else {
            throw UpdateError.invalidResponse("bad repository name \(repository)")
        }
        let data = try await client.data(from: url)
        do {
            return try JSONDecoder().decode([Release].self, from: data)
        } catch {
            throw UpdateError.invalidResponse("\(error)")
        }
    }

    /// The newest release that is newer than this one and has an installer
    /// for this platform, or `nil` if Mancora is up to date.
    public func availableUpdate() async throws -> AvailableUpdate? {
        Self.newestUpdate(in: try await releases(), after: currentVersion, platform: platform,
                          includePrereleases: includesPrereleases)
    }

    public static func newestUpdate(
        in releases: [Release],
        after current: SemanticVersion,
        platform: UpdatePlatform,
        includePrereleases: Bool
    ) -> AvailableUpdate? {
        var best: AvailableUpdate?
        for release in releases where !release.isDraft && (includePrereleases || !release.isPrerelease) {
            guard let version = release.version, version > current,
                let installer = release.assets.first(where: { platform.isInstaller($0.name) })
            else { continue }
            if best == nil || version > best!.version {
                best = AvailableUpdate(
                    version: version, release: release, installer: installer,
                    checksums: release.assets.first { $0.name == "SHA256SUMS.txt" })
            }
        }
        return best
    }

    /// Downloads the installer and checks it against `SHA256SUMS.txt`.
    public func download(_ update: AvailableUpdate) async throws -> Data {
        guard let checksums = update.checksums else { throw UpdateError.noChecksums(release: update.release.tagName) }
        let sums = Self.parseChecksums(String(decoding: try await client.data(from: checksums.downloadURL), as: UTF8.self))
        guard let expected = sums[update.installer.name] else { throw UpdateError.checksumMissing(file: update.installer.name) }
        let data = try await client.data(from: update.installer.downloadURL)
        let actual = hexString(SHA256.hash([UInt8](data)))
        guard actual == expected.lowercased() else {
            throw UpdateError.checksumMismatch(file: update.installer.name, expected: expected, actual: actual)
        }
        return data
    }

    /// Parses `sha256sum` output: `<hex>  <file>` (or `<hex> *<file>`).
    public static func parseChecksums(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64 else { continue }
            var name = parts[1].drop { $0 == " " }
            if name.first == "*" { name = name.dropFirst() }
            sums[String(name)] = String(parts[0])
        }
        return sums
    }
}

/// When to check again: at most once a day, unless the person asks.
public struct UpdateSchedule: Sendable {
    public var interval: TimeInterval

    public init(interval: TimeInterval = 24 * 60 * 60) {
        self.interval = interval
    }

    public func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}
