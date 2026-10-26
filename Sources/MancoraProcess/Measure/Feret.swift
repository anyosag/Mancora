import Foundation

/// A polygon with float vertices, as ImageJ's `FloatPolygon` stores them.
public struct FloatPolygon: Sendable, Hashable {
    public var xs: [Float]
    public var ys: [Float]

    public init(xs: [Float], ys: [Float]) {
        self.xs = xs
        self.ys = ys
    }

    /// The outline of the pixel rectangle at (`x`, `y`), as `Roi.getPolygon` gives it.
    public init(rectangleX x: Int, y: Int, width: Int, height: Int) {
        xs = [Float(x), Float(x + width), Float(x + width), Float(x)]
        ys = [Float(y), Float(y), Float(y + height), Float(y + height)]
    }

    public var count: Int { xs.count }

    /// `FloatPolygon.getConvexHull`: gift wrapping from the topmost-leftmost
    /// vertex, leaving out collinear and duplicate points.
    public func convexHull() -> FloatPolygon {
        let n = count
        guard n > 0 else { return self }
        var hx: [Float] = [], hy: [Float] = []
        let smallestY = ys.min() ?? 0
        var smallestX = Float.greatestFiniteMagnitude
        var p1 = 0
        for i in 0..<n where ys[i] == smallestY && xs[i] < smallestX {
            smallestX = xs[i]
            p1 = i
        }
        let start = p1
        func sqr(_ v: Double) -> Double { v * v }
        repeat {
            let x1 = Double(xs[p1]), y1 = Double(ys[p1])
            var p2 = p1
            var x2 = 0.0, y2 = 0.0
            repeat {
                p2 += 1
                if p2 == n { p2 = 0 }
                if p2 == p1 { break }
                x2 = Double(xs[p2])
                y2 = Double(ys[p2])
            } while x2 == x1 && y2 == y1
            var p3 = p2 + 1
            if p3 == n { p3 = 0 }
            if p2 != p1 {
                repeat {
                    let x3 = Double(xs[p3]), y3 = Double(ys[p3])
                    let determinate = x1 * (y2 - y3) - y1 * (x2 - x3) + (y3 * x2 - y2 * x3)
                    var collinearAndFurther = false
                    if determinate == 0 && p3 != p2 {
                        collinearAndFurther = sqr(x3 - x1) + sqr(y3 - y1) > sqr(x2 - x1) + sqr(y2 - y1)
                    }
                    if determinate > 0 || collinearAndFurther {
                        (x2, y2, p2) = (x3, y3, p3)
                    }
                    p3 += 1
                    if p3 == n { p3 = 0 }
                } while p3 != p1
            }
            hx.append(Float(x1))
            hy.append(Float(y1))
            if p2 == p1 { break }
            p1 = p2
            if hx.count > 1 && xs[p1] == hx[0] && ys[p1] == hy[0] { break }
        } while p1 != start
        return FloatPolygon(xs: hx, ys: hy)
    }
}

/// Feret's diameter and friends (`Roi.getFeretValues`).
public struct FeretValues: Sendable, Hashable {
    /// The largest distance between two points of the outline.
    public var diameter: Double
    /// Its angle in degrees (0–180).
    public var angle: Double
    /// The smallest caliper width.
    public var minimum: Double
    /// The diameter's starting point (the left end), in pixels.
    public var startX: Double
    public var startY: Double

    public init(diameter: Double, angle: Double, minimum: Double, startX: Double, startY: Double) {
        self.diameter = diameter
        self.angle = angle
        self.minimum = minimum
        self.startX = startX
        self.startY = startY
    }

    /// Computed on the convex hull of `polygon`, with pixel sizes `pw` × `ph`.
    public init?(polygon: FloatPolygon, pixelWidth pw: Double = 1, pixelHeight ph: Double = 1) {
        let hull = polygon.convexHull()
        let n = hull.count
        guard n > 0 else { return nil }
        let xs = hull.xs.map(Double.init), ys = hull.ys.map(Double.init)
        var p1 = 0, p2 = 0
        var diameterSqr = 0.0
        for i in 0..<n {
            for j in (i + 1)..<n {
                // FloatPolygon coordinates: subtracted in float, then scaled.
                let dx = Double(hull.xs[i] - hull.xs[j]) * pw
                let dy = Double(hull.ys[i] - hull.ys[j]) * ph
                let dsqr = dx * dx + dy * dy
                if dsqr > diameterSqr {
                    (diameterSqr, p1, p2) = (dsqr, i, j)
                }
            }
        }
        if xs[p1] > xs[p2] { swap(&p1, &p2) }
        let (xf1, yf1, xf2, yf2) = (xs[p1], ys[p1], xs[p2], ys[p2])
        var angle = (180.0 / Double.pi) * atan2((yf1 - yf2) * ph, (xf2 - xf1) * pw)
        if angle < 0 { angle += 180 }
        diameter = diameterSqr.squareRoot()
        self.angle = angle
        startX = xf1
        startY = yf1
        // The smallest caliper width: for each hull side, the farthest point from it.
        var x0 = xs[n - 1], y0 = ys[n - 1]
        var minFeret = Double.greatestFiniteMagnitude
        for i in 0..<n {
            let (xprev, yprev) = (x0, y0)
            (x0, y0) = (xs[i], ys[i])
            var xnorm = (y0 - yprev) * ph
            var ynorm = (xprev - x0) * pw
            let normalization = 1 / (xnorm * xnorm + ynorm * ynorm).squareRoot()
            xnorm *= normalization * pw
            ynorm *= normalization * ph
            var maxDist = 0.0
            for j in 0..<n {
                let dist = (xs[j] - x0) * xnorm + (ys[j] - y0) * ynorm
                if dist > maxDist { maxDist = dist }
            }
            if maxDist < minFeret { minFeret = maxDist }
        }
        minimum = minFeret
    }
}
