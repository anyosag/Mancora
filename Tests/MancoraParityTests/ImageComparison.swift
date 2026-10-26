import MancoraBridge
import MancoraCore

/// Describes how two images (or results tables) differ, in words a test
/// failure can show.
enum ImageComparison {
    static func differences(_ mancora: Hyperstack, _ imageJ: Hyperstack, tolerance: Double) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ what: String, _ a: T, _ b: T) {
            if a != b { out.append("\(what): Mancora \(a), ImageJ \(b)") }
        }
        check("title", mancora.title, imageJ.title)
        check("size", "\(mancora.width)×\(mancora.height)", "\(imageJ.width)×\(imageJ.height)")
        check("type", mancora.pixelType, imageJ.pixelType)
        check("dimensions", mancora.dimensions, imageJ.dimensions)
        guard out.isEmpty else { return out }

        for index in 0..<mancora.stack.count {
            if let difference = pixelDifference(mancora.stack[index], imageJ.stack[index], width: mancora.width, tolerance: tolerance) {
                out.append("plane \(index + 1): \(difference)")
                if out.count >= 3 { break }
            }
        }
        check("slice labels", mancora.stack.labels, imageJ.stack.labels)

        let a = mancora.calibration, b = imageJ.calibration
        check("unit", a.unit, b.unit)
        check("y unit", a.yUnit, b.yUnit)
        check("z unit", a.zUnit, b.zUnit)
        for (what, x, y) in [
            ("pixel width", a.pixelWidth, b.pixelWidth), ("pixel height", a.pixelHeight, b.pixelHeight),
            ("voxel depth", a.pixelDepth, b.pixelDepth), ("x origin", a.xOrigin, b.xOrigin),
            ("y origin", a.yOrigin, b.yOrigin), ("z origin", a.zOrigin, b.zOrigin),
            ("frame interval", a.frameInterval, b.frameInterval), ("fps", a.fps, b.fps),
        ] where !close(x, y, tolerance: 1e-9) {
            out.append("\(what): Mancora \(x), ImageJ \(y)")
        }
        check("time unit", a.timeUnit, b.timeUnit)
        check("invert Y", a.invertY, b.invertY)
        check("value function", a.valueFunction, b.valueFunction)
        check("value unit", a.valueUnit, b.valueUnit)

        check("composite mode", mancora.compositeMode, imageJ.compositeMode)
        for (index, (x, y)) in zip(mancora.channels, imageJ.channels).enumerated() {
            let channel = mancora.channels.count > 1 ? "channel \(index + 1) " : ""
            if !close(x.displayRange.lowerBound, y.displayRange.lowerBound, tolerance: 1e-9)
                || !close(x.displayRange.upperBound, y.displayRange.upperBound, tolerance: 1e-9)
            {
                out.append("\(channel)display range: Mancora \(x.displayRange), ImageJ \(y.displayRange)")
            }
            if !x.lut.hasSameColors(as: y.lut) {
                out.append("\(channel)LUT: Mancora \(describe(x.lut)), ImageJ \(describe(y.lut))")
            }
        }
        check("info", mancora.info, imageJ.info)
        check("properties", mancora.properties, imageJ.properties)
        return out
    }

    /// The first pixel that differs (beyond `tolerance` for float), and how many do.
    static func pixelDifference(_ a: Plane, _ b: Plane, width: Int, tolerance: Double) -> String? {
        var first: Int?
        var count = 0
        var largest = 0.0
        let exact = a.pixelType != .gray32Float
        for i in 0..<a.count {
            let same: Bool
            switch (a, b) {
            case (.rgb8(let x), .rgb8(let y)): same = x[i] & 0xFF_FFFF == y[i] & 0xFF_FFFF
            default:
                let x = a.value(at: i), y = b.value(at: i)
                same = exact ? x == y : (x.isNaN && y.isNaN) || close(x, y, tolerance: tolerance)
                if !same, x.isFinite, y.isFinite { largest = max(largest, abs(x - y)) }
            }
            if !same {
                count += 1
                if first == nil { first = i }
            }
        }
        guard let first else { return nil }
        return "\(count) of \(a.count) pixels differ; first at (\(first % width), \(first / width)): "
            + "Mancora \(describe(a, first)), ImageJ \(describe(b, first))"
            + (largest > 0 ? "; largest difference \(largest)" : "")
    }

    static func differences(_ mancora: ResultsTable, _ imageJ: BridgeResults, tolerance: Double) -> [String] {
        let hasLabels = mancora.labels.contains { $0 != nil }
        let columns = (hasLabels ? ["Label"] : []) + mancora.columns
        guard columns == imageJ.columns else {
            return ["results columns: Mancora \(columns), ImageJ \(imageJ.columns)"]
        }
        guard mancora.count == imageJ.rows.count else {
            return ["results rows: Mancora \(mancora.count), ImageJ \(imageJ.rows.count)"]
        }
        var out: [String] = []
        for row in 0..<mancora.count {
            for (index, column) in columns.enumerated() {
                let theirs = imageJ.rows[row][index]
                let ours: ResultValue
                if hasLabels && index == 0 {
                    ours = mancora.labels[row].map(ResultValue.text) ?? .empty
                } else {
                    switch mancora.value(column, row: row) {
                    case .number(let n)?: ours = .number(n)
                    case .text(let t)?: ours = .text(t)
                    case nil: ours = .empty
                    }
                }
                let same: Bool
                switch (ours, theirs) {
                case (.number(let x), .number(let y)): same = (x.isNaN && y.isNaN) || close(x, y, tolerance: tolerance)
                default: same = ours == theirs
                }
                if !same {
                    out.append("results row \(row + 1) \(column): Mancora \(ours), ImageJ \(theirs)")
                    if out.count >= 5 { return out }
                }
            }
        }
        return out
    }

    static func close(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
        a == b || abs(a - b) <= tolerance * max(1, abs(a), abs(b))
    }

    static func describe(_ plane: Plane, _ index: Int) -> String {
        if case .rgb8(let p) = plane {
            let c = p[index]
            return "RGB(\((c >> 16) & 0xFF), \((c >> 8) & 0xFF), \(c & 0xFF))"
        }
        return "\(plane.value(at: index))"
    }

    static func describe(_ lut: LUT) -> String {
        let ends = [0, 128, 255].map { i in "(\(lut.reds[i]),\(lut.greens[i]),\(lut.blues[i]))" }
        return "\(lut.name) \(ends.joined(separator: " "))"
    }
}
