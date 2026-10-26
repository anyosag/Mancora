import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("GIF")
struct GIFTests {
    @Test func manifestPresent() {
        #expect(FormatFixtures.gif.count >= 12)
    }

    /// Single images open as 8-bit with their colour table; animations as
    /// stacks composed as ImageJ's GifDecoder composes them.
    @Test(arguments: FormatFixtures.gif)
    func opensAsImageJDoes(_ entry: FormatFixtures.Entry) throws {
        let image = try GIFReader.read(path: Fixtures.path("Tests/Fixtures/gif/" + entry.file))
        let expect = try #require(entry.expect)
        #expect(image.title == entry.file)
        #expect(image.width == entry.width && image.height == entry.height)
        let planes = try #require(expect.planes)
        #expect(image.stack.count == planes.count)
        #expect(image.pixelType == (expect.type == "rgb8" ? .rgb8 : .gray8))
        for (k, hex) in planes.enumerated() where k < image.stack.count {
            switch image.stack[k] {
            case .gray8(let p):
                #expect(p == FormatFixtures.bytes(hex: hex), "plane \(k + 1)")
            case .rgb8(let p):
                let got = p.map { $0 & 0xFF_FFFF }, want = FormatFixtures.values(hex: hex, digits: 6)
                #expect(got == want, "plane \(k + 1), first difference at \(FormatFixtures.firstDifference(got, want))")
            default:
                Issue.record("unexpected type")
            }
        }
        if let lut = expect.lut {
            #expect(image.channels[0].lut.hasSameColors(as: try #require(FormatFixtures.lut(hex: lut))))
        }
    }

    static func gray8(_ w: Int, _ h: Int, slices: Int = 1, lut: LUT = .grays, fps: Double = 0) throws -> Hyperstack {
        let planes = (0..<slices).map { k in Plane.gray8((0..<(w * h)).map { UInt8(truncatingIfNeeded: $0 * 5 + k * 31) }) }
        var image = try Hyperstack(title: "g", stack: ImageStack(width: w, height: h, planes: planes))
        var display = image.channels[0]
        display.lut = lut
        image.setDisplay(display, forChannel: 0)
        image.calibration.fps = fps
        return image
    }

    @Test func singleImagesKeepValuesAndLUT() throws {
        let image = try Self.gray8(23, 9, lut: .fire)
        let back = try GIFReader.decode(GIFWriter.encode(image), title: "x.gif")
        #expect(back.stack[0] == image.stack[0])
        #expect(back.channels[0].lut.hasSameColors(as: .fire))
        let gray = try Self.gray8(23, 9)
        let grayBack = try GIFReader.decode(GIFWriter.encode(gray), title: "x.gif")
        #expect(grayBack.stack[0] == gray.stack[0])
        #expect(grayBack.channels[0].lut == .grays)
    }

    @Test func stacksBecomeAnimationsThatOpenAsImageJOpensThem() throws {
        let fire = try Self.gray8(17, 6, slices: 3, lut: .fire)
        let bytes = try GIFWriter.encode(fire)
        let back = try GIFReader.decode(bytes, title: "a.gif")
        #expect(back.stack.count == 3 && back.pixelType == .rgb8)
        for k in 0..<3 {
            guard case .gray8(let raw) = fire.stack[k], case .rgb8(let rgb) = back.stack[k] else { continue }
            #expect(rgb.map { $0 & 0xFF_FFFF } == raw.map { LUT.fire.argb(Int($0)) & 0xFF_FFFF })
        }
        // Gray animations come back as 8-bit.
        let gray = try Self.gray8(17, 6, slices: 2)
        let grayBack = try GIFReader.decode(GIFWriter.encode(gray), title: "g.gif")
        #expect(grayBack.stack.planes == gray.stack.planes)
    }

    @Test func frameDelayFollowsTheFrameRate() throws {
        // A delay of 1/fps s in hundredths, at ImageJ's 7 fps when the image has none.
        func delay(_ fps: Double) throws -> Int {
            let bytes = try GIFWriter.encode(try Self.gray8(4, 3, slices: 2, fps: fps))
            let gce = try #require((0..<(bytes.count - 1)).first { bytes[$0] == 0x21 && bytes[$0 + 1] == 0xF9 })
            return Int(bytes[gce + 4]) | Int(bytes[gce + 5]) << 8
        }
        #expect(try delay(0) == 14)
        #expect(try delay(25) == 4)
        #expect(try delay(1000) == 2)  // clamped to 60 fps
    }

    @Test func lzwHandlesFullTables() throws {
        var seed: UInt32 = 99
        let noise = (0..<(200 * 150)).map { _ -> UInt8 in
            seed = seed &* 1_103_515_245 &+ 12345
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
        let image = try Hyperstack(title: "n", stack: ImageStack(width: 200, height: 150, planes: [.gray8(noise)]))
        let back = try GIFReader.decode(GIFWriter.encode(image), title: "n.gif")
        #expect(back.stack[0] == .gray8(noise))
        let animated = try Hyperstack(title: "n", stack: ImageStack(width: 200, height: 150, planes: [.gray8(noise), .gray8(noise)]))
        let animatedBack = try GIFReader.decode(GIFWriter.encode(animated), title: "n.gif")
        #expect(animatedBack.stack[1] == .gray8(noise))
    }

    @Test func refusesWhatImageJCantWrite() throws {
        let rgb = try Hyperstack(title: "c", stack: ImageStack(width: 2, height: 2, planes: [.rgb8([0, 1, 2, 3])]))
        #expect(throws: MancoraIOError.self) { try GIFWriter.encode(rgb) }
        let sixteen = try Hyperstack(title: "s", stack: ImageStack(width: 2, height: 1, planes: [.gray16([1, 2]), .gray16([3, 4])]))
        #expect(throws: MancoraIOError.self) { try GIFWriter.encode(sixteen) }
        // A single 16-bit image is scaled to 8 bits, as ImageJ's getBufferedImage does.
        let one = try Hyperstack(title: "s", stack: ImageStack(width: 2, height: 1, planes: [.gray16([100, 300])]))
        let back = try GIFReader.decode(GIFWriter.encode(one), title: "s.gif")
        #expect(back.stack[0] == .gray8(DisplayMapper.lutIndices(for: one.stack[0], displayRange: one.channels[0].displayRange)))
    }

    @Test func rejectsNonGIFs() {
        #expect(throws: MancoraIOError.self) { try GIFReader.decode(Array("GIX89a".utf8), title: "x") }
        // A header with no image.
        #expect(throws: MancoraIOError.self) { try GIFReader.decode(Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0, 0x3B], title: "x") }
    }
}
