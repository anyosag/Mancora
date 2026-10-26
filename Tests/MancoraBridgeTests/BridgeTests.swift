import Foundation
import MancoraCore
import MancoraIO
import MancoraUpdate
import Testing

@testable import MancoraBridge
import MancoraPlugins

enum BridgeFixtures {
    static let repoRoot: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        return parts.joined(separator: "/")
    }()

    static func url(_ relative: String) -> URL { URL(fileURLWithPath: repoRoot + "/" + relative) }

    /// Integration tests need ImageJ's jar (`MANCORA_TEST_IJ_JAR`) and a JDK.
    static let imageJJar = ProcessInfo.processInfo.environment["MANCORA_TEST_IJ_JAR"]
    static let java = JavaRuntime.discover()
    static var available: Bool { imageJJar != nil && java?.compiler != nil }

    /// A fresh bridge home with ImageJ installed.
    static func bridge() throws -> Bridge {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bridge-test-\(UUID().uuidString)"))
        try home.createFolders()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: imageJJar!), to: home.imageJJar)
        var config = Bridge.Configuration(
            java: java!, home: home, helperSource: url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 120
        return Bridge(configuration: config)
    }
}

struct CannedClient: HTTPClient {
    let responses: [String: Data]
    func data(from url: URL) async throws -> Data {
        guard let data = responses[url.absoluteString] else { throw UpdateError.httpStatus(404, url: url.absoluteString) }
        return data
    }
}

@Suite("Java bridge: setup")
struct BridgeSetupTests {
    @Test func javaVersions() {
        #expect(JavaRuntime.parseMajorVersion("openjdk version \"21.0.2\" 2024-01-16") == 21)
        #expect(JavaRuntime.parseMajorVersion("java version \"1.8.0_392\"") == 8)
        #expect(JavaRuntime.parseMajorVersion("openjdk version \"17\" 2021-09-14") == 17)
        #expect(JavaRuntime.parseMajorVersion("no version here") == nil)
    }

    @Test func imageJDownloadIsVerified() async throws {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-home-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let jar = Data("not really a jar".utf8)
        let base = "https://repo1.maven.org/maven2/net/imagej/ij/1.54p/ij-1.54p.jar"
        let wrong = CannedClient(responses: [base: jar, base + ".sha1": Data(String(repeating: "0", count: 40).utf8)])
        await #expect(throws: BridgeError.self) { try await home.installImageJ(client: wrong) }
        #expect(!FileManager.default.fileExists(atPath: home.imageJJar.path))
        // Maven's .sha1 files hold the hex digest, sometimes followed by a file name.
        let right = CannedClient(responses: [base: jar, base + ".sha1": Data("38eaf03257a4bc319e4d8a8461543c0a041071f1  ij-1.54p.jar\n".utf8)])
        try await home.installImageJ(client: right)
        #expect(try Data(contentsOf: home.imageJJar) == jar)
    }

    @Test func missingImageJOrCompilerIsReported() async throws {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-home-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let jre = JavaRuntime(executable: URL(fileURLWithPath: "/usr/bin/java"), majorVersion: 21, compiler: nil)
        let bridge = Bridge(configuration: .init(
            java: jre, home: home, helperSource: BridgeFixtures.url("Resources/Bridge/MancoraBridgeHelper.java")))
        await #expect(throws: BridgeError.imageJMissing(path: home.imageJJar.path)) { try await bridge.start() }
        try home.createFolders()
        try Data("jar".utf8).write(to: home.imageJJar)
        await #expect(throws: BridgeError.noCompiler) { try await bridge.start() }
        #expect(home.classPath().first?.lastPathComponent == "ij.jar")
    }

