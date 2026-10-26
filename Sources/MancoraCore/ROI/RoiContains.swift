extension Roi {
    /// ImageJ's `Roi.contains(int x, int y)`: whether the pixel at (x, y) is
    /// inside, by each ROI class's own test (which can differ from its mask
    /// at the edges). `nil` for the shapes whose test Mancora doesn't
    /// reproduce: subpixel rectangles, ovals and polygons, spline fits,
    /// lines, points and opaque ROIs.
    public func containsPixel(x: Int, y: Int) -> Bool? {
        switch shape {
        case .rectangle(.integer(let rx, let ry, let rw, let rh), let corner):
            // Roi.contains: the rectangle, then a RoundRectangle2D for rounded corners.
            let (x0, y0, w, h) = (Int(rx), Int(ry), Int(max(rw, 1)), Int(max(rh, 1)))
            let inside = x >= x0 && y >= y0 && x < x0 + w && y < y0 + h
            guard corner > 0, inside else { return inside }
            return Self.roundRectangleContains(
                Double(x) + 0.4999, Double(y) + 0.4999, x: Double(x0), y: Double(y0), width: Double(w),
                height: Double(h), arc: Double(corner))
        case .oval(.integer(let ox, let oy, let ow, let oh)):
            // OvalRoi.contains(int, int)
            let a = Double(max(ow, 1)) * 0.5, b = Double(max(oh, 1)) * 0.5
            let dx = Double(x) - (Double(ox) + a - 0.5), dy = Double(y) - (Double(oy) + b - 0.5)
            return (dx * dx) / (a * a) + (dy * dy) / (b * b) <= 1.0
        case .polygon(let polygon):
            guard !polygon.kind.isLine, !polygon.isSplineFit, polygon.parametric == nil,
                case .integer(let points) = polygon.vertices, !points.isEmpty
            else { return nil }
            // PolygonRoi.contains: the bounds, then java.awt.Polygon.contains
            // at (x + 0.4999, y + 0.5) relative to them.
            let xs = points.map { Int($0.x) }, ys = points.map { Int($0.y) }
            let minX = xs.min()!, minY = ys.min()!
            let width = xs.max()! - minX, height = ys.max()! - minY
            guard x >= minX && y >= minY && x < minX + width && y < minY + height else { return false }
            return Self.polygonContains(
                xs.map { $0 - minX }, ys.map { $0 - minY }, Double(x - minX) + 0.4999, Double(y - minY) + 0.5)
        default:
            return nil
        }
    }

    /// `java.awt.geom.RoundRectangle2D.contains(x, y)`.
    static func roundRectangleContains(
        _ px: Double, _ py: Double, x: Double, y: Double, width: Double, height: Double, arc: Double
    ) -> Bool {
        if width <= 0 || height <= 0 { return false }
        var rrx0 = x, rry0 = y
        let rrx1 = rrx0 + width, rry1 = rry0 + height
        if px < rrx0 || py < rry0 || px >= rrx1 || py >= rry1 { return false }
        let aw = min(width, abs(arc)) / 2.0
        let ah = min(height, abs(arc)) / 2.0
        rrx0 += aw
        if px >= rrx0 {
            rrx0 = rrx1 - aw
            if px < rrx0 { return true }
        }
        rry0 += ah
        if py >= rry0 {
            rry0 = rry1 - ah
            if py < rry0 { return true }
        }
        let nx = (px - rrx0) / aw, ny = (py - rry0) / ah
        return nx * nx + ny * ny <= 1.0
    }

    /// `java.awt.Polygon.contains(double, double)`: even-odd crossings,
    /// within the bounding box.
    static func polygonContains(_ xs: [Int], _ ys: [Int], _ x: Double, _ y: Double) -> Bool {
        let n = xs.count
        guard n > 2 else { return false }
        let bx = xs.min()!, by = ys.min()!
        let bw = xs.max()! - bx, bh = ys.max()! - by
        guard x >= Double(bx), y >= Double(by), x < Double(bx + bw), y < Double(by + bh) else { return false }
        var hits = 0
        var lastx = xs[n - 1], lasty = ys[n - 1]
        for i in 0..<n {
            let curx = xs[i], cury = ys[i]
            defer {
                lastx = curx
                lasty = cury
            }
            if cury == lasty { continue }
            let leftx: Int
            if curx < lastx {
                if x >= Double(lastx) { continue }
                leftx = curx
            } else {
                if x >= Double(curx) { continue }
                leftx = lastx
            }
            let test1: Double, test2: Double
            if cury < lasty {
                if y < Double(cury) || y >= Double(lasty) { continue }
                if x < Double(leftx) {
                    hits += 1
                    continue
                }
                test1 = x - Double(curx)
                test2 = y - Double(cury)
            } else {
                if y < Double(lasty) || y >= Double(cury) { continue }
                if x < Double(leftx) {
                    hits += 1
                    continue
                }
                test1 = x - Double(lastx)
                test2 = y - Double(lasty)
            }
            if test1 < test2 / Double(lasty - cury) * Double(lastx - curx) { hits += 1 }
        }
        return hits & 1 != 0
    }
}
