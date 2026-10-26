import MancoraCore
import Testing

@testable import MancoraCommands

/// Crop, Canvas Size, Duplicate's crop, the flips and rotations, and Reverse.
@Suite("Crop and transform commands")
struct CropTransformCommandTests {
    /// A 4×3 16-bit image (pixel `i` holds `i`), with `planes` planes adding 100 each.
    func context(planes: Int = 1, roi: Roi? = nil) throws -> CommandContext {
        let stack = try ImageStack(
            width: 4, height: 3, planes: (0..<planes).map { k in .gray16((0..<12).map { UInt16($0 + 100 * k) }) },
            labels: (0..<planes).map { "s\($0 + 1)" })
        var context = CommandContext()
        context.add(try Hyperstack(title: "t.tif", stack: stack))
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in open.roi = roi }
        return context
    }

    func values(_ context: CommandContext, plane: Int = 0) throws -> [UInt16] {
        guard case .gray16(let p)? = context.current?.image.stack[plane] else { throw CommandError.noImage("test") }
        return p
    }

    @Test func cropKeepsTheSelectedRectangleOfEveryPlane() throws {
        var context = try context(planes: 2, roi: Roi(.rectangle(.integer(x: 1, y: 1, width: 2, height: 2))))
        try CommandRegistry.standard.run("Crop", in: &context)
        let image = try #require(context.current?.image)
        #expect((image.width, image.height) == (2, 2))
        #expect(try values(context) == [5, 6, 9, 10])
        #expect(try values(context, plane: 1) == [105, 106, 109, 110])
        #expect(image.stack.labels == ["s1", "s2"])
        #expect(image.encodedROI == nil)  // a rectangle goes away
    }

    @Test func cropMovesAnOvalToTheOrigin() throws {
        var context = try context(roi: Roi(.oval(.integer(x: 1, y: 0, width: 3, height: 2))))
        try CommandRegistry.standard.run("Crop", in: &context)
        #expect(context.current?.roi == Roi(.oval(.integer(x: 0, y: 0, width: 3, height: 2))))
        #expect(throws: CommandError.self) {
            var lineContext = try self.context(roi: Roi(.line(.init(x1: 0, y1: 0, x2: 3, y2: 2))))
            try CommandRegistry.standard.run("Crop", in: &lineContext)
        }
    }

    @Test func duplicateCropsToTheSelectionUnlessIgnored() throws {
        let rect = Roi(.rectangle(.integer(x: 2, y: 0, width: 2, height: 3)))
        var context = try context(roi: rect)
        try CommandRegistry.standard.run("Duplicate...", options: MacroOptions("title=c"), in: &context)
        #expect(try values(context) == [2, 3, 6, 7, 10, 11])
        #expect(context.current?.image.encodedROI == nil)
        try context.select(title: "t.tif")
        try CommandRegistry.standard.run("Duplicate...", options: MacroOptions("title=w ignore"), in: &context)
        #expect(try values(context).count == 12)
        #expect(context.current?.roi == rect)
    }

    @Test func canvasSizePlacesTheImageAndFillsTheRest() throws {
        var context = try context()
        try CommandRegistry.standard.run(
            "Canvas Size...", options: MacroOptions("width=6 height=4 position=Bottom-Right zero"), in: &context)
        let p = try values(context)
        #expect(p.count == 24)
        #expect(Array(p[0..<6]) == [0, 0, 0, 0, 0, 0])
        #expect(Array(p[6..<12]) == [0, 0, 0, 1, 2, 3])
        #expect(Array(p[18..<24]) == [0, 0, 8, 9, 10, 11])
    }

    @Test func flipsWorkWithinTheSelection() throws {
        var context = try context(roi: Roi(.oval(.integer(x: 0, y: 0, width: 2, height: 3))))
        try CommandRegistry.standard.run("Flip Horizontally", in: &context)
        #expect(try values(context) == [1, 0, 2, 3, 5, 4, 6, 7, 9, 8, 10, 11])  // the bounds, unmasked
        try CommandRegistry.standard.run("Select None", in: &context)
        try CommandRegistry.standard.run("Flip Vertically", in: &context)
        #expect(try values(context) == [9, 8, 10, 11, 5, 4, 6, 7, 1, 0, 2, 3])
    }

    @Test func rotationsTurnTheImageAndSwapThePixelSize() throws {
        var context = try context()
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in
            open.image.calibration.unit = "µm"
            open.image.calibration.pixelWidth = 0.5
            open.image.calibration.pixelHeight = 2
        }
        try CommandRegistry.standard.run("Rotate 90 Degrees Right", in: &context)
        let image = try #require(context.current?.image)
        #expect((image.width, image.height) == (3, 4))
        #expect(try values(context) == [8, 4, 0, 9, 5, 1, 10, 6, 2, 11, 7, 3])
        #expect((image.calibration.pixelWidth, image.calibration.pixelHeight) == (2, 0.5))
        try CommandRegistry.standard.run("Rotate 90 Degrees Left", in: &context)
        #expect(try values(context) == Array(0..<12))
    }

    @Test func reverseFlipsTheStackOrder() throws {
        var context = try context(planes: 3)
        try CommandRegistry.standard.run("Reverse", in: &context)
        #expect(try values(context, plane: 0)[0] == 200)
        #expect(context.current?.image.stack.labels == ["s3", "s2", "s1"])
        var single = try self.context()
        #expect(throws: CommandError.self) { try CommandRegistry.standard.run("Flip Z", in: &single) }
    }
}
