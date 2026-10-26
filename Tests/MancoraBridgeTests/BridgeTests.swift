import Foundation
import MancoraCore
import MancoraIO
import MancoraUpdate
import Testing

@testable import MancoraBridge

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
        return !(env["DISPLAY"] ?? "").isEmpty || Bridge.findOnPath("xvfb-run", environment: env) != nil
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
