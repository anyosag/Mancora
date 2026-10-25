import Foundation
import Testing

@testable import MancoraCore

/// ImageJ's built-in LUTs, as recorded by Tools/fixtures/ImageJFixtures.java.
enum BuiltInGolden {
    struct File: Decodable { let builtin: [String: String] }

    static let luts: [String: [UInt8]] = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        let path = parts.joined(separator: "/") + "/Tests/Fixtures/luts-golden.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return file.builtin.mapValues { hex in
            var out: [UInt8] = []
            var it = hex.utf8.makeIterator()
            func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 0x20) - 87 }
            while let hi = it.next(), let lo = it.next() { out.append(nibble(hi) << 4 | nibble(lo)) }
            return out
        }
    }()
}

@Suite("Built-in LUTs")
struct BuiltInLUTTests {
    @Test func goldenPresent() {
        #expect(BuiltInGolden.luts.count == LUT.builtIn.count)
    }

    @Test("Matches ImageJ's generated LUT", arguments: LUT.builtIn.map(\.name))
    func matchesImageJ(name: String) throws {
        let golden = try #require(BuiltInGolden.luts[name], "no golden data for \(name)")
        let lut = try #require(LUT.builtIn(named: name))
        #expect(lut.reds == Array(golden[0..<256]))
        #expect(lut.greens == Array(golden[256..<512]))
        #expect(lut.blues == Array(golden[512..<768]))
    }

    @Test func lookupIgnoresCaseAndAliases() {
        #expect(LUT.builtIn(named: "FIRE") == .fire)
        #expect(LUT.builtIn(named: "3-3-2 rgb") == .rgb332)
        #expect(LUT.builtIn(named: "redgreen") == .redGreen)
        #expect(LUT.builtIn(named: "nope") == nil)
    }

    @Test func inversion() {
        #expect(!LUT.grays.isInverted)
        #expect(LUT.grays.inverted().isInverted)
        #expect(LUT.grays.inverted().reds[0] == 255)
        #expect(LUT.grays.argb(128) == 0xFF80_8080)
    }

    @Test func rejectsWrongLengths() {
        #expect(throws: LUT.Error.wrongLength(3)) { try LUT(name: "x", reds: [1, 2, 3], greens: [], blues: []) }
        #expect(throws: LUT.Error.invalidColorCount(0)) {
            try LUT(name: "x", interpolating: [], [], [], colorCount: 0)
        }
    }
}

@Suite("Java numeric semantics")
struct JavaNumericsTests {
    @Test func intCast() {
        #expect(JavaNumerics.int32(Double.nan) == 0)
        #expect(JavaNumerics.int32(Double.infinity) == .max)
        #expect(JavaNumerics.int32(-1e20) == .min)
        #expect(JavaNumerics.int32(-2.9) == -2)
        #expect(JavaNumerics.int32(2.9) == 2)
    }

    @Test func byteCast() {
        #expect(JavaNumerics.byte(300.0) == 44)
        #expect(JavaNumerics.byte(-1.0) == 255)
        #expect(JavaNumerics.byte(Float(255.9)) == 255)
    }
}

@Suite("Image model")
struct ImageModelTests {
    @Test func hyperstackIndexing() {
        let dims = HyperstackDimensions(channels: 2, slices: 3, frames: 4)
        #expect(dims.planeCount == 24)
        #expect(dims.planeIndex(channel: 1, slice: 0, frame: 0) == 1)
        #expect(dims.planeIndex(channel: 0, slice: 1, frame: 0) == 2)
        #expect(dims.planeIndex(channel: 0, slice: 0, frame: 1) == 6)
        for i in 0..<24 {
            let p = dims.position(ofPlane: i)
            #expect(dims.planeIndex(channel: p.channel, slice: p.slice, frame: p.frame) == i)
        }
        #expect(HyperstackDimensions(channels: 0).planeCount == nil)
        #expect(HyperstackDimensions(channels: .max, slices: 2).planeCount == nil)
    }

