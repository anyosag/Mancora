import Foundation
public import MancoraCore

/// The geometry Analyze ▸ Measure takes from a selection: its perimeter,
/// its outline (for the convex hull and Feret's diameter) and the pixels it
/// covers, each as ImageJ computes them.
extension Roi {
    /// `Roi.getLength()`: the perimeter of an area, the length of a line,
    /// in units of `pixelWidth` × `pixelHeight` (ImageJ uses the image's
    /// calibration for a ROI on an image).
    public func length(pixelWidth pw: Double = 1, pixelHeight ph: Double = 1) -> Double {
        switch shape {
        case .rectangle(let rect, let corner):
            let b = rect.intBounds
            let width = Double(b.width), height = Double(b.height)
            var perimeter = 2.0 * width * pw + 2.0 * height * ph
            if corner > 0 {  // Ramanujan's ellipse circumference for the corners
                let a = 0.5 * min(Double(corner), width) * pw
                let c = 0.5 * min(Double(corner), height) * ph
                perimeter += Double.pi * (3 * (a + c) - ((3 * a + c) * (a + 3 * c)).squareRoot()) - 4 * (a + c)
            }
            return perimeter
        case .oval(let rect):
            let b = rect.intBounds
            let a = 0.5 * Double(b.width) * pw, c = 0.5 * Double(b.height) * ph
            return Double.pi * (3 * (a + c) - ((3 * a + c) * (a + 3 * c)).squareRoot())
        case .polygon(let polygon):
            return Self.polygonLength(polygon, pw, ph)
        case .line(let line):
            let dx = line.x2 - line.x1, dy = line.y2 - line.y1
            return (dx * dx * pw * pw + dy * dy * ph * ph).squareRoot()
        case .points, .opaque:
            return 0
        }
    }

    /// `PolygonRoi.getLength(imp)`.
    static func polygonLength(_ polygon: Polygon, _ pw: Double, _ ph: Double) -> Double {
        let state = polygon.state
        if case .ellipse? = polygon.parametric, let xpf = state.xpf, let ypf = state.ypf {
            // EllipseRoi.getLength: the segments, closed.
            let w2 = pw * pw, h2 = ph * ph
            var length = 0.0
            let n = xpf.count
            for i in 0..<(n - 1) {
                let dx = Double(xpf[i + 1] - xpf[i]), dy = Double(ypf[i + 1] - ypf[i])
                length += (dx * dx * w2 + dy * dy * h2).squareRoot()
            }
            let dx = Double(xpf[0] - xpf[n - 1]), dy = Double(ypf[0] - ypf[n - 1])
            return length + (dx * dx * w2 + dy * dy * h2).squareRoot()
        }
        if let traced = tracedVertices(polygon, state) { return tracedPerimeter(traced.xs, traced.ys, pw, ph) }
        let n = state.xpf?.count ?? state.xp?.count ?? 0
        if n > 2 {
            if polygon.kind == .freehand { return smoothedPerimeter(state, pw, ph) }
            if polygon.kind == .freeline && !(state.width == 0 || state.height == 0) {
                return smoothedLineLength(state, pw, ph)
            }
        }
        let close = !polygon.kind.isLine
        guard n >= 2 else { return 0 }
        func sqr(_ v: Double) -> Double { v * v }
        var length = 0.0
        if let xpf = state.xpf, let ypf = state.ypf {
            for i in 0..<(n - 1) {
                length += (sqr(Double(xpf[i + 1] - xpf[i]) * pw) + sqr(Double(ypf[i + 1] - ypf[i]) * ph)).squareRoot()
            }
            if close { length += (sqr(Double(xpf[0] - xpf[n - 1]) * pw) + sqr(Double(ypf[0] - ypf[n - 1]) * ph)).squareRoot() }
        } else if let xp = state.xp, let yp = state.yp {
            for i in 0..<(n - 1) {
                length += (sqr(Double(xp[i + 1] - xp[i]) * pw) + sqr(Double(yp[i + 1] - yp[i]) * ph)).squareRoot()
            }
            if close { length += (sqr(Double(xp[0] - xp[n - 1]) * pw) + sqr(Double(yp[0] - yp[n - 1]) * ph)).squareRoot() }
        }
        return length
    }

