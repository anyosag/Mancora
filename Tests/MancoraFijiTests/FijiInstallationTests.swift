import Foundation
import MancoraPlugins
import Testing

@testable import MancoraFiji

@Suite("Fiji: the installation's layout")
struct FijiInstallationTests {
    @Test func archiveNamesAreFijisDownloads() {
        #expect(FijiDistribution.archiveName(platform: "macos-arm64") == "fiji-latest-macos-arm64-jdk.zip")
        #expect(FijiDistribution.archiveName(platform: "macos64") == "fiji-latest-macos64-jdk.zip")
        #expect(FijiDistribution.archiveName(platform: "linux64") == "fiji-latest-linux64-jdk.zip")
        #expect(FijiDistribution.archiveName(platform: "linux-arm64") == "fiji-latest-linux-arm64-jdk.zip")
        #expect(FijiDistribution.archiveName(platform: "win64") == "fiji-latest-win64-jdk.zip")
        #expect(FijiDistribution.archiveName(platform: "linux32") == nil)
        let linux = FijiDistribution(platform: "linux64")
        #expect(linux.archiveURL?.absoluteString == "https://downloads.imagej.net/fiji/latest/fiji-latest-linux64-jdk.zip")
        #expect(linux.checksumURL?.absoluteString == "https://downloads.imagej.net/fiji/latest/fiji-latest-linux64-jdk.zip.sha256")
        // Every platform the updater knows that Fiji publishes for.
        #expect(FijiDistribution(platform: Platforms.current).archiveName != nil || Platforms.current.hasPrefix("win"))
    }

    @Test func publishedChecksumsAreRead() {
        let digest = "41b8f0e56d24e3db0eaf591109fd4b66089a7b70ffcfd87fbc7238cf60a55fdd"
        #expect(FijiDistribution.parseChecksum(digest + "\n") == digest)
        #expect(FijiDistribution.parseChecksum(digest.uppercased() + "  fiji-latest-linux64-jdk.zip\n") == digest)
        #expect(FijiDistribution.parseChecksum("<html>Not Found</html>") == nil)
        #expect(FijiDistribution.parseChecksum("") == nil)
    }