    @Test func stackValidation() throws {
        #expect(throws: ImageModelError.emptyStack) { try ImageStack(width: 2, height: 2, planes: []) }
        #expect(throws: ImageModelError.invalidSize(width: 0, height: 2)) {
            try ImageStack(width: 0, height: 2, planes: [.gray8([])])
        }
        #expect(throws: ImageModelError.planeSizeMismatch(index: 1, expected: 4, actual: 3)) {
            try ImageStack(width: 2, height: 2, planes: [.gray8([0, 0, 0, 0]), .gray8([0, 0, 0])])
        }
        #expect(throws: ImageModelError.pixelTypeMismatch(index: 1, expected: .gray8, actual: .gray16)) {
            try ImageStack(width: 2, height: 2, planes: [.gray8([0, 0, 0, 0]), .gray16([0, 0, 0, 0])])
        }
        var stack = try ImageStack(width: 2, height: 1, planes: [.gray8([1, 2])])
        try stack.setPlane(.gray8([3, 4]), at: 0)
        #expect(stack[0] == .gray8([3, 4]))
        #expect(throws: ImageModelError.self) { try stack.setPlane(.gray16([3, 4]), at: 0) }
    }

    @Test func hyperstackDefaults() throws {
        let planes = (0..<6).map { k in Plane.gray16([UInt16(k), UInt16(k * 10 + 5)]) }
        let stack = try ImageStack(width: 2, height: 1, planes: planes)
        let dims = HyperstackDimensions(channels: 2, slices: 3)
        let image = try Hyperstack(title: "t", stack: stack, dimensions: dims)
        #expect(image.channels.map(\.lut.name) == ["Red", "Green"])
        // Display ranges come from each channel's first plane.
        #expect(image.channels[0].displayRange == 0...5)
        #expect(image.channels[1].displayRange == 1...15)
        #expect(throws: ImageModelError.self) {
            try Hyperstack(title: "t", stack: stack, dimensions: HyperstackDimensions(channels: 4))
        }
    }

    @Test func planeRanges() {
        #expect(Plane.gray32Float([.nan, -2, .infinity, 3]).valueRange() == -2...3)
        #expect(Plane.gray32Float([.nan]).valueRange() == nil)
        #expect(Plane.gray8([]).valueRange() == nil)
        #expect(Plane.rgb8([0xFF10_2030]).value(at: 0) == Double(0x10 + 0x20 + 0x30) / 3)
    }
}

@Suite("Display mapping (ImageJ rules)")
struct DisplayMapperTests {
    @Test func eightBitIdentityAndWindow() {
        let plane = Plane.gray8((0..<256).map(UInt8.init))
        #expect(DisplayMapper.lutIndices(for: plane, displayRange: 0...255) == (0..<256).map(UInt8.init))
        let windowed = DisplayMapper.lutIndices(for: plane, displayRange: 100...200)
        #expect(windowed[99] == 0)
        #expect(windowed[100] == 0)
        #expect(windowed[150] == 128)  // (int)(256·50/100)
        #expect(windowed[201] == 255)
    }

    @Test func sixteenBitScaling() {
        // ShortProcessor: scale = 256/(max-min+1), value = (int)((v-min)·scale + 0.5), capped at 255.
        let plane = Plane.gray16([0, 99, 100, 1000, 1100, 1999, 2000, 60000])
        let indices = DisplayMapper.lutIndices(for: plane, displayRange: 100...2000)
        let scale = 256.0 / 1901.0
        let expected = [0, 0, 100, 1000, 1100, 1999, 2000, 60000].map { v -> UInt8 in
            let value = max(v - 100, 0)
            return UInt8(min(Int(Double(value) * scale + 0.5), 255))
        }
        #expect(indices == expected)
    }

    @Test func floatScalingAndNaN() {
        let plane = Plane.gray32Float([.nan, -1, 0, 0.5, 1, 2, .infinity])
        let indices = DisplayMapper.lutIndices(for: plane, displayRange: 0...1)
        #expect(indices == [0, 0, 0, 128, 255, 255, 255])
    }

    @Test func outputIsBGRAInLittleEndianMemory() {
        let display = ChannelDisplay(lut: .red, displayRange: 0...255)
        let pixels = DisplayMapper.render(.gray8([200]), display: display)
        #expect(pixels == [0xFFC8_0000])
        let bytes = withUnsafeBytes(of: pixels[0].littleEndian) { Array($0) }
        #expect(bytes == [0x00, 0x00, 0xC8, 0xFF])  // B, G, R, A
    }

    @Test func compositeAddsChannelsAndClamps() throws {
        let stack = try ImageStack(width: 1, height: 1, planes: [.gray8([255]), .gray8([255])])
        var image = try Hyperstack(
            title: "c",
            stack: stack,
            dimensions: HyperstackDimensions(channels: 2),
            compositeMode: .composite
        )
        image.setDisplay(ChannelDisplay(lut: .yellow, displayRange: 0...255), forChannel: 1)
        #expect(DisplayMapper.render(image) == [0xFFFF_FF00])  // red + yellow, clamped
        image.compositeMode = .grayscale
        #expect(DisplayMapper.render(image, channel: 1) == [0xFFFF_FFFF])
    }

    @Test func rgbPassesThrough() {
        let display = ChannelDisplay(lut: .fire, displayRange: 0...10)
        #expect(DisplayMapper.render(.rgb8([0x0012_3456]), display: display) == [0xFF12_3456])
    }
}
