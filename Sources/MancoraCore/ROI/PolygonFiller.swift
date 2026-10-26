/// ImageJ's scan-line polygon filler (`ij.process.PolygonFiller`, 1.54p),
/// ported operation for operation so the filled pixels match exactly.
///
/// ImageJ's conventions: outline coordinates are pixel corners, so pixel
/// (x, y) is filled when its center (x + 0.5, y + 0.5) is inside. A center
/// exactly on a left edge is outside and on a right edge inside; on a
/// horizontal edge it is outside at the top and inside at the bottom. Edges
/// are combined with the even-odd rule. With float coordinates each vertex's
/// y is first rounded to a pixel boundary (`Math.round`), and NaN x
/// coordinates separate several polygons.
struct PolygonFiller {
    private enum Vertices {
        case integer(xs: [Int32], ys: [Int32])
        case float(xs: [Float], ys: [Float], xOffset: Double, yOffset: Double)
    }

    private let vertices: Vertices
    private let n: Int

    // Edge table: x at the first row, the rows it spans, and dx per row.
    private var ex: [Double]
    private var ey1: [Int32]
    private var ey2: [Int32]
    private var eslope: [Double]
    private var edges = 0
    private var yMin = Int32.max
    private var yMax = Int32.min
    // Active edges (indexes into the edge table), sorted by x.
    private var aedge: [Int]
    private var activeEdges = 0

    init(xs: [Int32], ys: [Int32]) {
        vertices = .integer(xs: xs, ys: ys)
        n = Swift.min(xs.count, ys.count)
        (ex, ey1, ey2, eslope, aedge) = Self.arrays(n)
    }

    /// Float vertices; `xOffset` and `yOffset` are added to each (in double).
    init(xs: [Float], ys: [Float], xOffset: Double, yOffset: Double) {
        vertices = .float(xs: xs, ys: ys, xOffset: xOffset, yOffset: yOffset)
        n = Swift.min(xs.count, ys.count)
        (ex, ey1, ey2, eslope, aedge) = Self.arrays(n)
    }

    private static func arrays(_ n: Int) -> ([Double], [Int32], [Int32], [Double], [Int]) {
        ([Double](repeating: 0, count: n), [Int32](repeating: 0, count: n), [Int32](repeating: 0, count: n),
         [Double](repeating: 0, count: n), [Int](repeating: 0, count: n))
    }

    /// `buildEdgeTable()`: all non-horizontal edges.
    private mutating func buildEdgeTable() {
        yMin = .max
        yMax = .min
        edges = 0
        var polyStart = 0
        for i in 0..<n {
            var iplus1 = i == n - 1 ? polyStart : i + 1
            switch vertices {
            case .integer(let xs, let ys):
                var y1 = ys[i], y2 = ys[iplus1]
                var x1 = xs[i], x2 = xs[iplus1]
                if y1 == y2 { continue }
                if y1 > y2 {
                    swap(&y1, &y2)
                    swap(&x1, &x2)
                }
                let slope = Double(x2 &- x1) / Double(y2 &- y1)
                ex[edges] = Double(x1) + 0.5 * slope + 1e-8
                ey1[edges] = y1
                ey2[edges] = y2
                eslope[edges] = slope
                if y1 < yMin { yMin = y1 }
                if y2 > yMax { yMax = y2 }
            case .float(let xs, let ys, let xOffset, let yOffset):
                if xs[iplus1].isNaN { iplus1 = polyStart }  // close the polygon after its last point
                if xs[i].isNaN {  // a new polygon follows
                    polyStart = i + 1
                    continue
                }
                var y1f = Double(ys[i]) + yOffset, y2f = Double(ys[iplus1]) + yOffset
                var x1f = Double(xs[i]) + xOffset, x2f = Double(xs[iplus1]) + xOffset
                var y1 = Int32(truncatingIfNeeded: RoiJava.round(y1f))
                var y2 = Int32(truncatingIfNeeded: RoiJava.round(y2f))
                if y1 == y2 || (y1 <= 0 && y2 <= 0) { continue }
                if y1 > y2 {
                    swap(&y1, &y2)
                    swap(&y1f, &y2f)
                    swap(&x1f, &x2f)
                }
                let slope = (x2f - x1f) / (y2f - y1f)
                ex[edges] = x1f + (Double(y1) - y1f + 0.5) * slope + 1e-8
                ey1[edges] = y1
                ey2[edges] = y2
                eslope[edges] = slope
                if y1 < yMin { yMin = y1 }
                if y2 > yMax { yMax = y2 }
            }
            edges += 1
        }
        activeEdges = 0
    }

