import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

/// Differences between two images that a TIFF round trip must preserve, or
/// `nil` if there are none. LUTs compare by color (names aren't saved) and
/// pixel sizes to the precision of TIFF's rational resolution fields.
func imageDifferences(_ a: Hyperstack, _ b: Hyperstack) -> String? {
    var problems: [String] = []
    if a.dimensions != b.dimensions { problems.append("dimensions \(a.dimensions) ≠ \(b.dimensions)") }
    if a.pixelType != b.pixelType { problems.append("type \(a.pixelType) ≠ \(b.pixelType)") }
    if a.stack.count == b.stack.count {
        for k in 0..<a.stack.count {
            if let m = firstMismatch(b.stack[k], a.stack[k], width: a.width) { problems.append("plane \(k): \(m)") }
        }
    }
    if a.stack.labels != b.stack.labels { problems.append("labels \(a.stack.labels) ≠ \(b.stack.labels)") }
    if a.channels.count == b.channels.count {
        for (c, (x, y)) in zip(a.channels, b.channels).enumerated() {
            if !x.lut.hasSameColors(as: y.lut) { problems.append("channel \(c) LUT \(x.lut.name) ≠ \(y.lut.name)") }
            if x.displayRange != y.displayRange { problems.append("channel \(c) range \(x.displayRange) ≠ \(y.displayRange)") }
        }
    } else {
        problems.append("\(a.channels.count) ≠ \(b.channels.count) channels")
    }
    if a.dimensions.channels > 1, a.compositeMode != b.compositeMode {
        problems.append("mode \(a.compositeMode) ≠ \(b.compositeMode)")
    }
    var ca = a.calibration, cb = b.calibration
    for (x, y) in [(ca.pixelWidth, cb.pixelWidth), (ca.pixelHeight, cb.pixelHeight)] where abs(x - y) > 1e-6 * abs(x) {
        problems.append("pixel size \(x) ≠ \(y)")
    }
    ca.pixelWidth = 0; ca.pixelHeight = 0; cb.pixelWidth = 0; cb.pixelHeight = 0
    if ca != cb { problems.append("calibration \(ca) ≠ \(cb)") }
    if a.info != b.info { problems.append("info \(a.info ?? "nil") ≠ \(b.info ?? "nil")") }
    if a.properties != b.properties { problems.append("properties \(a.properties) ≠ \(b.properties)") }
    if a.encodedROI != b.encodedROI { problems.append("ROI differs") }
    if a.encodedOverlay != b.encodedOverlay { problems.append("overlay differs") }
    return problems.isEmpty ? nil : problems.joined(separator: "; ")
}

@Suite("ImageJ metadata in TIFFs")
struct TIFFMetadataTests {
    func open(_ name: String) throws -> Hyperstack {
        try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/\(name)"))
    }

    /// ImageJFixtures.writeMetadata, saved in both byte orders.
    @Test(arguments: ["ij-metadata-be.tif", "ij-metadata-le.tif"])
    func everyRecordType(_ name: String) throws {
        let image = try open(name)
        #expect(image.dimensions == HyperstackDimensions(channels: 2, slices: 3))
        for k in 0..<6 {
            let expected = Plane.gray16((0..<(image.width * image.height)).map {
                Patterns.hyperstack(k, $0 % image.width, $0 / image.width)
            })
            #expect(image.stack[k] == expected)
        }
        #expect(image.stack.labels == ["plane 1", "plane 2 µm ✓", "plane 3", "plane 4", nil, "plane 6"])
        #expect(image.info == "Acquired by Mancora fixtures\nObjective: 63× / 1.4\nGrüße → μm")
        #expect(image.properties == ["Experiment": "MC-42", "Operator": "fixture été"])
        #expect(image.compositeMode == .color)
        #expect(image.channels[0].lut.hasSameColors(as: .magenta))
        #expect(image.channels[0].lut.name == "Magenta")
        #expect(image.channels[1].lut.hasSameColors(as: .fire))
        #expect(image.channels.map(\.displayRange) == [5...1500, 1000...1200])

        let cal = image.calibration
        #expect((cal.pixelWidth, cal.pixelHeight, cal.pixelDepth) == (0.125, 0.125, 0.5))
        #expect(cal.unit == "µm")
        #expect((cal.xOrigin, cal.yOrigin) == (4, 2.5))
        #expect(cal.valueFunction == .straightLine(intercept: -10, slope: 0.5))
        #expect(cal.valueUnit == "nM")

        // RoiEncoder records start with "Iout".
        let roi = try #require(image.encodedROI)
        #expect(roi.count == 128 && Array(roi.prefix(4)) == Array("Iout".utf8))
        #expect(image.encodedOverlay.map(\.count) == [134, 128, 140])
        #expect(image.encodedOverlay.allSatisfy { Array($0.prefix(4)) == Array("Iout".utf8) })
    }

    @Test func invertedLUTOn16Bit() throws {
        let image = try open("ij-16bit-lut-inverted.tif")
        #expect(image.channels[0].lut.hasSameColors(as: LUT.fire.inverted()))
        #expect(image.channels[0].displayRange == 100...30000)
    }

    @Test func signed16BitCalibration() throws {
        let image = try open("ij-16bit-signed.tif")
        #expect(image.calibration.valueFunction == .straightLine(intercept: -32768, slope: 1))
        #expect(image.calibration.valueUnit == "Gray Value")
        #expect(image.channels[0].displayRange == 31168...34291)
        #expect(image.calibration.calibratedValue(image.stack[0].value(at: 0)) == -1600)
    }

    @Test func otherWritersTextTagsBecomeInfo() throws {
        let image = try open("tf-gray8-zlib.tif")
        #expect(image.info?.hasPrefix("Software: tifffile") == true)
        #expect(image.properties.isEmpty)
    }

    /// TiffDecoder turns ResolutionUnit 1 ("no absolute unit") into the unit
    /// " "; without the tag a file is uncalibrated.
    @Test func resolutionUnitsAsImageJReadsThem() throws {
        let none = try open("tf-gray8-zlib.tif").calibration  // XResolution 1/1, ResolutionUnit 1
        #expect((none.unit, none.pixelWidth, none.pixelHeight) == (" ", 1, 1))
        let missing = try open("im-bilevel-minisblack.tif").calibration
        #expect(missing == Calibration())
    }

    @Test func malformedMetadataIsIgnored() {
        let good = ImageJMetadata(counts: [12, 4], data: Array("IJIJinfo\0\0\0\u{1}\0H\0i".utf8)[...], bigEndian: true)
        #expect(good?.info == "Hi")
        // Wrong magic, a header size ImageJ rejects, and counts past the data.
        #expect(ImageJMetadata(counts: [12, 4], data: Array("XJIJinfo\0\0\0\u{1}\0H\0i".utf8)[...], bigEndian: true) == nil)
        #expect(ImageJMetadata(counts: [8, 4], data: Array("IJIJinfo".utf8)[...], bigEndian: true) == nil)
        #expect(ImageJMetadata(counts: [12, 400], data: Array("IJIJinfo\0\0\0\u{1}\0H\0i".utf8)[...], bigEndian: true) == nil)
        #expect(ImageJMetadata(counts: [12], data: Array("IJIJinfo\0\0\0\u{1}".utf8)[...], bigEndian: true) == nil)
    }

    /// TiffDecoder reads ImageJ's private tags without checking where they
    /// point, and skips records whose header doesn't check out; the image
    /// opens without them.
    @Test func unreadableMetadataTagsAreIgnored() throws {
        let pixels: [UInt8] = [1, 2, 3, 4]
        for tag: UInt16 in [50838, 50839] {
            var b = TIFFBuilder.gray8(width: 2, height: 2, pixels: pixels)
            b.set(50838, 4, [12, 8])
            b.set(50839, 1, Array("IJIJinfo\0\0\0\u{1}\0H\0i".utf8).map(UInt32.init))
            b.valueOffsets[tag] = 0x00FF_FFF0  // past the end of the file
            let image = try TIFFImporter.decode(b.build(), title: "x")
            #expect(image.stack[0] == .gray8(pixels))
            #expect(image.info == nil)
        }
    }

    @Test func metadataRoundTrip() throws {
        var m = ImageJMetadata()
        m.info = "ünïcödé ✓ 𝛑"
        m.labels = ["a", nil, "c"]
        m.ranges = [0, 255, -1.5, 1e300]
        m.luts = [[UInt8](repeating: 7, count: 768)]
        m.roi = [1, 2, 3]
        m.overlay = [[4], [5, 6]]
        m.properties = ["k", "v", "empty", ""]
        for bigEndian in [false, true] {
            let (counts, data) = m.encoded(bigEndian: bigEndian)
            let back = try #require(ImageJMetadata(counts: counts.map(Int.init), data: data[...], bigEndian: bigEndian))
            #expect(back == m)
        }
    }
}

@Suite("TIFF writer")
struct TIFFExporterTests {
    static let fixtureNames: [String] =
        Fixtures.tiffManifest.map(\.file) + [
            "ij-hyperstack-16bit.tif", "ij-8bit-fire.tif", "ij-stack-8bit.tif", "ij-32bit-float.tif", "ij-rgb.tif",
            "ij-metadata-be.tif", "ij-metadata-le.tif", "ij-16bit-lut-inverted.tif", "ij-16bit-signed.tif",
        ]

    /// Every image Mancora reads survives being saved and read again.
    @Test("Round trip", arguments: fixtureNames)
    func roundTrip(_ name: String) throws {
        let original = try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/\(name)"))
        for bigEndian in [false, true] {
            let bytes = try TIFFExporter.encode(original, options: .init(bigEndian: bigEndian))
            let reread = try TIFFImporter.decode(bytes, title: original.title)
            let diff = imageDifferences(original, reread)
            #expect(diff == nil, "\(bigEndian ? "big" : "little")-endian: \(diff ?? "")")
        }
    }

    /// Re-saving what ImageJ saved reproduces its file exactly, apart from
    /// the order of image properties (a Java Hashtable's).
    @Test(
        "Same bytes as ImageJ",
        arguments: [
            "ij-hyperstack-16bit.tif", "ij-8bit-fire.tif", "ij-stack-8bit.tif", "ij-32bit-float.tif", "ij-rgb.tif",
            "ij-16bit-lut-inverted.tif", "ij-16bit-signed.tif",
        ])
    func byteIdentical(_ name: String) throws {
        let path = Fixtures.path("Tests/Fixtures/tiff/\(name)")
        let imagej = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let mancora = try TIFFExporter.encode(try TIFFImporter.read(path: path))
        #expect(mancora.count == imagej.count)
        let first = zip(mancora, imagej).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(first == nil, "first difference at byte \(first ?? -1)")
    }

    @Test func metadataFileMatchesImageJBesidesPropertyOrder() throws {
        for (name, bigEndian) in [("ij-metadata-be.tif", true), ("ij-metadata-le.tif", false)] {
            let path = Fixtures.path("Tests/Fixtures/tiff/\(name)")
            let imagej = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            var image = try TIFFImporter.read(path: path)
            #expect(TIFFExporter.descriptionString(image) + "\0" == String(decoding: descriptionBytes(imagej), as: UTF8.self))
            // With no properties both files have the same layout and size.
            image.properties = [:]
            let mancora = try TIFFExporter.encode(image, options: .init(bigEndian: bigEndian))
            let propertyBytes = 2 * ("Experiment" + "MC-42" + "Operator" + "fixture été").utf16.count + 4 * 4 + 8
            #expect(mancora.count == imagej.count - propertyBytes)
        }
    }

    /// The raw ImageDescription of a TIFF's first IFD.
    func descriptionBytes(_ file: [UInt8]) -> [UInt8] {
        let reader = ByteReader(file, bigEndian: file[0] == 0x4D)
        guard let ifd = try? TIFFDirectory(reader: reader, offset: Int(try reader.u32(at: 4))),
            let entry = ifd.entries[TIFFTag.imageDescription]
        else { return [] }
        return Array(file[entry.valueOffset..<(entry.valueOffset + entry.count)])
    }

    @Test func descriptionKeys() throws {
        let stack = try ImageStack(width: 2, height: 1, planes: (0..<12).map { _ in .gray32Float([0, 1]) })
        var image = try Hyperstack(
            title: "t", stack: stack, dimensions: HyperstackDimensions(channels: 1, slices: 3, frames: 4))
        image.calibration.unit = "\\µm"
        image.calibration.pixelWidth = 0.3
        image.calibration.frameInterval = 2
        image.calibration.timeUnit = "min"
        image.calibration.fps = 7.5
        image.calibration.loop = true
        image.calibration.zOrigin = -1e-5
        image.calibration.invertY = true
        image.calibration.valueUnit = "dB"
        image.setDisplay(ChannelDisplay(lut: .grays, displayRange: 0...1e7), forChannel: 0)
        #expect(
            TIFFExporter.descriptionString(image) == """
                ImageJ=1.54p
                images=12
                slices=3
                frames=4
                hyperstack=true
                unit=\\u005C\\u00B5m
                vunit=dB
                finterval=2
                tunit=min
                fps=7.5
                loop=true
                min=0.0
                max=1.0E7
                zorigin=-1.0E-5
                inverty=true

                """)
        // ImageJ's integer arithmetic for the resolution of 1/0.3 pixels per unit.
        let scale = try #require(TIFFExporter.resolution(image.calibration))
        #expect(scale.x == (3_333_333, 1_000_000))
        #expect(scale.unit == 1)
    }

    @Test func refusesMultiChannelRGB() throws {
        let stack = try ImageStack(width: 1, height: 1, planes: [.rgb8([0]), .rgb8([0])])
        let image = try Hyperstack(title: "t", stack: stack, dimensions: HyperstackDimensions(channels: 2))
        #expect(throws: MancoraIOError.self) { try TIFFExporter.encode(image) }
    }
}

@Suite("Java number formatting")
struct JavaNumberTests {
    /// Expected strings printed by `Double.toString` on OpenJDK 21.
    @Test func matchesJava() {
        let cases: [(Double, String)] = [
            (0.0, "0.0"), (-0.0, "-0.0"), (1.0, "1.0"), (-1.0, "-1.0"), (0.5, "0.5"), (0.1, "0.1"), (0.001, "0.001"),
            (9.9E-4, "9.9E-4"), (1.0E-4, "1.0E-4"), (1.0E-5, "1.0E-5"), (1.234E-5, "1.234E-5"), (123.456, "123.456"),
            (4095.0, "4095.0"), (65535.0, "65535.0"), (-32768.0, "-32768.0"), (1234567.0, "1234567.0"),
            (9999999.0, "9999999.0"), (1.0E7, "1.0E7"), (1.0000001E7, "1.0000001E7"), (1.23456789E7, "1.23456789E7"),
            (1.0E21, "1.0E21"), (1.0E22, "1.0E22"), (1.0E23, "1.0E23"), (0.002, "0.002"),
            (3.141592653589793, "3.141592653589793"), (2.718281828459045, "2.718281828459045"),
            (1.0 / 3, "0.3333333333333333"), (2.0 / 3, "0.6666666666666666"), (0.1 + 0.2, "0.30000000000000004"),
            (.greatestFiniteMagnitude, "1.7976931348623157E308"), (.leastNormalMagnitude, "2.2250738585072014E-308"),
            (0.0645, "0.0645"), (0.1625, "0.1625"), (100.0, "100.0"), (1.23E-4, "1.23E-4"), (-11.5, "-11.5"),
            (7.75, "7.75"), (3.0E10, "3.0E10"), (2.99792458E8, "2.99792458E8"), (Double(Float(0.1)), "0.10000000149011612"),
            (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
        ]
        for (value, java) in cases {
            #expect(JavaNumerics.string(value) == java)
        }
    }
}
