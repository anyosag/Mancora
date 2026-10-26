/// Java semantics the ROI code needs beyond ``JavaNumerics``.
package enum RoiJava {
    /// `(int)Math.floor(v)`.
    package static func floorInt(_ v: Double) -> Int32 { JavaNumerics.int32(v.rounded(.down)) }

    /// `(int)Math.ceil(v)`.
    package static func ceilInt(_ v: Double) -> Int32 { JavaNumerics.int32(v.rounded(.up)) }

    /// `Math.round(double)`: the closest `long`, ties toward positive
    /// infinity, i.e. exactly `floor(v + 0.5)`; NaN gives 0.
    package static func round(_ v: Double) -> Int64 {
        guard v.isFinite else { return v.isNaN ? 0 : (v > 0 ? .max : .min) }
        let f = v.rounded(.down)
        // v - floor(v) is exact (Sterbenz) except for -0.5 < v < 0, where
        // 1 + v lies in (0.5, 1) and can't round below 0.5; so this is
        // floor(v + 0.5) without the rounding error of adding 0.5 first.
        let r = v - f >= 0.5 ? f + 1 : f
        if r >= 9.223372036854775807e18 { return .max }
        if r < -9.223372036854775807e18 { return .min }
        return Int64(r)
    }

    /// `Math.min(float, float)`: NaN wins, and -0.0 is less than 0.0.
    package static func min(_ a: Float, _ b: Float) -> Float {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return a.sign == .minus ? a : b }
        return a <= b ? a : b
    }

    /// `Math.max(float, float)`: NaN wins, and 0.0 is greater than -0.0.
    package static func max(_ a: Float, _ b: Float) -> Float {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return a.sign == .plus ? a : b }
        return a >= b ? a : b
    }

    /// `Math.min(double, double)`.
    package static func min(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return a.sign == .minus ? a : b }
        return a <= b ? a : b
    }

    /// `Math.max(double, double)`.
    package static func max(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return a.sign == .plus ? a : b }
        return a >= b ? a : b
    }
}

/// ImageJ's in-memory form of a `PolygonRoi` or `PointRoi`: the vertices
/// relative to the ROI's origin, and its integer bounds (`finishPolygon()`,
/// or `makePolygonRelative()` for ellipses and rotated rectangles).
package struct PolygonState: Sendable {
    /// Whole-pixel vertices relative to (x, y): ImageJ's `xp`, `yp`.
    package var xp: [Int32]?
    package var yp: [Int32]?
    /// Subpixel vertices relative to (xBase, yBase): ImageJ's `xpf`, `ypf`.
    package var xpf: [Float]?
    package var ypf: [Float]?
    /// `getXBase()`, `getYBase()`.
    package var xBase: Double
    package var yBase: Double
    /// `getBounds()`.
    package var x: Int32
    package var y: Int32
    package var width: Int32
    package var height: Int32

    package var count: Int { xpf?.count ?? xp?.count ?? 0 }
    package var isSubpixel: Bool { xpf != nil }

    /// `new PolygonRoi(int[], int[], n, type)`.
    package init(integer points: [Roi.IntPoint], isLine: Bool) {
        var minX = Int32.max, minY = Int32.max, maxX = Int32.min, maxY = Int32.min
        for p in points {
            minX = Swift.min(minX, p.x)
            maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y)
            maxY = Swift.max(maxY, p.y)
        }
        if points.isEmpty { (minX, minY, maxX, maxY) = (0, 0, 0, 0) }  // java.awt.Polygon's empty bounds
        x = minX
        y = minY
        width = maxX &- minX
        height = maxY &- minY
        let ox = x, oy = y
        xp = points.map { $0.x &- ox }
        yp = points.map { $0.y &- oy }
        if isLine {  // open lines include the pixels that drawing them touches
            width &+= 1
            height &+= 1
        }
        xBase = Double(x)
        yBase = Double(y)
    }

    /// `new PolygonRoi(float[], float[], n, type)` and `new PointRoi(...)`.
    package init(subpixel points: [Roi.FloatPoint], isLine: Bool) {
        // FloatPolygon.getFloatBounds() starts maxX at Float.MIN_VALUE, the
        // smallest positive float, so an all-negative polygon's bounds reach 0.
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = Float.leastNonzeroMagnitude, maxY = Float.leastNonzeroMagnitude
        for p in points {
            minX = RoiJava.min(minX, p.x)
            maxX = RoiJava.max(maxX, p.x)
            minY = RoiJava.min(minY, p.y)
            maxY = RoiJava.max(maxY, p.y)
        }
        let bx, by, bw, bh: Double
        if points.isEmpty {
            (bx, by, bw, bh) = (0, 0, 0, 0)
        } else {
            (bx, by, bw, bh) = (Double(minX), Double(minY), Double(maxX - minX), Double(maxY - minY))
        }
        let fx = Float(bx), fy = Float(by)
        xpf = points.map { $0.x - fx }
        ypf = points.map { $0.y - fy }
        xBase = bx
        yBase = by
        // Roi.setIntBounds(): lines and points use pixel centers.
        if isLine {
            x = RoiJava.floorInt(bx + 0.5)
            y = RoiJava.floorInt(by + 0.5)
            width = RoiJava.floorInt(bx + bw + 1.5) &- x
            height = RoiJava.floorInt(by + bh + 1.5) &- y
        } else {
            x = RoiJava.floorInt(bx)
            y = RoiJava.floorInt(by)
            width = RoiJava.ceilInt(bx + bw) &- x
            height = RoiJava.ceilInt(by + bh) &- y
        }
    }

    /// `EllipseRoi` and `RotatedRectRoi`: `makePolygonRelative()`, which uses
    /// `FloatPolygon.getBounds()` (rounding the size rather than enclosing
    /// every vertex) and keeps the integer origin as the base.
    package init(parametric points: [Roi.FloatPoint]) {
        if points.isEmpty {
            (x, y, width, height) = (0, 0, 0, 0)
        } else {
            var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
            var maxX = Float.leastNonzeroMagnitude, maxY = Float.leastNonzeroMagnitude
            for p in points {
                minX = RoiJava.min(minX, p.x)
                maxX = RoiJava.max(maxX, p.x)
                minY = RoiJava.min(minY, p.y)
                maxY = RoiJava.max(maxY, p.y)
            }
            x = RoiJava.floorInt(Double(minX))
            y = RoiJava.floorInt(Double(minY))
            width = JavaNumerics.int32(Double(maxX - Float(x)) + 0.5)
            height = JavaNumerics.int32(Double(maxY - Float(y)) + 0.5)
        }
        let fx = Float(x), fy = Float(y)
        xpf = points.map { $0.x - fx }
        ypf = points.map { $0.y - fy }
        xBase = Double(x)
        yBase = Double(y)
    }

    /// `Roi.enableSubPixelResolution()` on an integer polygon, which
    /// `RoiEncoder` calls for ROIs beyond 60000 pixels.
    package mutating func enableSubPixelResolution() {
        guard let xp, let yp, xpf == nil else { return }
        xpf = xp.map { Float($0) }
        ypf = yp.map { Float($0) }
        xBase = Double(x)
        yBase = Double(y)
    }

    /// `getFloatPolygon()` (without a spline): absolute 32-bit coordinates.
    package var floatPolygon: (xs: [Float], ys: [Float]) {
        if let xpf, let ypf {
            let bx = Float(xBase), by = Float(yBase)
            return (xpf.map { $0 + bx }, ypf.map { $0 + by })
        }
        let ox = x, oy = y
        return ((xp ?? []).map { Float($0 &+ ox) }, (yp ?? []).map { Float($0 &+ oy) })
    }

    /// `getNonSplineCoordinates()`: integer vertices relative to the base,
    /// rounded with `toIntR` (`(int)Math.floor(v + 0.5)`) from subpixel ones.
    package var relativeIntegerPolygon: (xs: [Int32], ys: [Int32]) {
        if let xpf, let ypf {
            return (xpf.map { RoiJava.floorInt(Double($0) + 0.5) }, ypf.map { RoiJava.floorInt(Double($0) + 0.5) })
        }
        return (xp ?? [], yp ?? [])
    }
}

