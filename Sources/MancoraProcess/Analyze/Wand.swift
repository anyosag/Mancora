import MancoraCore

/// ImageJ's wand (`ij.gui.Wand`): traces the outline of a connected area of
/// thresholded pixels. The outline's vertices lie between pixels: a vertical
/// edge at x separates the pixels at x−1 and x.
public struct Wand {
    public enum Mode: Sendable {
        /// ImageJ before 1.43: no check whether the area or an inner hole was
        /// traced; thresholded areas are 8-connected. Analyze Particles' default.
        case legacy
        case fourConnected
        case eightConnected
    }

    private let values: [Float]
    private let width: Int
    private let height: Int
    private var lower: Float = 0
    private var upper: Float = 0
    public private(set) var xs: [Int32] = []
    public private(set) var ys: [Int32] = []
    private var xmin = 0

    /// The outline from (x, y) in `values`, the pixel values as ImageJ's
    /// `getPixel` reads them (8- and 16-bit values, or floats), `width`
    /// pixels wide: `autoOutline(startX, startY, lower, upper, mode)`.
    public static func outline(
        values: [Float], width: Int, x: Int, y: Int, lower: Double, upper: Double, mode: Mode
    ) -> (xs: [Int32], ys: [Int32]) {
        var wand = Wand(values: values, width: width)
        wand.autoOutline(x: x, y: y, lower: lower, upper: upper, mode: mode)
        return (wand.xs, wand.ys)
    }

    /// A wand on `values`, `width` pixels wide.
    public init(values: [Float], width: Int) {
        self.values = values
        self.width = width
        height = width > 0 ? values.count / width : 0
    }

    /// `autoOutline(startX, startY, lower, upper, mode)`: the outline of the
    /// area of values in `lower...upper` that contains (startX, startY), or
    /// the first one to its right. Empty when there is none.
    public mutating func autoOutline(x startX: Int, y startY: Int, lower: Double, upper: Double, mode: Mode) {
        self.lower = Float(lower)
        self.upper = Float(upper)
        trace(x: startX, y: startY, thresholded: true, legacy: mode == .legacy, fourConnected: mode == .fourConnected)
    }

    /// `autoOutline(startX, startY, tolerance, mode)`: the outline of the area
    /// of values within `tolerance` of the one at (startX, startY), as the
    /// wand tool traces an image without a threshold. In legacy mode with no
    /// tolerance it keeps the first edge it reaches, and traces 4-connected
    /// unless the area looks like a thin line. For RGB images, `values` holds
    /// the colors (`0xRRGGBB`) when `tolerance` is 0, else the gray values.
    public mutating func autoOutline(x startX: Int, y startY: Int, tolerance: Double, mode: Mode) {
        guard startX >= 0, startX < width, startY >= 0, startY < height else {
            xs = []
            ys = []
            return
        }
        let start = Double(pixel(startX, startY))
        lower = Float(start - tolerance)
        upper = Float(start + tolerance)
        trace(
            x: startX, y: startY, thresholded: false, legacy: mode == .legacy && tolerance == 0,
            fourConnected: mode == .fourConnected)
    }

    private mutating func trace(x startX: Int, y startY: Int, thresholded: Bool, legacy: Bool, fourConnected mode4: Bool) {
        xs = []
        ys = []
        guard startX >= 0, startX < width, startY >= 0, startY < height else { return }
        guard !pixel(startX, startY).isNaN else { return }
        var x = startX
        let y = startY
        let seedX: Int
        if inside(x, y) {
            seedX = x
            repeat { x += 1 } while inside(x, y)
        } else {
            repeat {
                x += 1
                if x >= width { return }
            } while !inside(x, y)
            seedX = x
        }
        // Thresholded tracing in legacy mode is 8-connected.
        let fourConnected = legacy ? !thresholded && !isLine(x, y) : mode4
        var first = true
        while true {
            let insideSelected = traceEdge(x, y, fourConnected: fourConnected)
            if legacy { return }
            if insideSelected {
                if first { return }
                if xmin <= seedX, Self.contains(xs, ys, seedX, startY) { return }
            }
            first = false
            if !inside(x, y) {
                repeat {
                    x += 1
                    if x > width { return }
                } while !inside(x, y)
            }
            repeat { x += 1 } while inside(x, y)
        }
    }