    /// `PolygonRoi.isTraced()`: a traced ROI, or a polygon whose edges are
    /// all horizontal or vertical (on whole pixels): the integer vertices.
    static func tracedVertices(_ polygon: Polygon, _ state: PolygonState) -> (xs: [Int32], ys: [Int32])? {
        guard polygon.kind == .traced || (polygon.kind == .polygon && polygon.parametric == nil) else { return nil }
        var xs: [Int32], ys: [Int32]
        if let xp = state.xp, let yp = state.yp {
            (xs, ys) = (xp, yp)
        } else if let xpf = state.xpf, let ypf = state.ypf {
            if polygon.kind != .traced {
                for i in 0..<xpf.count {
                    let next = (i + 1) % xpf.count
                    guard xpf[next] - xpf[i] == 0 || ypf[next] - ypf[i] == 0 else { return nil }
                    guard xpf[i] == xpf[i].rounded(.towardZero), ypf[i] == ypf[i].rounded(.towardZero) else { return nil }
                }
            }
            xs = xpf.map { JavaNumerics.int32($0) }
            ys = ypf.map { JavaNumerics.int32($0) }
        } else {
            return nil
        }
        if polygon.kind != .traced {
            for i in 0..<xs.count {
                let next = (i + 1) % xs.count
                guard xs[next] - xs[i] == 0 || ys[next] - ys[i] == 0 else { return nil }
            }
        }
        return (xs, ys)
    }

    /// `PolygonRoi.getTracedPerimeter`: straight edge pixels count 1, corner pixels √2.
    static func tracedPerimeter(_ xp: [Int32], _ yp: [Int32], _ w: Double, _ h: Double) -> Double {
        let n = xp.count
        if n < 4 { return 0 }
        var sumdx = 0, sumdy = 0, corners = 0
        var dx1 = Int(xp[0]) - Int(xp[n - 1]), dy1 = Int(yp[0]) - Int(yp[n - 1])
        var side1 = abs(dx1) + abs(dy1)
        var corner = false
        for i in 0..<n {
            let next = i + 1 == n ? 0 : i + 1
            let dx2 = Int(xp[next]) - Int(xp[i]), dy2 = Int(yp[next]) - Int(yp[i])
            sumdx += abs(dx1)
            sumdy += abs(dy1)
            let side2 = abs(dx2) + abs(dy2)
            if side1 > 1 || !corner {
                corner = true
                corners += 1
            } else {
                corner = false
            }
            (dx1, dy1, side1) = (dx2, dy2, side2)
        }
        return Double(sumdx) * w + Double(sumdy) * h - (Double(corners) * ((w + h) - (w * w + h * h).squareRoot()))
    }

    /// `getSmoothedLineLength`: a 3-point running average.
    static func smoothedLineLength(_ s: PolygonState, _ pw: Double, _ ph: Double) -> Double {
        let w2 = pw * pw, h2 = ph * ph
        func run(_ x: [Double], _ y: [Double]) -> Double {
            let n = x.count
            var length = 0.0
            var dx = (x[0] + x[1] + x[2]) / 3.0 - x[0], dy = (y[0] + y[1] + y[2]) / 3.0 - y[0]
            length += (dx * dx * w2 + dy * dy * h2).squareRoot()
            if n > 3 {
                for i in 1..<(n - 2) {
                    dx = (x[i + 2] - x[i - 1]) / 3.0
                    dy = (y[i + 2] - y[i - 1]) / 3.0
                    length += (dx * dx * w2 + dy * dy * h2).squareRoot()
                }
            }
            dx = x[n - 1] - (x[n - 3] + x[n - 2] + x[n - 1]) / 3.0
            dy = y[n - 1] - (y[n - 3] + y[n - 2] + y[n - 1]) / 3.0
            return length + (dx * dx * w2 + dy * dy * h2).squareRoot()
        }
        if let xpf = s.xpf, let ypf = s.ypf { return run(xpf.map(Double.init), ypf.map(Double.init)) }
        return run((s.xp ?? []).map(Double.init), (s.yp ?? []).map(Double.init))
    }

