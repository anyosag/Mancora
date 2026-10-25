import MancoraCore
import Testing

@testable import MancoraIO

/// The first differing pixel of two planes, for readable failures.
func firstMismatch(_ actual: Plane, _ expected: Plane, width: Int) -> String? {
    guard actual.pixelType == expected.pixelType else {
        return "type \(actual.pixelType) ≠ \(expected.pixelType)"
    }
    guard actual.count == expected.count else { return "count \(actual.count) ≠ \(expected.count)" }
    for i in 0..<actual.count {
        let a = actual.value(at: i), e = expected.value(at: i)
        let same: Bool
        if case .rgb8(let ap) = actual, case .rgb8(let ep) = expected {
            same = ap[i] == ep[i]
        } else {
            same = a == e || (a.isNaN && e.isNaN)
        }
        if !same { return "pixel (\(i % width), \(i / width)): \(a) ≠ \(e)" }
    }
    return nil
}

@Suite("TIFF fixtures from independent writers")
struct TIFFFixtureTests {
    @Test func manifestPresent() {
        #expect(Fixtures.tiffManifest.count >= 30)
    }

    @Test("Fixture decodes to its pattern", arguments: Fixtures.tiffManifest)
    func fixture(_ entry: Fixtures.TIFFEntry) throws {
        let image = try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/\(entry.file)"))
        #expect(image.width == entry.width)
        #expect(image.height == entry.height)
        #expect(image.pixelType.rawValue == entry.type)
        try #require(image.stack.count == entry.planes)
        for k in 0..<entry.planes {
            let expected = try #require(
                Patterns.plane(entry.pattern, width: entry.width, height: entry.height, k: k,
                               inverted: entry.invertPattern ?? false)
            )
            let mismatch = firstMismatch(image.stack[k], expected, width: entry.width)
            #expect(mismatch == nil, "plane \(k): \(mismatch ?? "")")
        }
        if entry.signed == true {
            #expect(image.calibration.valueFunction == .straightLine(intercept: -32768, slope: 1))
        }
        if image.pixelType.usesLUT {
            #expect(image.channels[0].lut.isInverted == (entry.lutInverted ?? false))
        }
        if entry.lut == "palette" {
            let lut = image.channels[0].lut
            for i in [0, 1, 100, 255] {
                #expect(lut.reds[i] == UInt8(i))
                #expect(lut.greens[i] == UInt8(255 - i))
                #expect(lut.blues[i] == UInt8((i * 3) & 255))
            }
        }
    }
}

@Suite("TIFFs written by ImageJ")
struct ImageJTIFFTests {
    let width = 32, height = 24

    func open(_ name: String) throws -> Hyperstack {
        try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/\(name)"))
    }

    @Test func hyperstack() throws {
        let image = try open("ij-hyperstack-16bit.tif")
        #expect(image.dimensions == HyperstackDimensions(channels: 2, slices: 3, frames: 4))
        #expect(image.pixelType == .gray16)
        #expect(image.compositeMode == .composite)
        for k in 0..<24 {
            let expected = Plane.gray16(
                (0..<height).flatMap { y in (0..<width).map { x in Patterns.hyperstack(k, x, y) } }
            )
            #expect(firstMismatch(image.stack[k], expected, width: width) == nil, "plane \(k)")
        }
        // Channel fastest: channel 1, slice 2, frame 3 → plane (3·3 + 2)·2 + 1.
        #expect(image.plane(channel: 1, slice: 2, frame: 3) == image.stack[23])
        let cal = image.calibration
        #expect(cal.pixelWidth == 0.25)
        #expect(cal.pixelHeight == 0.5)
        #expect(cal.pixelDepth == 2.0)
        #expect(cal.unit == "µm")
        #expect(cal.frameInterval == 1.5)
        #expect(image.channels.map(\.lut.name) == ["Red", "Green"])
        #expect(image.channels.allSatisfy { $0.displayRange == 10...4000 })
    }

