public import Foundation
public import MancoraPlugins

/// A Fiji folder, laid out as Fiji's own downloads unpack
/// (`fiji-latest-<platform>-jdk.zip`, see ``FijiDistribution``):
///
///     fiji-linux-x64, Fiji.app/Contents/MacOS/fiji-macos-arm64, fiji-windows-x64.exe
///                                  Fiji's Jaunch launchers (Mancora starts Java itself)
///     config/jaunch/fiji.toml      the launchers' configuration, whose Java options Mancora mirrors
///     java/<platform>/<jdk>/       the bundled JDK; on macOS its home is <jdk>/zulu-21.jdk/Contents/Home
///     jars/*.jar, jars/*/*.jar     ImageJ2, SciJava and Fiji's libraries (platform folders: this platform's only);
///                                  ImageJ 1.x is Fiji's own jars/ij-<version>.jar
///     plugins/*.jar, plugins/*/*.jar   ImageJ 1.x plugins
///     lib/<platform>/              native libraries
///     db.xml.gz                    the update sites and what they installed, as Fiji's updater keeps it
///
/// A Fiji without Java of its own (`fiji-latest-portable-nojava.zip`, or
/// one put together from its update sites, which don't carry Java) runs on
/// the JDK `MANCORA_JAVA_HOME` or `JAVA_HOME` names, if it is Java 11 or newer.
public struct FijiInstallation: Sendable, Hashable {
    public let root: URL
    /// The updater's name for the platform it runs on (``Platforms/current``).
    public let platform: String
    /// The Java home used when Fiji has none bundled: `MANCORA_JAVA_HOME`,
    /// else `JAVA_HOME`, when it holds Java 11 or newer.
    public let fallbackJavaHome: URL?

    public init(
        root: URL, platform: String = Platforms.current, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.root = root
        self.platform = platform
        fallbackJavaHome = Self.javaHome(environment: environment)
    }

