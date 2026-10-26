// Selections, the results table, the ROI Manager and the variable
// functions (Table., Roi., RoiManager., Property., Image., Color.), ported
// from ImageJ 1.54p's Functions.java.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraProcess

extension Functions {
    // MARK: - Making selections

    func setSelection(_ roi: Roi?) throws(MacroSignal) {
        try modifyImage { $0.roi = roi }
    }

    /// `new Roi(x, y, w, h)` with doubles: whole pixels when every value is one.
    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Roi.Rect {
        if x == Double(jInt(x)) && y == Double(jInt(y)) && w == Double(jInt(w)) && h == Double(jInt(h)) {
            return .integer(x: jInt(x), y: jInt(y), width: max(jInt(w), 1), height: max(jInt(h), 1))
        }
        return .subpixel(x: x, y: y, width: w, height: h)
    }

    func makeRectangle() throws(MacroSignal) {
        let x = try getFirstArg()
        let y = try getNextArg()
        let w = try getNextArg()
        let h = try getNextArg()
        var arcSize = 0
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            arcSize = jIntI(try interp.getExpression())
        }
        try interp.getRightParen()
        _ = try image()
        if arcSize < 1 && (w <= 0 || h < 0) {
            try setSelection(nil)
            return
        }
        try setSelection(Roi(.rectangle(Self.rect(x, y, w, h), cornerDiameter: max(arcSize, 0))))
    }

    /// `doWand(x, y)` or `doWand(x, y, tolerance, mode)`: the selection
    /// stays as it was when the wand finds nothing.
    func doWand() throws(MacroSignal) {
        let x = jIntI(try getFirstArg())
        let y = jIntI(try getNextArg())
        var tolerance = 0.0
        var mode: String?
        if interp.nextToken() == ch(",") {
            tolerance = try getNextArg()
            mode = try getNextString()
        }
        try interp.getRightParen()
        let open = try image()
        if mode?.contains("smooth") == true, open.threshold != nil { try unsupported("doWand(\"smooth\")") }
        if let roi = open.wandSelection(x: x, y: y, tolerance: tolerance, mode: mode) { try setSelection(roi) }
    }

    func makeOval() throws(MacroSignal) {
        let x = try getFirstArg()
        let y = try getNextArg()
        let w = try getNextArg()
        let h = try getLastArg()
        _ = try image()
        if w <= 0 || h < 0 {
            try setSelection(nil)
            return
        }
        try setSelection(Roi(.oval(Self.rect(x, y, w, h))))
    }

    func makeLine() throws(MacroSignal) {
        let x1 = try getFirstArg()
        let y1 = try getNextArg()
        let x2 = try getNextArg()
        try interp.getComma()
        let y2 = try interp.getExpression()
        interp.getToken()
        if interp.token == ch(")") {
            try setSelection(Roi(.line(Roi.Line(x1: x1, y1: y1, x2: x2, y2: y2))))
            return
        }
        var points = [Roi.IntPoint(x: Int32(javaMathRound(x1)), y: Int32(javaMathRound(y1))),
            Roi.IntPoint(x: Int32(javaMathRound(x2)), y: Int32(javaMathRound(y2)))]
        while interp.token == ch(",") {
            let x = Int32(truncatingIfNeeded: javaMathRound(try interp.getExpression()))
            if points.count == 2 && interp.nextToken() == ch(")") {
                // makeLine(x1, y1, x2, y2, lineWidth), Line.updateWideLine: the
                // width, and the ROI color at 30% opacity.
                try interp.getRightParen()
                let line = Roi.Line(x1: x1, y1: y1, x2: x2, y2: y2)
                try setSelection(
                    Roi(.line(line), strokeColor: Self.defaultRoiColor & 0x00FF_FFFF | 0x4D00_0000, strokeWidth: max(Float(x), 0)))
                return
            }
            try interp.getComma()
            let y = Int32(truncatingIfNeeded: javaMathRound(try interp.getExpression()))
            points.append(Roi.IntPoint(x: x, y: y))
            interp.getToken()
        }
        try setSelection(Roi(.polygon(Roi.Polygon(.polyline, .integer(points)))))
    }

    func makePolygon() throws(MacroSignal) {
        var points: [Roi.IntPoint] = []
        let x0 = try getFirstArg()
        let y0 = try getNextArg()
        points.append(Roi.IntPoint(x: Int32(truncatingIfNeeded: javaMathRound(x0)), y: Int32(truncatingIfNeeded: javaMathRound(y0))))
        interp.getToken()
        while interp.token == ch(",") {
            let x = Int32(truncatingIfNeeded: javaMathRound(try interp.getExpression()))
            try interp.getComma()
            let y = Int32(truncatingIfNeeded: javaMathRound(try interp.getExpression()))
            points.append(Roi.IntPoint(x: x, y: y))
            interp.getToken()
        }
        if points.count < 3 { try interp.fail("Fewer than 3 points") }
        _ = try image()
        try setSelection(Roi(.polygon(Roi.Polygon(.polygon, .integer(points)))))
    }

    func makePoint() throws(MacroSignal) {
        let x = try getFirstArg()
        let y = try getNextArg()
        var options: String?
        if interp.nextToken() == ch(",") { options = try getNextString() }
        try interp.getRightParen()
        _ = try image()
        if let options {
            // new PointRoi(x, y, options): always subpixel, with the options' type, size and color.
            try setSelection(try pointRoi(.subpixel([Roi.FloatPoint(x: Float(x), y: Float(y))]), options: options))
            return
        }
        let vertices: Roi.Vertices =
            Double(jInt(x)) == x && Double(jInt(y)) == y
            ? .integer([Roi.IntPoint(x: jInt(x), y: jInt(y))]) : .subpixel([Roi.FloatPoint(x: Float(x), y: Float(y))])
        try setSelection(Roi(.points(Roi.Points(vertices))))
    }

    func makeSelection() throws(MacroSignal) {
        var type: String?
        var kind: Roi.Kind
        try interp.getLeftParen()
        if isStringArg() {
            let t = try getString().lowercased()
            type = t
            kind = .polygon
            if t.contains("free") { kind = .freehand }
            if t.contains("traced") { kind = .traced }
            if t.contains("line") { kind = t.contains("free") ? .freeline : .polyline }
            if t.contains("angle") { kind = .angle }
            if t.contains("point") || t.contains("cross") || t.contains("circle") || t.contains("dot") { kind = .point }
        } else {
            let n = jIntI(try interp.getExpression())
            guard let k = Roi.Kind(rawValue: n), k != .composite else { try interp.fail("Invalid selection type (\(n))") }
            kind = k == .rectangle ? .polygon : k == .oval ? .freehand : k
        }
        try interp.getComma()
        let x = try getNumericArray()
        var n = x.count
        try interp.getComma()
        let y = try getNumericArray()
        if interp.nextToken() == ch(",") {
            n = jIntI(try getLastArg())
            if n > x.count || n > y.count { try interp.fail("Array too short") }
        } else {
            try interp.getRightParen()
            if y.count != n { try interp.fail("Arrays are not the same length") }
        }
        _ = try image()
        let float = (0..<n).contains { x[$0] != Double(jInt(x[$0])) || y[$0] != Double(jInt(y[$0])) }
        let vertices: Roi.Vertices =
            float
            ? .subpixel((0..<n).map { Roi.FloatPoint(x: Float(x[$0]), y: Float(y[$0])) })
            : .integer((0..<n).map { Roi.IntPoint(x: Int32(truncatingIfNeeded: javaMathRound(x[$0])), y: Int32(truncatingIfNeeded: javaMathRound(y[$0]))) })
        let roi: Roi
        switch kind {
        case .line:
            guard n == 2 else { try interp.fail("2 element arrays expected") }
            let p = vertices.floatPoints
            roi = Roi(.line(Roi.Line(x1: Double(p[0].x), y1: Double(p[0].y), x2: Double(p[1].x), y2: Double(p[1].y))))
        case .point:
            if let type, type != "point" {
                // new PointRoi(x, y, type): every element of the arrays, as floats.
                let all = (0..<min(x.count, y.count)).map { Roi.FloatPoint(x: Float(x[$0]), y: Float(y[$0])) }
                roi = try pointRoi(.subpixel(all), options: type)
            } else {
                roi = Roi(.points(Roi.Points(vertices)))
            }
        default:
            let polygonKind: Roi.Polygon.Kind =
                switch kind {
                case .freehand: .freehand
                case .traced: .traced
                case .polyline: .polyline
                case .freeline: .freeline
                case .angle: .angle
                default: .polygon
                }
            roi = Roi(.polygon(Roi.Polygon(polygonKind, vertices)))
        }
        try setSelection(roi)
    }

    func getSelectionType() throws(MacroSignal) -> Double {
        try interp.getParens()
        guard !session.context.images.isEmpty else { return -1 }
        guard let roi = try image().roi else { return -1 }
        return Double(roi.kind.rawValue)
    }

    func getBounds() throws(MacroSignal) {
        let x = try getFirstVariable()
        let y = try getNextVariable()
        let width = try getNextVariable()
        let height = try getLastVariable()
        let open = try image()
        if let roi = open.roi {
            let b = roi.bounds
            x.setValue(Double(b.x))
            y.setValue(Double(b.y))
            width.setValue(Double(b.width))
            height.setValue(Double(b.height))
        } else {
            x.setValue(0)
            y.setValue(0)
            width.setValue(Double(open.image.width))
            height.setValue(Double(open.image.height))
        }
    }

    func getCoordinates() throws(MacroSignal) {
        let xCoordinates = try getFirstArrayVariable()
        let yCoordinates = try getLastArrayVariable()
        guard let roi = try image().roi else { try interp.fail("Selection required") }
        var xs: [Double] = [], ys: [Double] = []
        switch roi.shape {
        case .line(let line):
            xs = [line.x1, line.x2]
            ys = [line.y1, line.y2]
        case .polygon(let p):
            for v in p.vertices.floatPoints {
                xs.append(Double(v.x))
                ys.append(Double(v.y))
            }
        case .points(let p):
            for v in p.vertices.floatPoints {
                xs.append(Double(v.x))
                ys.append(Double(v.y))
            }
        default:
            guard let outline = roi.outline() else { try unsupported("getSelectionCoordinates of this selection") }
            xs = outline.xs.map(Double.init)
            ys = outline.ys.map(Double.init)
        }
        xCoordinates.setArray(VariableArray(xs.map { Variable($0) }))
        yCoordinates.setArray(VariableArray(ys.map { Variable($0) }))
    }

    func setSelectionName() throws(MacroSignal) {
        guard var roi = try image().roi else { try interp.fail("No selection") }
        roi.name = try getStringArg()
        try setSelection(roi)
    }

    func selectionName() throws(MacroSignal) -> String {
        guard let roi = try image().roi else { try interp.fail("No selection") }
        return roi.name ?? ""
    }

    func setSelectionLocation() throws(MacroSignal) {
        let x = Int(javaMathRound(try getFirstArg()))
        let y = Int(javaMathRound(try getLastArg()))
        guard let roi = try image().roi else { try interp.fail("Selection required") }
        let b = roi.bounds
        try setSelection(Self.translated(roi, dx: Double(x - b.x), dy: Double(y - b.y)))
    }

    /// The ROI moved by (dx, dy).
    static func translated(_ roiIn: Roi, dx: Double, dy: Double) -> Roi {
        var roi = roiIn
        func move(_ r: Roi.Rect) -> Roi.Rect {
            switch r {
            case .integer(let x, let y, let w, let h):
                if dx == Double(jInt(dx)) && dy == Double(jInt(dy)) {
                    return .integer(x: x + jInt(dx), y: y + jInt(dy), width: w, height: h)
                }
                return .subpixel(x: Double(x) + dx, y: Double(y) + dy, width: Double(w), height: Double(h))
            case .subpixel(let x, let y, let w, let h):
                return .subpixel(x: x + dx, y: y + dy, width: w, height: h)
            }
        }
        func move(_ v: Roi.Vertices) -> Roi.Vertices {
            switch v {
            case .integer(let p) where dx == Double(jInt(dx)) && dy == Double(jInt(dy)):
                return .integer(p.map { Roi.IntPoint(x: $0.x + jInt(dx), y: $0.y + jInt(dy)) })
            default:
                return .subpixel(v.floatPoints.map { Roi.FloatPoint(x: $0.x + Float(dx), y: $0.y + Float(dy)) })
            }
        }
        switch roi.shape {
        case .rectangle(let r, let c): roi.shape = .rectangle(move(r), cornerDiameter: c)
        case .oval(let r): roi.shape = .oval(move(r))
        case .polygon(var p):
            p.vertices = move(p.vertices)
            roi.shape = .polygon(p)
        case .line(var l):
            l.x1 += dx
            l.x2 += dx
            l.y1 += dy
            l.y2 += dy
            roi.shape = .line(l)
        case .points(var p):
            p.vertices = move(p.vertices)
            roi.shape = .points(p)
        case .opaque: break
        }
        return roi
    }

    // MARK: - Measurements

    /// `List.setMeasurements`: every measurement of the current image and selection.
    func setListMeasurements() throws(MacroSignal) {
        var arg = ""
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if interp.nextToken() != ch(")") { arg = try getString().lowercased() }
            try interp.getRightParen()
        }
        props = [:]
        let open = try image()
        var measurements = Measurements.allStatistics.union(.stackPosition)
        if arg.contains("limit") { measurements.insert(.limitToThreshold) }
        if let roi = open.roi, !roi.isArea || roi.kind == .composite { try unsupported("List.setMeasurements with a line selection") }
        var table = ResultsTable()
        let threshold = open.threshold.flatMap { $0.lower <= $0.upper ? $0.lower...$0.upper : nil }
        do {
            try Analyzer.measure(
                open.image, channel: open.channel, slice: open.slice, frame: open.frame, roi: open.roi,
                options: measurements, threshold: threshold, into: &table)
        } catch {
            try interp.fail("\(error)")
        }
        for column in table.columns { props[column] = javaString(table.number(column, row: 0)) }
    }

    // MARK: - Variable functions

    /// The name after `X.` in `X.name(...)`.
    func memberName() throws(MacroSignal) -> String {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        return interp.tokenString ?? ""
    }

    func doProperty() throws(MacroSignal) -> Variable? {
        let name = try memberName()
        switch name {
        case "get":
            let key = try getStringArg()
            return Variable(try image().image.properties[key] ?? "")
        case "set":
            let key = try getFirstString()
            let value = try getLastString()
            try modifyImage { $0.image.properties[key] = value }
            return nil
        case "getInfo":
            try interp.getParens()
            return Variable(try image().image.info ?? "")
        case "setInfo":
            let info = try getStringArg()
            try modifyImage { $0.image.info = info }
            return nil
        case "getSliceLabel":
            try interp.getParens()
            let open = try image()
            return Variable(open.image.stack.labels[open.stackIndex] ?? "")
        default:
            try unsupported("Property." + name)
        }
    }

    func doImage() throws(MacroSignal) -> Variable? {
        let name = try memberName()
        switch name {
        case "title", "name":
            try interp.getParens()
            return Variable(try image().image.title)
        case "width":
            try interp.getParens()
            return Variable(Double(try image().image.width))
        case "height":
            try interp.getParens()
            return Variable(Double(try image().image.height))
        default:
            try unsupported("Image." + name)
        }
    }

    func doColor() throws(MacroSignal) -> Variable? {
        let name = try memberName()
        switch name {
        case "foreground", "background":
            try interp.getParens()
            let color = name == "foreground" ? session.foreground : session.background
            return Variable(Self.colorName(color))
        case "setForeground", "setBackground":
            try interp.getLeftParen()
            var color: UInt32
            if isStringArg() {
                let s = try getString()
                guard let c = Self.namedColor(s) else { try interp.fail("'red', 'green', or '#0000ff' etc. expected") }
                color = c
                try interp.getRightParen()
            } else {
                let r = jIntI(try interp.getExpression())
                let g = jIntI(try getNextArg())
                let b = jIntI(try getLastArg())
                color = UInt32((r & 255) << 16 | (g & 255) << 8 | (b & 255))
            }
            if name == "setForeground" { session.foreground = color } else { session.background = color }
            return nil
        default:
            try unsupported("Color." + name)
        }
    }

    /// `Colors.colorToString`: a name for the standard colors, else "#rrggbb".
    static func colorName(_ color: UInt32) -> String {
        let names: [UInt32: String] = [
            0x000000: "black", 0xFFFFFF: "white", 0xFF0000: "red", 0x00FF00: "green", 0x0000FF: "blue",
            0x00FFFF: "cyan", 0xFF00FF: "magenta", 0xFFFF00: "yellow", 0xFFC800: "orange", 0xFFAFAF: "pink",
            0x808080: "gray", 0xC0C0C0: "lightGray", 0x404040: "darkGray",
        ]
        if let name = names[color & 0xFF_FFFF] { return name }
        return "#" + String(format: "%06x", color & 0xFF_FFFF)
    }
}