    @Test func eightBitWithFireLUT() throws {
        let image = try open("ij-8bit-fire.tif")
        let lut = image.channels[0].lut
        #expect(lut.reds == LUT.fire.reds)
        #expect(lut.greens == LUT.fire.greens)
        #expect(lut.blues == LUT.fire.blues)
        let expected = Plane.gray8((0..<height).flatMap { y in (0..<width).map { x in Patterns.p8(x, y) } })
        #expect(firstMismatch(image.stack[0], expected, width: width) == nil)
    }

    @Test func stackStoredAfterFirstIFD() throws {
        let image = try open("ij-stack-8bit.tif")
        #expect(image.dimensions == HyperstackDimensions(slices: 5))
        for k in 0..<5 {
            let expected = Plane.gray8((0..<height).flatMap { y in (0..<width).map { x in Patterns.p8(x, y, k) } })
            #expect(firstMismatch(image.stack[k], expected, width: width) == nil, "slice \(k)")
        }
    }

    @Test func floatWithNaNAndCalibration() throws {
        let image = try open("ij-32bit-float.tif")
        guard case .gray32Float(let pixels) = image.stack[0] else {
            Issue.record("expected float pixels")
            return
        }
        #expect(pixels[2 * width + 3].isNaN)
        #expect(pixels[5 * width + 9] == Float(9) * 0.25 - Float(5) * 0.5)
        #expect(image.calibration.unit == "mm")
        #expect(abs(image.calibration.pixelWidth - 0.1) < 1e-9)
        #expect(image.channels[0].displayRange == -11.5...7.75)
    }

    @Test func rgb() throws {
        let image = try open("ij-rgb.tif")
        let expected = Plane.rgb8((0..<height).flatMap { y in (0..<width).map { x in Patterns.rgb(x, y) } })
        #expect(firstMismatch(image.stack[0], expected, width: width) == nil)
    }
}

@Suite("Malformed TIFFs fail safely")
struct TIFFRobustnessTests {
    @Test func notATIFF() {
        #expect(throws: MancoraIOError.self) { try TIFFImporter.decode(Array("hello, world".utf8), title: "x") }
        #expect(throws: MancoraIOError.self) { try TIFFImporter.decode([0x49, 0x49], title: "x") }
    }

    @Test func bigTIFFIsReportedAsUnsupported() {
        var b = TIFFBuilder.gray8(width: 4, height: 4)
        b.magic = 43
        #expect(throws: MancoraIOError.unsupported("BigTIFF (arrives in Phase 1)")) {
            try TIFFImporter.decode(b.build(), title: "x")
        }
    }

    @Test func minimalImageInBothByteOrders() throws {
        for bigEndian in [false, true] {
            var b = TIFFBuilder.gray8(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])
            b.bigEndian = bigEndian
            let image = try TIFFImporter.decode(b.build(), title: "tiny")
            #expect(image.stack[0] == .gray8([1, 2, 3, 4, 5, 6]))
        }
    }

    @Test func ifdLoopTerminates() throws {
        var b = TIFFBuilder.gray8(width: 4, height: 4)
        b.nextIFD = 8 + 16  // points at itself
        #expect(try TIFFImporter.decode(b.build(), title: "loop").stack.count == 1)

        var two = TIFFBuilder.gray8(width: 4, height: 4)
        two.secondIFDPointsBackToFirst = true
        #expect(try TIFFImporter.decode(two.build(), title: "loop2").stack.count == 2)
    }

    @Test func stripPastEndOfFile() {
        var b = TIFFBuilder.gray8(width: 8, height: 8)
        b.set(273, 4, [100_000])
        #expect(throws: MancoraIOError.self) { try TIFFImporter.decode(b.build(), title: "x") }
    }

    @Test func hugeDimensionsAreRefusedBeforeAllocating() {
        var b = TIFFBuilder.gray8(width: 4, height: 4)
        b.set(256, 4, [100_000])
        b.set(257, 4, [100_000])
        b.set(258, 3, [16])
        b.set(278, 4, [100_000])
        #expect(throws: MancoraIOError.tooLarge(bytes: 20_000_000_000, limit: 1 << 30)) {
            try TIFFImporter.decode(b.build(), title: "x", options: .init(maximumDecodedBytes: 1 << 30))
        }
    }

    @Test func decompressionBombIsRejected() {
        var b = TIFFBuilder.gray8(width: 4, height: 4, pixels: [0xFE, 0x00])  // PackBits: 3 zeros
        b.set(256, 4, [4096])
        b.set(257, 4, [4096])
        b.set(259, 3, [32773])
        b.set(278, 4, [4096])
        b.set(279, 4, [2])
        #expect(throws: MancoraIOError.self) { try TIFFImporter.decode(b.build(), title: "x") }
    }

    @Test func unsupportedCompression() {
        var b = TIFFBuilder.gray8(width: 4, height: 4)
        b.set(259, 3, [7])
        #expect(throws: MancoraIOError.unsupported("JPEG compression")) { try TIFFImporter.decode(b.build(), title: "x") }
    }

    @Test func corruptLZW() {
        // First code 300 (9 bits: 1001_0110_0) refers to an undefined entry.
        var b = TIFFBuilder.gray8(width: 4, height: 4, pixels: [0x96, 0x00])
        b.set(259, 3, [5])
        b.set(279, 4, [2])
        #expect(throws: MancoraIOError.self) { try TIFFImporter.decode(b.build(), title: "x") }
    }
}

