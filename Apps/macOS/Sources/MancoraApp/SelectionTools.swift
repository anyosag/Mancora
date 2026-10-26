import AppKit
import MancoraCommands
import MancoraCore
import MancoraIO
import SwiftUI

/// ImageJ's toolbar tools: the selection tools, the wand and the
/// magnifying glass. As in ImageJ, one tool is chosen for every window.
enum CanvasTool: String, CaseIterable, Identifiable {
    case rectangle, oval, polygon, freehand, line, segmentedLine, freehandLine, angle, point, multiPoint, wand, zoom

    var id: Self { self }

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .polygon: "Polygon"
        case .freehand: "Freehand"
        case .line: "Straight Line"
        case .segmentedLine: "Segmented Line"
        case .freehandLine: "Freehand Line"
        case .angle: "Angle"
        case .point: "Point"
        case .multiPoint: "Multi-point"
        case .wand: "Wand (tracing)"
        case .zoom: "Magnifying Glass"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .oval: "circle.dashed"
        case .polygon: "pentagon"
        case .freehand: "scribble"
        case .line: "line.diagonal"
        case .segmentedLine: "point.3.connected.trianglepath.dotted"
        case .freehandLine: "scribble.variable"
        case .angle: "angle"
        case .point: "plus.viewfinder"
        case .multiPoint: "circle.grid.2x2"
        case .wand: "wand.and.stars"
        case .zoom: "plus.magnifyingglass"
        }
    }

    /// Tools whose selections enclose an area, which a drag inside moves.
    var makesArea: Bool { [.rectangle, .oval, .polygon, .freehand, .wand].contains(self) }

    /// Tools that place vertices one click at a time.
    var placesVertices: Bool { [.polygon, .segmentedLine, .angle].contains(self) }
}

/// A selection being made with the mouse.
struct SelectionGesture {
    enum Kind {
        case drawing
        case moving(Roi)
    }

    var kind: Kind
    /// Where the button went down, in pixels.
    var start: CGPoint
    /// Freehand vertices so far.
    var points: [Roi.IntPoint] = []
}

extension ViewerModel {
    /// The image's selection, as ImageJ keeps it in the image.
    var selection: Roi? { image?.encodedROI.flatMap { try? RoiCodec.decode($0) } }

    /// Sets the selection (no undo, as in ImageJ) and records it.
    func setSelection(_ roi: Roi?) {
        guard image != nil else { return }
        image?.encodedROI = roi.map(RoiCodec.encode)
        AppRecorder.shared.recordSelection(roi)
    }

    /// The mouse moved with the button down, from `start` to `point` (in pixels).
    func drag(from start: CGPoint, to point: CGPoint, tool: CanvasTool, shift: Bool) {
        guard let image else { return }
        if gesture == nil {
            if tool.makesArea, !tool.placesVertices, let roi = selection, roi.isArea, Self.contains(roi.bounds, start) {
                gesture = SelectionGesture(kind: .moving(roi), start: start)
            } else {
                gesture = SelectionGesture(kind: .drawing, start: start)
            }
        }
        guard var current = gesture else { return }
        let (x0, y0) = (Int32(floor(start.x)), Int32(floor(start.y)))
        // Rectangles reach the far edge; lines and points stop at the last pixel, as in ImageJ.
        let edge = tool == .rectangle || tool == .oval ? 0.0 : 1.0
        let x1 = Int32(min(max(floor(point.x), 0), Double(image.width) - edge))
        let y1 = Int32(min(max(floor(point.y), 0), Double(image.height) - edge))
        switch current.kind {
        case .moving(let roi):
            draft = roi.translated(dx: Int32(floor(point.x)) - x0, dy: Int32(floor(point.y)) - y0)
        case .drawing:
            switch tool {
            case .rectangle, .oval:
                var (w, h) = (x1 - x0, y1 - y0)
                if shift { (w, h) = (Self.square(w, h), Self.square(h, w)) }
                let rect = Roi.Rect.integer(x: min(x0, x0 + w), y: min(y0, y0 + h), width: abs(w), height: abs(h))
                draft = Roi(tool == .rectangle ? .rectangle(rect) : .oval(rect))
            case .freehand, .freehandLine:
                let p = Roi.IntPoint(x: x1, y: y1)
                if current.points.isEmpty { current.points = [Roi.IntPoint(x: x0, y: y0)] }
                if current.points.last != p { current.points.append(p) }
                draft = Roi(.polygon(.init(tool == .freehand ? .freehand : .freeline, .integer(current.points))))
            case .line:
                var (x2, y2) = (Double(x1), Double(y1))
                if shift {
                    // ImageJ's shift: horizontal or vertical
                    if abs(x2 - Double(x0)) > abs(y2 - Double(y0)) { y2 = Double(y0) } else { x2 = Double(x0) }
                }
                draft = Roi(.line(.init(x1: Double(x0), y1: Double(y0), x2: x2, y2: y2)))
            default:
                break
            }
        }
        gesture = current
        selectionText = draft.map { Self.describe($0, calibration: image.calibration) }
    }

