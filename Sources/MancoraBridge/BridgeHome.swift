public import Foundation
public import MancoraUpdate
import MancoraPlugins
import MancoraSupport

/// The folder the bridge helper runs in, laid out like a Fiji installation
/// so ImageJ finds its plugins and update sites can manage it:
///
///     <home>/jars/ij.jar           ImageJ itself (or jars/ij-<version>.jar from an update site)
///     <home>/jars/**/*.jar         libraries (on the helper's class path; platform folders only for this one)
///     <home>/lib/<platform>/       native libraries
///     <home>/plugins/              ImageJ 1.x plugins and Bio-Formats
///     <home>/db.xml.gz             the update sites and what they installed (as Fiji keeps it)
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
    /// Native libraries for this platform, as Fiji keeps them.
    public var nativeLibraries: URL { root.appendingPathComponent("lib").appendingPathComponent(Platforms.current) }

    /// ImageJ's jar: `jars/ij.jar` as `mancora bridge setup` installs it, or
    /// the `jars/ij-<version>.jar` the ImageJ update site installs instead.
    public var imageJJar: URL {
        let plain = jars.appendingPathComponent("ij.jar")
        if FileManager.default.fileExists(atPath: plain.path) { return plain }
        let versioned = ((try? FileManager.default.contentsOfDirectory(atPath: jars.path)) ?? [])
            .filter { $0 != "ij.jar" && FilenameVersion.strip("jars/" + $0) == "jars/ij.jar" }
            .sorted()
        return versioned.last.map { jars.appendingPathComponent($0) } ?? plain
    }

    /// Whether ImageJ is installed (`mancora bridge setup`, or an update site).
    public var hasImageJ: Bool { FileManager.default.fileExists(atPath: imageJJar.path) }

    /// The ImageJ release the bridge installs, and the SHA-1 Maven Central publishes for it.
    public static let imageJVersion = "1.54p"

    /// Jars on the helper's class path: ImageJ first, then every jar under
    /// `jars/` (other ImageJ jars and other platforms' folders left out), as
    /// Fiji's launcher builds it.
    public func classPath() -> [URL] {
        let imageJ = imageJJar
        let otherPlatforms = Set(Platforms.known.filter { !Platforms.matches(Platforms.current, $0) })
        var found: [String] = []
        func scan(_ relative: String) {
            let folder = root.appendingPathComponent(relative)
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = relative + "/" + name
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if relative == "jars" && otherPlatforms.contains(name) { continue }
                    scan(path)
                } else if name.hasSuffix(".jar"), FilenameVersion.strip(path) != "jars/ij.jar" {
                    found.append(path)
                }
            }
        }
        scan("jars")
        return [imageJ] + found.map { root.appendingPathComponent($0) }
    }

    public func createFolders() throws {
        for dir in [root, jars, plugins] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Downloads ImageJ from Maven Central unless it's already installed,
    /// checking it against the SHA-1 Maven Central publishes alongside it.
    public func installImageJ(client: any HTTPClient) async throws {
        if hasImageJ { return }
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
        try jar.write(to: jars.appendingPathComponent("ij.jar"), options: .atomic)
    }
}
