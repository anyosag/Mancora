import MancoraCore
import MancoraProcess
import Testing

@testable import MancoraCommands

@Suite("Background, maxima and EDM commands")
struct SegmentationCommandTests {
    static let width = 40, height = 24

    static func inDisc(_ x: Double, _ y: Double, _ cx: Double) -> Bool {
        let dx = x - cx, dy = y - 12
        return dx * dx + dy * dy <= 64
    }

    /// Two touching discs, 255 on 0.
    static var discs: Hyperstack {
        let pixels = (0..<(width * height)).map { i -> UInt8 in
            let x = Double(i % width), y = Double(i / width)
            return Self.inDisc(x, y, 13) || Self.inDisc(x, y, 26) ? 255 : 0
        }
        let stack = try! ImageStack(width: width, height: height, planes: [.gray8(pixels)])
        return try! Hyperstack(title: "discs.tif", stack: stack)
    }

    static func run(_ steps: [(String, String)], on image: Hyperstack) throws -> CommandContext {
        var context = CommandContext()
        context.add(image)
        for (command, options) in steps {
            try CommandRegistry.standard.run(command, options: MacroOptions(options), in: &context)
        }
        return context
    }

    @Test func binaryOptionsSetTheEDMOutput() throws {
        var context = try Self.run([("Options...", "iterations=1 count=1 black edm=16-bit do=Nothing")], on: Self.discs)
        #expect(context.settings.edmOutput == .short)
        // Left out, the output stays as it was.
        try CommandRegistry.standard.run("Options...", options: MacroOptions("iterations=1 count=1 black"), in: &context)
        #expect(context.settings.edmOutput == .short)
        #expect(throws: CommandError.self) {
            try CommandRegistry.standard.run("Options...", options: MacroOptions("edm=64-bit"), in: &context)
        }
    }

    @Test func distanceMapOutputs() throws {
        let overwritten = try Self.run([("Distance Map", "")], on: Self.discs)
        #expect(overwritten.images.count == 1)
        #expect(overwritten.current?.image.channels[0].displayRange == 0...8)
        let float = try Self.run([("Options...", "black edm=32-bit"), ("Distance Map", "")], on: Self.discs)
        let edm = try #require(float.current)
        #expect(float.images.count == 2)
        #expect(edm.title == "EDM of discs")
        #expect(edm.image.pixelType == .gray32Float)
        #expect(edm.image.channels[0].displayRange == edm.currentPlane.valueRange())
        // Find Maxima treats a 32-bit "EDM of" image as a distance map.
        let maxima = try Self.run(
            [("Options...", "black edm=32-bit"), ("Distance Map", ""), ("Find Maxima...", "prominence=0.5 output=Count")],
            on: Self.discs)
        #expect(maxima.results.number("Count", row: 0) == 2)
    }

    @Test func watershedNeedsABinaryImage() throws {
        var gray = Self.discs
        try gray.setPlane(.gray8([UInt8](repeating: 7, count: Self.width * Self.height)), at: 0)
        #expect(throws: CommandError.failed(command: "Watershed", detail: "8-bit binary (0 and 255) required.")) {
            try Self.run([("Watershed", "")], on: gray)
        }
        let cut = try Self.run([("Watershed", "")], on: Self.discs)
        #expect(cut.current?.threshold == ThresholdLevels(lower: 255, upper: 255))
    }

    @Test func findMaximaOutputs() throws {
        let count = try Self.run([("Find Maxima...", "prominence=10 output=Count")], on: Self.discs)
        #expect(count.results.count == 1)
        #expect(count.results.number("Count", row: 0) == 1)
        let list = try Self.run([("Find Maxima...", "prominence=10 output=List")], on: Self.discs)
        #expect(list.results.columns == ["X", "Y"])
        let points = try Self.run([("Find Maxima...", "prominence=10 output=[Point Selection]")], on: Self.discs)
        guard case .points(let p)? = points.current?.roi?.shape else {
            Issue.record("no point selection")
            return
        }
        #expect(p.vertices.count == 1)
        #expect(p.size == 4)
        let single = try Self.run([("Find Maxima...", "prominence=10 output=[Single Points]")], on: Self.discs)
        #expect(single.current?.title == "discs.tif Maxima")
        #expect(single.images.count == 2)
        #expect(throws: CommandError.self) {
            try Self.run([("Find Maxima...", "prominence=10 output=Everything")], on: Self.discs)
        }
    }

    @Test func subtractBackgroundResetsTheDisplayRange() throws {
        let stack = try ImageStack(width: 30, height: 20, planes: [.gray16((0..<600).map { UInt16(1000 + ($0 % 30) * 10) })])
        var image = try Hyperstack(title: "ramp.tif", stack: stack)
        var display = image.channels[0]
        display.displayRange = 0...5000
        image.setDisplay(display, forChannel: 0)
        let context = try Self.run([("Subtract Background...", "rolling=5")], on: image)
        let result = try #require(context.current)
        #expect(result.image.channels[0].displayRange == result.currentPlane.valueRange())
    }

    @Test func shortTitles() {
        #expect(SegmentationCommands.shortTitle("blobs.gif") == "blobs")
        #expect(SegmentationCommands.shortTitle(" my image.tif ") == "myimage")
        #expect(SegmentationCommands.shortTitle("EDM of blobs") == "EDM")
        #expect(SegmentationCommands.shortTitle(".hidden") == ".hidden")
    }
}