    @Test func classPathFollowsFijisLayout() throws {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-home-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let fm = FileManager.default
        let other = Platforms.current.hasPrefix("win") ? "linux64" : "win64"
        for path in ["jars/ij-1.54f.jar", "jars/a.jar", "jars/sub/b.jar", "jars/\(Platforms.current)/native.jar", "jars/\(other)/skip.jar", "jars/notes.txt"] {
            let url = home.root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        // The ImageJ update site installs ImageJ under its version.
        #expect(home.imageJJar.lastPathComponent == "ij-1.54f.jar")
        #expect(home.hasImageJ)
        let paths = home.classPath().map { String($0.path.dropFirst(home.root.path.count + 1)) }
        #expect(paths == ["jars/ij-1.54f.jar"] + ["jars/a.jar", "jars/sub/b.jar", "jars/\(Platforms.current)/native.jar"].sorted())
        // jars/ij.jar, as `mancora bridge setup` installs it, comes first.
        try Data("x".utf8).write(to: home.jars.appendingPathComponent("ij.jar"))
        #expect(home.imageJJar.lastPathComponent == "ij.jar")
        #expect(!home.classPath().contains { $0.lastPathComponent == "ij-1.54f.jar" })
    }
}

@Suite("Java bridge: ImageJ in a helper process", .enabled(if: BridgeFixtures.available), .serialized)
struct BridgeIntegrationTests {
    let fixture = try! TIFFImporter.read(path: BridgeFixtures.url("Tests/Fixtures/tiff/ij-hyperstack-16bit.tif").path)

    @Test func helloAndCommands() async throws {
        let bridge = try BridgeFixtures.bridge()
        let hello = try await bridge.start()
        #expect(hello.imagej == "1.54p")
        let commands = try await bridge.commands()
        #expect(commands.count >= 400)
        #expect(commands.contains { $0.name == "Gaussian Blur..." && $0.className == "ij.plugin.filter.GaussianBlur" })
        await bridge.stop()
    }

    @Test func filterChangesTheInputInPlace() async throws {
        let bridge = try BridgeFixtures.bridge()
        let result = try await bridge.run("Gaussian Blur...", options: "sigma=2 stack", images: [fixture])
        let output = try #require(result.images.first, "log: \(result.log)")
        #expect(result.images.count == 1)
        #expect(output.replacesInput == 0)
        #expect(output.image.dimensions == fixture.dimensions)
        #expect(output.image.calibration.unit == "µm")
        #expect(output.image.stack[0] != fixture.stack[0])
        await bridge.stop()
    }

    /// Whether the helper gets a display (or a virtual one) and so can build dialogs.
    static var hasDisplay: Bool {
        #if os(Linux)
        let env = ProcessInfo.processInfo.environment
        return !(env["DISPLAY"] ?? "").isEmpty || Bridge.findOnPath("Xvfb", environment: env) != nil
        #else
        return true
        #endif
    }

    @Test func commandsThatOpenDialogsAndMakeNewImages() async throws {
        let bridge = try BridgeFixtures.bridge()
        guard Self.hasDisplay else {
            // Headless without xvfb-run, ImageJ can't build the dialog: the bridge says so.
            await #expect(throws: BridgeError.self) {
                try await bridge.run("Z Project...", options: "projection=[Max Intensity] all", images: [fixture])
            }
            await bridge.stop()
            return
        }
        let result = try await bridge.run("Z Project...", options: "projection=[Max Intensity] all", images: [fixture])
        let projection = try #require(result.images.first)
        #expect(projection.replacesInput == nil)
        #expect(projection.title == "MAX_ij-hyperstack-16bit.tif")
        #expect(projection.image.dimensions == HyperstackDimensions(channels: 2, slices: 1, frames: 4))
        await bridge.stop()
    }

    @Test func macrosLogAndMeasure() async throws {
        let bridge = try BridgeFixtures.bridge()
        let result = try await bridge.runMacro(
            """
            print("title=" + getTitle());
            run("Set Measurements...", "area mean min redirect=None decimal=3");
            run("Measure");
            return "done";
            """, images: [fixture])
        #expect(result.log.contains("title=ij-hyperstack-16bit.tif"))
        #expect(result.value == "done")
        #expect(result.results.columns == ["Area", "Mean", "Min", "Max"])
        #expect(result.results.rows.count == 1)
        await bridge.stop()
    }

