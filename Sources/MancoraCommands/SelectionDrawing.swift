import MancoraCore
import MancoraProcess

/// Edit ▸ Fill, Clear and Clear Outside on line and point selections, and
/// Edit ▸ Draw (ImageJ's `Filler`), which draw the selection's outline
/// (`Roi.drawPixels`) with `ImageProcessor.lineTo`.
enum SelectionDrawing {
    static var all: [CommandDefinition] { [draw] }

    /// `Filler("draw")`: the selection's outline in the foreground color.
    static let draw = CommandDefinition("Draw", menu: "Edit") { context, options in
        let name = "Draw"
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard let roi = open.roi else { throw CommandError.failed(command: name, detail: "This command requires a selection") }
        let value = EditCommands.fillValue(color: context.settings.foreground, for: open)
        try drawOutline(name, roi, value: value, &context, options, planes: FilterCommands.targetPlanes(open, options))
    }

    /// Fill and Clear on a line or point selection: a line is drawn with the
    /// value; points need an area. Clear Outside leaves points alone and
    /// refuses lines. Clear works on the current plane only.
    static func paintNonArea(
        _ name: String, _ roi: Roi, value: Double, _ context: inout CommandContext, _ options: MacroOptions
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        switch name {
        case "Clear Outside":
            if roi.isLine { throw CommandError.failed(command: name, detail: "\"Clear Outside\" does not work with line selections.") }
            return  // fillOutside ignores selections that aren't areas
        default:
            if case .points = roi.shape { throw CommandError.failed(command: name, detail: "Area selection required") }
            if case .line = roi.shape, roi.strokeWidth > 1 { throw CommandError.notNative(name) }  // filled as an area
            let current = open.image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
            let planes = name == "Clear" && roi.isLine ? [current] : FilterCommands.targetPlanes(open, options)
            try drawOutline(name, roi, value: value, &context, options, planes: planes)
        }
    }

    /// `roi.drawPixels(ip)` on each of `planes`.
    static func drawOutline(
        _ name: String, _ roi: Roi, value: Double, _ context: inout CommandContext, _ options: MacroOptions, planes: [Int]
    ) throws {
        guard let path = outline(roi) else { throw CommandError.notNative(name) }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            if planes.count == 1 { open.resetBinaryThreshold() }
            for index in planes {
                var pen = PixelPen(
                    plane: open.image.stack[index], width: open.image.width, height: open.image.height, value: value,
                    lineWidth: path.lineWidth)
                for stroke in path.strokes {
                    guard let first = stroke.first else { continue }
                    pen.moveTo(first.x, first.y)
                    for point in stroke { pen.lineTo(point.x, point.y) }
                }
                do { try open.image.setPlane(pen.plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
            }
        }
    }

    /// The `moveTo`/`lineTo` strokes of `Roi.drawPixels`, and the line
    /// width it sets; `nil` for selections Mancora doesn't draw (ovals,
    /// rounded rectangles, splines, wide straight lines, arrows, composites).
    static func outline(_ roi: Roi) -> (strokes: [[(x: Int, y: Int)]], lineWidth: Int)? {
        func round(_ v: Double) -> Int { Int(Int32(truncatingIfNeeded: JavaNumerics.round(v))) }
        let stroke = roi.strokeWidth > 1 ? Int(JavaNumerics.round(Double(roi.strokeWidth))) : 1
        switch roi.shape {
        case .line(let line):
            guard line.arrow == nil, roi.strokeWidth <= 1 else { return nil }
            return ([[(round(line.x1), round(line.y1)), (round(line.x2), round(line.y2))]], 1)
        case .points(let points):
            // PointRoi: a dot per point (Analyzer.markWidth, 0, is drawn 1 wide).
            let p = points.vertices.floatPoints
            return (p.map { [(round(Double($0.x)), round(Double($0.y)))] }, 1)
        case .rectangle(_, let corner):
            guard corner == 0 else { return nil }
            let b = roi.bounds
            // drawRect(x, y, width+1, height+1) at width 1, (x, y, width, height) otherwise.
            let (w, h) = stroke == 1 ? (b.width + 1, b.height + 1) : (b.width, b.height)
            let e = stroke == 1 ? 1 : 0
            guard w >= 1, h >= 1 else { return ([], stroke) }
            let (x, y) = (b.x, b.y)
            return ([[(x, y), (x + w - e, y), (x + w - e, y + h - e), (x, y + h - e), (x, y)]], stroke)
        case .polygon(let polygon):
            guard !polygon.isSplineFit, polygon.parametric == nil else { return nil }
            let close = !polygon.kind.isLine
            var points: [(x: Int, y: Int)]
            switch polygon.vertices {
            case .integer(let p): points = p.map { (Int($0.x), Int($0.y)) }
            case .subpixel:
                let f = polygon.state.floatPolygon
                points = zip(f.xs, f.ys).map { (round(Double($0)), round(Double($1))) }
            }
            if close, let first = points.first { points.append(first) }
            return ([points], stroke)
        case .oval, .opaque:
            return nil
        }
    }
}

/// An `ImageProcessor` drawing with one value: `moveTo`, `lineTo` (with
/// `drawDot2` and `drawDot` for wider lines) and `drawPixel`, clipped to
/// the image. (The macro interpreter's `Canvas` draws the same way.)
struct PixelPen {
    var plane: Plane
    let width: Int
    let height: Int
    let value: Double
    let lineWidth: Int
    private var cx = 0
    private var cy = 0

