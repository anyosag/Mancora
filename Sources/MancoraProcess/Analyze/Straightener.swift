import MancoraCore

/// ImageJ's `Straightener.straightenLine`, which wide line profiles use: a
/// spline through the line's vertices, resampled at one-pixel steps
/// (`PolygonRoi.fitSplineForStraightening`), and at each of its points
/// `width` values sampled across the line.
enum Straightener {
    /// The straightened line: one column per point along the line, `width`
    /// rows, as the `FloatProcessor` ImageJ builds; `nil` when the line has
    /// fewer than two points.
    static func straighten(_ polygon: PolygonState, isFreeline: Bool, width: Int, from values: PixelValues) -> PixelValues? {
        guard width >= 1, let (px, py) = splineForStraightening(polygon, isFreeline: isFreeline), px.count >= 2 else {
            return nil
        }
        let n = px.count
        var out = [Float](repeating: 0, count: n * width)
        func put(_ i: Int, _ j: Int, _ v: Double) {
            if i >= 0 && i < n && j >= 0 && j < width { out[j * n + i] = Float(v) }
        }
        // The point before the first: extrapolated back one segment.
        var x2 = Double(px[0] - (px[1] - px[0]))
        var y2 = Double(py[0] - (py[1] - py[0]))
        if width <= 1 { put(0, 0, values.interpolated(x2, y2)) }
        for i in 0..<n {
            let x1 = x2, y1 = y2
            x2 = Double(px[i])
            y2 = Double(py[i])
            if width == 1 {
                put(i, 0, values.interpolated(x2, y2))
                continue
            }
            var dx = x2 - x1
            var dy = y1 - y2
            let length = Double(Float((dx * dx + dy * dy).squareRoot()))
            dx /= length
            dy /= length
            var x = x2 - dy * Double(width - 1) / 2.0
            var y = y2 - dx * Double(width - 1) / 2.0
            var j = 0
            var n2 = width
            repeat {
                put(i, j, values.interpolated(x, y))
                j += 1
                x += dy
                y += dx
                n2 -= 1
            } while n2 > 0
        }
        return PixelValues(width: n, height: width, pixels: out)
    }

    /// The points `getFloatPolygon()` returns after
    /// `fitSplineForStraightening()`: a spline evaluated at half-pixel
    /// steps, resampled to (nearly) one-pixel segments, and moved to the
    /// spline's own bounds the way `setSpline` does (all in `float`, which
    /// rounds them as in ImageJ).
    static func splineForStraightening(_ polygon: PolygonState, isFreeline: Bool) -> (xs: [Float], ys: [Float])? {
        let n = polygon.count
        guard n >= 2 else { return nil }
        let length = uncalibratedLength(polygon, isFreeline: isFreeline)
        // getSpline: an integer polygon becomes a subpixel one on the same base.
        let xpf: [Float], ypf: [Float], xBase: Double, yBase: Double
        if let fx = polygon.xpf, let fy = polygon.ypf {
            (xpf, ypf, xBase, yBase) = (fx, fy, polygon.xBase, polygon.yBase)
        } else {
            xpf = (polygon.xp ?? []).map { Float($0) }
            ypf = (polygon.yp ?? []).map { Float($0) }
            (xBase, yBase) = (Double(polygon.x), Double(polygon.y))
        }
        let evaluationPoints = Int(JavaNumerics.int32(length * 2)) + 1
        guard evaluationPoints >= 1 else { return nil }
        // The independent variable: cumulative square roots of the segment lengths.
        var nodes = [Float](repeating: 0, count: n)
        var last: Float = 0
        for i in 1..<n {
            let dx = xpf[i] - xpf[i - 1]
            let dy = ypf[i] - ypf[i - 1]
            let squared = dx * dx + dy * dy
            var dLength = Float(Double(squared).squareRoot().squareRoot())
            if dLength < 0.001 { dLength = 0.001 }
            last += dLength
            nodes[i] = last
        }
        let sfx = SplineFitter(nodes, xpf)
        let sfy = SplineFitter(nodes, ypf)
        let scale = Double(last) / Double(evaluationPoints - 1)
        var xs = [Float](repeating: 0, count: evaluationPoints)
        var ys = [Float](repeating: 0, count: evaluationPoints)
        for i in 0..<evaluationPoints {
            let v = Double(i) * scale
            xs[i] = Float(sfx.evaluate(v))
            ys[i] = Float(sfy.evaluate(v))
        }
        let (ex, ey) = equidistantPoints(xs, ys, segmentLength: 1.0)
        // setSpline → resetSplineFitBoundingRect, then getFloatPolygon.
        let bx = Float(xBase), by = Float(yBase)
        let ax = ex.map { $0 + bx }, ay = ey.map { $0 + by }
        let minX = ax.reduce(Float.greatestFiniteMagnitude) { RoiJava.min($0, $1) }
        let minY = ay.reduce(Float.greatestFiniteMagnitude) { RoiJava.min($0, $1) }
        return (ax.map { ($0 - minX) + minX }, ay.map { ($0 - minY) + minY })
    }