    /// `getSmoothedPerimeter`: the smoothed line, closed.
    static func smoothedPerimeter(_ s: PolygonState, _ pw: Double, _ ph: Double) -> Double {
        let w2 = pw * pw, h2 = ph * ph
        let length = smoothedLineLength(s, pw, ph)
        let dx: Double, dy: Double
        if let xpf = s.xpf, let ypf = s.ypf {
            (dx, dy) = (Double(xpf[xpf.count - 1] - xpf[0]), Double(ypf[ypf.count - 1] - ypf[0]))
        } else {
            let xp = s.xp ?? [0], yp = s.yp ?? [0]
            (dx, dy) = (Double(xp[xp.count - 1] - xp[0]), Double(yp[yp.count - 1] - yp[0]))
        }
        return length + (dx * dx * w2 + dy * dy * h2).squareRoot()
    }

    /// `Roi.getFloatPolygon("")`: the outline in image coordinates, without
    /// a closing point; ovals as Java2D flattens an ellipse.
    public func outline() -> FloatPolygon? {
        switch shape {
        case .rectangle(let rect, let corner):
            if corner > 0 {
                let b = rect.intBounds
                // ShapeRoi(roi).getFloatPolygon(): a RoundRectangle2D.Double at
                // the origin; absolute coordinates add the ROI's origin (in float).
                let path = FlattenedPath.roundedRectangle(
                    x: 0, y: 0, width: b.width, height: b.height, corner: Int32(clamping: corner), floatStorage: false)
                let p = FlattenedPath.polygon(path, flatness: 0.1)
                let fx = Float(b.x), fy = Float(b.y)
                return FloatPolygon(xs: p.xs.map { $0 + fx }, ys: p.ys.map { $0 + fy })
            }
            switch rect {
            case .integer:
                let b = rect.intBounds
                return FloatPolygon(rectangleX: Int(b.x), y: Int(b.y), width: Int(b.width), height: Int(b.height))
            case .subpixel(let x, let y, let w, let h):
                let (fx, fy, fx2, fy2) = (Float(x), Float(y), Float(x + w), Float(y + h))
                return FloatPolygon(xs: [fx, fx2, fx2, fx], ys: [fy, fy, fy2, fy2])
            }
        case .oval(let rect):
            let b = rect.intBounds
            return Self.ellipseOutline(x: Int(b.x), y: Int(b.y), width: Int(b.width), height: Int(b.height))
        case .polygon(let polygon):
            let p = polygon.state.floatPolygon
            var xs = p.xs, ys = p.ys
            if !polygon.kind.isLine, xs.count > 1, xs[0] == xs[xs.count - 1], ys[0] == ys[ys.count - 1] {
                xs.removeLast()
                ys.removeLast()
            }
            return FloatPolygon(xs: xs, ys: ys)
        case .line(let line):
            return FloatPolygon(xs: [Float(line.x1), Float(line.x2)], ys: [Float(line.y1), Float(line.y2)])
        case .points(let points):
            let p = points.state.floatPolygon
            return FloatPolygon(xs: p.xs, ys: p.ys)
        case .opaque:
            return nil
        }
    }

