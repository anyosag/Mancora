import Foundation
import Testing

@testable import MancoraCore

/// ImageJ 1.54p's ROIs and masks, as recorded by Tools/fixtures/RoiFixtures.java
/// (each ROI as RoiDecoder reads it back from the `.roi` file).
enum RoiGolden {
    struct File: Decodable {
        let imagej: String
        let imageWidth: Int
        let imageHeight: Int
        let rois: [Entry]
    }

    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        let file: String
        let `class`: String
        let type: Int
        let subpixel: Bool
        let bounds: [Int]
        let floatBounds: [Double]
        let cornerDiameter: Int?
        let line: [Double]?
        let xs: [Double]?
        let ys: [Double]?
        let xi: [Int32]?
        let yi: [Int32]?
        let splineFit: Bool?
        let params: [Double]?
        /// `Roi.getMask()` as hex bits, "all" where ImageJ returns null.
        let mask: String?
        /// `ImageProcessor.fill(roi)` on the 48×40 image, as hex bits.
        let image: String?

        var testDescription: String { file }

        var roiBounds: RoiBounds { RoiBounds(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }

        /// The ROI's geometry, built from ImageJ's description (not by decoding).
        var shape: Roi.Shape? {
            let rect: Roi.Rect =
                subpixel
                ? .subpixel(x: floatBounds[0], y: floatBounds[1], width: floatBounds[2], height: floatBounds[3])
                : .integer(x: Int32(bounds[0]), y: Int32(bounds[1]), width: Int32(bounds[2]), height: Int32(bounds[3]))
            switch `class` {
            case "Roi": return .rectangle(rect, cornerDiameter: cornerDiameter ?? 0)
            case "OvalRoi": return .oval(rect)
            case "PolygonRoi", "EllipseRoi", "RotatedRectRoi":
                let kind: Roi.Polygon.Kind = [2: .polygon, 3: .freehand, 4: .traced, 6: .polyline, 7: .freeline, 8: .angle][type]!
                var parametric: Roi.Polygon.Parametric?
                if `class` == "EllipseRoi" { parametric = .ellipse(aspectRatio: params![4]) }
                if `class` == "RotatedRectRoi" { parametric = .rotatedRectangle(width: params![4]) }
                return .polygon(Roi.Polygon(kind, vertices, splineFit: splineFit ?? false, parametric: parametric))
            case "Line", "Arrow":
                return .line(Roi.Line(x1: line![0], y1: line![1], x2: line![2], y2: line![3]))
            case "PointRoi":
                return .points(Roi.Points(vertices))
            default:
                return nil
            }
        }

        var vertices: Roi.Vertices {
            if let xs, let ys {
                return .subpixel(zip(xs, ys).map { Roi.FloatPoint(x: Float($0), y: Float($1)) })
            }
            return .integer(zip(xi ?? [], yi ?? []).map { Roi.IntPoint(x: $0, y: $1) })
        }
    }

    static let file: File? = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        let path = parts.joined(separator: "/") + "/Tests/Fixtures/roi/golden.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var entries: [Entry] { file?.rois ?? [] }

    /// Area ROIs with an ImageJ mask that Mancora computes.
    static var masked: [Entry] {
        entries.filter { $0.image != nil && $0.class != "ShapeRoi" && $0.splineFit != true }
    }

    /// Mask bits from a hex string (row-major, most significant bit first).
    static func bits(_ hex: String, count: Int) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(count)
        for c in hex.utf8 {
            let v = c <= 57 ? Int(c) - 48 : Int(c | 0x20) - 87
            for bit in (0..<4).reversed() where out.count < count { out.append(v >> bit & 1 == 1) }
        }
        return out
    }
}

@Suite("ROI masks match ImageJ")
struct RoiMaskTests {
    @Test func goldenPresent() throws {
        let golden = try #require(RoiGolden.file)
        #expect(golden.imagej == "1.54p")
        #expect(golden.rois.count >= 100)
        #expect(RoiGolden.masked.count >= 60)
    }