@Suite("TIFF codecs")
struct TIFFCodecTests {
    /// The example from the TIFF 6.0 specification, section 9.
    @Test func packBitsSpecExample() {
        let packed: [UInt8] = [0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80, 0x00, 0x2A, 0x22, 0xF7, 0xAA]
        let unpacked: [UInt8] =
            [0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0x22]
            + [UInt8](repeating: 0xAA, count: 10)
        #expect(TIFFCodecs.unpackBits(packed[...], expectedCount: unpacked.count) == unpacked)
        // Output is capped and padded to the expected size.
        #expect(TIFFCodecs.unpackBits(packed[...], expectedCount: 4) == Array(unpacked.prefix(4)))
        #expect(TIFFCodecs.unpackBits([0x00, 0x05][...], expectedCount: 3) == [5, 0, 0])
    }

    @Test func horizontalPredictor16BitBigEndian() throws {
        // Two pixels per row: 1000, then +5 → 1005.
        var data: [UInt8] = [0x03, 0xE8, 0x00, 0x05]
        try TIFFCodecs.undoHorizontalDifferencing(
            &data, rowBytes: 4, rows: 1, samplesPerPixel: 1, bitsPerSample: 16, bigEndian: true)
        #expect(data == [0x03, 0xE8, 0x03, 0xED])
    }
}

@Suite("ImageJ description")
struct ImageJDescriptionTests {
    @Test func parsesHyperstackKeys() throws {
        let text = "ImageJ=1.54p\nimages=24\nchannels=2\nslices=3\nframes=4\nhyperstack=true\nmode=composite\n"
            + "unit=\\u00B5m\nspacing=2.0\nfinterval=1.5\nmin=10.0\nmax=4000.0\n"
        let d = try #require(ImageJDescription(text))
        #expect(d.version == "1.54p")
        #expect((d.images, d.channels, d.slices, d.frames) == (24, 2, 3, 4))
        #expect(d.isHyperstack)
        #expect(d.compositeMode == .composite)
        #expect(d.unit == "µm")
        #expect(d.spacing == 2.0)
        #expect(d.frameInterval == 1.5)
        #expect(d.displayRange == 10...4000)
    }

    @Test func propertiesSyntax() {
        let p = ImageJDescription.parseProperties("# comment\n  a = 1\nb:2\nc 3\nlong=x\\\n   y\npath=C:\\\\data\nempty=\r\n")
        #expect(p["a"] == "1")
        #expect(p["b"] == "2")
        #expect(p["c"] == "3")
        #expect(p["long"] == "xy")
        #expect(p["path"] == "C:\\data")
        #expect(p["empty"] == "")
        #expect(p["# comment"] == nil)
    }

    @Test func notImageJ() {
        #expect(ImageJDescription("{\"shape\": [3, 4]}") == nil)
        #expect(ImageJDescription("ImageJ=1.54p\nmin=0.0\nmax=0.0\n")?.displayRange == nil)
    }
}
