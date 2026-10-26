/// The parts of Java2D that ImageJ's `ShapeRoi.getMask()` relies on for
/// rounded rectangles, ported so the curved corners flatten to exactly the
/// same polygon: `RoundRectIterator`, `FlatteningPathIterator`, and the
/// subdivision and flatness test of `CubicCurve2D` (OpenJDK 21). Quadratic
/// segments, which only composite ROIs use, are not needed yet.
package enum FlattenedPath {
    package enum Segment {
        case move(Double, Double)
        case line(Double, Double)
        case cubic(Double, Double, Double, Double, Double, Double)
        case close
    }

    /// The path ImageJ fills for a rounded rectangle:
    /// `new ShapeRoi(new RoundRectangle2D.Float(x, y, w, h, d, d))`, whose
    /// shape is translated to the ROI origin and stored as a `GeneralPath`
    /// (32-bit floats).
    /// - Parameter floatStorage: round the points to floats, as the
    ///   `Path2D.Float` of `ShapeRoi(Shape)` stores them; `RoundRectangle2D`
    ///   iterated directly (`ShapeRoi(Roi)`'s outline) keeps doubles.
    package static func roundedRectangle(
        x: Int32, y: Int32, width: Int32, height: Int32, corner: Int32, floatStorage: Bool = true
    ) -> [Segment] {
        // RoundRectangle2D.Float holds floats; RoundRectIterator works in double.
        let rx = Double(Float(x)), ry = Double(Float(y))
        let w = Double(Float(width)), h = Double(Float(height))
        let arc = Double(Float(corner))
        let aw = RoiJava.min(w, abs(arc)), ah = RoiJava.min(h, abs(arc))
        guard aw >= 0, ah >= 0 else { return [] }
        // ShapeRoi(Shape): AffineTransform.translate(-x, -y) by the shape's
        // integer bounds (RectangularShape.getBounds()).
        let tx = Double(0 &- RoiJava.floorInt(rx)), ty = Double(0 &- RoiJava.floorInt(ry))
        // RoundRectIterator's acv = (1 - 4/3·a·b/c) / 2, from Math.cos and
        // Math.tan of π/4 as Java computes them.
        let acv = Double(bitPattern: 0x3FCC_A75D_DD59_6BBE)  // 0.22385762508460333
        // {v0, v1, v2, v3} per point: (x + v0*w + v1*aw, y + v2*h + v3*ah).
        let ctrl: [[Double]] = [
            [0.0, 0.0, 0.0, 0.5],
            [0.0, 0.0, 1.0, -0.5],
            [0.0, 0.0, 1.0, -acv, 0.0, acv, 1.0, 0.0, 0.0, 0.5, 1.0, 0.0],
            [1.0, -0.5, 1.0, 0.0],
            [1.0, -acv, 1.0, 0.0, 1.0, 0.0, 1.0, -acv, 1.0, 0.0, 1.0, -0.5],
            [1.0, 0.0, 0.0, 0.5],
            [1.0, 0.0, 0.0, acv, 1.0, -acv, 0.0, 0.0, 1.0, -0.5, 0.0, 0.0],
            [0.0, 0.5, 0.0, 0.0],
            [0.0, acv, 0.0, 0.0, 0.0, 0.0, 0.0, acv, 0.0, 0.0, 0.0, 0.5],
        ]
        func points(_ v: [Double]) -> [Double] {
            var out: [Double] = []
            var i = 0
            while i < v.count {
                // RoundRectIterator.currentSegment(double[]), the translation,
                // then Path2D.Float's float storage.
                let px = (rx + v[i] * w + v[i + 1] * aw) + tx
                let py = (ry + v[i + 2] * h + v[i + 3] * ah) + ty
                out.append(floatStorage ? Double(Float(px)) : px)
                out.append(floatStorage ? Double(Float(py)) : py)
                i += 4
            }
            return out
        }
        var path: [Segment] = []
        for (k, v) in ctrl.enumerated() {
            let p = points(v)
            switch k {
            case 0: path.append(.move(p[0], p[1]))
            case 1, 3, 5, 7: path.append(.line(p[0], p[1]))
            default: path.append(.cubic(p[0], p[1], p[2], p[3], p[4], p[5]))
            }
        }
        path.append(.close)
        return path
    }

    /// `ShapeRoi.getFloatPolygon(shape, flatness, separateSubpaths: true,
    /// addPointForClose: false, absoluteCoord: false)`: the flattened
    /// vertices as floats, subpaths separated by NaN.
    package static func polygon(_ path: [Segment], flatness: Double) -> (xs: [Float], ys: [Float]) {
        var xs: [Float] = [], ys: [Float] = []
        var subPathStart = 0
        var iterator = FlatteningIterator(path, flatness: flatness)
        while let segment = iterator.next() {
            switch segment {
            case .move(let x, let y):
                if let last = xs.last, !last.isNaN {
                    xs.append(.nan)
                    ys.append(.nan)
                }
                subPathStart = xs.count
                xs.append(Float(x))
                ys.append(Float(y))
            case .line(let x, let y):
                xs.append(Float(x))
                ys.append(Float(y))
            case .close:
                guard let lastX = xs.last, let lastY = ys.last, subPathStart < xs.count else { break }
                if lastX == xs[subPathStart] && lastY == ys[subPathStart] {
                    xs.removeLast()
                    ys.removeLast()
                }
                if let last = xs.last, !last.isNaN {
                    xs.append(.nan)
                    ys.append(.nan)
                }
            case .cubic:
                break  // the flattening iterator only returns lines
            }
        }
        if let last = xs.last, last.isNaN {
            xs.removeLast()
            ys.removeLast()
        }
        return (xs, ys)
    }

    /// `java.awt.geom.FlatteningPathIterator` with the default recursion
    /// limit of 10.
    package struct FlatteningIterator {
        private enum HoldType { case move, line, cubic, close }

        private let source: [Segment]
        private var sourceIndex = 0
        private let squareflat: Double
        private let limit = 10
        private var hold = [Double](repeating: 0, count: 14)
        private var curx = 0.0, cury = 0.0
        private var movx = 0.0, movy = 0.0
        private var holdType = HoldType.move
        private var holdEnd = 0
        private var holdIndex = 0
        private var levels = [Int](repeating: 0, count: 11)
        private var levelIndex = 0
        private var done = false
        private var primed = false

        package init(_ source: [Segment], flatness: Double) {
            self.source = source
            squareflat = flatness * flatness
        }

        /// The next flattened segment: `.move`, `.line` or `.close`.
        package mutating func next() -> Segment? {
            advance(doNext: primed)  // the constructor primes the first segment
            primed = true
            if done { return nil }
            switch holdType {
            case .close: return .close
            case .move: return .move(hold[holdIndex], hold[holdIndex + 1])
            case .line, .cubic: return .line(hold[holdIndex], hold[holdIndex + 1])
            }
        }

        private mutating func ensureHoldCapacity(_ want: Int) {
            if holdIndex - want < 0 {
                let have = hold.count - holdIndex
                var newhold = [Double](repeating: 0, count: hold.count + 24)
                for k in 0..<have { newhold[holdIndex + 24 + k] = hold[holdIndex + k] }
                hold = newhold
                holdIndex += 24
                holdEnd += 24
            }
        }

        private mutating func advance(doNext: Bool) {
            if holdIndex >= holdEnd {
                if doNext { sourceIndex += 1 }
                if sourceIndex >= source.count {
                    done = true
                    return
                }
                switch source[sourceIndex] {
                case .move(let x, let y):
                    holdType = .move
                    (hold[0], hold[1]) = (x, y)
                case .line(let x, let y):
                    holdType = .line
                    (hold[0], hold[1]) = (x, y)
                case .cubic(let x1, let y1, let x2, let y2, let x3, let y3):
                    holdType = .cubic
                    (hold[0], hold[1], hold[2], hold[3], hold[4], hold[5]) = (x1, y1, x2, y2, x3, y3)
                case .close:
                    holdType = .close
                }
                levelIndex = 0
                levels[0] = 0
            }
            switch holdType {
            case .move, .line:
                curx = hold[0]
                cury = hold[1]
                if holdType == .move {
                    movx = curx
                    movy = cury
                }
                holdIndex = 0
                holdEnd = 0
            case .close:
                curx = movx
                cury = movy
                holdIndex = 0
                holdEnd = 0
            case .cubic:
                if holdIndex >= holdEnd {
                    // Move the coordinates to the end of the array.
                    holdIndex = hold.count - 8
                    holdEnd = hold.count - 2
                    hold[holdIndex + 0] = curx
                    hold[holdIndex + 1] = cury
                    hold[holdIndex + 2] = hold[0]
                    hold[holdIndex + 3] = hold[1]
                    hold[holdIndex + 4] = hold[2]
                    hold[holdIndex + 5] = hold[3]
                    curx = hold[4]
                    hold[holdIndex + 6] = curx
                    cury = hold[5]
                    hold[holdIndex + 7] = cury
                }
                var level = levels[levelIndex]
                while level < limit {
                    if Self.cubicFlatnessSq(hold, holdIndex) < squareflat { break }
                    ensureHoldCapacity(6)
                    Self.subdivideCubic(&hold, holdIndex, holdIndex - 6, holdIndex)
                    holdIndex -= 6
                    level += 1
                    levels[levelIndex] = level
                    levelIndex += 1
                    levels[levelIndex] = level
                }
                holdIndex += 6
                levelIndex -= 1
            }
        }

        /// `Line2D.ptSegDistSq`.
        static func ptSegDistSq(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ px: Double, _ py: Double) -> Double {
            let x2 = x2 - x1, y2 = y2 - y1
            var px = px - x1, py = py - y1
            var dotprod = px * x2 + py * y2
            let projlenSq: Double
            if dotprod <= 0.0 {
                projlenSq = 0.0
            } else {
                px = x2 - px
                py = y2 - py
                dotprod = px * x2 + py * y2
                projlenSq = dotprod <= 0.0 ? 0.0 : dotprod * dotprod / (x2 * x2 + y2 * y2)
            }
            var lenSq = px * px + py * py - projlenSq
            if lenSq < 0 { lenSq = 0 }
            return lenSq
        }

        /// `CubicCurve2D.getFlatnessSq(coords, offset)`.
        static func cubicFlatnessSq(_ c: [Double], _ o: Int) -> Double {
            RoiJava.max(
                ptSegDistSq(c[o], c[o + 1], c[o + 6], c[o + 7], c[o + 2], c[o + 3]),
                ptSegDistSq(c[o], c[o + 1], c[o + 6], c[o + 7], c[o + 4], c[o + 5]))
        }

        /// `CubicCurve2D.subdivide(src, srcoff, left, leftoff, right, rightoff)`
        /// with all three in one array (reads everything before writing).
        static func subdivideCubic(_ a: inout [Double], _ src: Int, _ left: Int, _ right: Int) {
            var x1 = a[src + 0], y1 = a[src + 1]
            var ctrlx1 = a[src + 2], ctrly1 = a[src + 3]
            var ctrlx2 = a[src + 4], ctrly2 = a[src + 5]
            var x2 = a[src + 6], y2 = a[src + 7]
            a[left + 0] = x1
            a[left + 1] = y1
            a[right + 6] = x2
            a[right + 7] = y2
            x1 = (x1 + ctrlx1) / 2.0
            y1 = (y1 + ctrly1) / 2.0
            x2 = (x2 + ctrlx2) / 2.0
            y2 = (y2 + ctrly2) / 2.0
            var centerx = (ctrlx1 + ctrlx2) / 2.0
            var centery = (ctrly1 + ctrly2) / 2.0
            ctrlx1 = (x1 + centerx) / 2.0
            ctrly1 = (y1 + centery) / 2.0
            ctrlx2 = (x2 + centerx) / 2.0
            ctrly2 = (y2 + centery) / 2.0
            centerx = (ctrlx1 + ctrlx2) / 2.0
            centery = (ctrly1 + ctrly2) / 2.0
            a[left + 2] = x1
            a[left + 3] = y1
            a[left + 4] = ctrlx1
            a[left + 5] = ctrly1
            a[left + 6] = centerx
            a[left + 7] = centery
            a[right + 0] = centerx
            a[right + 1] = centery
            a[right + 2] = ctrlx2
            a[right + 3] = ctrly2
            a[right + 4] = x2
            a[right + 5] = y2
        }
    }
}
