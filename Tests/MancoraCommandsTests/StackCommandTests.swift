import MancoraCore
import Testing

@testable import MancoraCommands

/// Commands checked here rather than against ImageJ: Fiji's Re-order
/// Hyperstack isn't part of ImageJ 1.54p.
@Suite("Stack and hyperstack commands")
struct StackCommandTests {
    /// A 2×1 8-bit composite with `c` channels, `z` slices and `t` frames;
    /// plane `i` holds `i` and is labeled `p<i>`.
    func context(c: Int, z: Int, t: Int) throws -> CommandContext {
        let n = c * z * t
        let stack = try ImageStack(
            width: 2, height: 1, planes: (0..<n).map { .gray8([UInt8($0), UInt8($0)]) }, labels: (0..<n).map { "p\($0)" })
        var context = CommandContext()
        context.add(
            try Hyperstack(
                title: "h.tif", stack: stack, dimensions: HyperstackDimensions(channels: c, slices: z, frames: t),
                compositeMode: .color))
        return context
    }

    func order(_ context: CommandContext) -> [UInt8] {
        guard let image = context.current?.image else { return [] }
        return image.stack.planes.map { plane in
            guard case .gray8(let p) = plane else { return 255 }
            return p[0]
        }
    }

    @Test func reorderSwapsChannelsAndSlices() throws {
        var context = try context(c: 2, z: 3, t: 1)
        let source = try #require(context.current?.id)
        try CommandRegistry.standard.run(
            "Re-order Hyperstack ...", options: MacroOptions("channels=[Slices (z)] slices=[Channels (c)] frames=[Frames (t)]"),
            in: &context)
        let image = try #require(context.current?.image)
        #expect(image.dimensions == HyperstackDimensions(channels: 3, slices: 2, frames: 1))
        // New channel c, slice z is the old channel z, slice c.
        #expect(order(context) == [0, 2, 4, 1, 3, 5])
        #expect(image.stack.labels == ["p0", "p2", "p4", "p1", "p3", "p5"])
        #expect(image.compositeMode == .composite)
        #expect(image.channels.map(\.lut) == [LUT.red, .green, .blue])
        #expect(!context.images.contains { $0.id == source })
    }

    @Test func reorderKeepsChannelLUTsWhenChannelsStay() throws {
        var context = try context(c: 2, z: 2, t: 3)
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in
            open.image.setDisplay(ChannelDisplay(lut: .cyan, displayRange: 3...9), forChannel: 1)
        }
        try CommandRegistry.standard.run(
            "Re-order Hyperstack ...", options: MacroOptions("channels=[Channels (c)] slices=[Frames (t)] frames=[Slices (z)]"),
            in: &context)
        let image = try #require(context.current?.image)
        #expect(image.dimensions == HyperstackDimensions(channels: 2, slices: 3, frames: 2))
        #expect(order(context) == [0, 1, 4, 5, 8, 9, 2, 3, 6, 7, 10, 11])
        #expect(image.channels[1] == ChannelDisplay(lut: .cyan, displayRange: 3...9))
    }

    @Test func reorderLogsAnInconsistentMapping() throws {
        var context = try context(c: 2, z: 3, t: 1)
        let before = try #require(context.current?.image)
        try CommandRegistry.standard.run(
            "Re-order Hyperstack ...", options: MacroOptions("channels=[Slices (z)] slices=[Slices (z)] frames=[Frames (t)]"),
            in: &context)
        #expect(context.current?.image == before)
        #expect(context.log.last?.hasPrefix("Mapping is inconsistent") == true)
    }
}
