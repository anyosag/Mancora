public import MancoraCore

/// The values Analyze ▸ Measure samples along a one-pixel-wide line
/// selection: ImageJ's `ProfilePlot.getProfile()` with "Interpolate line
/// profiles" on (its default). Measure needs only this much of the profile
/// engine; Plot Profile builds on the same sampling.
extension Roi {
    /// The profile along a straight line (`ImageProcessor.getLine`), a
    /// polyline or a freeline (`ProfilePlot.getIrregularProfile`), or `nil`
    /// for other selections and for lines wider than one pixel.
    public func lineProfile(of plane: Plane, width: Int) -> [Double]? {
        guard strokeWidth.rounded() <= 1 else { return nil }
        let processor = GeometryProcessor(plane, width: width)
        switch shape {
        case .line(let line):
            return LineProfile.straight(processor, x1: line.x1, y1: line.y1, x2: line.x2, y2: line.y2)
        case .polygon(let polygon) where polygon.kind == .polyline || polygon.kind == .freeline:
            guard !polygon.isSplineFit else { return nil }
            let p = polygon.state.floatPolygon
            return LineProfile.irregular(processor, xs: p.xs, ys: p.ys)
        default:
            return nil
        }
    }
}

enum LineProfile {
    /// `ImageProcessor.getLine(x1, y1, x2, y2)` with interpolation: `n + 1`
    /// points `getInterpolatedValue` reads, `n` the rounded length.
    static func straight(_ ip: GeometryProcessor, x1: Double, y1: Double, x2: Double, y2: Double) -> [Double] {
        let dx = x2 - x1, dy = y2 - y1
        let n = Int(JavaNumerics.round((dx * dx + dy * dy).squareRoot()))
        let xinc = n > 0 ? dx / Double(n) : 0
        let yinc = n > 0 ? dy / Double(n) : 0
        var rx = x1, ry = y1
        var data = [Double](repeating: 0, count: n + 1)
        for i in 0...n {
            data[i] = ip.interpolatedValue(x: rx, y: ry)
            rx += xinc
            ry += yinc
        }
        return data
    }

    /// `ProfilePlot.getIrregularProfile`: steps of 0.01 pixels along each
    /// segment, taking a value whenever the step is at least 0.995 pixels
    /// from the last one taken.
    static func irregular(_ ip: GeometryProcessor, xs: [Float], ys: [Float]) -> [Double] {
        let n = xs.count
        var values: [Double] = []
        let inc = 0.01
        var lastx = 0.0, lasty = 0.0
        var x2 = Double(xs.first ?? 0), y2 = Double(ys.first ?? 0)
        guard n > 1 else { return values }
        for i in 1..<n {
            let x1 = x2, y1 = y2
            var x = x1, y = y1
            x2 = Double(xs[i])
            y2 = Double(ys[i])
            var dx = x2 - x1, dy = y2 - y1
            let distance = (dx * dx + dy * dy).squareRoot()
            let xinc = dx * inc / distance, yinc = dy * inc / distance
            var n2 = Int(JavaNumerics.int32(distance / inc))
            if n == 2 { n2 += 1 }
            repeat {
                dx = x - lastx
                dy = y - lasty
                let distance2 = (dx * dx + dy * dy).squareRoot()
                if distance2 >= 1.0 - inc / 2.0 {
                    values.append(ip.interpolatedValue(x: x, y: y))
                    lastx = x
                    lasty = y
                }
                x += xinc
                y += yinc
                n2 -= 1
            } while n2 > 0
        }
        return values
    }
}