extension OpenImage {
    /// Whether ROIs added from this image get a hyperstack position (c, z, t) rather than a stack index.
    var isHyperstackPosition: Bool { image.dimensions.isHyperstack }
}

extension HyperstackDimensions {
    /// `ImagePlus.isHyperStack()` for an image opened as one: more than one of c, z and t above 1.
    var isHyperstack: Bool { [channels, slices, frames].filter { $0 > 1 }.count > 1 }
}

extension Measurements {
    /// ImageJ's `ALL_STATS`.
    static let allStatistics: Measurements = [
        .area, .mean, .standardDeviation, .mode, .minMax, .centroid, .centerOfMass, .perimeter, .boundingRectangle,
        .ellipse, .shapeDescriptors, .feret, .integratedDensity, .median, .skewness, .kurtosis, .areaFraction,
    ]
}

/// `MaximumFinder.findMaxima(double[], tolerance, edgeMode)`: the peaks of
/// a 1D array, strongest first.
enum MaximumFinder1D {
    static func findMaxima(_ input: [Double], _ toleranceIn: Double, _ edgeMode: Int) -> [Int] {
        var xx = input
        var len = xx.count
        let origLen = len
        if len < 2 { return [] }
        let tolerance = toleranceIn < 0 ? 0 : toleranceIn
        if edgeMode == 2 {
            xx = input + input + input
            len *= 3
        }
        var maxPositions = [Int](repeating: 0, count: len)
        var jStart = 0
        var minimum = Double.nan, maximum = Double.nan
        repeat {
            maximum = xx[jStart]
            minimum = xx[jStart]
            jStart += 1
            if jStart >= xx.count { return [] }
        } while minimum.isNaN
        var maxPos = jStart - 1
        var lastMaxPos = -1
        var leftValleyFound = edgeMode == 0
        var maxCount = 0
        for jj in jStart..<len {
            let val = xx[jj]
            if val > minimum + tolerance { leftValleyFound = true }
            if val > maximum && leftValleyFound {
                maximum = val
                maxPos = jj
            }
            if leftValleyFound { lastMaxPos = maxPos }
            if val < maximum - tolerance && leftValleyFound {
                maxPositions[maxCount] = maxPos
                maxCount += 1
                leftValleyFound = false
                minimum = val
                maximum = val
            }
            if val < minimum {
                minimum = val
                if !leftValleyFound { maximum = val }
            }
        }
        if edgeMode == 0 {
            if maxCount > 0 && maxPositions[maxCount - 1] != lastMaxPos {
                maxPositions[maxCount] = lastMaxPos
                maxCount += 1
            }
            if maxCount == 0 && maximum - minimum >= tolerance {
                maxPositions[maxCount] = lastMaxPos
                maxCount += 1
            }
        }
        var positions = Array(maxPositions[0..<maxCount])
        var maxValues = [Double](repeating: 0, count: maxCount)
        for jj in 0..<maxCount {
            var pos = positions[jj]
            var midPos = Double(pos)
            while pos < len - 1 && xx[pos] == xx[pos + 1] {
                midPos += 0.5
                pos += 1
            }
            positions[jj] = Int(midPos)
            maxValues[jj] = xx[positions[jj]]
        }
        let rank = Functions.rank(maxValues)
        var result = [Int](repeating: 0, count: maxCount)
        for jj in 0..<maxCount { result[maxCount - jj - 1] = positions[rank[jj]] }
        if edgeMode == 2 {
            result = result.map { $0 - origLen }.filter { $0 >= 0 && $0 < origLen }
        }
        return result
    }

    static func findMinima(_ input: [Double], _ tolerance: Double, _ edgeMode: Int) -> [Int] {
        findMaxima(input.map { -$0 }, tolerance, edgeMode)
    }
}

/// How the results table shows and saves numbers.
enum ResultsFormatter {
    /// A number in `column` as `ResultsTable.getStringValue` gives it: with
    /// `decimalPlaces` once the column has held a non-integer, otherwise
    /// integers without decimals (`n(value)`).
    static func cell(_ value: Double, column: String, of rt: ResultsTable, decimalPlaces: Int) -> String {
        if value.isNaN { return "NaN" }
        if !rt.decimalColumns.contains(column) && Double(jInt(value)) == value { return ImageJFormat.d2s(value, 0) }
        return ImageJFormat.resultsTableD2S(value, decimalPlaces)
    }

    /// `getColumnHeadings()`: the row numbers' column, Label, then the columns, tab-separated.
    static func headings(_ rt: ResultsTable) -> String {
        ResultsTableIO.headingLine(rt, csv: false, rowNumbers: true)
    }
}