    @Test func standardLocations() {
        let root = FijiManager.defaultRoot(environment: ["HOME": "/home/ana", "XDG_DATA_HOME": "/data"])
        #if os(macOS)
        #expect(root.path == "/home/ana/Library/Application Support/Mancora/Fiji")
        #elseif os(Linux)
        #expect(root.path == "/data/mancora/Fiji")
        #expect(FijiManager.defaultRoot(environment: ["HOME": "/home/ana"]).path == "/home/ana/.local/share/mancora/Fiji")
        #endif
        #expect(
            FijiManager.defaultRoot(environment: ["HOME": "/home/ana", "MANCORA_FIJI_HOME": "/opt/F"]).path
                == URL(fileURLWithPath: "/opt/F").path)
    }

    @Test(.disabled(if: onWindows, "Fiji runs on macOS and Linux")) func classPathIsFijiLaunchersForThisPlatform() throws {
        let root = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fiji = try FakeFiji.make(at: root)
        let paths = fiji.classPath().map { String($0.path.dropFirst(root.path.count + 1)) }
        // jars/*.jar, jars/*/*.jar (not other platforms'), plugins/*.jar, plugins/*/*.jar, each sorted.
        let platformJar = "jars/\(Platforms.current)/javafx-base-23.0.2.jar"
        let subfolders = ["jars/bio-formats/formats-api-8.5.0.jar", platformJar].sorted()
        #expect(
            paths == [
                "jars/fiji-2.18.1-SNAPSHOT.jar", "jars/fiji-lib-2.1.3.jar", "jars/ij-1.54p.jar", "jars/imagej-2.18.0.jar",
                "jars/imagej-legacy-3.0.0.jar",
            ] + subfolders + ["plugins/Fiji_Plugins-3.2.0.jar", "plugins/Sub/nested.jar"])
        #expect(!paths.contains("jars/win-arm64/elsewhere.jar") || Platforms.current == "win-arm64")
    }

    @Test(.disabled(if: onWindows, "Fiji runs on macOS and Linux")) func javaAndVersionsAreFound() throws {
        let root = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fiji = try FakeFiji.make(at: root)
        #expect(fiji.isComplete)
        #expect(fiji.imageJJar?.lastPathComponent == "ij-1.54p.jar")
        let java = try #require(fiji.javaExecutable)
        #expect(FileManager.default.isExecutableFile(atPath: java.path))
        #expect(fiji.javaCompiler != nil)
        if Platforms.isMac(Platforms.current) { #expect(java.path.contains("/zulu-21.jdk/Contents/Home/bin/")) }
        #expect(fiji.version == FijiVersion(fiji: "2.18.1-SNAPSHOT", imageJ2: "2.18.0", imageJ1: "1.54p", java: "21.0.7"))
        #expect(fiji.version.description == "Fiji 2.18.1-SNAPSHOT (ImageJ 2.18.0/1.54p, Java 21.0.7)")
        #expect(fiji.javaFXModulePath?.lastPathComponent == Platforms.current)
        #expect(fiji.icon?.lastPathComponent == "icon.png")
    }

    @Test(.disabled(if: onWindows, "Fiji runs on macOS and Linux")) func theNewestBundledJavaWins() throws {
        let root = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fiji = try FakeFiji.make(at: root)
        // A newer JDK beside the first, as Fiji's Java upgrade leaves it.
        let newer = root.appendingPathComponent("java/\(Platforms.current)/zulu25-fake")
        var home = newer
        if Platforms.isMac(Platforms.current) { home = newer.appendingPathComponent("zulu-25.jdk/Contents/Home") }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = home.appendingPathComponent("bin/java")
        try Data("#!/bin/sh\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        try Data("JAVA_VERSION=\"25.0.1\"\n".utf8).write(to: home.appendingPathComponent("release"))
        #expect(fiji.javaHome?.standardizedFileURL.path == home.standardizedFileURL.path)
        #expect(fiji.version.java == "25.0.1")
        // Without Java (or ImageJ's legacy layer) it isn't a Fiji Mancora can run.
        try FileManager.default.removeItem(at: root.appendingPathComponent("jars/imagej-legacy-3.0.0.jar"))
        #expect(!fiji.isComplete)
    }

    /// A Fiji without Java of its own (one put together from its update
    /// sites, or Fiji's no-Java download) runs on JAVA_HOME's JDK.
    @Test(.disabled(if: onWindows, "Fiji runs on macOS and Linux")) func withoutBundledJavaJavaHomeRunsIt() throws {
        let folder = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Fiji")
        try FakeFiji.make(at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("java"))
        func jdk(_ name: String, version: String) throws -> URL {
            let home = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
            for tool in ["java", "javac"] {
                let url = home.appendingPathComponent("bin/\(tool)")
                try Data("#!/bin/sh\n".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try Data("JAVA_VERSION=\"\(version)\"\n".utf8).write(to: home.appendingPathComponent("release"))
            return home
        }
        let jdk21 = try jdk("jdk-21", version: "21.0.9"), jdk17 = try jdk("jdk-17", version: "17.0.2")
        let jdk8 = try jdk("jdk-8", version: "1.8.0_392")
        #expect(!FijiInstallation(root: root, environment: [:]).isComplete)
        let fiji = FijiInstallation(root: root, environment: ["JAVA_HOME": jdk21.path])
        #expect(fiji.isComplete)
        #expect(fiji.bundledJavaHome == nil)
        #expect(fiji.javaExecutable?.path == jdk21.appendingPathComponent("bin/java").path)
        #expect(fiji.javaCompiler?.path == jdk21.appendingPathComponent("bin/javac").path)
        #expect(fiji.version.java == "21.0.9")
        // MANCORA_JAVA_HOME first; Java 8 is too old for the helper.
        #expect(FijiInstallation(root: root, environment: ["JAVA_HOME": jdk21.path, "MANCORA_JAVA_HOME": jdk17.path]).version.java == "17.0.2")
        #expect(!FijiInstallation(root: root, environment: ["JAVA_HOME": jdk8.path]).isComplete)
        // Fiji's own Java wins when it has one.
        let bundled = try FakeFiji.make(at: folder.appendingPathComponent("Bundled"))
        let withBoth = FijiInstallation(root: bundled.root, environment: ["JAVA_HOME": jdk17.path])
        #expect(withBoth.version.java == "21.0.7")
    }

    @Test(.disabled(if: onWindows, "Fiji runs on macOS and Linux")) func javaOptionsMirrorFijisLauncher() throws {
        let root = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fiji = try FakeFiji.make(at: root)
        let options = fiji.javaOptions()
        let dir = root.path
        #expect(options.first == "-XX:MaxRAMPercentage=75")
        for expected in [
            "--add-opens=java.base/java.lang=ALL-UNNAMED", "--enable-native-access=ALL-UNNAMED",
            "--module-path=\(dir)/jars/\(Platforms.current)",
            "--add-modules=javafx.base,javafx.controls,javafx.fxml,javafx.graphics,javafx.media,javafx.web",
            "-Dplugins.dir=\(dir)", "-Dimagej.dir=\(dir)", "-Dij.dir=\(dir)", "-Dfiji.dir=\(dir)",
            "-Djava.library.path=\(dir)/lib/\(Platforms.current)", "-Dscijava.context.strict=false", "-Dpython.cachedir.skip=true",
        ] {
            #expect(options.contains(expected), "\(expected)")
        }
        #expect(fiji.javaOptions(maximumHeapMegabytes: 512).first == "-Xmx512m")
        // Java 8 knows no modules.
        #expect(!fiji.javaOptions(javaMajorVersion: 8).contains { $0.hasPrefix("--") })
        // Without JavaFX in jars/<platform>, no module path (Java would refuse to start).
        try FileManager.default.removeItem(at: root.appendingPathComponent("jars/\(Platforms.current)"))
        #expect(!fiji.javaOptions().contains { $0.hasPrefix("--module-path") || $0.hasPrefix("--add-modules") })
    }
}