    /// The button came up at `point` after `clicks` clicks.
    func endDrag(at point: CGPoint, tool: CanvasTool, clicks: Int, option: Bool) {
        defer {
            gesture = nil
            draft = nil
            if vertices.isEmpty { selectionText = nil }
        }
        guard image != nil else { return }
        let p = Roi.IntPoint(x: Int32(floor(point.x)), y: Int32(floor(point.y)))
        let moved = gesture.map { abs($0.start.x - point.x) >= 1 || abs($0.start.y - point.y) >= 1 } ?? false
        if case .moving = gesture?.kind {
            if moved, let draft { setSelection(draft) }
            return
        }
        switch tool {
        case .rectangle, .oval, .freehand, .line, .freehandLine:
            if let draft, moved, Self.isUsable(draft) {
                setSelection(draft)
            } else if selection.map({ !Self.contains($0.bounds, point) }) ?? false {
                setSelection(nil)  // a click off the selection removes it
            }
        case .polygon, .segmentedLine, .angle:
            if vertices.isEmpty { setSelection(nil) }
            if vertices.last != p { vertices.append(p) }
            let closes = tool == .polygon && vertices.count > 2 && Self.isNear(vertices[0], point)
            if closes { vertices.removeLast() }
            if clicks > 1 || closes || (tool == .angle && vertices.count == 3) { finishVertices(tool) }
        case .point:
            setSelection(Roi(.points(.init(.integer([p])))))
        case .multiPoint:
            if let roi = selection, case .points(var points) = roi.shape, case .integer(var list) = points.vertices {
                list.append(p)
                points.vertices = .integer(list)
                setSelection(Roi(.points(points)))
            } else {
                setSelection(Roi(.points(.init(.integer([p])))))
            }
        case .wand:
            wand(at: p)
        case .zoom:
            zoom(by: option ? 0.5 : 2)
        }
    }

    /// Ends a polygon, segmented line or angle being placed.
    func finishVertices(_ tool: CanvasTool) {
        defer {
            vertices = []
            selectionText = nil
        }
        let kind: Roi.Polygon.Kind = tool == .polygon ? .polygon : tool == .angle ? .angle : .polyline
        let needed = kind == .polygon ? 3 : kind == .angle ? 3 : 2
        guard vertices.count >= needed else { return }
        setSelection(Roi(.polygon(.init(kind, .integer(vertices)))))
    }

    /// Abandons a selection being placed (Escape).
    func cancelVertices() {
        vertices = []
        selectionText = nil
    }

