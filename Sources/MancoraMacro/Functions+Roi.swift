// Selections: Roi.*, the selection constructors that build ImageJ's
// parametric ROIs (ellipses, rotated rectangles, arrows, styled points) and
// the geometry queries, ported from ImageJ 1.54p's Functions.java with the
// parts of Roi, PointRoi, Arrow and Colors they use.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraProcess

extension Functions {
    /// `Roi.getColor()`: ImageJ's default selection color, yellow.
    static let defaultRoiColor: UInt32 = 0xFFFF_FF00

    // MARK: - Colors

    /// `Colors.colorToString`: a name for the standard opaque colors,
    /// "#rrggbb" for other opaque ones, "#aarrggbb" otherwise, "none" for none.
    static func colorToString(_ argb: UInt32?) -> String {
        guard let argb else { return "none" }
        let names: [UInt32: String] = [
            0xFFFF_0000: "red", 0xFF00_FF00: "green", 0xFF00_00FF: "blue", 0xFFFF_00FF: "magenta",
            0xFF00_FFFF: "cyan", 0xFFFF_FF00: "yellow", 0xFFFF_C800: "orange", 0xFF00_0000: "black",
            0xFFFF_FFFF: "white", 0xFF80_8080: "gray", 0xFFC0_C0C0: "lightgray", 0xFF40_4040: "darkgray",
            0xFFFF_AFAF: "pink",
        ]
        if let name = names[argb] { return name }
        return argb >> 24 == 0xFF ? String(format: "#%06x", argb & 0xFF_FFFF) : String(format: "#%08x", argb)
    }

    /// `Colors.getColor(name, default)`: the first standard color name `name` contains.
    static func namedRoiColor(_ nameIn: String, _ defaultColor: UInt32?) -> UInt32? {
        if nameIn.utf16.count < 2 { return defaultColor }
        let name = javaToLowerCase(nameIn)
        let colors: [(String, UInt32)] = [
            ("black", 0xFF00_0000), ("white", 0xFFFF_FFFF), ("red", 0xFFFF_0000), ("blue", 0xFF00_00FF),
            ("yellow", 0xFFFF_FF00), ("green", 0xFF00_FF00), ("magenta", 0xFFFF_00FF), ("cyan", 0xFF00_FFFF),
            ("orange", 0xFFFF_C800), ("pink", 0xFFFF_AFAF),
        ]
        for (word, color) in colors where javaContains(name, word) { return color }
        if javaContains(name, "gray") || javaContains(name, "grey") {
            if javaContains(name, "light") { return 0xFFC0_C0C0 }
            if javaContains(name, "dark") { return 0xFF40_4040 }
            return 0xFF80_8080
        }
        return defaultColor
    }

    /// `Colors.decode(s, default)`: a color name, or 6 (opaque) or 8 (with alpha) hex digits.
    static func decodeColor(_ sIn: String, _ defaultColor: UInt32?) -> UInt32? {
        if sIn.utf16.count < 2 { return defaultColor }
        if let named = namedRoiColor(sIn, nil) { return named }
        var s = sIn
        if javaStartsWith(s, "#") { s = javaSubstring(s, 1) } else if javaStartsWith(s, "0x") { s = javaSubstring(s, 2) }
        let length = s.utf16.count
        guard length == 6 || length == 8, let value = UInt64(s, radix: 16) else { return defaultColor }
        return length == 8 ? UInt32(truncatingIfNeeded: value) : 0xFF00_0000 | UInt32(truncatingIfNeeded: value)
    }

