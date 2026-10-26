import MancoraCore
import Testing

@testable import MancoraCommands

/// Filters and Math within a selection, as ImageJ's PlugInFilterRunner runs them.
@Suite("Commands in selections")
struct SelectionCommandTests {
    static let width = 9, height = 7

    func context(with roi: Roi?) throws -> CommandContext {
        let pixels = (0..<(Self.width * Self.height)).map { UInt8(($0 * 37) % 251) }
        let stack = try ImageStack(width: Self.width, height: Self.height, planes: [.gray8(pixels)])
        var context = CommandContext()
        context.add(try Hyperstack(title: "g.tif", stack: stack))
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in open.roi = roi }
        return context
    }

    func pixels(_ context: CommandContext) throws -> [UInt8] {
        guard case .gray8(let p)? = context.current?.currentPlane else { throw CommandError.noImage("test") }
        return p
    }

    @Test func mathChangesOnlyTheSelectedRectangle() throws {
        let before = try pixels(try context(with: nil))
        var context = try context(with: Roi(.rectangle(.integer(x: 2, y: 1, width: 4, height: 3))))
        try CommandRegistry.standard.run("Invert", in: &context)
        let after = try pixels(context)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let i = y * Self.width + x
                let inside = (2..<6).contains(x) && (1..<4).contains(y)
                #expect(after[i] == (inside ? 255 - before[i] : before[i]), "pixel (\(x), \(y))")
            }
        }
    }

    @Test func ovalsRestoreTheCornersOfTheirBounds() throws {
        let before = try pixels(try context(with: nil))
        var context = try context(with: Roi(.oval(.integer(x: 1, y: 1, width: 7, height: 5))))
        try CommandRegistry.standard.run("Invert", in: &context)
        let after = try pixels(context)
        let corner = 1 * Self.width + 1, center = 3 * Self.width + 4
        #expect(after[corner] == before[corner])
        #expect(after[center] == 255 - before[center])
    }

    /// ImageJ's Salt and Pepper is never seeded: only what it may change is fixed.
    @Test func saltAndPepperChangesOnlyTheSelectionToBlackOrWhite() throws {
        let width = 40, height = 30
        let before = (0..<(width * height)).map { UInt8(1 + ($0 * 37) % 250) }
        var context = CommandContext()
        context.add(try Hyperstack(title: "g.tif", stack: try ImageStack(width: width, height: height, planes: [.gray8(before)])))
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in
            open.roi = Roi(.rectangle(.integer(x: 5, y: 4, width: 20, height: 20)))
        }
        try CommandRegistry.standard.run("Salt and Pepper", in: &context)
        let after = try pixels(context)
        var changed = 0
        for y in 0..<height {
            for x in 0..<width where after[y * width + x] != before[y * width + x] {
                #expect((5..<25).contains(x) && (4..<24).contains(y), "pixel (\(x), \(y))")
                #expect(after[y * width + x] == 0 || after[y * width + x] == 255)
                changed += 1
            }
        }
        // (int)(0.05 * 400) / 2 = 10 salt and 10 pepper pixels, some of them the same.
        #expect(changed > 0 && changed <= 20)
    }

    @Test func linesAndPointsCountAsNoSelection() throws {
        let before = try pixels(try context(with: nil))
        for roi in [Roi(.line(.init(x1: 1, y1: 1, x2: 6, y2: 4))), Roi(.points(.init(.integer([.init(x: 3, y: 3)]))))] {
            var context = try context(with: roi)
            try CommandRegistry.standard.run("Invert", in: &context)
            #expect(try pixels(context) == before.map { 255 - $0 })
        }
    }

    /// `ByteProcessor.filter` also writes the image's last column when the
    /// rectangle ends just before it.
    @Test func eightBitSmoothWritesTheColumnNextToARectangleEndingOnePixelShort() throws {
        let before = try pixels(try context(with: nil))
        var whole = try context(with: nil)
        try CommandRegistry.standard.run("Smooth", in: &whole)
        let smoothed = try pixels(whole)
        var context = try context(with: Roi(.rectangle(.integer(x: 3, y: 2, width: 5, height: 3))))
        try CommandRegistry.standard.run("Smooth", in: &context)
        let after = try pixels(context)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let i = y * Self.width + x
                let written = (2..<5).contains(y) && (3...8).contains(x)
                #expect(after[i] == (written ? smoothed[i] : before[i]), "pixel (\(x), \(y))")
            }
        }
    }
}