    /// The wand tool: traces the area the click is in, as ImageJ does with
    /// the Wand Tool's default options (legacy mode, no tolerance).
    func wand(at p: Roi.IntPoint) {
        guard let image else { return }
        var context = CommandContext()
        context.add(image)
        let (c, z, t) = (channel, slice, frame)
        try? context.withCurrent("Wand") { (open: inout OpenImage) in
            (open.channel, open.slice, open.frame) = (c, z, t)
        }
        guard let roi = context.current?.wandSelection(x: Int(p.x), y: Int(p.y)) else { return }
        self.image?.encodedROI = RoiCodec.encode(roi)
        AppRecorder.shared.recordLine("doWand(\(p.x), \(p.y));")
    }

    /// What ImageJ's status bar shows while a selection is drawn.
    static func describe(_ roi: Roi, calibration: Calibration) -> String {
        switch roi.shape {
        case .line(let line):
            let dx = (line.x2 - line.x1) * calibration.pixelWidth
            let dy = (line.y2 - line.y1) * calibration.pixelHeight
            let angle = atan2(-(line.y2 - line.y1), line.x2 - line.x1) * 180 / .pi
            return String(format: "angle=%.2f, length=%.3f", angle, (dx * dx + dy * dy).squareRoot())
        default:
            let b = roi.bounds
            if calibration.isSpatiallyCalibrated {
                return String(
                    format: "x=%.3f, y=%.3f, w=%.3f, h=%.3f %@", Double(b.x) * calibration.pixelWidth,
                    Double(b.y) * calibration.pixelHeight, Double(b.width) * calibration.pixelWidth,
                    Double(b.height) * calibration.pixelHeight, calibration.unit)
            }
            return "x=\(b.x), y=\(b.y), w=\(b.width), h=\(b.height)"
        }
    }

    private static func square(_ a: Int32, _ b: Int32) -> Int32 {
        let side = max(abs(a), abs(b))
        return a < 0 ? -side : side
    }

    private static func contains(_ b: RoiBounds, _ p: CGPoint) -> Bool {
        p.x >= Double(b.x) && p.x < Double(b.x + b.width) && p.y >= Double(b.y) && p.y < Double(b.y + b.height)
    }

    private static func isNear(_ vertex: Roi.IntPoint, _ p: CGPoint) -> Bool {
        abs(Double(vertex.x) - p.x) <= 2 && abs(Double(vertex.y) - p.y) <= 2
    }

    /// Whether a drawn selection is big enough to keep (a click makes none).
    private static func isUsable(_ roi: Roi) -> Bool {
        switch roi.shape {
        case .rectangle(let r, _), .oval(let r):
            if case .integer(_, _, let w, let h) = r { return w > 0 && h > 0 }
            return true
        case .polygon(let p): return p.vertices.count >= (p.kind.isLine ? 2 : 3)
        case .line(let l): return l.x1 != l.x2 || l.y1 != l.y2
        default: return true
        }
    }
}

extension Roi {
    /// The ROI moved by whole pixels.
    func translated(dx: Int32, dy: Int32) -> Roi {
        var moved = self
        func shift(_ r: Rect) -> Rect {
            switch r {
            case .integer(let x, let y, let w, let h): .integer(x: x + dx, y: y + dy, width: w, height: h)
            case .subpixel(let x, let y, let w, let h):
                .subpixel(x: x + Double(dx), y: y + Double(dy), width: w, height: h)
            }
        }
        func shift(_ v: Vertices) -> Vertices {
            switch v {
            case .integer(let p): .integer(p.map { IntPoint(x: $0.x + dx, y: $0.y + dy) })
            case .subpixel(let p): .subpixel(p.map { FloatPoint(x: $0.x + Float(dx), y: $0.y + Float(dy)) })
            }
        }
        switch shape {
        case .rectangle(let r, let corner): moved.shape = .rectangle(shift(r), cornerDiameter: corner)
        case .oval(let r): moved.shape = .oval(shift(r))
        case .polygon(var p):
            p.vertices = shift(p.vertices)
            moved.shape = .polygon(p)
        case .line(var l):
            (l.x1, l.y1, l.x2, l.y2) = (l.x1 + Double(dx), l.y1 + Double(dy), l.x2 + Double(dx), l.y2 + Double(dy))
            moved.shape = .line(l)
        case .points(var p):
            p.vertices = shift(p.vertices)
            moved.shape = .points(p)
        case .opaque:
            break
        }
        return moved
    }
}

