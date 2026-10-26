import Foundation
import MancoraCore
import MancoraFiji
import MancoraPlugins
import MancoraUpdate
import Testing

@testable import MancoraBridge

/// The real Fiji, end to end: the latest Linux (or macOS) download installs,
/// the bridge runs inside it (ImageJ 1.x commands, SciJava commands and
/// scripts, Fiji's menus), and its update sites are checked. It needs the
/// network, so it runs only with `MANCORA_NETWORK_TESTS=1` (CI's parity job),
/// and a display or Xvfb on Linux.
///
/// `MANCORA_TEST_FIJI_DOWNLOADS` may name a folder already holding the
/// archive and its `.sha256` (as downloads.imagej.net/fiji/latest/ does),
/// to install from it instead of downloading.
///
/// With `MANCORA_TEST_FIJI_FROM_SITES=1`, Fiji is put together from its own
/// update site instead (Fiji-Latest, https://sites.imagej.net/Fiji/, the one
/// site a downloaded Fiji's `db.xml.gz` enables), every file installed and
/// checked by Mancora's updater as Fiji's updater would, and run on the JDK
/// in `JAVA_HOME` (update sites carry no Java). CI does that: GitHub's
/// runners can't download from downloads.imagej.net.
@Suite(
    "Fiji over the network",
    .enabled(if: ProcessInfo.processInfo.environment["MANCORA_NETWORK_TESTS"] == "1" && Parity.hasDisplay),
    .serialized)
struct FijiNetworkTests {
    static let distribution: FijiDistribution = {
        if let folder = ProcessInfo.processInfo.environment["MANCORA_TEST_FIJI_DOWNLOADS"], !folder.isEmpty {
            return FijiDistribution(baseURL: URL(fileURLWithPath: folder, isDirectory: true))
        }
        return FijiDistribution()
    }()

    static let fromSites = ProcessInfo.processInfo.environment["MANCORA_TEST_FIJI_FROM_SITES"] == "1"
    /// The update site a downloaded Fiji's `db.xml.gz` enables, and the only one.
    static let site = (name: "Fiji-Latest", url: "https://sites.imagej.net/Fiji/")

    static let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-fiji-network-\(UUID().uuidString)")
    static let manager = FijiManager(root: parent.appendingPathComponent("Fiji"), distribution: distribution)

    /// Installs Fiji once for the suite (the first test to ask does it):
    /// from its download, or put together from its update site.
    static func installed() async throws -> FijiManager {
        if !manager.isInstalled {
            if fromSites { try await assembleFromUpdateSite() } else { try await manager.install() }
        }
        return manager
    }

    /// Fiji as its update site holds it, installed as Fiji's updater installs
    /// a site: every file the site lists for this platform, each download
    /// checked against the site's checksum, in a folder renamed into place.
    static func assembleFromUpdateSite() async throws {
        let fm = FileManager.default
        let staging = parent.appendingPathComponent("Fiji.assembling")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let updater = try PluginManager(root: staging)
        try updater.addSite(name: site.name, url: site.url)
        let client = URLSessionHTTPClient(userAgent: "mancora-tests")
        try await updater.refresh(client: client)
        try #require(updater.warnings.isEmpty, "\(updater.warnings)")
        let (changes, conflicts) = updater.plan()
        try #require(conflicts.filter { !$0.isWarning }.isEmpty, "\(conflicts)")
        try #require(changes.count > 500, "the site offers only \(changes.count) files")
        try await updater.apply(client: client)
        try fm.moveItem(at: staging, to: manager.root)
        await manager.refreshStatus()
    }

    static func bridge() async throws -> Bridge {
        let fiji = try await installed()
        let java = try #require(fiji.installation.javaExecutable.flatMap { JavaRuntime.probe($0) }, "Fiji's Java doesn't run")
        let home = BridgeHome(root: parent.appendingPathComponent("Bridge"))
        var config = Bridge.Configuration(
            java: java, home: home, helperSource: Parity.url("Resources/Bridge/MancoraBridgeHelper.java"))
        config.fiji = fiji
        config.timeoutSeconds = 600
        return Bridge(configuration: config)
    }

    @Test func theLatestFijiInstalls() async throws {
        let log = ProgressLog()
        if !Self.manager.isInstalled {
            if Self.fromSites { try await Self.assembleFromUpdateSite() } else { try await Self.manager.install { log.add($0) } }
        }
        let fiji = Self.manager.installation
        #expect(fiji.isComplete, "Java: \(fiji.javaHome?.path ?? "none (set JAVA_HOME to a JDK 11 or newer)")")
        let version = fiji.version
        #expect(version.fiji != nil && version.imageJ2 != nil && version.imageJ1 != nil && version.java != nil, "\(version)")
        #expect(await Self.manager.status == .installed(version))
        if Self.fromSites {
            // The sites carry no Java: JAVA_HOME's runs it.
            #expect(fiji.bundledJavaHome == nil && fiji.fallbackJavaHome != nil)
        } else {
            #expect(await Self.manager.settings.installedFrom?.contains(Self.distribution.archiveName ?? "?") == true)
            #expect(fiji.bundledJavaHome != nil)
        }
        if !log.all.isEmpty {
            #expect(log.all.contains { $0.phase == .downloading && ($0.totalBytes ?? 0) > 100_000_000 })
            #expect(log.all.contains { $0.phase == .unpacking })
        }
        // Fiji's layout as relied on: ImageJ2's legacy layer, TrackMate, Labkit, the JDK, and the updater's database.
        let names = try FileManager.default.contentsOfDirectory(atPath: fiji.jars.path)
        #expect(names.contains { $0.hasPrefix("imagej-legacy-") })
        #expect(names.contains { $0.hasPrefix("TrackMate-") })
        #expect(names.contains { $0.hasPrefix("labkit-ui-") })
        #expect(fiji.javaCompiler != nil)
        let database = try PluginManager(root: fiji.root)
        #expect(database.sites.contains { $0.name == Self.site.name && $0.url == Self.site.url && $0.isActive })
    }