    private mutating func traceEdge(_ startX: Int, _ startYIn: Int, fourConnected: Bool) -> Bool {
        xs = []
        ys = []
        xmin = width
        var startY = startYIn
        let startDirection: Int
        if inside(startX, startY) {
            startDirection = 1
        } else {
            startDirection = 3
            startY += 1
        }
        var x = startX, y = startY
        var direction = startDirection
        repeat {
            var newDirection: Int
            if fourConnected {
                newDirection = direction
                repeat {
                    if !inside(x, y, newDirection) { break }
                    newDirection += 1
                } while newDirection < direction + 2
                newDirection -= 1
            } else {
                newDirection = direction + 1
                repeat {
                    if inside(x, y, newDirection) { break }
                    newDirection -= 1
                } while newDirection >= direction
            }
            if newDirection != direction { add(x, y) }
            switch newDirection & 3 {
            case 0: x += 1
            case 1: y -= 1
            case 2: x -= 1
            default: y += 1
            }
            direction = newDirection
        } while x != startX || y != startY || (direction & 3) != startDirection
        if Int(xs[0]) != x { add(x, y) }
        return direction <= 0
    }

    /// Whether the area right of (x, y) looks like a one-pixel-wide line:
    /// under a quarter of an 11×11 box inside it.
    private func isLine(_ x0: Int, _ y0: Int) -> Bool {
        let r = 5
        let xmax = min(x0 + 2 * r, width - 1)
        let ymin = max(y0 - r, 0), ymax = min(y0 + r, height - 1)
        var area = 0, insideCount = 0
        if x0 <= xmax, ymin <= ymax {
            for x in x0...xmax {
                for y in ymin...ymax {
                    area += 1
                    if inside(x, y) { insideCount += 1 }
                }
            }
        }
        return Double(insideCount) / Double(area) < 0.25
    }

    private mutating func add(_ x: Int, _ y: Int) {
        xs.append(Int32(x))
        ys.append(Int32(y))
        if xmin > x { xmin = x }
    }

    private func pixel(_ x: Int, _ y: Int) -> Float {
        guard x >= 0, x < width, y >= 0, y < height else { return .nan }
        return values[y * width + x]
    }

    private func inside(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let v = values[y * width + x]
        return v >= lower && v <= upper
    }

    private func inside(_ x: Int, _ y: Int, _ direction: Int) -> Bool {
        switch direction & 3 {
        case 0: inside(x, y)
        case 1: inside(x, y - 1)
        case 2: inside(x - 1, y - 1)
        default: inside(x - 1, y)
        }
    }

    /// `java.awt.Polygon.contains(x, y)` (even-odd, half-open edges).
    static func contains(_ xs: [Int32], _ ys: [Int32], _ px: Int, _ py: Int) -> Bool {
        let n = xs.count
        guard n > 2 else { return false }
        let x = Double(px), y = Double(py)
        var hits = 0
        var lastX = Double(xs[n - 1]), lastY = Double(ys[n - 1])
        for i in 0..<n {
            let curX = Double(xs[i]), curY = Double(ys[i])
            defer { (lastX, lastY) = (curX, curY) }
            if curY == lastY { continue }
            let leftX: Double
            if curX < lastX {
                if x >= lastX { continue }
                leftX = curX
            } else {
                if x >= curX { continue }
                leftX = lastX
            }
            var test1: Double, test2: Double
            if curY < lastY {
                if y < curY || y >= lastY { continue }
                if x < leftX {
                    hits += 1
                    continue
                }
                test1 = x - curX
                test2 = y - curY
            } else {
                if y < lastY || y >= curY { continue }
                if x < leftX {
                    hits += 1
                    continue
                }
                test1 = x - lastX
                test2 = y - lastY
            }
            if test1 < (test2 / (lastY - curY) * (lastX - curX)) { hits += 1 }
        }
        return (hits & 1) != 0
    }
}