    /// `getRoiColor()`: a color by name or hex, or `(rgb)` or `(r, g, b)` (clamped).
    private func roiColorArgument() throws(MacroSignal) -> UInt32? {
        try interp.getLeftParen()
        if isStringArg() {
            let color = Self.decodeColor(try getString(), nil)
            try interp.getRightParen()
            return color
        }
        let r = jIntI(try interp.getExpression())
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
            return 0xFF00_0000 | UInt32(truncatingIfNeeded: r) & 0xFF_FFFF
        }
        let g = jIntI(try getNextArg())
        let b = jIntI(try getLastArg())
        func clamp(_ v: Int) -> UInt32 { UInt32(min(max(v, 0), 255)) }
        return 0xFF00_0000 | clamp(r) << 16 | clamp(g) << 8 | clamp(b)
    }

    // MARK: - Making selections

    /// `new PointRoi(points, options)`: `PointRoi.setOptions` reads the
    /// size, marker type, labels and color from `options`.
    func pointRoi(_ vertices: Roi.Vertices, options: String) throws(MacroSignal) -> Roi {
        if javaContains(options, "add") { try unsupported("points added to an overlay") }
        var points = Roi.Points(vertices)
        func has(_ s: String) -> Bool { javaContains(options, s) }
        if has("tiny") {
            points.size = 0
        } else if has("medium") {
            points.size = 2
        } else if has("extra") {
            points.size = 4
        } else if has("large") {
            points.size = 3
        } else if has("xxxl") {
            points.size = 6
        } else if has("xxl") {
            points.size = 5
        }
        if has("cross") {
            points.pointType = .cross
        } else if has("dot") {
            points.pointType = .dot
        } else if has("circle") {
            points.pointType = .circle
        }
        if has("nolabel") { points.showLabels = false } else if has("label") { points.showLabels = true }
        return Roi(.points(points), strokeColor: Self.namedRoiColor(options, Self.defaultRoiColor))
    }

    /// `makeEllipse(x1, y1, x2, y2, aspectRatio)`: ImageJ's `EllipseRoi`, a
    /// freehand outline of 72 vertices around the major axis given.
    func makeEllipse() throws(MacroSignal) {
        _ = try image()
        let x1 = try getFirstArg()
        let y1 = try getNextArg()
        let x2 = try getNextArg()
        let y2 = try getNextArg()
        let aspectRatio = min(max(try getLastArg(), 0), 1)
        try setSelection(Roi(.polygon(Self.ellipse(x1, y1, x2, y2, aspectRatio: aspectRatio))))
    }

    /// `EllipseRoi.makeEllipse`: the vertices, rotated by the axis' angle.
    static func ellipse(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, aspectRatio: Double) -> Roi.Polygon {
        let vertices = 72
        let centerX = (x1 + x2) / 2, centerY = (y1 + y2) / 2
        let major = ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot()
        let minor = major * aspectRatio
        let phiB = atan2(y2 - y1, x2 - x1)
        let alpha = phiB * 180 / Double.pi
        var points: [Roi.FloatPoint] = []
        for i in 0..<vertices {
            let degrees = Double(i) * 360 / Double(vertices)
            let beta1 = degrees / 180 * Double.pi
            let dx = cos(beta1) * major / 2
            let dy = sin(beta1) * minor / 2
            let beta2 = atan2(dy, dx)
            let rad = (dx * dx + dy * dy).squareRoot()
            let beta3 = beta2 + alpha / 180 * Double.pi
            points.append(Roi.FloatPoint(x: Float(centerX + cos(beta3) * rad), y: Float(centerY + sin(beta3) * rad)))
        }
        return Roi.Polygon(.freehand, .subpixel(points), parametric: .ellipse(aspectRatio: aspectRatio))
    }

    /// `makeRotatedRectangle(x1, y1, x2, y2, width)`: ImageJ's `RotatedRectRoi`.
    func makeRotatedRectangle() throws(MacroSignal) {
        _ = try image()
        let x1 = try getFirstArg()
        let y1 = try getNextArg()
        let x2 = try getNextArg()
        let y2 = try getNextArg()
        let width = try getLastArg()
        try setSelection(Roi(.polygon(Roi.Polygon.rotatedRectangle(x1: x1, y1: y1, x2: x2, y2: y2, width: width))))
    }

    /// `makeArrow(x1, y1, x2, y2, style)`: an `Arrow` two pixels wide;
    /// the style names the head ("notched", "open", "headless", "bar"),
    /// its size ("small", "large") and "double" and "outline".
    func makeArrow() throws(MacroSignal) {
        var options = ""
        let x1 = try getFirstArg()
        let y1 = try getNextArg()
        let x2 = try getNextArg()
        let y2 = try getNextArg()
        if interp.nextToken() == ch(",") { options = try getNextString() }
        try interp.getRightParen()
        let style = javaToLowerCase(options)
        var arrow = Roi.Arrow()
        arrow.style =
            javaContains(style, "notched") ? .notched : javaContains(style, "open") ? .open
            : javaContains(style, "headless") ? .headless : javaContains(style, "bar") ? .bar : .filled
        arrow.outline = javaContains(style, "outline")
        arrow.doubleHeaded = javaContains(style, "double")
        if javaContains(style, "small") { arrow.headSize = 5 } else if javaContains(style, "large") { arrow.headSize = 15 }
        _ = try image()
        try setSelection(Roi(.line(Roi.Line(x1: x1, y1: y1, x2: x2, y2: y2, arrow: arrow)), strokeWidth: 2))
    }

    // MARK: - Geometry

    /// `selectionContains(x, y)`: whether the selection contains the pixel nearest (x, y).
    func selectionContains() throws(MacroSignal) -> Double {
        let x = Int(Int32(truncatingIfNeeded: javaMathRound(try getFirstArg())))
        let y = Int(Int32(truncatingIfNeeded: javaMathRound(try getLastArg())))
        guard let roi = try image().roi else { try interp.fail("Selection required") }
        return try roiContains(roi, x, y) ? 1 : 0
    }

    /// `Roi.contains(x, y)`: area selections test the pixel against their
    /// mask, open polylines their closed outline, points their vertices;
    /// a thin straight line contains nothing.
    func roiContains(_ roi: Roi, _ x: Int, _ y: Int) throws(MacroSignal) -> Bool {
        switch roi.shape {
        case .line:
            if roi.strokeWidth <= 1 { return false }
            try unsupported("contains() of a wide line")
        case .points(let points):
            let s = points.state
            let (fx, fy) = (Float(s.x), Float(s.y))
            for (px, py) in zip(s.xpf ?? [], s.ypf ?? []) where Float(x) == fx + px && Float(y) == fy + py { return true }
            return false
        case .polygon(let polygon) where polygon.kind.isLine:
            let b = roi.bounds
            guard x >= b.x, y >= b.y, x < b.x + b.width, y < b.y + b.height else { return false }
            let s = polygon.state
            if let xpf = s.xpf, let ypf = s.ypf {
                return Self.polygonContains(xpf.map(Double.init), ypf.map(Double.init), Double(x) - s.xBase + 0.4999, Double(y) - s.yBase + 0.5)
            }
            let p = s.relativeIntegerPolygon
            return Self.polygonContains(p.xs.map(Double.init), p.ys.map(Double.init), Double(x - Int(s.x)) + 0.4999, Double(y - Int(s.y)) + 0.5)
        default:
            guard roi.isArea, let mask = try? roi.mask() else { return false }
            return mask[x: x, y: y]
        }
    }

    /// `FloatPolygon.contains(x, y)`: the even-odd rule.
    static func polygonContains(_ xs: [Double], _ ys: [Double], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = xs.count - 1
        for i in xs.indices {
            if (ys[i] >= y) != (ys[j] >= y), x > (xs[j] - xs[i]) * (y - ys[i]) / (ys[j] - ys[i]) + xs[i] { inside.toggle() }
            j = i
        }
        return inside
    }

    /// `Roi.getFloatBounds()`: subpixel rectangles, ovals and polygons keep their fractions.
    static func floatBounds(_ roi: Roi) -> (x: Double, y: Double, width: Double, height: Double) {
        switch roi.shape {
        case .rectangle(.subpixel(let x, let y, let w, let h), _), .oval(.subpixel(let x, let y, let w, let h)):
            return (x, y, w, h)
        case .polygon(let p) where p.parametric == nil:
            if case .subpixel(let points) = p.vertices, !points.isEmpty {
                let xs = points.map(\.x), ys = points.map(\.y)
                let (minX, minY) = (xs.min()!, ys.min()!)
                return (Double(minX), Double(minY), Double(xs.max()! - minX), Double(ys.max()! - minY))
            }
        default:
            break
        }
        let b = roi.bounds
        return (Double(b.x), Double(b.y), Double(b.width), Double(b.height))
    }

    /// `Roi.getTypeAsString()`, lowercased, with "line" for a straight line.
    static func typeName(_ roi: Roi) -> String {
        switch roi.shape {
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .polygon(let p):
            switch p.kind {
            case .polygon:
                switch p.parametric {
                case .rotatedRectangle?: "rotated rectangle"
                case .ellipse?: "ellipse"
                case nil: "polygon"
                }
            case .freehand: "freehand"
            case .traced: "traced"
            case .polyline: "polyline"
            case .freeline: "freeline"
            case .angle: "angle"
            }
        case .line(let l): l.arrow == nil ? "line" : "arrow"
        case .points: "point"
        case .opaque(let o):
            switch o.kind {
            case .composite: "composite"
            case .text: "text"
            case .image: "image"
            }
        }
    }

    // MARK: - Roi.*

    func doRoi() throws(MacroSignal) -> Variable? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == PREDEFINED_FUNCTION) { try interp.error("Function name expected: ") }
        let name = interp.tokenString ?? ""
        // The defaults, which need no image.
        switch name {
        case "getDefaultStrokeWidth":
            try interp.getParens()
            return Variable(session.defaultStrokeWidth)
        case "setDefaultStrokeWidth":
            session.defaultStrokeWidth = max(try getArg(), 0)
            return nil
        case "getDefaultGroup":
            try interp.getParens()
            return Variable(0)
        case "getGroupNames":
            // As in ImageJ, without its parentheses.
            return Variable(session.groupNames ?? "")
        case "setGroupNames":
            session.groupNames = try getStringArg()
            return nil
        case "getDefaultColor":
            try interp.getParens()
            return Variable(Self.colorToString(Self.defaultRoiColor))
        default:
            break
        }
        _ = try image()
        switch name {
        case "paste":
            try interp.getParens()
            if let roi = session.roiClipboard { try setSelection(roi) }
            return nil
        case "remove", "selectNone":
            try setSelection(nil)
            return nil
        default:
            break
        }
        let selection = try image().roi
        if name == "size" {
            try interp.getParens()
            return Variable(Double(selection.map(Self.roiSize) ?? 0))
        }
        guard var roi = selection else { try interp.fail("No selection") }
        switch name {
        case "contains":
            let x = Int(Int32(truncatingIfNeeded: javaMathRound(try getFirstArg())))
            let y = Int(Int32(truncatingIfNeeded: javaMathRound(try getLastArg())))
            return Variable(try roiContains(roi, x, y) ? 1 : 0)
        case "copy":
            try interp.getParens()
            session.roiClipboard = roi
            return nil
        case "getBounds", "getFloatBounds":
            let x = try getFirstVariable()
            let y = try getNextVariable()
            let width = try getNextVariable()
            let height = try getLastVariable()
            let b = name == "getBounds" ? { () -> (Double, Double, Double, Double) in
                let r = roi.bounds
                return (Double(r.x), Double(r.y), Double(r.width), Double(r.height))
            }() : Self.floatBounds(roi)
            x.setValue(b.0)
            y.setValue(b.1)
            width.setValue(b.2)
            height.setValue(b.3)
            return nil
        case "getStrokeColor":
            try interp.getParens()
            return Variable(Self.colorToString(roi.strokeColor))
        case "getFillColor":
            try interp.getParens()
            return Variable(Self.colorToString(roi.fillColor))
        case "getCoordinates":
            try getCoordinates()
            return nil
        case "getContainedPoints":
            let xs = try getFirstArrayVariable()
            let ys = try getLastArrayVariable()
            let points = try containedPoints(roi)
            xs.setArray(VariableArray(points.map { Variable(Double($0.x)) }))
            ys.setArray(VariableArray(points.map { Variable(Double($0.y)) }))
            return nil
        case "getName":
            try interp.getParens()
            return Variable(roi.name ?? "")
        case "getGroup":
            try interp.getParens()
            return Variable(Double(roi.group))
        case "getProperty":
            let key = try getStringArg()
            return Variable(Self.roiProperties(roi)[key] ?? "")
        case "getProperties":
            try interp.getParens()
            let props = Self.roiProperties(roi)
            return Variable(props.keys.sorted().map { $0 + ": " + props[$0]! + "\n" }.joined())
        case "setProperty":
            var value = "1"
            try interp.getLeftParen()
            let key = try getString()
            if key.contains(" ") { try interp.error("Keys contain a space") }
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                value = try getString()
            }
            try interp.getRightParen()
            var props = Self.roiProperties(roi)
            props[key] = value.isEmpty ? nil : value
            roi.properties = props.keys.sorted().map { $0 + ": " + props[$0]! + "\n" }.joined()
        case "setFillColor":
            roi.fillColor = try roiColorArgument()
            // A filled area is drawn without its outline.
            if roi.fillColor != nil && roi.isArea { roi.strokeColor = nil }
        case "setStrokeColor":
            roi.strokeColor = try roiColorArgument()
        case "setAntiAlias":
            _ = try getBooleanArg()
            return nil
        case "move":
            try setSelectionLocation()
            return nil
        case "setName":
            roi.name = try getStringArg()
        case "setStrokeWidth", "setUnscalableStrokeWidth":
            let width = Float(max(try getArg(), 0))
            roi.strokeWidth = width
            if width > 0 { roi.scalesStrokeWidth = true }
            if name == "setUnscalableStrokeWidth" { roi.scalesStrokeWidth = false }
        case "setMinStrokeWidth":
            _ = try getArg()
            return nil
        case "getStrokeWidth":
            try interp.getParens()
            return Variable(Double(roi.strokeWidth))
        case "getType":
            try interp.getParens()
            return Variable(Self.typeName(roi))
        case "getFeretPoints":
            let xs = try getFirstArrayVariable()
            let ys = try getLastArrayVariable()
            let cal = try image().image.calibration
            guard let feret = roi.feretValues(pixelWidth: cal.pixelWidth, pixelHeight: cal.pixelHeight) else {
                try unsupported("Roi.getFeretPoints of this selection")
            }
            let p = feret.points
            xs.setArray(VariableArray([p[0], p[2], p[4], p[6]].map { Variable($0) }))
            ys.setArray(VariableArray([p[1], p[3], p[5], p[7]].map { Variable($0) }))
            return nil
        case "setPosition":
            let channel = jIntI(try getFirstArg())
            if interp.nextToken() == ch(")") {
                try interp.getRightParen()
                roi.position = channel <= 0 ? .none : .stack(channel)
            } else {
                let slice = jIntI(try getNextArg())
                let frame = jIntI(try getLastArg())
                roi.position = .hyperstack(channel: max(channel, 0), slice: max(slice, 0), frame: max(frame, 0))
            }
        case "getPosition":
            let c = try getFirstVariable()
            let z = try getNextVariable()
            let t = try getLastVariable()
            // getZPosition() is the stack position when there's no hyperstack position.
            var position = (c: 0, z: 0, t: 0)
            switch roi.position {
            case .none: break
            case .stack(let n): position.z = n
            case .hyperstack(let ch, let sl, let fr): position = (ch, sl, fr)
            }
            c.setValue(Double(position.c))
            z.setValue(Double(position.z))
            t.setValue(Double(position.t))
            return nil
        case "getPointPosition":
            guard case .points(let points) = roi.shape else { try interp.fail("Point selection required") }
            let index = jIntI(try getArg())
            if let positions = points.positions, index >= 0, index < positions.count { return Variable(Double(positions[index])) }
            if case .stack(let n) = roi.position { return Variable(Double(n)) }
            return Variable(0)
        case "setFontSize", "setJustification":
            // Text selections only; Mancora keeps them as they were read.
            if name == "setFontSize" { _ = try getArg() } else { _ = try getStringArg() }
            return nil
        case "translate":
            let dx = try getFirstArg()
            let dy = try getLastArg()
            roi = Self.translated(roi, dx: dx, dy: dy)
        case "setGroup", "getSplineAnchors", "setPolygonSplineAnchors", "setPolylineSplineAnchors", "setDefaultGroup":
            try unsupported("Roi." + name)
        default:
            try interp.error("Unrecognized Roi function")
            return nil
        }
        try setSelection(roi)
        return nil
    }

    /// `Roi.getContainedFloatPoints()`: the pixels of an area (from its
    /// mask), or a point selection's points.
    private func containedPoints(_ roi: Roi) throws(MacroSignal) -> [(x: Float, y: Float)] {
        switch roi.shape {
        case .points(let points):
            let p = points.state.floatPolygon
            return Array(zip(p.xs, p.ys))
        case .line:
            try unsupported("Roi.getContainedPoints of a line")
        case .polygon(let p) where p.kind.isLine:
            try unsupported("Roi.getContainedPoints of a line")
        default:
            guard roi.isArea, let mask = try? roi.mask() else { try unsupported("Roi.getContainedPoints of this selection") }
            var points: [(x: Float, y: Float)] = []
            let b = mask.bounds
            for y in 0..<b.height {
                for x in 0..<b.width where mask.pixels[y * b.width + x] { points.append((Float(b.x + x), Float(b.y + y))) }
            }
            return points
        }
    }

    /// A selection's properties (`key: value` lines) as a dictionary.
    static func roiProperties(_ roi: Roi) -> [String: String] {
        guard let text = roi.properties else { return [:] }
        return loadProperties(text)
    }
}