    /// `PolygonRoi.getUncalibratedLength()` for an open line: freelines of
    /// more than two points are smoothed with a 3-point running average.
    static func uncalibratedLength(_ polygon: PolygonState, isFreeline: Bool) -> Double {
        let n = polygon.count
        guard n >= 2 else { return 0 }
        if n > 2 && isFreeline && !(polygon.width == 0 || polygon.height == 0) {
            if let x = polygon.xpf, let y = polygon.ypf {
                // getFloatSmoothedLineLength
                func segment(_ dx: Double, _ dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }
                var length = segment(
                    Double(x[0] + x[1] + x[2]) / 3.0 - Double(x[0]), Double(y[0] + y[1] + y[2]) / 3.0 - Double(y[0]))
                for i in stride(from: 1, to: n - 2, by: 1) {
                    length += segment(Double(x[i + 2] - x[i - 1]) / 3.0, Double(y[i + 2] - y[i - 1]) / 3.0)
                }
                length += segment(
                    Double(x[n - 1]) - Double(x[n - 3] + x[n - 2] + x[n - 1]) / 3.0,
                    Double(y[n - 1]) - Double(y[n - 3] + y[n - 2] + y[n - 1]) / 3.0)
                return length
            }
            // getSmoothedLineLength
            let x = (polygon.xp ?? []).map(Int.init), y = (polygon.yp ?? []).map(Int.init)
            func segment(_ dx: Double, _ dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }
            var length = segment(
                Double(x[0] + x[1] + x[2]) / 3.0 - Double(x[0]), Double(y[0] + y[1] + y[2]) / 3.0 - Double(y[0]))
            for i in stride(from: 1, to: n - 2, by: 1) {
                length += segment(Double(x[i + 2] - x[i - 1]) / 3.0, Double(y[i + 2] - y[i - 1]) / 3.0)
            }
            length += segment(
                Double(x[n - 1]) - Double(x[n - 3] + x[n - 2] + x[n - 1]) / 3.0,
                Double(y[n - 1]) - Double(y[n - 3] + y[n - 2] + y[n - 1]) / 3.0)
            return length
        }
        if let x = polygon.xpf, let y = polygon.ypf { return polylineLength(x, y) }
        let x = polygon.xp ?? [], y = polygon.yp ?? []
        var length = 0.0
        for i in 0..<(n - 1) {
            let dx = Double(Int(x[i + 1]) - Int(x[i])), dy = Double(Int(y[i + 1]) - Int(y[i]))
            length += (dx * dx + dy * dy).squareRoot()
        }
        return length
    }

    /// `PolygonRoi.getLength(float[], float[], n, false, null)`.
    static func polylineLength(_ x: [Float], _ y: [Float]) -> Double {
        var length = 0.0
        for i in stride(from: 0, to: x.count - 1, by: 1) {
            let dx = Double(x[i + 1] - x[i]), dy = Double(y[i + 1] - y[i])
            length += (dx * dx + dy * dy).squareRoot()
        }
        return length
    }