    /// `MANCORA_JAVA_HOME` or `JAVA_HOME`, if it holds a `java` of version 11 or newer.
    static func javaHome(environment: [String: String]) -> URL? {
        for key in ["MANCORA_JAVA_HOME", "JAVA_HOME"] {
            guard let path = environment[key], !path.isEmpty else { continue }
            let home = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: java(in: home).path),
                let major = javaVersion(home: home).flatMap({ Int($0.prefix { $0.isNumber }) }), major >= 11
            else { continue }
            return home
        }
        return nil
    }

    public var jars: URL { root.appendingPathComponent("jars") }
    public var plugins: URL { root.appendingPathComponent("plugins") }
    public var nativeLibraries: URL { root.appendingPathComponent("lib").appendingPathComponent(platform) }
    /// Fiji's icon, as its launcher gives the Dock and window managers.
    public var icon: URL? { existing(root.appendingPathComponent("images/icon.png")) }

    /// Whether this is a Fiji Mancora can run: Fiji's ImageJ 1.x, the
    /// legacy layer that lets ImageJ2 run it, and Java (bundled, or the fallback).
    public var isComplete: Bool { imageJJar != nil && jar(named: "imagej-legacy") != nil && javaExecutable != nil }

    // MARK: Jars

    /// Fiji's ImageJ 1.x: `jars/ij-<version>.jar`.
    public var imageJJar: URL? { jar(named: "ij") }

    /// `jars/<name>-<version>.jar` (or `jars/<name>.jar`), the newest name if several.
    func jar(named name: String) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: jars.path)) ?? [])
            .filter { FilenameVersion.strip("jars/" + $0) == "jars/\(name).jar" }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return names.last.map { jars.appendingPathComponent($0) }
    }

    /// The version in a jar's name: `fiji-2.18.1-SNAPSHOT.jar` → `2.18.1-SNAPSHOT`.
    static func version(of jar: URL?, name: String) -> String? {
        guard let file = jar?.lastPathComponent, file.hasPrefix(name + "-"), file.hasSuffix(".jar") else { return nil }
        return String(file.dropFirst(name.count + 1).dropLast(4))
    }

    /// What's installed: Fiji's, ImageJ2's and ImageJ 1.x's versions (from
    /// their jars' names), and the bundled Java's.
    public var version: FijiVersion {
        FijiVersion(
            fiji: Self.version(of: jar(named: "fiji"), name: "fiji"),
            imageJ2: Self.version(of: jar(named: "imagej"), name: "imagej"),
            imageJ1: Self.version(of: imageJJar, name: "ij"),
            java: javaHome.flatMap(Self.javaVersion(home:)))
    }

    /// Every jar Fiji's launcher puts on the class path (`fiji.toml`'s
    /// `jvm.classpath`): `jars/*.jar`, `jars/*/*.jar`, `plugins/*.jar` and
    /// `plugins/*/*.jar`, each sorted by name; folders of other platforms'
    /// libraries (`jars/win64`, say) are left out.
    public func classPath() -> [URL] {
        let fm = FileManager.default
        func list(_ folder: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        let otherPlatforms = Set(Platforms.known.filter { !Platforms.matches(platform, $0) })
        var found: [URL] = []
        for folder in [jars, plugins] {
            let names = list(folder)
            found += names.filter { $0.hasSuffix(".jar") }.map { folder.appendingPathComponent($0) }
                .filter { !isDirectory($0) }
            for sub in names where isDirectory(folder.appendingPathComponent(sub)) {
                if folder == jars && otherPlatforms.contains(sub) { continue }
                let subfolder = folder.appendingPathComponent(sub)
                found += list(subfolder).filter { $0.hasSuffix(".jar") }.map { subfolder.appendingPathComponent($0) }
                    .filter { !isDirectory($0) }
            }
        }
        return found
    }

    /// `jars/<platform>`, when it holds JavaFX's modules, which Fiji's launcher puts on the module path.
    public var javaFXModulePath: URL? {
        let folder = jars.appendingPathComponent(platform)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix("javafx-base") && $0.hasSuffix(".jar") } ? folder : nil
    }

    // MARK: Java

    /// The JDK the helper runs on: the bundled one, else ``fallbackJavaHome``.
    public var javaHome: URL? { bundledJavaHome ?? fallbackJavaHome }

    /// The bundled JDK's home: `java/<platform>/<jdk>/` (on macOS, the
    /// `.jdk` bundle's `Contents/Home` inside it), the newest if several.
    public var bundledJavaHome: URL? {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("java").appendingPathComponent(platform)
        let jdks = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        var homes: [URL] = []
        for jdk in jdks {
            let base = folder.appendingPathComponent(jdk)
            var candidates = [base.appendingPathComponent("Contents/Home"), base]
            for bundle in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() where bundle.hasSuffix(".jdk") {
                candidates.insert(base.appendingPathComponent(bundle).appendingPathComponent("Contents/Home"), at: 0)
            }
            if let home = candidates.first(where: { fm.isExecutableFile(atPath: Self.java(in: $0).path) }) { homes.append(home) }
        }
        return homes.max { a, b in
            let (x, y) = (Self.javaVersion(home: a) ?? "", Self.javaVersion(home: b) ?? "")
            return x != y ? x.compare(y, options: .numeric) == .orderedAscending : a.path < b.path
        }
    }

    public var javaExecutable: URL? { javaHome.map(Self.java(in:)) }

    /// `javac`: the bundled Java is a JDK, so the helper compiles with it.
    public var javaCompiler: URL? {
        guard let home = javaHome else { return nil }
        let javac = home.appendingPathComponent("bin").appendingPathComponent(Self.isWindows ? "javac.exe" : "javac")
        return FileManager.default.isExecutableFile(atPath: javac.path) ? javac : nil
    }

    static func java(in home: URL) -> URL {
        home.appendingPathComponent("bin").appendingPathComponent(isWindows ? "java.exe" : "java")
    }

    /// `JAVA_VERSION` in the JDK's `release` file.
    static func javaVersion(home: URL) -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("JAVA_VERSION=") {
            return line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
    }

    static var isWindows: Bool {
        #if os(Windows)
        true
        #else
        false
        #endif
    }

    // MARK: Launching

    /// The Java options Fiji's launcher gives (`config/jaunch/fiji.toml` and
    /// `jvm.toml`), for the class path to start ImageJ2 the way Fiji does:
    /// the heap (75% of memory unless given), the module access ImageJ 1.x's
    /// patcher and native libraries need, JavaFX's modules, and the
    /// properties that tell ImageJ, SciJava and native loaders where Fiji is.
    /// The class path and main class are the caller's.
    public func javaOptions(maximumHeapMegabytes: Int? = nil, javaMajorVersion: Int = 21) -> [String] {
        let dir = root.path
        var options = [maximumHeapMegabytes.map { "-Xmx\($0)m" } ?? "-XX:MaxRAMPercentage=75"]
        if javaMajorVersion >= 9 {
            options += ["--add-opens=java.base/java.lang=ALL-UNNAMED", "-Dscijava.app.unlock-modules=true"]
            if let modules = javaFXModulePath {
                options += [
                    "--module-path=\(modules.path)",
                    "--add-modules=javafx.base,javafx.controls,javafx.fxml,javafx.graphics,javafx.media,javafx.web",
                ]
            }
        }
        if javaMajorVersion >= 17 { options.append("--enable-native-access=ALL-UNNAMED") }
        options += [
            "-XX:+UseG1GC",
            "-Dpython.cachedir.skip=true",
            "-Dplugins.dir=\(dir)", "-Dimagej.dir=\(dir)", "-Dij.dir=\(dir)", "-Dfiji.dir=\(dir)",
            "-Djava.library.path=\(nativeLibraries.path)", "-Djna.library.path=\(nativeLibraries.path)",
            "-Dscijava.app.name=Fiji", "-Dscijava.app.directory=\(dir)",
            "-Dscijava.context.strict=false",
            "-Dsun.java2d.uiScale=true",
            "-Dpython.console.encoding=UTF-8",
            "-Dfile.encoding=UTF-8",
        ]
        return options
    }
}

/// The versions in a Fiji installation.
public struct FijiVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Fiji's own, e.g. `2.18.1-SNAPSHOT` (`jars/fiji-<version>.jar`).
    public var fiji: String?
    /// ImageJ2's, e.g. `2.18.0`.
    public var imageJ2: String?
    /// ImageJ 1.x's, e.g. `1.54p`.
    public var imageJ1: String?
    /// The bundled Java's, e.g. `21.0.7`.
    public var java: String?

    public init(fiji: String? = nil, imageJ2: String? = nil, imageJ1: String? = nil, java: String? = nil) {
        self.fiji = fiji
        self.imageJ2 = imageJ2
        self.imageJ1 = imageJ1
        self.java = java
    }

    public var description: String {
        var details: [String] = []
        if let imageJ2 { details.append("ImageJ \(imageJ2)" + (imageJ1.map { "/\($0)" } ?? "")) } else if let imageJ1 { details.append("ImageJ \(imageJ1)") }
        if let java { details.append("Java \(java)") }
        return "Fiji \(fiji ?? "(unknown version)")" + (details.isEmpty ? "" : " (" + details.joined(separator: ", ") + ")")
    }
}

func existing(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }
