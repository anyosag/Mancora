import MancoraCore
import Testing

@testable import MancoraIO

@Suite("ROI files written by ImageJ")
struct RoiCodecTests {
    @Test func fixturesPresent() throws {
        let golden = try #require(RoiFixtures.file)
        #expect(golden.imagej == "1.54p")
        #expect(golden.rois.count >= 100)
        for entry in golden.rois { #expect(!entry.bytes.isEmpty, "missing \(entry.file)") }
        #expect(!golden.rois.filter { !$0.reencodedIdentical }.allSatisfy { $0.reencodedBytes.isEmpty })
    }

    /// Every field RoiDecoder sets, compared with the ROI ImageJ read.
    @Test("Decodes as RoiDecoder", arguments: RoiFixtures.entries)
    func decodesLikeImageJ(entry: RoiFixtures.Entry) throws {
        let roi = try RoiCodec.decode(entry.bytes, name: entry.file)
        #expect(roi.kind.rawValue == entry.type)
        if entry.class != "Arrow" && entry.splineFit != true {  // ImageJ computes these from the arrow head and spline
            #expect(roi.bounds == entry.roiBounds)
        }
        if entry.isOpaque {
            guard case .opaque(let opaque) = roi.shape else {
                Issue.record("\(entry.file) should decode as opaque")
                return
            }
            let kinds: [String: Roi.Opaque.Kind] = ["ShapeRoi": .composite, "TextRoi": .text, "ImageRoi": .image]
            #expect(opaque.kind == kinds[entry.class])
            #expect(opaque.bytes == entry.bytes)
            #expect(roi.name == entry.name)
            #expect(roi.strokeColor == entry.strokeColor && roi.fillColor == entry.fillColor)
            #expect(roi.position == .none && roi.group == entry.group)
        } else {
            let expected = try #require(entry.roi())
            #expect(roi == expected)
        }
        #expect(try RoiCodec.decode(entry.bytes).name == entry.storedName)
    }

    @Test("Masks of decoded ROIs equal ImageJ's", arguments: RoiFixtures.entries.filter {
        $0.image != nil && !$0.isOpaque && $0.splineFit != true
    })
    func decodedMasksMatchImageJ(entry: RoiFixtures.Entry) throws {
        let golden = try #require(RoiFixtures.file)
        let roi = try RoiCodec.decode(entry.bytes)
        if let expected = entry.mask {
            let mask = try roi.mask()
            #expect(mask.bounds == entry.roiBounds)
            let n = entry.bounds[2] * entry.bounds[3]
            #expect(mask.pixels == (expected == "all" ? [Bool](repeating: true, count: n) : RoiFixtures.bits(expected, count: n)))
        }
        let (w, h) = (golden.imageWidth, golden.imageHeight)
        let clipped = try roi.mask(width: w, height: h)
        let image = (0..<(w * h)).map { clipped[x: $0 % w, y: $0 / w] }
        #expect(image == RoiFixtures.bits(try #require(entry.image), count: w * h))
    }

    /// `encode(decode(file))` is what ImageJ writes when it re-saves the file.
    @Test("Re-encodes as RoiEncoder", arguments: RoiFixtures.entries)
    func reencodesLikeImageJ(entry: RoiFixtures.Entry) throws {
        let encoded = RoiCodec.encode(try RoiCodec.decode(entry.bytes))
        if entry.isOpaque {
            #expect(encoded == entry.bytes, "opaque ROIs are written back unchanged")
        } else {
            expectSameEncoding(encoded, entry.reencodedBytes, entry)
        }
    }

    /// The ROI built from ImageJ's description (not decoded) encodes to
    /// RoiEncoder's bytes.
    @Test("Encodes as RoiEncoder", arguments: RoiFixtures.entries.filter { !$0.isOpaque })
    func encodesLikeImageJ(entry: RoiFixtures.Entry) throws {
        let roi = try #require(entry.roi(storedNameOnly: true))
        expectSameEncoding(RoiCodec.encode(roi), entry.reencodedBytes, entry)
    }

    /// Byte equality, except where RoiEncoder's bounds come from Java2D
    /// (arrow heads) or the spline (spline-fitted outlines): RoiDecoder
    /// ignores the header bounds (bytes 8–15) for lines, and both those and
    /// the integer vertices (relative to the bounds) for subpixel outlines.
    private func expectSameEncoding(_ encoded: [UInt8], _ expected: [UInt8], _ entry: RoiFixtures.Entry) {
        guard entry.class == "Arrow" || entry.splineFit == true else {
            #expect(encoded == expected, "\(firstDifference(encoded, expected))")
            return
        }
        #expect(encoded.count == expected.count)
        var a = encoded, b = expected
        var ignored = Array(8..<16)
        if entry.splineFit == true, entry.subpixel { ignored += 64..<(64 + 4 * (entry.xs?.count ?? 0)) }
        for i in ignored where i < a.count && i < b.count { (a[i], b[i]) = (0, 0) }
        #expect(a == b, "\(firstDifference(a, b))")
    }

    private func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> String {
        guard let i = (0..<min(a.count, b.count)).first(where: { a[$0] != b[$0] }) else {
            return a.count == b.count ? "identical" : "lengths \(a.count) and \(b.count)"
        }
        return "first difference at byte \(i): \(a[i]) vs \(b[i]) (lengths \(a.count), \(b.count))"
    }

    @Test func readsFilesByPath() throws {
        let roi = try RoiCodec.read(path: Fixtures.path("Tests/Fixtures/roi/oval-17x11.roi"))
        #expect(roi.name == "oval-17x11")
        #expect(roi.shape == .oval(.integer(x: 4, y: 5, width: 17, height: 11)))
        #expect(throws: MancoraIOError.self) { try RoiCodec.read(path: Fixtures.path("Tests/Fixtures/roi/missing.roi")) }
    }
}

@Suite("ROI encoding")
struct RoiEncodingTests {
    @Test func roundTripsEveryShape() throws {
        let shapes: [Roi.Shape] = [
            .rectangle(.integer(x: -4, y: 7, width: 30, height: 2), cornerDiameter: 5),
            .rectangle(.subpixel(x: 0.25, y: -3.5, width: 2.125, height: 9)),
            .oval(.subpixel(x: 1, y: 2, width: 3.5, height: 4.25)),
            .polygon(Roi.Polygon(.traced, .integer([.init(x: 3, y: 3), .init(x: 9, y: 3), .init(x: 9, y: 4)]))),
            .polygon(Roi.Polygon(.angle, .subpixel([.init(x: 1.5, y: 2), .init(x: 3, y: 4.75), .init(x: 9, y: 1)]))),
            .line(Roi.Line(x1: 1.5, y1: 2.5, x2: -3, y2: 40, arrow: Roi.Arrow(style: .bar, headSize: 7, outline: true))),
            .points(Roi.Points(.subpixel([.init(x: 3.25, y: 4), .init(x: 7, y: 8)]), pointType: .circle, size: 6, counters: [4, 9], positions: [2, 3])),
        ]
        for shape in shapes {
            var isPoints = false
            if case .points = shape { isPoints = true }
            let roi = Roi(
                shape, name: "r ✓", strokeColor: 0x80FF_0000, fillColor: 0xFF00_FF00,
                strokeWidth: isPoints ? 0 : 1.5,  // a point ROI's stroke width would replace its size
                position: .hyperstack(channel: 1, slice: 0, frame: 3), group: 12, properties: "k: v\n",
                labels: Roi.OverlayLabels(drawNames: true, color: 0xFF12_3456, font: .init(size: 11, bold: true)))
            #expect(try RoiCodec.decode(RoiCodec.encode(roi)) == roi, "\(shape)")
        }
    }

    /// RoiDecoder rebuilds the rotated rectangle tool's ROIs (freehand type)
    /// from their parameters; ImageJ saves them as polygons, which it then
    /// reads as plain polygons. Mancora does both the same way.
    @Test func rotatedRectangles() throws {
        let entry = try #require(RoiFixtures.entries.first { $0.file == "rotated-rect-tool.roi" })
        let roi = try RoiCodec.decode(entry.bytes)
        let expected = Roi.Polygon.rotatedRectangle(x1: 4, y1: 30, x2: 35, y2: 8, width: 9)
        #expect(roi.shape == .polygon(expected))
        guard case .polygon(let saved) = try RoiCodec.decode(RoiCodec.encode(roi)).shape else { return #expect(Bool(false)) }
        #expect(saved.kind == .polygon && saved.parametric == nil)
    }

    @Test func pointPositions() throws {
        // PointRoi.setPosition(n) gives every point the position.
        var roi = Roi(.points(Roi.Points(.integer([.init(x: 1, y: 2), .init(x: 3, y: 4)]))), position: .stack(6))
        var back = try RoiCodec.decode(RoiCodec.encode(roi))
        guard case .points(let p) = back.shape else { return #expect(Bool(false)) }
        #expect(p.positions == [6, 6] && back.position == .none)
        // Different positions are saved as POINTWISE_POSITION (-2).
        roi = Roi(.points(Roi.Points(.integer([.init(x: 1, y: 2), .init(x: 3, y: 4)]), counters: [1, 2], positions: [3, 4])))
        let bytes = RoiCodec.encode(roi)
        #expect(Array(bytes[56..<60]) == [0xFF, 0xFF, 0xFF, 0xFE])
        back = try RoiCodec.decode(bytes)
        guard case .points(let q) = back.shape else { return #expect(Bool(false)) }
        #expect(q.counters == [1, 2] && q.positions == [3, 4])
        #expect(q.vertices == .subpixel([.init(x: 1, y: 2), .init(x: 3, y: 4)]), "PointRoi always stores floats")
    }

    /// RoiEncoder would convert such polygons to composite ROIs; Mancora
    /// stores the 32-bit count that RoiDecoder reads for any type.
    @Test func polygonsWithMoreThan65535Vertices() throws {
        let n = 70_000
        let points = (0..<n).map { Roi.IntPoint(x: Int32($0 % 997), y: Int32($0 / 997)) }
        let roi = Roi(.polygon(Roi.Polygon(.traced, .integer(points))))
        let bytes = RoiCodec.encode(roi)
        #expect(bytes[16] == 0 && bytes[17] == 0)
        #expect(Array(bytes[18..<22]) == [0, 1, 0x11, 0x70])
        #expect(try RoiCodec.decode(bytes).shape == roi.shape)
    }

    @Test func farRoisBecomeSubpixel() throws {
        // RoiEncoder.enableSubPixelResolution() beyond 60000 pixels.
        let roi = Roi(.rectangle(.integer(x: 61_000, y: 5, width: 10, height: 10)))
        let back = try RoiCodec.decode(RoiCodec.encode(roi))
        #expect(back.shape == .rectangle(.subpixel(x: 61_000, y: 5, width: 10, height: 10)))
        #expect(back.bounds == roi.bounds)
    }
}

@Suite("Malformed ROI files fail safely")
struct MalformedRoiTests {
    @Test func everyTruncationThrowsOrDecodes() {
        for entry in RoiFixtures.entries {
            let bytes = entry.bytes
            for length in 0..<bytes.count {
                let decoded = try? RoiCodec.decode(Array(bytes[..<length]))
                if length < 64 { #expect(decoded == nil, "\(entry.file) cut to \(length) bytes") }
            }
        }
    }

    @Test func corruptedHeadersDontCrash() {
        var decoded = 0
        for entry in RoiFixtures.entries {
            let bytes = entry.bytes
            for offset in 0..<min(bytes.count, 160) {
                for value: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xEC, 0xFF] where bytes[offset] != value {
                    var b = bytes
                    b[offset] = value
                    guard let roi = try? RoiCodec.decode(b) else { continue }
                    decoded += 1
                    let r = roi.bounds
                    if roi.isArea, r.height < 50_000, r.width < 50_000 { _ = try? roi.mask(width: 48, height: 40) }
                    _ = RoiCodec.encode(roi)
                }
            }
        }
        #expect(decoded > 0)
    }

    @Test func rejectsWhatImageJRejects() throws {
        let rect = try #require(RoiFixtures.entries.first { $0.file == "rect-int.roi" }).bytes
        #expect(throws: MancoraIOError.invalidFormat("not an ImageJ ROI")) { try RoiCodec.decode([UInt8]("Xout".utf8) + rect.dropFirst(4)) }
        #expect((try? RoiCodec.decode([UInt8]("Iota".utf8) + rect.dropFirst(4))) != nil, "RoiDecoder only checks \"Io\"")
        var b = rect
        b[6] = 6  // "noRoi"
        #expect(throws: MancoraIOError.invalidFormat("unrecognized ROI type 6")) { try RoiCodec.decode(b) }
        b[6] = 2
        b[36] = 1  // a composite must be of type rect
        #expect(throws: MancoraIOError.self) { try RoiCodec.decode(b) }
        // A polygon claiming 2^31 - 1 vertices (32-bit count) in a tiny file.
        var p = try #require(RoiFixtures.entries.first { $0.file == "polygon-triangle.roi" }).bytes
        p[16] = 0
        p[17] = 0
        p.replaceSubrange(18..<22, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: MancoraIOError.self) { try RoiCodec.decode(p) }
        // No vertices: RoiDecoder returns null.
        p.replaceSubrange(18..<22, with: [0, 0, 0, 0])
        #expect(throws: MancoraIOError.invalidFormat("the ROI has no coordinates")) { try RoiCodec.decode(p) }
        // A name pointing past the end falls back to the file name; a negative one is an error.
        var named = try #require(RoiFixtures.entries.first { $0.file == "named-unicode.roi" }).bytes
        let hdr2 = Int(named[60]) << 24 | Int(named[61]) << 16 | Int(named[62]) << 8 | Int(named[63])
        named.replaceSubrange((hdr2 + 20)..<(hdr2 + 24), with: [0, 0x10, 0, 0])
        #expect(try RoiCodec.decode(named, name: "x.roi").name == "x")
        named.replaceSubrange((hdr2 + 16)..<(hdr2 + 24), with: [0xFF, 0xFF, 0xFF, 0x00, 0, 0, 0, 2])
        #expect(throws: MancoraIOError.self) { try RoiCodec.decode(named) }
    }
}