    /// `OvalRoi.getFloatPolygon`: a `ShapeRoi` of an `Ellipse2D` 0.0004
    /// pixels larger all round, flattened with `ShapeRoi.FLATNESS` (0.1).
    /// The ShapeRoi stores the path, relative to its bounds, in floats.
    static func ellipseOutline(x: Int, y: Int, width: Int, height: Int) -> FloatPolygon {
        let ex = Double(x) - 0.0004, ey = Double(y) - 0.0004
        let ew = Double(width) + 0.0008, eh = Double(height) + 0.0008
        let bx = ex.rounded(.down), by = ey.rounded(.down)
        // java.awt.geom.EllipseIterator
        let ctrl = 0.5522847498307933
        let pcv = 0.5 + ctrl * 0.5, ncv = 0.5 - ctrl * 0.5
        let points: [[Double]] = [
            [1.0, pcv, pcv, 1.0, 0.5, 1.0], [ncv, 1.0, 0.0, pcv, 0.0, 0.5],
            [0.0, ncv, ncv, 0.0, 0.5, 0.0], [pcv, 0.0, 1.0, ncv, 1.0, 0.5],
        ]
        func px(_ c: Double) -> Double { Double(Float(ex + c * ew + -bx)) }
        func py(_ c: Double) -> Double { Double(Float(ey + c * eh + -by)) }
        var path: [FlattenedPath.Segment] = [.move(px(points[3][4]), py(points[3][5]))]
        for p in points {
            path.append(.cubic(px(p[0]), py(p[1]), px(p[2]), py(p[3]), px(p[4]), py(p[5])))
        }
        path.append(.close)
        let flat = FlattenedPath.polygon(path, flatness: 0.1)
        let fbx = Float(bx), fby = Float(by)
        return FloatPolygon(xs: flat.xs.map { $0 + fbx }, ys: flat.ys.map { $0 + fby })
    }

    /// `getFeretValues()`, calibrated with `pw` × `ph`. Ovals are measured
    /// along their axes (and report a calibrated start point).
    public func feretValues(pixelWidth pw: Double = 1, pixelHeight ph: Double = 1) -> FeretValues? {
        if case .oval(let rect) = shape {
            let b = rect.intBounds
            let (x, y, w, h) = (Double(b.x), Double(b.y), Double(b.width), Double(b.height))
            let high = ph * h > pw * w
            let points = [
                x + (high ? 0.5 * w : 0), y + (high ? h : 0.5 * h), x + (high ? 0.5 * w : w), y + (high ? 0 : 0.5 * h),
                x + (high ? 0 : 0.5 * w), y + (high ? 0.5 * h : h), x + (high ? w : 0.5 * w), y + (high ? 0.5 * h : 0),
            ]
            return FeretValues(
                diameter: high ? h * ph : w * pw, angle: high ? 90 : 0, minimum: high ? w * pw : h * ph,
                startX: (x + (high ? 0.5 * w : 0)) * pw, startY: (y + (high ? h : 0.5 * h)) * ph, points: points)
        }
        return outline().flatMap { FeretValues(polygon: $0, pixelWidth: pw, pixelHeight: ph) }
    }

    /// The measured pixels on a `width × height` image: the bounds, clipped,
    /// and a mask unless the ROI is a plain rectangle (whose ImageJ mask is null).
    public func measurementRegion(width: Int, height: Int) throws(RoiMaskError) -> MeasurementRegion {
        let mask = try self.mask(width: width, height: height)
        if case .rectangle(_, let corner) = shape, corner == 0 {
            return MeasurementRegion(x: mask.bounds.x, y: mask.bounds.y, width: mask.bounds.width, height: mask.bounds.height)
        }
        return MeasurementRegion(
            x: mask.bounds.x, y: mask.bounds.y, width: mask.bounds.width, height: mask.bounds.height, mask: mask.pixels)
    }
}

extension FloatPolygon {
    /// `Analyzer.getArea(Polygon)` on the polygon rounded to whole pixels
    /// (`Roi.getConvexHull()` rounds with `toIntR`).
    public var roundedArea: Double {
        let xs = self.xs.map { Int(JavaNumerics.int32((Double($0) + 0.5).rounded(.down))) }
        let ys = self.ys.map { Int(JavaNumerics.int32((Double($0) + 0.5).rounded(.down))) }
        var area = 0
        for i in 0..<xs.count {
            let j = i == 0 ? xs.count - 1 : i - 1
            area += (xs[i] + xs[j]) * (ys[i] - ys[j])
        }
        return abs(Double(area) / 2.0)
    }
}
