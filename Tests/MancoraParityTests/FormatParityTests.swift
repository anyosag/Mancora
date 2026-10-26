import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import Testing

@testable import MancoraBridge
@testable import MancoraMacro

/// File formats against ImageJ 1.54p: every PNG, GIF and ZIP fixture opens
/// natively as ImageJ opens it (through the bridge's `open`); what Mancora
/// writes, ImageJ reads exactly as it reads what it writes itself; and
/// tables saved by the same macro are the same files.
@Suite(
    "ImageJ parity: file formats", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"),
    .serialized)
struct FormatParityTests {
    static func withBridge(_ body: (Bridge) async throws -> Void) async throws {
        var config = Bridge.Configuration(
            java: Parity.java!, home: Parity.home, helperSource: Parity.url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: Parity.url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 300
        config.maximumHeapMegabytes = 512
        let bridge = Bridge(configuration: config)
        do {
            _ = try await bridge.start()
            try await body(bridge)
        } catch {
            await bridge.stop()
            throw error
        }
        await bridge.stop()
    }

    static func temporaryDirectory(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-formats-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path + "/"
    }

    /// The differences between Mancora's and ImageJ's reading of `path`.
    static func readingDifferences(_ path: String, bridge: Bridge) async throws -> [String] {
        let result = try await bridge.open(path)
        guard result.images.count == 1, let imageJ = result.images.first else {
            return ["ImageJ opened \(result.images.count) images"]
        }
        let native = try Parity.roundTrip(ImageOpener.read(path: path))
        return ImageComparison.differences(native, imageJ.image, tolerance: 0)
    }

    @Test func fixturesOpenAsInImageJ() async throws {
        let root = Parity.repoRoot + "/Tests/Fixtures/"
        var paths: [String] = []
        for folder in ["png", "gif"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: root + folder).filter { !$0.hasSuffix(".json") }
            paths += names.sorted().map { root + folder + "/" + $0 }
        }
        paths += ["stack.zip", "stack-stored.zip", "hyperstack.zip"].map { root + "zip/" + $0 }
        try await Self.withBridge { bridge in
            for path in paths {
                for difference in try await Self.readingDifferences(path, bridge: bridge) {
                    Issue.record("\((path as NSString).lastPathComponent): \(difference)")
                }
            }
        }
    }

    /// Images to save, as ImageJ opens them from the TIFF the bridge hands it.
    static func writtenInputs() throws -> [(String, Hyperstack)] {
        var inputs: [(String, Hyperstack)] = []
        for input in [ParityInput.gray8, .gray16, .gray32, .rgb, .stack8, .stack16, .hyperstack, .calibrated, .fixtureFire,
            .fixtureHyperstack, .namedROI]
        {
            inputs.append((input.rawValue, try input.image()))
        }
        // Display ranges and LUTs change what PNG and GIF save.
        var ranged = try ParityInput.gray8.image()
        var display = ranged.channels[0]
        display.displayRange = 40...180
        ranged.setDisplay(display, forChannel: 0)
        inputs.append(("gray8 shown 40-180", try Parity.roundTrip(ranged)))
        var fire = try ParityInput.fixtureFire.image()
        display = fire.channels[0]
        display.displayRange = 20...100
        fire.setDisplay(display, forChannel: 0)
        inputs.append(("Fire shown 20-100", try Parity.roundTrip(fire)))
        inputs.append(("16-bit inverted LUT", try TIFFImporter.read(path: Parity.url("Tests/Fixtures/tiff/ij-16bit-lut-inverted.tif").path)))
        var fireStack = try ParityInput.stack8.image()
        for c in 0..<fireStack.channels.count {
            var d = fireStack.channels[c]
            d.lut = .fire
            fireStack.setDisplay(d, forChannel: c)
        }
        fireStack.calibration.fps = 12
        inputs.append(("8-bit stack with Fire at 12 fps", try Parity.roundTrip(fireStack)))
        let base = try ParityInput.stack8.image()
        let alpha = try Hyperstack(
            title: "rgba.tif",
            stack: ImageStack(width: base.width, height: base.height, planes: Array(base.stack.planes.prefix(4)),
                labels: ["Red", "Green", "Blue", "alpha"]))
        inputs.append(("alpha stack", try Parity.roundTrip(alpha)))
        return inputs
    }

