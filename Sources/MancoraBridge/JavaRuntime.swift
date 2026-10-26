public import Foundation

/// A Java installation the bridge helper can run on.
public struct JavaRuntime: Sendable, Hashable {
    /// The `java` (or, on Windows, `javaw`) executable.
    public let executable: URL
    /// The feature release, e.g. 21 for "21.0.2" and 8 for "1.8.0_392".
    public let majorVersion: Int
    /// `javac`, when this is a JDK; the helper is compiled with it once.
    public let compiler: URL?

    public init(executable: URL, majorVersion: Int, compiler: URL?) {
        self.executable = executable
        self.majorVersion = majorVersion
        self.compiler = compiler
    }

    /// ImageJ 1.54 needs Java 8; the helper uses Java 11 APIs.
    public static let minimumVersion = 11

    static var isWindows: Bool {
        #if os(Windows)
        true
        #else
        false
        #endif
    }

    /// Candidate Java homes, most specific first: `MANCORA_JAVA_HOME`,
    /// `JAVA_HOME`, the Java bundled with a Fiji installation, macOS's
    /// `/usr/libexec/java_home`, then every `java` on `PATH`.
    public static func candidateExecutables(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [URL]
    {
        let exe = isWindows ? "java.exe" : "java"
        var found: [URL] = []
        func addHome(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            found.append(URL(fileURLWithPath: path).appendingPathComponent("bin").appendingPathComponent(exe))
        }
        addHome(environment["MANCORA_JAVA_HOME"])
        addHome(environment["JAVA_HOME"])
        for fiji in fijiLocations(environment: environment) {
            // Fiji.app/java/<platform>/<jdk>/[Contents/Home/]bin/java
            let javaDir = fiji.appendingPathComponent("java")
            guard let platforms = try? FileManager.default.contentsOfDirectory(atPath: javaDir.path) else { continue }
            for platform in platforms.sorted() {
                let platformDir = javaDir.appendingPathComponent(platform)
                for jdk in ((try? FileManager.default.contentsOfDirectory(atPath: platformDir.path)) ?? []).sorted(by: >) {
                    let base = platformDir.appendingPathComponent(jdk)
                    addHome(base.appendingPathComponent("Contents/Home").path)
                    addHome(base.path)
                }
            }
        }
        #if os(macOS)
        if let home = try? run("/usr/libexec/java_home", [], environment: environment)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            addHome(home)
        }
        #endif
        let separator: Character = isWindows ? ";" : ":"
        for dir in (environment["PATH"] ?? environment["Path"] ?? "").split(separator: separator) {
            found.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(exe))
        }
        var seen = Set<String>()
        return found.filter { FileManager.default.isExecutableFile(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func fijiLocations(environment: [String: String]) -> [URL] {
        var paths: [String] = []
        if let fiji = environment["FIJI_HOME"] { paths.append(fiji) }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? ""
        #if os(macOS)
        paths += ["/Applications/Fiji.app", home + "/Applications/Fiji.app"]
        #elseif os(Windows)
        paths += [home + "\\Fiji.app", home + "\\Desktop\\Fiji.app", "C:\\Fiji.app"]
        #else
        paths += [home + "/Fiji.app", home + "/fiji/Fiji.app", "/opt/Fiji.app"]
        #endif
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// The first usable Java (at least ``minimumVersion``), preferring a JDK.
    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> JavaRuntime? {
        let runtimes = candidateExecutables(environment: environment).compactMap { probe($0, environment: environment) }
            .filter { $0.majorVersion >= minimumVersion }
        return runtimes.first { $0.compiler != nil } ?? runtimes.first
    }

    /// Asks `java -version` which release it is.
    public static func probe(_ executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> JavaRuntime?
    {
        guard let output = try? run(executable.path, ["-version"], environment: environment),
            let version = parseMajorVersion(output)
        else { return nil }
        let javac = executable.deletingLastPathComponent().appendingPathComponent(isWindows ? "javac.exe" : "javac")
        let windowed = executable.deletingLastPathComponent().appendingPathComponent("javaw.exe")
        let launcher = isWindows && FileManager.default.isExecutableFile(atPath: windowed.path) ? windowed : executable
        return JavaRuntime(
            executable: launcher, majorVersion: version,
            compiler: FileManager.default.isExecutableFile(atPath: javac.path) ? javac : nil)
    }

    /// The major version in `java -version` output: `version "21.0.2"` → 21,
    /// `version "1.8.0_392"` → 8.
    public static func parseMajorVersion(_ output: String) -> Int? {
        guard let start = output.range(of: "version \"") else { return nil }
        let rest = output[start.upperBound...]
        let number = rest.prefix { $0 != "\"" }
        let parts = number.split(whereSeparator: { !$0.isNumber })
        guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
        return first == 1 && parts.count > 1 ? Int(parts[1]) : first
    }

    /// Runs a tool to completion and returns its combined output, or `nil` if it failed.
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
