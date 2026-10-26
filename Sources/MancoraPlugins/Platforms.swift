public import Foundation

/// The updater's platform names (`net.imagej.updater.util.Platforms`):
/// `linux64`, `linux-arm64`, `macos64`, `macos-arm64`, `win64`,
/// `win-arm64`, the groups `linuxx`, `macosx` and `winx` (any
/// architecture), and the older `linux32` and `win32`.
public enum Platforms {
    /// Launchers and the platform each belongs to.
    static let launchers: [String: String] = [
        "fiji-linux-arm64": "linux-arm64",
        "fiji-linux-x64": "linux64",
        "fiji-windows-arm64.exe": "win-arm64",
        "fiji-windows-x64.exe": "winx",
        "config/jaunch-linux-arm64": "linux-arm64",
        "config/jaunch-linux-x64": "linux64",
        "config/jaunch-windows-arm64.exe": "win-arm64",
        "config/jaunch-windows-x64.exe": "winx",
        "config/jaunch/jaunch-linux-arm64": "linux-arm64",
        "config/jaunch/jaunch-linux-x64": "linux64",
        "config/jaunch/jaunch-windows-arm64.exe": "win-arm64",
        "config/jaunch/jaunch-windows-x64.exe": "winx",
        "ImageJ-linux32": "linux32",
        "ImageJ-linux64": "linux64",
        "Contents/MacOS/ImageJ-macosx": "macosx",
        "Contents/MacOS/ImageJ-tiger": "macosx",
        "ImageJ-win32.exe": "win32",
        "ImageJ-win64.exe": "win64",
    ]

    /// Every platform name, sorted.
    public static let known: [String] = {
        var set = Set(launchers.values)
        for arch in ["64", "-arm64", "x"] {
            for os in ["linux", "macos", "win"] { set.insert(os + arch) }
        }
        return set.sorted()
    }()

    /// The platform this process runs on.
    public static var current: String {
        #if os(macOS)
        let os = "macos"
        #elseif os(Windows)
        let os = "win"
        #else
        let os = "linux"
        #endif
        #if arch(arm64)
        return os + "-arm64"
        #else
        return os + "64"
        #endif
    }

    public static func isWindows(_ platform: String) -> Bool { platform.hasPrefix("win") }
    public static func isMac(_ platform: String) -> Bool { platform.hasPrefix("macos") }
    public static func isLinux(_ platform: String) -> Bool { platform.hasPrefix("linux") }

    /// Whether a file marked for `candidate` belongs on `platform`.
    public static func matches(_ platform: String, _ candidate: String) -> Bool {
        platform == candidate
            || (candidate == "linuxx" && isLinux(platform))
            || (candidate == "macosx" && isMac(platform))
            || (candidate == "winx" && isWindows(platform))
    }

    /// Whether any of the active platforms matches `candidate`.
    public static func matches(active: some Collection<String>, _ candidate: String) -> Bool {
        active.contains { matches($0, candidate) }
    }

    public static func platformForLauncher(_ filename: String) -> String? {
        if let slash = filename.firstIndex(of: "/"), filename[..<slash].hasSuffix(".app") { return "macosx" }
        return launchers[filename]
    }

    public static func isLauncher(_ filename: String) -> Bool {
        if let slash = filename.firstIndex(of: "/"), filename[..<slash].hasSuffix(".app") { return true }
        return launchers[filename] != nil
    }

    /// `inferActive`: the current platform, plus any whose launcher or
    /// platform-specific folder (`jars/<platform>`, `lib/<platform>`) exists.
    public static func inferActive(root: URL?) -> Set<String> {
        var active: Set<String> = [current]
        guard let root else { return active }
        let fm = FileManager.default
        for (launcher, platform) in launchers where fm.fileExists(atPath: root.appendingPathComponent(launcher).path) {
            active.insert(platform)
        }
        for dir in ["jars", "lib"] {
            for platform in known {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: root.appendingPathComponent("\(dir)/\(platform)").path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    active.insert(platform)
                }
            }
        }
        return active
    }
}

/// `org.scijava.util.FileUtils.stripFilenameVersion`: `jars/foo-1.2.3.jar`
/// is the same file as `jars/foo.jar` to the updater.
enum FilenameVersion {
    // Java's \d and \w are ASCII-only; spelled out so ICU reads them the same way.
    static let pattern: NSRegularExpression = {
        let version = "[0-9]+(\\.[0-9]+|[0-9]{7})+[a-z]?[0-9]?(-[A-Za-z0-9.]+?|\\.GA)*?"
        let classifiers = [
            "swing", "swt", "shaded", "sources", "javadoc", "natives?-?[a-zA-Z_0-9]*",
            "(natives-)?(android|linux|macosx|macos|solaris|windows)-"
                + "(aarch64|amd64|arm64|armv6hf|armv6|arm|i386|i486|i586|i686|universal|x86[_-]32|x86[_-]64|x86)",
        ].joined(separator: "|")
        let suffix = "\\.jar(-[a-z]*)?"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "^(.+?)(-\(version))?((-(\(classifiers)))?(\(suffix)))$")
    }()

    static func strip(_ filename: String) -> String {
        let ns = filename as NSString
        guard let match = pattern.firstMatch(in: filename, range: NSRange(location: 0, length: ns.length)) else {
            return filename
        }
        let group1 = match.range(at: 1), group5 = match.range(at: 5)
        let base = group1.location == NSNotFound ? "" : ns.substring(with: group1)
        let tail = group5.location == NSNotFound ? "" : ns.substring(with: group5)
        return base + tail
    }
}