    /// Saves each input natively and in ImageJ, then opens both files in
    /// ImageJ (which must see the same image) and natively (which must
    /// see what ImageJ sees).
    func checkWriting(_ format: ImageSaver.Format, macroFormat: String, skip: (String, Hyperstack) -> Bool = { _, _ in false })
        async throws
    {
        let mine = try Self.temporaryDirectory("mancora"), theirs = try Self.temporaryDirectory("imagej")
        var compared = 0
        try await Self.withBridge { bridge in
            for (name, input) in try Self.writtenInputs() where !skip(name, input) {
                compared += 1
                let file = "out" + format.fileExtension
                try ImageSaver.write(input, to: mine + file, format: format)
                let saved = try await bridge.runMacro("saveAs(\"\(macroFormat)\", \"\(theirs + file)\");", images: [input])
                if let error = saved.macroError {
                    Issue.record("\(name): ImageJ couldn't save: \(error)")
                    continue
                }
                let fromMancora = try await bridge.open(mine + file), fromImageJ = try await bridge.open(theirs + file)
                guard let a = fromMancora.images.first?.image, let b = fromImageJ.images.first?.image else {
                    Issue.record("\(name): ImageJ opened nothing")
                    continue
                }
                for difference in ImageComparison.differences(a, b, tolerance: 0) {
                    Issue.record("\(name) as \(format): ImageJ reads Mancora's file differently: \(difference)")
                }
                for (path, imageJ) in [(mine + file, a), (theirs + file, b)] {
                    let native = try Parity.roundTrip(ImageOpener.read(path: path))
                    for difference in ImageComparison.differences(native, imageJ, tolerance: 0) {
                        let whose = path.hasPrefix(mine) ? "Mancora's" : "ImageJ's"
                        Issue.record("\(name) as \(format): Mancora reads \(whose) file differently: \(difference)")
                    }
                }
            }
        }
        #expect(compared >= 10)
    }

    @Test func png() async throws {
        try await checkWriting(.png, macroFormat: "PNG")
    }

    @Test func gif() async throws {
        // ImageJ reduces RGB to 256 colours (Mancora doesn't yet) and refuses other stacks than 8-bit.
        try await checkWriting(.gif, macroFormat: "Gif") { _, image in
            image.pixelType == .rgb8 || (image.stack.count > 1 && image.pixelType != .gray8)
        }
    }

    @Test func zip() async throws {
        try await checkWriting(.zip, macroFormat: "ZIP")
    }

    /// The same macro saves its tables natively and in ImageJ; the files must be identical.
    @Test func tableFiles() async throws {
        let code = #"""
            newImage("a", "8-bit ramp", 64, 64, 1);
            run("Set Measurements...", "area mean min centroid redirect=None decimal=3");
            makeRectangle(0, 0, 32, 32); run("Measure");
            makeRectangle(32, 0, 31, 30); run("Measure");
            makeRectangle(3, 5, 7, 9); run("Measure");
            setResult("Label", 0, "left, top");
            setResult("Note", 1, "x,y");
            saveAs("Results", dir + "r.xls");
            saveAs("Results", dir + "r.csv");
            saveAs("Results", dir + "r.txt");
            saveAs("Results", dir + "plain");
            Table.create("T");
            Table.set("A", 0, 1.5, "T"); Table.set("A", 1, 2, "T"); Table.set("B", 0, "s", "T"); Table.set("B", 1, "", "T");
            Table.save(dir + "t.csv", "T");
            Table.save(dir + "t.tsv", "T");
            Table.open(dir + "r.csv", "R2");
            Table.save(dir + "r2.csv", "R2");
            Table.save(dir + "r2.xls", "R2");
            Table.showRowNumbers(true, "T");
            Table.save(dir + "t-numbered.csv", "T");
            open(dir + "t.csv");
            Table.save(dir + "t2.csv", "t.csv");
            print(Table.size("t.csv") + " " + Table.getString("B", 0, "t.csv") + " " + Table.get("A", 1, "t.csv"));
            """#
        let mine = try Self.temporaryDirectory("tables-mancora"), theirs = try Self.temporaryDirectory("tables-imagej")
        let session = MacroSession(registry: .standard)
        try session.run("dir = \"\(mine)\";\n" + code)
        try await Self.withBridge { bridge in
            let result = try await bridge.runMacro("dir = \"\(theirs)\";\n" + code)
            if let error = result.macroError { Issue.record("ImageJ: \(error)") }
            #expect(session.logLines.joined(separator: "\n") == result.log.trimmingCharacters(in: .newlines))
        }
        for file in ["r.xls", "r.csv", "r.txt", "plain", "t.csv", "t.tsv", "r2.csv", "r2.xls", "t-numbered.csv", "t2.csv"] {
            let a = try? String(contentsOfFile: mine + file, encoding: .utf8)
            let b = try? String(contentsOfFile: theirs + file, encoding: .utf8)
            #expect(a == b, "\(file): Mancora \(a.map { "\n" + $0 } ?? "nothing"), ImageJ \(b.map { "\n" + $0 } ?? "nothing")")
        }
    }
}