    /// The P4 exit test: killing the helper loses nothing, and the next
    /// request starts a new one.
    /// Bridges that start together on a new home (as test suites and app
    /// windows do) compile the helper once between them, and none of them
    /// runs a copy that another is still writing.
    @Test func bridgesStartingTogetherShareTheHelper() async throws {
        let first = try BridgeFixtures.bridge()
        let config = await first.configuration
        let image = fixture
        let bridges = [first] + (1..<6).map { _ in Bridge(configuration: config) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for bridge in bridges {
                group.addTask {
                    let result = try await bridge.run("Invert", images: [image])
                    #expect(result.images.count == 1)
                    #expect(await bridge.launchCount == 1)
                    await bridge.stop()
                }
            }
            try await group.waitForAll()
        }
        let helpers = try FileManager.default.contentsOfDirectory(atPath: config.home.root.appendingPathComponent("helper").path)
        #expect(helpers.count == 1)
        #expect(helpers.allSatisfy { !$0.hasPrefix(".") })
    }

    /// ImageJ shows a modal dialog for every macro error, which the helper
    /// closes; however the close lands, the next request still runs.
    @Test(.enabled(if: hasDisplay)) func macroErrorsNeverHang() async throws {
        let first = try BridgeFixtures.bridge()
        var config = await first.configuration
        config.timeoutSeconds = 20
        config.environment["MANCORA_WATCHDOG_MS"] = "1"
        // Several helpers at once, as the parity suites run them, make the timing vary.
        let bridges = (0..<6).map { _ in Bridge(configuration: config) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for bridge in bridges {
                group.addTask {
                    for i in 0..<100 {
                        let code = "for (i = 0; i < 2; i++) {\n    print(i)\n    print(\"next\");\n}\n"
                        let result = try await bridge.runMacro(i % 2 == 0 ? code : "print(\"start\");\ny = x + 1;\n", images: [])
                        #expect(result.macroError != nil)
                    }
                    await bridge.stop()
                }
            }
            try await group.waitForAll()
        }
    }