    /// Roi.getMask(): the exact pixels, at ImageJ's bounds.
    @Test("Mask equals Roi.getMask()", arguments: RoiGolden.masked)
    func maskMatchesImageJ(entry: RoiGolden.Entry) throws {
        let roi = Roi(try #require(entry.shape))
        let mask = try roi.mask()
        #expect(mask.bounds == entry.roiBounds)
        guard let expected = entry.mask else { return }  // over 20000 pixels: not recorded
        let pixels =
            expected == "all"
            ? [Bool](repeating: true, count: mask.pixels.count)
            : RoiGolden.bits(expected, count: entry.bounds[2] * entry.bounds[3])
        #expect(mask.pixels == pixels, "\(differences(mask.pixels, pixels, width: entry.bounds[2]))")
    }

    /// ImageProcessor.fill(roi) on a 48×40 image: the mask clipped to the image.
    @Test("Image mask equals ImageProcessor.fill(roi)", arguments: RoiGolden.masked)
    func imageMaskMatchesImageJ(entry: RoiGolden.Entry) throws {
        let golden = try #require(RoiGolden.file)
        let (w, h) = (golden.imageWidth, golden.imageHeight)
        let roi = Roi(try #require(entry.shape))
        let mask = try roi.mask(width: w, height: h)
        #expect(mask.bounds.x >= 0 && mask.bounds.y >= 0)
        #expect(mask.bounds.x + mask.bounds.width <= w && mask.bounds.y + mask.bounds.height <= h)
        var image = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask[x: x, y: y] { image[y * w + x] = true }
        }
        let expected = RoiGolden.bits(try #require(entry.image), count: w * h)
        #expect(image == expected, "\(differences(image, expected, width: w))")
    }

    @Test("Bounds equal Roi.getBounds()", arguments: RoiGolden.entries.filter { $0.class != "Arrow" && $0.splineFit != true })
    func boundsMatchImageJ(entry: RoiGolden.Entry) throws {
        guard let shape = entry.shape else { return }  // composite, text and image ROIs
        #expect(Roi(shape).bounds == entry.roiBounds)
    }

    private func differences(_ a: [Bool], _ b: [Bool], width: Int) -> String {
        let diffs = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map { "(\($0.offset % max(width, 1)), \($0.offset / max(width, 1)))" }
        return diffs.isEmpty ? "same" : "\(diffs.count) pixels differ: \(diffs.prefix(12).joined(separator: " "))"
    }
}

@Suite("ROI masks")
struct RoiMaskRuleTests {
    private func pixels(_ roi: Roi) throws -> Set<[Int]> {
        let m = try roi.mask()
        var set = Set<[Int]>()
        for y in m.bounds.y..<(m.bounds.y + m.bounds.height) {
            for x in m.bounds.x..<(m.bounds.x + m.bounds.width) where m[x: x, y: y] { set.insert([x, y]) }
        }
        return set
    }

    @Test func linesAndPointsHaveNoMask() {
        let line = Roi(.line(Roi.Line(x1: 1, y1: 2, x2: 10, y2: 3)))
        #expect(throws: RoiMaskError.notAnArea) { try line.mask() }
        let polyline = Roi(.polygon(Roi.Polygon(.polyline, .integer([.init(x: 1, y: 1), .init(x: 5, y: 9)]))))
        #expect(throws: RoiMaskError.notAnArea) { try polyline.mask(width: 10, height: 10) }
        let points = Roi(.points(Roi.Points(.subpixel([.init(x: 1, y: 1)]))))
        #expect(throws: RoiMaskError.notAnArea) { try points.mask() }
    }

    @Test func unsupportedShapesSaySo() {
        let spline = Roi(.polygon(Roi.Polygon(
            .polygon, .integer([.init(x: 1, y: 1), .init(x: 9, y: 2), .init(x: 4, y: 8)]), splineFit: true)))
        #expect(throws: RoiMaskError.unsupported("spline-fitted outlines")) { try spline.mask() }
        let composite = Roi(.opaque(Roi.Opaque(kind: .composite, bytes: [], bounds: RoiBounds(x: 0, y: 0, width: 1, height: 1))))
        #expect(throws: RoiMaskError.self) { try composite.mask() }
    }

    /// Pixel (x, y) is in when its center (x + 0.5, y + 0.5) is: an integer
    /// square selects exactly the pixels it covers.
    @Test func integerPolygonCoversWholePixels() throws {
        let square = Roi(.polygon(Roi.Polygon(
            .polygon, .integer([.init(x: 1, y: 1), .init(x: 4, y: 1), .init(x: 4, y: 3), .init(x: 1, y: 3)]))))
        #expect(try pixels(square) == [[1, 1], [2, 1], [3, 1], [1, 2], [2, 2], [3, 2]])
        #expect(square.bounds == RoiBounds(x: 1, y: 1, width: 3, height: 2))
    }

    @Test func roundedCornersAreCut() throws {
        let plain = try Roi(.rectangle(.integer(x: 0, y: 0, width: 10, height: 10))).mask()
        #expect(plain.count == 100)
        let rounded = try Roi(.rectangle(.integer(x: 0, y: 0, width: 10, height: 10), cornerDiameter: 6)).mask()
        #expect(rounded.count < 100 && rounded.count > 80)
        #expect(!rounded[x: 0, y: 0] && rounded[x: 5, y: 0] && rounded[x: 0, y: 5] && !rounded[x: 9, y: 9])
    }

    @Test func clippingToTheImage() throws {
        let rect = Roi(.rectangle(.integer(x: -3, y: 2, width: 10, height: 20)))
        let m = try rect.mask(width: 5, height: 8)
        #expect(m.bounds == RoiBounds(x: 0, y: 2, width: 5, height: 6))
        #expect(m.count == 30)
        let outside = Roi(.oval(.integer(x: 50, y: 50, width: 4, height: 4)))
        #expect(try outside.mask(width: 10, height: 10) == RoiMask(bounds: RoiBounds(x: 0, y: 0, width: 0, height: 0), pixels: []))
        #expect(!m[x: -1, y: 3] && !m[x: 100, y: 3])
    }

    @Test func tooLargeForImageJ() {
        let huge = Roi(.polygon(Roi.Polygon(
            .polygon, .subpixel([.init(x: -1e9, y: -1e9), .init(x: 1e9, y: -1e9), .init(x: 0, y: 1e9)]))))
        #expect(throws: RoiMaskError.self) { try huge.mask() }
        #expect(throws: RoiMaskError.self) { try huge.mask(width: 10, height: 10) }
    }

    @Test func subpixelRectanglesSelectTheirIntegerBounds() throws {
        // new Roi(1.7, 2.2, 2.0, 1.1): (int)x, (int)y, ceil(w), ceil(h).
        let r = Roi(.rectangle(.subpixel(x: 1.7, y: 2.2, width: 2.0, height: 1.1)))
        #expect(r.bounds == RoiBounds(x: 1, y: 2, width: 2, height: 2))
        #expect(try r.mask().count == 4)
        // ImageJ keeps at least one pixel.
        #expect(Roi(.oval(.integer(x: 3, y: 3, width: 0, height: -2))).bounds == RoiBounds(x: 3, y: 3, width: 1, height: 1))
    }

    @Test func javaRounding() {
        #expect(RoiJava.round(0.49999999999999994) == 0)
        #expect(RoiJava.round(-2.5) == -2)
        #expect(RoiJava.round(-0.5) == 0)
        #expect(RoiJava.round(2.5) == 3)
        #expect(RoiJava.round(-0.7) == -1)
        #expect(RoiJava.round(.nan) == 0)
        #expect(RoiJava.round(.infinity) == .max)
        #expect(RoiJava.round(-1e300) == .min)
        #expect(RoiJava.min(Float(0), -Float(0)).sign == .minus)
        #expect(RoiJava.max(Float.nan, 1).isNaN)
    }
}