    /// `PolygonRoi.getEquidistantPoints`: points along the polyline, a
    /// constant distance (as close to `segmentLength` as divides the
    /// length) apart.
    static func equidistantPoints(_ x: [Float], _ y: [Float], segmentLength: Double) -> ([Float], [Float]) {
        let n = x.count
        guard n > 0 else { return ([], []) }
        let length = polylineLength(x, y)
        let npOut = Int(JavaNumerics.roundToInt32(length / segmentLength)) + 1
        guard npOut >= 1 else { return ([], []) }
        let step = length / Double(npOut - 1)
        var xo = [Float](repeating: 0, count: npOut), yo = [Float](repeating: 0, count: npOut)
        xo[0] = x[0]
        yo[0] = y[0]
        var lengthRead = 0.0
        var written = 1
        var x2 = Double(x[0]), y2 = Double(y[0])
        for i in stride(from: 1, to: n, by: 1) {
            let x1 = x2, y1 = y2
            x2 = Double(x[i])
            y2 = Double(y[i])
            let dx = x2 - x1, dy = y2 - y1
            let distance = (dx * dx + dy * dy).squareRoot()
            lengthRead += distance
            var over = lengthRead - Double(written) * step
            while (over >= 0 || i == n - 1) && written < npOut {
                var fraction = over / distance
                if distance == 0 { fraction = 0 }
                xo[written] = Float(x2 - fraction * dx)
                yo[written] = Float(y2 - fraction * dy)
                over -= step
                written += 1
            }
        }
        return (xo, yo)
    }
}

/// ImageJ's `SplineFitter` for an open curve: a natural cubic spline
/// (zero second derivative at the ends) through `(x[i], y[i])`, with the
/// knots `x` in increasing order.
struct SplineFitter {
    let x: [Float]
    let y: [Float]
    private var y2: [Double]

    init(_ x: [Float], _ y: [Float]) {
        self.x = x
        self.y = y
        let n = x.count
        var y2 = [Double](repeating: 0, count: n)
        var cp = [Double](repeating: 0, count: n)
        var newX = Double(x[1]), newY = Double(y[1])
        var cj = Double(x[1] - x[0])
        var newDj = Double(y[1] - y[0]) / cj
        var j = 1
        while j < n - 1 {
            let oldX = newX, oldY = newY
            let aj = cj
            let oldDj = newDj
            newX = Double(x[j + 1])
            newY = Double(y[j + 1])
            cj = newX - oldX
            newDj = (newY - oldY) / cj
            let bj = 2.0 * (cj + aj)
            let invDenom = 1.0 / (bj - aj * cp[j - 1])
            let dj = 6.0 * (newDj - oldDj)
            y2[j] = (dj - aj * y2[j - 1]) * invDenom
            cp[j] = cj * invDenom
            j += 1
        }
        while j > 0 {
            j -= 1
            y2[j] = y2[j] - cp[j] * y2[j + 1]
        }
        self.y2 = y2
    }

    /// `evalSpline(xp)`.
    func evaluate(_ xp: Double) -> Double {
        var ls = 0, rs = x.count - 1
        while rs > 1 + ls {
            let m = Int((0.5 * Double(ls + rs)).rounded(.down))
            if Double(x[m]) < xp { ls = m } else { rs = m }
        }
        let ba = Double(x[rs] - x[ls])
        let xa = xp - Double(x[ls])
        let bx = Double(x[rs]) - xp
        let ba2 = ba * ba
        let lower = xa * Double(y[rs]) + bx * Double(y[ls])
        let c = (xa * xa - ba2) * xa * y2[rs]
        let d = (bx * bx - ba2) * bx * y2[ls]
        return (lower + (c + d) / 6.0) / ba
    }
}