/// The selection drawn over the image, in ImageJ's yellow, with the
/// selection being made and, while a polygon is placed, a line to the pointer.
struct SelectionOverlay: View {
    let selection: Roi?
    let draft: Roi?
    let vertices: [Roi.IntPoint]
    let pointer: CGPoint?
    let tool: CanvasTool
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            let yellow = GraphicsContext.Shading.color(.yellow)
            for roi in [draft ?? selection].compactMap({ $0 }) {
                context.stroke(Self.path(roi, scale: scale), with: yellow, lineWidth: 1)
                if case .points(let points) = roi.shape {
                    for p in points.vertices.floatPoints {
                        let center = CGPoint(x: (CGFloat(p.x) + 0.5) * scale, y: (CGFloat(p.y) + 0.5) * scale)
                        context.fill(Path(CGRect(x: center.x - 2, y: center.y - 2, width: 5, height: 5)), with: yellow)
                    }
                }
            }
            if !vertices.isEmpty {
                var path = Path()
                let offset: CGFloat = tool == .polygon ? 0 : 0.5
                let points = vertices.map { CGPoint(x: (CGFloat($0.x) + offset) * scale, y: (CGFloat($0.y) + offset) * scale) }
                path.addLines(points)
                if let pointer {
                    path.addLine(to: CGPoint(x: (floor(pointer.x) + offset) * scale, y: (floor(pointer.y) + offset) * scale))
                }
                context.stroke(path, with: yellow, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// The outline at `scale`. Area vertices lie on pixel corners; lines and
    /// points run through pixel centers, as ImageJ draws them.
    static func path(_ roi: Roi, scale: CGFloat) -> Path {
        func rect(_ r: Roi.Rect) -> CGRect {
            switch r {
            case .integer(let x, let y, let w, let h):
                CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: CGFloat(w) * scale, height: CGFloat(h) * scale)
            case .subpixel(let x, let y, let w, let h):
                CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
            }
        }
        var path = Path()
        switch roi.shape {
        case .rectangle(let r, let corner):
            if corner > 0 {
                let radius = CGFloat(corner) * scale / 2
                path.addRoundedRect(in: rect(r), cornerSize: CGSize(width: radius, height: radius))
            } else {
                path.addRect(rect(r))
            }
        case .oval(let r):
            path.addEllipse(in: rect(r))
        case .polygon(let p):
            let isInteger = if case .integer = p.vertices { true } else { false }
            let offset: CGFloat = p.kind.isLine && isInteger ? 0.5 : 0
            let points = p.vertices.floatPoints.map {
                CGPoint(x: (CGFloat($0.x) + offset) * scale, y: (CGFloat($0.y) + offset) * scale)
            }
            path.addLines(points)
            if !p.kind.isLine { path.closeSubpath() }
        case .line(let l):
            path.move(to: CGPoint(x: (l.x1 + 0.5) * scale, y: (l.y1 + 0.5) * scale))
            path.addLine(to: CGPoint(x: (l.x2 + 0.5) * scale, y: (l.y2 + 0.5) * scale))
        case .points:
            break
        case .opaque:
            let b = roi.bounds
            path.addRect(
                CGRect(
                    x: CGFloat(b.x) * scale, y: CGFloat(b.y) * scale, width: CGFloat(b.width) * scale,
                    height: CGFloat(b.height) * scale))
        }
        return path
    }
}

/// The toolbar's tool picker.
struct ToolPicker: View {
    @Bindable var session: AppSession

    var body: some View {
        Picker("Tool", selection: $session.tool) {
            ForEach(CanvasTool.allCases) { tool in
                Label(tool.title, systemImage: tool.systemImage).tag(tool).help(tool.title)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
    }
}