extension Roi.Polygon {
    /// ImageJ's in-memory polygon for this shape.
    package var state: PolygonState {
        if parametric != nil {
            return PolygonState(parametric: vertices.floatPoints)
        }
        switch vertices {
        case .integer(let p): return PolygonState(integer: p, isLine: kind.isLine)
        case .subpixel(let p): return PolygonState(subpixel: p, isLine: kind.isLine)
        }
    }
}

extension Roi.Points {
    /// ImageJ's in-memory polygon: `PointRoi` always has subpixel vertices.
    package var state: PolygonState { PolygonState(subpixel: vertices.floatPoints, isLine: true) }
}

extension Roi.Rect {
    /// `getBounds()`: subpixel rectangles truncate their origin and round
    /// their size up, and ImageJ keeps at least one pixel.
    package var intBounds: (x: Int32, y: Int32, width: Int32, height: Int32) {
        switch self {
        case .integer(let x, let y, let w, let h):
            return (x, y, Swift.max(w, 1), Swift.max(h, 1))
        case .subpixel(let x, let y, let w, let h):
            return (
                JavaNumerics.int32(x), JavaNumerics.int32(y),
                Swift.max(RoiJava.ceilInt(w), 1), Swift.max(RoiJava.ceilInt(h), 1)
            )
        }
    }
}

extension Roi.Line {
    /// `Line.updateCoordinates()`: bounds around the pixel centers. (An
    /// `Arrow` reports the bounds of its head instead, which Mancora doesn't
    /// compute; the shaft's bounds are used.)
    package var intBounds: (x: Int32, y: Int32, width: Int32, height: Int32) {
        let bx = RoiJava.min(x1, x2), by = RoiJava.min(y1, y2)
        let bw = abs(x2 - x1), bh = abs(y2 - y1)
        let x = RoiJava.floorInt(bx + 0.5), y = RoiJava.floorInt(by + 0.5)
        return (x, y, RoiJava.floorInt(bx + bw + 1.5) &- x, RoiJava.floorInt(by + bh + 1.5) &- y)
    }
}

extension Roi {
    /// The ROI's integer bounding rectangle, as ImageJ's `Roi.getBounds()`.
    ///
    /// Area ROIs enclose every vertex; lines and points include the pixels
    /// whose centers they touch. Masks are placed at these bounds.
    public var bounds: RoiBounds {
        let b: (x: Int32, y: Int32, width: Int32, height: Int32)
        switch shape {
        case .rectangle(let r, _), .oval(let r): b = r.intBounds
        case .polygon(let p):
            let s = p.state
            b = (s.x, s.y, s.width, s.height)
        case .line(let l): b = l.intBounds
        case .points(let p):
            let s = p.state
            b = (s.x, s.y, s.width, s.height)
        case .opaque(let o): return o.bounds
        }
        return RoiBounds(x: Int(b.x), y: Int(b.y), width: Int(b.width), height: Int(b.height))
    }
}
