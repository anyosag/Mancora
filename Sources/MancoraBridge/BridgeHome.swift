public import Foundation
public import MancoraUpdate
import MancoraSupport

/// The folder the bridge helper runs in, laid out like a Fiji installation
/// so ImageJ finds its plugins and update sites can manage it:
///
///     <home>/jars/ij.jar           ImageJ itself
///     <home>/jars/*.jar            libraries (on the helper's class path)
///     <home>/plugins/              ImageJ 1.x plugins and Bio-Formats
///     <home>/helper/<hash>/        the compiled helper
public struct BridgeHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Mancora/Bridge`, `%LOCALAPPDATA%\Mancora\Bridge`
    /// or `$XDG_DATA_HOME/mancora/bridge` (default `~/.local/share`).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeHome {
        if let override = environment["MANCORA_BRIDGE_HOME"] { return BridgeHome(root: URL(fileURLWithPath: override)) }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSTemporaryDirectory()
        #if os(macOS)
        let base = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Mancora/Bridge")
        #elseif os(Windows)
        let local = environment["LOCALAPPDATA"] ?? home
        let base = URL(fileURLWithPath: local).appendingPathComponent("Mancora").appendingPathComponent("Bridge")
        #else
        let data = environment["XDG_DATA_HOME"] ?? (home + "/.local/share")
        let base = URL(fileURLWithPath: data).appendingPathComponent("mancora/bridge")
        #endif
        return BridgeHome(root: base)
    }

    public var jars: URL { root.appendingPathComponent("jars") }
    public var plugins: URL { root.appendingPathComponent("plugins") }
    public var imageJJar: URL { jars.appendingPathComponent("ij.jar") }

    /// The ImageJ release the bridge installs, and the SHA-1 Maven Central publishes for it.
    public static let imageJVersion = "1.54p"

    /// Jars on the helper's class path: ij.jar first, then the other jars.
    public func classPath() -> [URL] {
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: jars.path)) ?? [])
            .filter { $0.hasSuffix(".jar") && $0 != "ij.jar" }
            .sorted()
            .map { jars.appendingPathComponent($0) }
        return [imageJJar] + others
    }

    public func createFolders() throws {
        for dir in [root, jars, plugins] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Downloads ImageJ from Maven Central unless it's already installed,
    /// checking it against the SHA-1 Maven Central publishes alongside it.
    public func installImageJ(client: any HTTPClient) async throws {
        if FileManager.default.fileExists(atPath: imageJJar.path) { return }
        try createFolders()
        let base = "https://repo1.maven.org/maven2/net/imagej/ij/\(Self.imageJVersion)/ij-\(Self.imageJVersion).jar"
        guard let jarURL = URL(string: base), let sumURL = URL(string: base + ".sha1") else { return }
        let expected = String(decoding: try await client.data(from: sumURL), as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)?.lowercased() ?? ""
        let jar = try await client.data(from: jarURL)
        let actual = hexString(SHA1.hash([UInt8](jar)))
        guard actual == expected else {
            throw BridgeError.verificationFailed(file: "ij-\(Self.imageJVersion).jar", expected: expected, actual: actual)
        }
        try jar.write(to: imageJJar, options: .atomic)
    }
}