    /// A request that times out stops its helper, so the next one doesn't
    /// wait behind it.
    @Test func aTimedOutRequestRestartsTheHelper() async throws {
        let first = try BridgeFixtures.bridge()
        var config = await first.configuration
        config.timeoutSeconds = 3
        let bridge = Bridge(configuration: config)
        await #expect(throws: BridgeError.timedOut(seconds: 3)) {
            try await bridge.runMacro("wait(60000);", images: [])
        }
        let result = try await bridge.runMacro("return \"back\";", images: [])
        #expect(result.value == "back")
        #expect(await bridge.launchCount == 2)
        await bridge.stop()
    }

    @Test func recoversWhenTheHelperIsKilled() async throws {
        let bridge = try BridgeFixtures.bridge()
        try await bridge.start()
        let first = try #require(await bridge.helperProcessIdentifier)
        #if !os(Windows)
        kill(first, SIGKILL)
        #endif
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await bridge.run("Invert", images: [fixture])
        #expect(result.images.count == 1)
        #expect(await bridge.launchCount == 2)
        #expect(await bridge.helperProcessIdentifier != first)

        // A helper that dies mid-request fails that request, then recovers.
        await bridge.crashHelperForTesting()
        let commands = try await bridge.commands()
        #expect(!commands.isEmpty)
        #expect(await bridge.launchCount == 3)
        await bridge.stop()
    }

    /// A request that times out leaves its helper busy with it; the helper is
    /// stopped, so the next request gets a new one instead of queueing behind it.
    @Test func aTimedOutRequestDoesNotHoldUpTheNext() async throws {
        var config = try await BridgeFixtures.bridge().configuration
        config.timeoutSeconds = 5
        let bridge = Bridge(configuration: config)
        try await bridge.start()
        await #expect(throws: BridgeError.timedOut(seconds: 5)) { try await bridge.runMacro("wait(15000);") }
        #expect(try await !bridge.commands().isEmpty)
        #expect(await bridge.launchCount == 2)
        await bridge.stop()
    }

    /// Requests waiting on a helper that dies are all retried on one new helper.
    @Test func concurrentRequestsRetryOnOneNewHelper() async throws {
        let bridge = try BridgeFixtures.bridge()
        try await bridge.start()
        let pid = try #require(await bridge.helperProcessIdentifier)
        async let a = bridge.runMacro("wait(2000); return \"a\";")
        async let b = bridge.runMacro("wait(2000); return \"b\";")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #if !os(Windows)
        kill(pid, SIGKILL)
        #endif
        let values = try await [a, b].map(\.value)
        #expect(values == ["a", "b"])
        #expect(await bridge.launchCount == 2)
        await bridge.stop()
    }

    /// Requests sent at once reach the helper whole, however long they are.
    @Test func concurrentLargeRequestsStayWhole() async throws {
        let bridge = try BridgeFixtures.bridge()
        try await bridge.start()
        let comment = "// " + String(repeating: "x", count: 200_000) + "\n"
        async let busy = bridge.runMacro("wait(1500); return \"busy\";")
        try await Task.sleep(nanoseconds: 300_000_000)
        async let b = bridge.runMacro(comment + "return \"b\";")
        async let c = bridge.runMacro(comment + "return \"c\";")
        async let d = bridge.runMacro(comment + "return \"d\";")
        let values = try await [busy, b, c, d].map(\.value)
        #expect(values == ["busy", "b", "c", "d"])
        await bridge.stop()
    }

    /// Titles and paths outside ASCII reach Java intact even when Mancora runs
    /// in a locale that isn't UTF-8 (where Java's file names would be ASCII).
    @Test func unicodeTitlesAndPathsInAnyLocale() async throws {
        var config = try await BridgeFixtures.bridge().configuration
        config.environment["LC_ALL"] = "C"
        let bridge = Bridge(configuration: config)
        var image = fixture
        image.title = "größe ü 😀.tif"
        let result = try await bridge.runMacro("print(getTitle()); run(\"Invert\", \"stack\");", images: [image])
        #expect(result.log.contains("größe ü 😀.tif"))
        let output = try #require(result.images.first)
        #expect(output.title == "größe ü 😀.tif")
        #expect(output.replacesInput == 0)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mancora open é \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pgm = folder.appendingPathComponent("rämp ü.pgm")
        try Data(Array("P5\n2 1\n255\n".utf8) + [10, 20]).write(to: pgm)
        let opened = try await bridge.open(pgm.path)
        #expect(opened.images.first?.title == "rämp ü.pgm")
        #expect(opened.images.first?.image.stack[0] == .gray8([10, 20]))
        await bridge.stop()
    }

    /// Titles reach ImageJ, and come back, as they are, including ones no
    /// file name can hold.
    @Test func titlesNoFileNameCanHold() async throws {
        let bridge = try BridgeFixtures.bridge()
        for title in ["cells: a/b?", "..", String(repeating: "長", count: 100) + ".tif"] {
            var image = fixture
            image.title = title
            let result = try await bridge.runMacro("print(\"title=\" + getTitle()); run(\"Invert\", \"stack\");", images: [image])
            #expect(result.log.contains("title=" + title), "\(result.log)")
            let output = try #require(result.images.first)
            #expect(output.title == title)
            #expect(output.replacesInput == 0)
        }
        await bridge.stop()
    }

    /// Dialogs nobody can answer don't hang the helper: ImageJ's errors come
    /// back as errors, and "Process all slices?" is answered No.
    @Test(.enabled(if: hasDisplay)) func dialogsAreAnswered() async throws {
        let bridge = try BridgeFixtures.bridge()
        let gray = try Hyperstack(
            title: "gray.tif", stack: ImageStack(width: 4, height: 1, planes: [.gray8([0, 10, 200, 255])]))
        do {
            _ = try await bridge.run("Erode", images: [gray])
            Issue.record("expected ImageJ's error")
        } catch let error as BridgeError {
            #expect(error.description.contains("binary"))
        }
        let stack = try Hyperstack(
            title: "stack.tif",
            stack: ImageStack(width: 2, height: 1, planes: [.gray8([0, 255]), .gray8([0, 255]), .gray8([255, 0])]))
        let result = try await bridge.runMacro("run(\"Invert\");", images: [stack])
        let output = try #require(result.images.first)
        #expect(output.image.stack[0] == .gray8([255, 0]))  // the current slice
        #expect(output.image.stack[2] == .gray8([255, 0]))  // the others untouched
        #expect(result.log.contains("answered No"))
        await bridge.stop()
    }

    @Test func opensOtherFormatsWithImageJ() async throws {
        let bridge = try BridgeFixtures.bridge()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A binary PGM: ImageJ reads it, Mancora doesn't.
        let pgm = folder.appendingPathComponent("ramp.pgm")
        try Data(Array("P5\n4 3\n255\n".utf8) + (0..<12).map { UInt8($0 * 20) }).write(to: pgm)
        let result = try await bridge.open(pgm.path)
        let opened = try #require(result.images.first)
        #expect(result.value == "ImageJ")
        #expect(opened.title == "ramp.pgm")
        #expect(opened.image.width == 4 && opened.image.height == 3)
        #expect(opened.image.stack[0] == .gray8((0..<12).map { UInt8($0 * 20) }))
        // A format nothing installed reads.
        let unknown = folder.appendingPathComponent("data.xyz")
        try Data("?".utf8).write(to: unknown)
        do {
            _ = try await bridge.open(unknown.path)
            Issue.record("expected an error")
        } catch let error as BridgeError {
            #expect(error.description.contains("Bio-Formats isn't installed"), "\(error)")
        }
        await bridge.stop()
    }

    @Test(.enabled(if: hasDisplay)) func dialogsAreDescribedForNativeForms() async throws {
        let bridge = try BridgeFixtures.bridge()
        // Gaussian Blur on a calibrated stack: sigma, scaled units, a preview, and the stack question.
        let blur = try await bridge.describeDialog("Gaussian Blur...", images: [fixture])
        let dialog = try #require(blur.dialogs.first, "no dialog")
        #expect(dialog.title == "Gaussian Blur...")
        #expect(blur.supportsPreview)
        let sigma = try #require(dialog.fields.first { $0.key == "sigma" }, "\(dialog.fields)")
        #expect(sigma.kind == .number)
        #expect(sigma.label.hasPrefix("Sigma"))
        #expect(Double(sigma.value ?? "") != nil)
        #expect(dialog.fields.contains { $0.key == "scaled" && $0.kind == .checkbox })
        #expect(blur.asksForStack)
        #expect(blur.options(["sigma": "3.5", "scaled": "false"], processStack: true) == "sigma=3.5 stack")

        // Analyze Particles: text fields, a choice, checkboxes, keys as ImageJ's recorder writes them.
        let mask = try Hyperstack(
            title: "mask.tif", stack: ImageStack(width: 8, height: 8, planes: [.gray8((0..<64).map { $0 % 9 == 0 ? 255 : 0 })]))
        let particles = try await bridge.describeDialog("Analyze Particles...", images: [mask])
        let fields = try #require(particles.dialogs.first?.fields)
        #expect(fields.first { $0.key == "size" }?.kind == .string)
        #expect(fields.first { $0.key == "show" }?.items?.contains("Outlines") == true)
        #expect(fields.contains { $0.key == "summarize" && $0.kind == .checkbox })
        #expect(!particles.asksForStack)

        // A command without a dialog.
        #expect(try await bridge.describeDialog("Invert", images: [mask]).dialogs.isEmpty)
        await bridge.stop()
    }

    @Test func unknownCommandsAreReported() async throws {
        let bridge = try BridgeFixtures.bridge()
        do {
            _ = try await bridge.run("No Such Command", images: [fixture])
            Issue.record("expected an error")
        } catch let error as BridgeError {
            #expect(error.description.contains("Unrecognized command: \"No Such Command\""))
        }
        // The helper is still usable afterwards.
        #expect(try await bridge.run("Invert", images: [fixture]).images.count == 1)
        await bridge.stop()
    }
}