    /// `fillByteProcessorMask()` for a `width` × `height` mask, calling
    /// `span(y, x1, x2)` for the pixels `x1..<x2` filled on row `y`. Rows from
    /// `rowLimit` on are skipped; earlier rows must still be scanned (even if
    /// the caller discards them), because each row's edge positions are
    /// accumulated from the previous row's, as in ImageJ.
    mutating func fill(width: Int, height: Int, rowLimit: Int, _ span: (Int, Int, Int) -> Void) {
        buildEdgeTable()
        let yStart = yMin > 0 ? yMin : 0
        if yMin != 0 { shiftXValuesAndActivate(yStart) }
        let end = Swift.min(Int64(Swift.min(height, rowLimit)), Int64(yMax &+ 1))
        var y = Int64(yStart)
        while y < end {
            let row = Int32(y)
            removeInactiveEdges(row)
            activateEdges(row)
            var i = 0
            while i < activeEdges {
                // Java reads aedge[i + 1] even for an odd count (a stale
                // entry); it can't be odd for a closed polygon.
                guard i + 1 < aedge.count else { break }
                var x1 = Int(JavaNumerics.int32(ex[aedge[i]] + 0.5))
                if x1 < 0 { x1 = 0 }
                if x1 > width { x1 = width }
                var x2 = Int(JavaNumerics.int32(ex[aedge[i + 1]] + 0.5))
                if x2 < 0 { x2 = 0 }
                if x2 > width { x2 = width }
                if x1 < x2 { span(Int(row), x1, x2) }
                i += 2
            }
            updateXCoordinates()
            y += 1
        }
    }

    private mutating func shiftXValuesAndActivate(_ yStart: Int32) {
        for index in 0..<edges where ey1[index] < yStart && ey2[index] >= yStart {
            ex[index] += eslope[index] * Double(yStart &- ey1[index])
            aedge[activeEdges] = index
            activeEdges += 1
        }
        sortActiveEdges()
    }

    private mutating func updateXCoordinates() {
        var x1 = -Double.greatestFiniteMagnitude
        var sorted = true
        for i in 0..<activeEdges {
            let index = aedge[i]
            let x2 = ex[index] + eslope[index]
            ex[index] = x2
            if x2 < x1 { sorted = false }
            x1 = x2
        }
        if !sorted { sortActiveEdges() }
    }

    /// Selection sort by x, as in ImageJ.
    private mutating func sortActiveEdges() {
        for i in 0..<activeEdges {
            var min = i
            for j in i..<activeEdges where ex[aedge[j]] < ex[aedge[min]] { min = j }
            aedge.swapAt(min, i)
        }
    }

    private mutating func removeInactiveEdges(_ y: Int32) {
        var i = 0
        while i < activeEdges {
            let index = aedge[i]
            if y < ey1[index] || y >= ey2[index] {
                for j in i..<(activeEdges - 1) { aedge[j] = aedge[j + 1] }
                activeEdges -= 1
            } else {
                i += 1
            }
        }
    }

    private mutating func activateEdges(_ y: Int32) {
        for edge in 0..<edges where y == ey1[edge] {
            var index = 0
            while index < activeEdges && ex[edge] > ex[aedge[index]] { index += 1 }
            var j = activeEdges - 1
            while j >= index {
                aedge[j + 1] = aedge[j]
                j -= 1
            }
            aedge[index] = edge
            activeEdges += 1
        }
    }
}