    init(plane: Plane, width: Int, height: Int, value: Double, lineWidth: Int) {
        self.plane = plane
        self.width = width
        self.height = height
        self.value = value
        self.lineWidth = max(lineWidth, 1)
    }

    mutating func moveTo(_ x: Int, _ y: Int) { (cx, cy) = (x, y) }

    mutating func drawPixel(_ x: Int, _ y: Int) {
        if x >= 0 && x < width && y >= 0 && y < height { EditCommands.putFill(&plane, y * width + x, value) }
    }

    /// `ImageProcessor.lineTo`: from the pen to (x2, y2), skipping the part outside the image.
    mutating func lineTo(_ x2: Int, _ y2: Int) {
        func int(_ v: Double) -> Int { Int(JavaNumerics.int32(v)) }
        let xMin = 0 - lineWidth / 2 - 1, xMax = width - 1 + lineWidth / 2 + 1
        let yMin = 0 - lineWidth / 2 - 1, yMax = height - 1 + lineWidth / 2 + 1
        let dx = x2 - cx, dy = y2 - cy
        let n = max(abs(dx), abs(dy))
        let xinc = dx != 0 ? Double(dx) / Double(n) : 0
        let yinc = dy != 0 ? Double(dy) / Double(n) : 0
        var x = Double(cx), y = Double(cy)
        (cx, cy) = (x2, y2)
        var i1 = 0
        if dx > 0 {
            i1 = max(i1, int((Double(xMin) - x) / xinc))
        } else if dx < 0 {
            i1 = max(i1, int((Double(xMax) - x) / xinc))
        } else if x < Double(xMin) || x > Double(xMax) {
            return
        }
        if dy > 0 {
            i1 = max(i1, int((Double(yMin) - y) / yinc))
        } else if dy < 0 {
            i1 = max(i1, int((Double(yMax) - y) / yinc))
        } else if y < Double(yMin) || y > Double(yMax) {
            return
        }
        var i2 = n
        if dx > 0 {
            i2 = min(i2, int((Double(xMax) - x) / xinc))
        } else if dx < 0 {
            i2 = min(i2, int((Double(xMin) - x) / xinc))
        }
        if dy > 0 {
            i2 = min(i2, int((Double(yMax) - y) / yinc))
        } else if dy < 0 {
            i2 = min(i2, int((Double(yMin) - y) / yinc))
        }
        x += Double(i1) * xinc
        y += Double(i1) * yinc
        guard i1 <= i2 else { return }
        for _ in i1...i2 {
            let px = Int(Int32(truncatingIfNeeded: JavaNumerics.round(x)))
            let py = Int(Int32(truncatingIfNeeded: JavaNumerics.round(y)))
            switch lineWidth {
            case 1: drawPixel(px, py)
            case 2:
                drawPixel(px, py)
                drawPixel(px - 1, py)
                drawPixel(px, py - 1)
                drawPixel(px - 1, py - 1)
            default: drawDot(px, py)
            }
            x += xinc
            y += yinc
        }
    }

    /// `ImageProcessor.drawDot`: a disk `lineWidth` across.
    mutating func drawDot(_ xcenter: Int, _ ycenter: Int) {
        var r = Double(lineWidth) / 2.0
        let xmin = Int(JavaNumerics.int32(Double(xcenter) - r + 0.5))
        let ymin = Int(JavaNumerics.int32(Double(ycenter) - r + 0.5))
        let xmax = xmin + lineWidth, ymax = ymin + lineWidth
        if xmin < 0 || ymin < 0 || xmax > width - 1 || ymax > height - 1 {
            let r2 = r * r
            r -= 0.5
            let xoffset = Double(xmin) + r, yoffset = Double(ymin) + r
            for y in ymin..<ymax {
                for x in xmin..<xmax {
                    let xx = Double(x) - xoffset, yy = Double(y) - yoffset
                    if xx * xx + yy * yy <= r2 { drawPixel(x, y) }
                }
            }
        } else if let mask = try? Roi(.oval(.integer(x: 0, y: 0, width: Int32(lineWidth), height: Int32(lineWidth)))).mask() {
            for y in 0..<lineWidth {
                for x in 0..<lineWidth where mask[x: x, y: y] { drawPixel(xmin + x, ymin + y) }
            }
        }
    }
}
