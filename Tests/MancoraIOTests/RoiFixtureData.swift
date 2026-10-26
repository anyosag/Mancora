import Foundation
import MancoraCore
import Testing

/// ImageJ 1.54p's ROI fixtures (Tools/fixtures/RoiFixtures.java): every ROI
/// as RoiDecoder reads it back, and the files RoiEncoder wrote.
enum RoiFixtures {
    struct File: Decodable {
        let imagej: String
        let imageWidth: Int
        let imageHeight: Int
        let rois: [Entry]
    }

    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        struct Arrow: Decodable, Sendable {
            let style: Int
            let headSize: Double
            let doubleHeaded: Bool
            let outline: Bool
        }

        struct Point: Decodable, Sendable {
            let type: Int
            let size: Int
            let showLabels: Bool
            let promptBeforeDeleting: Bool
            /// `PointRoi.getCounters()`: counter + (position << 8).
            let counters: [Int32]?
        }

        struct Font: Decodable, Sendable {
            let size: Int
            let bold: Bool
        }

        struct Overlay: Decodable, Sendable {
            let labels: Bool
            let names: Bool
            let backgrounds: Bool
            let color: UInt32?
            let font: Font?
            let scalable: Bool
        }

        let file: String
        /// Whether ImageJ writes the file back unchanged after reading it.
        let reencodedIdentical: Bool
        /// The name stored in the file (`RoiDecoder` without a file name).
        let storedName: String?
        let `class`: String
        let type: Int
        let subpixel: Bool
        let bounds: [Int]
        let floatBounds: [Double]
        let cornerDiameter: Int?
        let line: [Double]?
        let arrow: Arrow?
        let xs: [Double]?
        let ys: [Double]?
        let xi: [Int32]?
        let yi: [Int32]?
        let splineFit: Bool?
        let params: [Double]?
        let point: Point?
        /// `getName()` when read with the file name as the default.
        let name: String?
        let strokeColor: UInt32?
        let fillColor: UInt32?
        let strokeWidth: Double
        let scaleStrokeWidth: Bool
        let position: Int
        let hyperstack: Bool
        let cztPosition: [Int]
        let group: Int
        let properties: String?
        let overlay: Overlay
        let mask: String?
        let image: String?

        var testDescription: String { file }
        var stem: String { String(file.dropLast(4)) }
        var roiBounds: RoiBounds { RoiBounds(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }
        var isOpaque: Bool { ["ShapeRoi", "TextRoi", "ImageRoi"].contains(`class`) }

        /// The file's bytes.
        var bytes: [UInt8] { (try? [UInt8](Fixtures.data("Tests/Fixtures/roi/\(file)"))) ?? [] }

        /// What ImageJ writes when it re-saves the file it read.
        var reencodedBytes: [UInt8] {
            reencodedIdentical ? bytes : (try? [UInt8](Fixtures.data("Tests/Fixtures/roi/\(stem).reencoded.roi"))) ?? []
        }

        /// The file's format version.
        var version: Int { bytes.count >= 6 ? Int(bytes[4]) << 8 | Int(bytes[5]) : 0 }

        /// The ROI ImageJ describes, built field by field (independently of
        /// Mancora's decoder). `name` is the decoded name with the file name
        /// as default, or the stored one.
        func roi(storedNameOnly: Bool = false) -> Roi? {
            guard let shape else { return nil }
            var roiPosition = Roi.Position.none
            if hyperstack {
                roiPosition = .hyperstack(channel: cztPosition[0], slice: cztPosition[1], frame: cztPosition[2])
            } else if position > 0, `class` != "PointRoi" {  // points keep their positions per point
                roiPosition = .stack(position)
            }
            let labels = Roi.OverlayLabels(
                drawLabels: overlay.labels, drawNames: overlay.names, drawBackgrounds: overlay.backgrounds,
                color: overlay.color, font: overlay.font.map { .init(size: $0.size, bold: $0.bold) },
                scalable: overlay.scalable)
            return Roi(
                shape, name: storedNameOnly ? storedName : name, strokeColor: strokeColor, fillColor: fillColor,
                strokeWidth: Float(strokeWidth), scalesStrokeWidth: scaleStrokeWidth, position: roiPosition, group: group,
                properties: properties, labels: labels)
        }

        var vertices: Roi.Vertices {
            if let xs, let ys {
                return .subpixel(zip(xs, ys).map { Roi.FloatPoint(x: Float($0), y: Float($1)) })
            }
            return .integer(zip(xi ?? [], yi ?? []).map { Roi.IntPoint(x: $0, y: $1) })
        }

        var shape: Roi.Shape? {
            let rect: Roi.Rect =
                subpixel
                ? .subpixel(x: floatBounds[0], y: floatBounds[1], width: floatBounds[2], height: floatBounds[3])
                : .integer(x: Int32(bounds[0]), y: Int32(bounds[1]), width: Int32(bounds[2]), height: Int32(bounds[3]))
            switch `class` {
            case "Roi": return .rectangle(rect, cornerDiameter: cornerDiameter ?? 0)
            case "OvalRoi": return .oval(rect)
            case "PolygonRoi", "EllipseRoi", "RotatedRectRoi":
                let kinds: [Int: Roi.Polygon.Kind] = [2: .polygon, 3: .freehand, 4: .traced, 6: .polyline, 7: .freeline, 8: .angle]
                var parametric: Roi.Polygon.Parametric?
                if `class` == "EllipseRoi" { parametric = .ellipse(aspectRatio: Double(Float(params![4]))) }
                if `class` == "RotatedRectRoi" { parametric = .rotatedRectangle(width: params![4]) }
                return .polygon(Roi.Polygon(kinds[type]!, vertices, splineFit: splineFit ?? false, parametric: parametric))
            case "Line", "Arrow":
                let a = arrow.map {
                    Roi.Arrow(style: .init(rawValue: $0.style)!, headSize: $0.headSize, doubleHeaded: $0.doubleHeaded, outline: $0.outline)
                }
                return .line(Roi.Line(x1: line![0], y1: line![1], x2: line![2], y2: line![3], arrow: a))
            case "PointRoi":
                let p = point!
                var points = Roi.Points(
                    vertices, pointType: .init(rawValue: p.type)!, size: p.size, showLabels: p.showLabels,
                    promptBeforeDeleting: p.promptBeforeDeleting)
                // RoiEncoder always writes counters (from version 227); older
                // files only have the common position.
                if version >= 227, let counters = p.counters {
                    points.counters = counters.map { UInt8(truncatingIfNeeded: $0) }
                    points.positions = counters.map { $0 >> 8 }
                } else if position > 0 {
                    points.positions = [Int32](repeating: Int32(position), count: vertices.count)
                }
                return .points(points)
            default:
                return nil
            }
        }
    }

    static let file: File? = try? JSONDecoder().decode(File.self, from: Fixtures.data("Tests/Fixtures/roi/golden.json"))
    static var entries: [Entry] { file?.rois ?? [] }

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

    /// CRC-32 (the zip polynomial), to tie verified.json to the zip it checked.
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }
}
