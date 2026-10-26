import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("PNG")
struct PNGTests {
    @Test func manifestPresent() {
        #expect(FormatFixtures.png.count >= 25)
    }

    /// Every fixture opens as ImageJ opens it: the samples as stored, or
    /// what ImageJ converts them to.
    @Test(arguments: FormatFixtures.png)
    func opensAsImageJDoes(_ entry: FormatFixtures.Entry) throws {
        let image = try PNGReader.read(path: Fixtures.path("Tests/Fixtures/png/" + entry.file))
        #expect(image.title == entry.file)
        #expect(image.width == entry.width && image.height == entry.height)
        let w = entry.width, h = entry.height
        let coords = (0..<h).flatMap { y in (0..<w).map { x in (x, y) } }

        if let expect = entry.expect {
            #expect(image.pixelType == .rgb8)
            guard case .rgb8(let pixels) = image.stack[0] else { return }
            if let hex = expect.pixels {
                let want = FormatFixtures.values(hex: hex, digits: 6)
                let got = pixels.map { $0 & 0xFF_FFFF }
                #expect(got == want, "first difference at \(FormatFixtures.firstDifference(got, want))")
            }
            if let crc = expect.crc32 {
                let bytes = pixels.flatMap { [UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
                #expect(FormatFixtures.crc32(bytes) == crc)
            }
            return
        }
        let stored = try #require(entry.stored)
        switch stored.pattern {
        case "p8":
            let shift = stored.shift ?? 0, modulo = stored.modulo ?? 256
            #expect(image.stack[0] == .gray8(coords.map { UInt8((Int(Patterns.p8($0.0, $0.1)) >> shift) % modulo) }))
            let lut = image.channels[0].lut
            if let palette = stored.palette {
                #expect(lut.hasSameColors(as: try #require(FormatFixtures.lut(palette: palette))))
            } else if shift > 0 {
                // 2^depth gray levels, then black.
                let levels = 1 << (8 - shift)
                let ramp = (0..<256).map { $0 < levels ? UInt8($0 * 255 / (levels - 1)) : 0 }
                #expect(lut.reds == ramp && lut.greens == ramp && lut.blues == ramp)
            } else {
                #expect(lut == .grays)
            }
            #expect(image.channels[0].displayRange == 0...255)
        case "p16":
            #expect(image.stack[0] == .gray16(coords.map { Patterns.p16($0.0, $0.1) }))
            #expect(image.channels[0].displayRange == 0...33394)
        case "rgb":
            #expect(image.stack[0] == .rgb8(coords.map { Patterns.rgb($0.0, $0.1) }))
        case "p16x3":
            #expect(image.dimensions == HyperstackDimensions(channels: 3))
            #expect(image.compositeMode == .composite)
            for k in 0..<3 {
                #expect(image.stack[k] == .gray16(coords.map { Patterns.p16($0.0, $0.1, k) }))
            }
            #expect(image.channels.map(\.lut) == [.red, .green, .blue])
        default:
            Issue.record("unknown pattern \(stored.pattern)")
        }
    }

    @Test func linearGrayTablesMatchOpenJDK() {
        // Spot values of ColorModel.getLinearRGB8TosRGB8LUT; the fixtures check all of them.
        #expect(SRGB.from8[0] == 0 && SRGB.from8[255] == 255)
        #expect(SRGB.from8[7] == 46 && SRGB.from8[14] == 66)
        #expect(SRGB.from16[0] == 0 && SRGB.from16[65535] == 255)
    }

    @Test func rejectsWhatImageIORejects() {
        let good = try! Fixtures.data("Tests/Fixtures/png/gray8.png")
        var bytes = [UInt8](good)
        #expect(throws: MancoraIOError.self) { try PNGReader.decode(Array(bytes.prefix(40)), title: "cut.png") }
        bytes[0] = 0
        #expect(throws: MancoraIOError.self) { try PNGReader.decode(bytes, title: "x.png") }
        var row: [UInt8] = [1, 2]
        #expect(throws: MancoraIOError.self) { try PNGReader.unfilter(5, &row, [0, 0], bpp: 1) }
    }

    @Test func toleratesBadChecksumsAsImageIODoes() throws {
        var bytes = [UInt8](try Fixtures.data("Tests/Fixtures/png/gray8.png"))
        // The IHDR chunk's CRC is at 8 + 8 + 13.
        bytes[29] ^= 0xFF
        let image = try PNGReader.decode(bytes, title: "crc.png")
        #expect(image.pixelType == .gray8)
    }

    // MARK: Writing, then reading back

    static func make(_ type: PixelType, channels: Int = 1, slices: Int = 1, lut: LUT = .grays) throws -> Hyperstack {
        let w = 19, h = 7
        let planes = (0..<(channels * slices)).map { k -> Plane in
            switch type {
            case .gray8: .gray8((0..<(w * h)).map { UInt8(truncatingIfNeeded: $0 * 3 + k * 40) })
            case .gray16: .gray16((0..<(w * h)).map { UInt16($0 * 397 + k * 1000) })
            case .gray32Float: .gray32Float((0..<(w * h)).map { Float($0) * 0.5 - 7 })
            case .rgb8:
                .rgb8((0..<(w * h)).map { (i: Int) -> UInt32 in
                    let r = UInt32(i * 7 & 255), g = UInt32(i * 3 & 255)
                    return 0xFF00_0000 | r << 16 | g << 8 | 17
                })
            }
        }
        var image = try Hyperstack(
            title: "made", stack: ImageStack(width: w, height: h, planes: planes),
            dimensions: HyperstackDimensions(channels: channels, slices: slices),
            compositeMode: channels > 1 ? .composite : .color)
        if channels == 1, type != .rgb8 {
            var display = image.channels[0]
            display.lut = lut
            image.setDisplay(display, forChannel: 0)
        }
        return image
    }

    static func roundTrip(_ image: Hyperstack, _ options: PNGWriter.Options = .init()) throws -> Hyperstack {
        try PNGReader.decode(PNGWriter.encode(image, options: options), title: "back.png")
    }

    @Test func gray8WithTheDefaultLUTStaysGray() throws {
        let image = try Self.make(.gray8)
        let back = try Self.roundTrip(image)
        #expect(back.stack[0] == image.stack[0])
        #expect(back.channels[0].lut == .grays)
    }

    @Test func gray8DisplayRangeIsAppliedToGrayValues() throws {
        var image = try Self.make(.gray8)
        var display = image.channels[0]
        display.displayRange = 40...200
        image.setDisplay(display, forChannel: 0)
        let back = try Self.roundTrip(image)
        #expect(back.stack[0] == .gray8(DisplayMapper.lutIndices(for: image.stack[0], displayRange: 40...200)))
    }

    @Test func gray8WithALUTKeepsValuesAndTheStretchedLUT() throws {
        var image = try Self.make(.gray8, lut: .fire)
        let back = try Self.roundTrip(image)
        #expect(back.stack[0] == image.stack[0])
        #expect(back.channels[0].lut.hasSameColors(as: .fire))
        var display = image.channels[0]
        display.displayRange = 10...100
        image.setDisplay(display, forChannel: 0)
        let stretched = try Self.roundTrip(image)
        #expect(stretched.stack[0] == image.stack[0])
        #expect(stretched.channels[0].lut.hasSameColors(as: ImageJView.stretched(.fire, over: 10...100)))
    }

    @Test func gray16WithTheDefaultLUTIsSixteenBit() throws {
        let image = try Self.make(.gray16, slices: 3)
        let back = try Self.roundTrip(image, .init(slice: 2))
        #expect(back.pixelType == .gray16)
        #expect(back.stack[0] == image.stack[2])
    }

    @Test func gray16And32WithOtherLUTsAreScaledToEightBits() throws {
        let sixteen = try Self.make(.gray16, lut: .ice)
        let back = try Self.roundTrip(sixteen)
        #expect(back.stack[0] == .gray8(DisplayMapper.lutIndices(for: sixteen.stack[0], displayRange: sixteen.channels[0].displayRange)))
        #expect(back.channels[0].lut.hasSameColors(as: .ice))
        let float = try Self.make(.gray32Float)
        let floatBack = try Self.roundTrip(float)
        #expect(floatBack.stack[0] == .gray8(DisplayMapper.lutIndices(for: float.stack[0], displayRange: float.channels[0].displayRange)))
        #expect(floatBack.channels[0].lut == .grays)
    }

    @Test func rgbAndCompositesAreRGB() throws {
        let rgb = try Self.make(.rgb8)
        #expect(try Self.roundTrip(rgb).stack[0] == rgb.stack[0])
        let composite = try Self.make(.gray16, channels: 2)
        let back = try Self.roundTrip(composite)
        #expect(back.stack[0] == .rgb8(DisplayMapper.render(composite)))
    }

    @Test func alphaStacksAreRGBA() throws {
        let made = try Self.make(.gray8, slices: 4)
        let image = try Hyperstack(
            title: "rgba", stack: ImageStack(width: made.width, height: made.height, planes: made.stack.planes,
                labels: [nil, nil, nil, "Alpha"]),
            dimensions: made.dimensions)
        let back = try Self.roundTrip(image)
        // ImageJ composites the alpha on white when it reads the file back.
        guard case .rgb8(let pixels) = back.stack[0], case .gray8(let a) = image.stack[3], case .gray8(let r) = image.stack[0]
        else { Issue.record("not RGB"); return }
        let i = 5
        let alpha = Int(a[i]), red = Int(r[i])
        #expect(Int(pixels[i] >> 16 & 0xFF) == (alpha * red + 127) / 255 + ((255 - alpha) * 255 + 127) / 255)
    }

    @Test func transparentIndexWritesThePaletteWithTRNS() throws {
        let image = try Self.make(.gray8, lut: .fire)
        let bytes = PNGWriter.encode(image, options: .init(transparentIndex: 3))
        #expect(bytes.windowsContain(Array("tRNS".utf8)))
        let back = try PNGReader.decode(bytes, title: "t.png")
        #expect(back.pixelType == .rgb8)  // a transparent entry makes ImageJ composite it on white
    }
}

extension Array where Element == UInt8 {
    func windowsContain(_ needle: [UInt8]) -> Bool {
        guard needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { Array(self[$0..<($0 + needle.count)]) == needle }
    }
}