    @Test func imageJAndSciJavaRunInFiji() async throws {
        let bridge = try await Self.bridge()
        let hello = try await bridge.start()
        #expect(hello.isFiji)
        #expect(hello.fiji?["Fiji"] != nil, "\(hello)")
        #expect(hello.imagej.contains("/1."), "\(hello.imagej)")

        // 1. An ImageJ 1.x command on an image: Fiji's patched ij.jar.
        let pixels: [UInt8] = (0..<64).map { UInt8(($0 % 16) * 16) }
        let ramp = try Hyperstack(title: "ramp", stack: ImageStack(width: 16, height: 4, planes: [.gray8(pixels)]))
        let inverted = try await bridge.run("Invert", images: [ramp])
        let output = try #require(inverted.images.first, "log: \(inverted.log)")
        #expect(output.replacesInput == 0)
        let invertedPixels: [UInt8] = pixels.map { 255 - $0 }
        #expect(output.image.stack[0] == .gray8(invertedPixels))

        // 2. Scripts in SciJava's languages, with parameters, images and outputs.
        let groovy = try await bridge.runScript(
            """
            #@ ImagePlus imp
            #@ Integer factor
            #@output Double mean
            mean = imp.getStatistics().mean
            println "mean is " + mean
            return 6 * factor
            """, language: "groovy", parameters: ["factor": 7], images: [ramp])
        #expect(groovy.scriptError == nil, "\(groovy.log)")
        #expect(groovy.value == "42")
        #expect(groovy.outputValues["mean"] == .number(120))
        #expect(groovy.log.contains("mean is 120"))
        let javascript = try await bridge.runScript("1 + 2", language: "JavaScript")
        #expect(javascript.value == "3")
        let python = try await bridge.runScript(
            "#@ String name\n#@output String greeting\ngreeting = 'hello ' + name\n", language: "python", parameters: ["name": "Fiji"])
        #expect(python.outputValues["greeting"] == .string("hello Fiji"), "\(python.log)")
        let failing = try await bridge.runScript("throw new IllegalStateException('boom')", language: "groovy")
        #expect(failing.scriptError?.contains("boom") == true)
        // A SciJava command by class, and an ImageJ 1.x one by menu path, with parameters.
        let info = try await bridge.runCommand("org.scijava.plugins.commands.debug.SystemInformation")
        #expect(info.outputValues["info"]?.string?.contains("ImageJ") == true, "\(info.outputValues.keys)")
        let blurred = try await bridge.runCommand("Process > Filters > Gaussian Blur...", parameters: ["sigma": 2], images: [ramp])
        #expect(blurred.images.first?.replacesInput == 0)
        #expect(blurred.images.first?.image.stack[0] != ramp.stack[0])

        // 3. Fiji's menus: ImageJ 1.x's, Fiji's plugins and SciJava's commands.
        let menus = try await bridge.menus()
        let paths = Set(menus.filter { !$0.isSeparator }.map { $0.path.joined(separator: " > ") })
        #expect(paths.contains("Plugins > Tracking > TrackMate"))
        #expect(paths.contains("File > New > Script..."))
        #expect(paths.contains("Process > Filters > Gaussian Blur..."))
        #expect(menus.contains { $0.kind == .command && $0.path.first == "Plugins" && $0.path.contains("Labkit") })
        #expect(menus.contains { $0.kind == .script })
        #expect(menus.contains { $0.isSeparator })
        #expect(menus.count > 900)
        let languages = try await bridge.scriptLanguages().map(\.name)
        for language in ["Groovy", "JavaScript", "Python (Jython)", "ImageJ Macro", "BeanShell"] {
            #expect(languages.contains(language), "\(languages)")
        }
        await bridge.stop()
    }

    @Test func fijisUpdateSitesAreChecked() async throws {
        let fiji = try await Self.installed()
        let check = try await fiji.checkForUpdates()
        #expect(check.warnings.isEmpty, "\(check.warnings)")
        #expect(check.conflicts.isEmpty, "\(check.conflicts)")
        #expect(await fiji.settings.lastCheck != nil)
        // Applying them (often nothing, a fresh download being current) leaves a Fiji that runs.
        let outcome = try await fiji.applyUpdates()
        #expect(fiji.isInstalled, "\(outcome)")
        let lease = try await fiji.prepareForLaunch()
        lease.release()
        #expect(fiji.isInstalled)
    }
}

/// Recorded progress.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FijiProgress] = []
    func add(_ p: FijiProgress) { lock.withLock { entries.append(p) } }
    var all: [FijiProgress] { lock.withLock { entries } }
}
