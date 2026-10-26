public import MancoraCore

/// The neighborhood statistics of Process ▸ Filters (ImageJ's
/// `ij.plugin.filter.RankFilters`).
public enum RankFilter: Sendable, Hashable {
    /// Which side of the median Remove Outliers looks at.
    public enum Outliers: Sendable, Hashable {
        /// Pixels above the median (`RankFilters.BRIGHT_OUTLIERS`).
        case bright
        /// Pixels below the median (`RankFilters.DARK_OUTLIERS`).
        case dark
    }

    /// Process ▸ Filters ▸ Mean (`RankFilters.MEAN`).
    case mean
    /// Process ▸ Filters ▸ Minimum (`RankFilters.MIN`).
    case minimum
    /// Process ▸ Filters ▸ Maximum (`RankFilters.MAX`).
    case maximum
    /// Process ▸ Filters ▸ Variance (`RankFilters.VARIANCE`); integer
    /// results are clipped to the type's range.
    case variance
    /// Process ▸ Filters ▸ Median (`RankFilters.MEDIAN`). On float data a
    /// NaN pixel stays NaN and other NaNs in the neighborhood are ignored.
    case median
    /// Process ▸ Noise ▸ Remove Outliers (`RankFilters.OUTLIERS`): replaces
    /// a pixel by the neighborhood median when it lies more than `threshold`
    /// beyond it on the given side.
    ///
    /// Sides refer to pixel values. ImageJ swaps them for an image shown
    /// with an inverted LUT, so pass the other side for such images.
    case removeOutliers(Outliers, threshold: Double)
    /// Process ▸ Noise ▸ Remove NaNs (`RankFilters.REMOVE_NAN`): replaces
    /// NaN pixels by the median of their neighborhood's other values. Only
    /// float data can hold NaNs; other planes are returned unchanged.
    case removeNaNs
}

extension Plane {
    /// A rank filter over ImageJ's circular neighborhood of `radius`:
    /// `RankFilters.rank(ip, radius, filterType, whichOutliers, threshold)`.
    ///
    /// Out-of-image pixels take the value of the nearest edge pixel. Integer
    /// results are rounded; RGB planes are filtered per channel.
    ///
    /// - Parameters:
    ///   - filter: The statistic to compute.
    ///   - radius: The kernel radius as in ImageJ's dialogs (Process ▸
    ///     Filters ▸ Show Circular Masks): 0.5 is the 4-neighborhood, 1 a
    ///     3×3 square. Must be finite and not negative.
    ///   - width: The plane's width in pixels.
    ///   - rect: A selection's bounds, within the plane, or `nil` for the
    ///     whole plane. Only the rectangle changes; the kernel reads the
    ///     pixels around it, and each row's running sums start at its left
    ///     edge, as in ImageJ.
    public func rankFiltered(_ filter: RankFilter, radius: Double, width: Int, rect: RoiBounds? = nil) -> Plane {
        let height = filterHeight(width: width)
        precondition(radius.isFinite && radius >= 0, "rank filter radius must be finite and not negative")
        guard count > 0 else { return self }
        let rect = rect ?? .whole(width: width, height: height)
        guard !rect.isEmpty else { return self }
        let kernel = RankKernel(radius: radius)
        switch self {
        case .gray8(let p):
            let out = p.withUnsafeBufferPointer { src in
                RankFilters.filterIntegers(
                    src, width: width, height: height, rect: rect, kernel: kernel, filter: filter, maxValue: 255
                ) {
                    Float($0)
                } store: {
                    UInt8(truncatingIfNeeded: JavaNumerics.int32($0 + 0.5))
                }
            }
            return .gray8(out)
        case .gray16(let p):
            let out = p.withUnsafeBufferPointer { src in
                RankFilters.filterIntegers(
                    src, width: width, height: height, rect: rect, kernel: kernel, filter: filter, maxValue: 65535
                ) {
                    Float($0)
                } store: {
                    UInt16(truncatingIfNeeded: JavaNumerics.int32($0 + 0.5))
                }
            }
            return .gray16(out)
        case .gray32Float(let p):
            var out = p
            p.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    RankFilters.filter(
                        width: width, height: height, rect: rect, kernel: kernel, filter: filter, isFloat: true, maxValue: .nan
                    ) { y, line in
                        for x in 0..<width { line[x] = src[y * width + x] }
                    } writeLine: { y, values in
                        for x in rect.x..<(rect.x + rect.width) { dst[y * width + x] = values[x] }
                    }
                }
            }
            return .gray32Float(out)
        case .rgb8(let p):
            var out = p
            p.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for shift: UInt32 in [16, 8, 0] {
                        RankFilters.filter(
                            width: width, height: height, rect: rect, kernel: kernel, filter: filter, isFloat: false, maxValue: 255
                        ) { y, line in
                            for x in 0..<width { line[x] = Float((src[y * width + x] >> shift) & 0xFF) }
                        } writeLine: { y, values in
                            let keep = ~(UInt32(0xFF) << shift)
                            for x in rect.x..<(rect.x + rect.width) {
                                let v = UInt32(truncatingIfNeeded: JavaNumerics.int32(values[x] + 0.5)) & 0xFF
                                dst[y * width + x] = (dst[y * width + x] & keep) | v << shift
                            }
                        }
                    }
                }
            }
            return .rgb8(out)
        }
    }

    /// Process ▸ Noise ▸ Despeckle: a median filter of radius 1, as ImageJ
    /// runs it.
    public func despeckled(width: Int, rect: RoiBounds? = nil) -> Plane {
        rankFiltered(.median, radius: 1, width: width, rect: rect)
    }
}

extension ImageStack {
    /// A rank filter on every plane; see
    /// `Plane.rankFiltered(_:radius:width:)`.
    public func rankFiltered(_ filter: RankFilter, radius: Double) -> ImageStack {
        mapPlanes { $0.rankFiltered(filter, radius: radius, width: width) }
    }

    /// Process ▸ Noise ▸ Despeckle on every plane.
    public func despeckled() -> ImageStack {
        mapPlanes { $0.despeckled(width: width) }
    }
}

/// ImageJ's circular kernel (`RankFilters.makeLineRadii`): for each kernel
/// row, the x offsets of its first and last pixel.
struct RankKernel: Equatable {
    /// `[left0, right0, left1, right1, …, nPoints, kRadius]`, as in ImageJ.
    let lineRadii: [Int]

    init(radius: Double) {
        var radius = radius
        if radius >= 1.5 && radius < 1.75 {  // the sizes of ImageJ's earlier RankFilters
            radius = 1.75
        } else if radius >= 2.5 && radius < 2.85 {
            radius = 2.85
        }
        let r2 = Int(JavaNumerics.int32(radius * radius)) + 1
        let kRadius = Int(JavaNumerics.int32((Double(r2) + 1e-10).squareRoot()))
        let kHeight = 2 * kRadius + 1
        var kernel = [Int](repeating: 0, count: 2 * kHeight + 2)
        kernel[2 * kRadius] = -kRadius
        kernel[2 * kRadius + 1] = kRadius
        var nPoints = 2 * kRadius + 1
        var y = 1
        while y <= kRadius {  // rows above and below the center together
            let dx = Int(JavaNumerics.int32((Double(r2 - y * y) + 1e-10).squareRoot()))
            kernel[2 * (kRadius - y)] = -dx
            kernel[2 * (kRadius - y) + 1] = dx
            kernel[2 * (kRadius + y)] = -dx
            kernel[2 * (kRadius + y) + 1] = dx
            nPoints += 4 * dx + 2
            y += 1
        }
        kernel[kernel.count - 2] = nPoints
        kernel[kernel.count - 1] = kRadius
        lineRadii = kernel
    }

    var kHeight: Int { (lineRadii.count - 2) / 2 }
    var kRadius: Int { lineRadii[lineRadii.count - 1] }
    var kNPoints: Int { lineRadii[lineRadii.count - 2] }
}

/// A port of the filtering core of ImageJ 1.54p's `RankFilters`, for a
/// rectangle of a plane and one thread. Lines are read through the same padded line cache,
/// in the same order, with the same incremental sums and the same median
/// search, so float results match bit for bit.
enum RankFilters {
    enum Kind {
        case mean, minimum, maximum, variance, median, outliers, removeNaN
    }

    /// Filters 8 or 16-bit data, converting through `Float` like ImageJ's
    /// `readLineToCache` and `writeLineToPixels`.
    static func filterIntegers<T>(
        _ src: UnsafeBufferPointer<T>, width: Int, height: Int, rect: RoiBounds, kernel: RankKernel, filter: RankFilter,
        maxValue: Float, load: (T) -> Float, store: (Float) -> T
    ) -> [T] {
        var out = Array(src)
        if case .removeNaNs = filter { return out }
        out.withUnsafeMutableBufferPointer { dst in
            RankFilters.filter(
                width: width, height: height, rect: rect, kernel: kernel, filter: filter, isFloat: false, maxValue: maxValue
            ) { y, line in
                for x in 0..<width { line[x] = load(src[y * width + x]) }
            } writeLine: { y, values in
                for x in rect.x..<(rect.x + rect.width) { dst[y * width + x] = store(values[x]) }
            }
        }
        return out
    }

    /// Filters one channel within `rect`. `readLine(y, line)` fills `line`
    /// with row `y` as floats; `writeLine(y, values)` receives each row of
    /// the rectangle, filtered within it (`values` is indexed by image x).
    static func filter(
        width: Int, height: Int, rect: RoiBounds, kernel: RankKernel, filter: RankFilter, isFloat: Bool, maxValue: Float,
        readLine: (Int, UnsafeMutablePointer<Float>) -> Void,
        writeLine: (Int, UnsafePointer<Float>) -> Void
    ) {
        let kind: Kind
        var sign: Float = 1  // -1 to find the minimum as the maximum of negated values
        var threshold: Float = 0
        switch filter {
        case .mean: kind = .mean
        case .minimum: kind = .minimum; sign = -1
        case .maximum: kind = .maximum
        case .variance: kind = .variance
        case .median: kind = .median
        case .removeOutliers(let side, let t):
            kind = .outliers
            sign = side == .bright ? -1 : 1  // for a normal (not inverted) LUT
            threshold = Float(t)
        case .removeNaNs:
            guard isFloat else {  // ImageJ refuses; integer data has no NaNs
                withUnsafeTemporaryAllocation(of: Float.self, capacity: width) { line in
                    for y in rect.y..<(rect.y + rect.height) {
                        readLine(y, line.baseAddress!)
                        writeLine(y, line.baseAddress!)
                    }
                }
                return
            }
            kind = .removeNaN
        }

        let kHeight = kernel.kHeight, kRadius = kernel.kRadius
        let cacheWidth = width + 2 * kRadius
        let cacheHeight = kHeight
        var cache = [Float](repeating: 0, count: cacheWidth * cacheHeight)
        var pointers = [Int](repeating: 0, count: 2 * kHeight)
        var values = [Float](repeating: 0, count: width)
        var medianBuf1 = [Float](repeating: 0, count: kernel.kNPoints)
        var medianBuf2 = [Float](repeating: 0, count: kernel.kNPoints)

        cache.withUnsafeMutableBufferPointer { cache in
        pointers.withUnsafeMutableBufferPointer { pointers in
        values.withUnsafeMutableBufferPointer { values in
        medianBuf1.withUnsafeMutableBufferPointer { buf1 in
        medianBuf2.withUnsafeMutableBufferPointer { buf2 in
        kernel.lineRadii.withUnsafeBufferPointer { lineRadii in
            let cacheBase = cache.baseAddress!
            /// Reads image row `y` (clamped to the image) into its cache line,
            /// padded with the edge pixels (`readLineToCacheOrPad`).
            func readToCache(_ y: Int) {
                let lineStart = cacheBase + slot(y) * cacheWidth
                readLine(min(max(y, 0), height - 1), lineStart + kRadius)
                let first = lineStart[kRadius], last = lineStart[kRadius + width - 1]
                for i in 0..<kRadius {
                    lineStart[i] = first
                    lineStart[kRadius + width + i] = last
                }
            }
            func slot(_ y: Int) -> Int {
                let s = y % cacheHeight
                return s < 0 ? s + cacheHeight : s
            }
            var line = LineFilter(
                cache: cacheBase, pointers: pointers, values: values, buf1: buf1, buf2: buf2,
                kind: kind, sign: sign, threshold: threshold, maxValue: maxValue, isFloat: isFloat,
                kNPoints: kernel.kNPoints, smallKernel: kRadius < 2)
            for y in rect.y..<(rect.y + rect.height) {
                if y == rect.y {
                    for yy in (y - kHeight / 2)...(y + kHeight / 2) { readToCache(yy) }
                } else {
                    readToCache(y + kHeight / 2)
                }
                for i in 0..<kHeight {
                    let rowStart = slot(y - kHeight / 2 + i) * cacheWidth + kRadius
                    pointers[2 * i] = rowStart + lineRadii[2 * i]
                    pointers[2 * i + 1] = rowStart + lineRadii[2 * i + 1]
                }
                let cacheLineP = slot(y) * cacheWidth + kRadius
                for x in 0..<width { values[x] = cacheBase[cacheLineP + x] }
                line.filterLine(from: rect.x, to: rect.x + rect.width, cacheLineP: cacheLineP)
                writeLine(y, values.baseAddress!)
            }
        }
        }
        }
        }
        }
        }
    }

    /// `RankFilters.filterLine` and the helpers it calls.
    struct LineFilter {
        let cache: UnsafeMutablePointer<Float>
        let pointers: UnsafeMutableBufferPointer<Int>
        let values: UnsafeMutableBufferPointer<Float>
        let buf1: UnsafeMutableBufferPointer<Float>
        let buf2: UnsafeMutableBufferPointer<Float>
        let kind: Kind
        let sign: Float
        let threshold: Float
        let maxValue: Float
        let isFloat: Bool
        let kNPoints: Int
        let smallKernel: Bool
        var sum0 = 0.0
        var sum1 = 0.0

        init(
            cache: UnsafeMutablePointer<Float>, pointers: UnsafeMutableBufferPointer<Int>,
            values: UnsafeMutableBufferPointer<Float>, buf1: UnsafeMutableBufferPointer<Float>,
            buf2: UnsafeMutableBufferPointer<Float>, kind: Kind, sign: Float, threshold: Float, maxValue: Float,
            isFloat: Bool, kNPoints: Int, smallKernel: Bool
        ) {
            self.cache = cache
            self.pointers = pointers
            self.values = values
            self.buf1 = buf1
            self.buf2 = buf2
            self.kind = kind
            self.sign = sign
            self.threshold = threshold
            self.maxValue = maxValue
            self.isFloat = isFloat
            self.kNPoints = kNPoints
            self.smallKernel = smallKernel
        }

        /// Filters points `xFrom..<xTo` of one line; `values` holds the
        /// line's input on entry (for the float median's first guess and
        /// Remove NaNs) and the result on return. Running sums start at `xFrom`.
        mutating func filterLine(from xFrom: Int, to xTo: Int, cacheLineP: Int) {
            let minOrMax = kind == .minimum || kind == .maximum
            let minOrMaxOrOutliers = minOrMax || kind == .outliers
            let sumFilter = kind == .mean || kind == .variance
            var max: Float = 0
            let first = cache[cacheLineP + xFrom]
            var median: Float = first.isNaN ? 0 : first  // a first guess
            var fullCalculation = true
            for x in xFrom..<xTo {
                if fullCalculation {
                    fullCalculation = smallKernel  // a small kernel always uses the full area
                    if minOrMaxOrOutliers { max = areaMax(x, ignoreRight: 0, start: -Float.greatestFiniteMagnitude) }
                    if minOrMax {
                        values[x] = max * sign
                        continue
                    } else if sumFilter {
                        areaSums(x)
                    }
                } else {
                    if minOrMaxOrOutliers {
                        let newPointsMax = sideMax(x, isRight: true)
                        if newPointsMax >= max {
                            max = newPointsMax
                        } else {
                            let removedPointsMax = sideMax(x, isRight: false)
                            if removedPointsMax >= max { max = areaMax(x, ignoreRight: 1, start: newPointsMax) }
                        }
                        if minOrMax {
                            values[x] = max * sign
                            continue
                        }
                    } else if sumFilter {
                        addSideSums(x)
                        if sum0.isNaN { fullCalculation = true }  // don't carry NaNs along the line
                    }
                }
                switch kind {
                case .mean:
                    values[x] = Float(sum0 / Double(kNPoints))
                case .variance:
                    let n = Double(kNPoints)
                    var value = Float((sum1 - sum0 * sum0 / n) / n)
                    if value > maxValue { value = maxValue }
                    if value < 0 { value = 0 }  // rounding errors
                    values[x] = value
                case .median:
                    if isFloat {
                        median = values[x].isNaN ? .nan : values[x]
                        median = nanAwareMedian(x, guess: median)
                    } else {
                        median = self.median(x, guess: median)
                    }
                    values[x] = median
                case .outliers:
                    var v = cache[cacheLineP + x]
                    if v * sign + threshold < max {  // the median can't be beyond the maximum
                        median = self.median(x, guess: median)
                        if v * sign + threshold < median * sign { v = median }
                    }
                    values[x] = v
                case .removeNaN:
                    if values[x].isNaN {
                        values[x] = nanAwareMedian(x, guess: median)
                    } else {
                        median = values[x]  // the guess for the next point
                    }
                case .minimum, .maximum:
                    break
                }
            }
        }

        /// `getAreaMax`: the maximum of `value * sign` over the kernel,
        /// leaving out the rightmost column if `ignoreRight` is 1.
        @inline(__always)
        func areaMax(_ x: Int, ignoreRight: Int, start: Float) -> Float {
            var max = start
            var kk = 0
            while kk < pointers.count {
                var p = pointers[kk] + x
                let end = pointers[kk + 1] + x - ignoreRight
                while p <= end {
                    let v = cache[p] * sign
                    if max < v { max = v }
                    p += 1
                }
                kk += 2
            }
            return max
        }

        /// `getSideMax`: the maximum at the right edge of the kernel, or just
        /// outside its left edge.
        @inline(__always)
        func sideMax(_ x: Int, isRight: Bool) -> Float {
            var max = -Float.greatestFiniteMagnitude
            let x0 = isRight ? x : x - 1
            var kk = isRight ? 1 : 0
            while kk < pointers.count {
                let v = cache[x0 + pointers[kk]] * sign
                if max < v { max = v }
                kk += 2
            }
            return max
        }

        /// `getAreaSums`: sum and sum of squares over the kernel.
        @inline(__always)
        mutating func areaSums(_ x: Int) {
            var sum = 0.0, sum2 = 0.0
            var kk = 0
            while kk < pointers.count {
                var p = pointers[kk] + x
                let end = pointers[kk + 1] + x
                while p <= end {
                    let v = Double(cache[p])
                    sum += v
                    sum2 += v * v
                    p += 1
                }
                kk += 2
            }
            sum0 = sum
            sum1 = sum2
        }

        /// `addSideSums`: moves the sums one pixel to the right.
        @inline(__always)
        mutating func addSideSums(_ x: Int) {
            var sum = 0.0, sum2 = 0.0
            var kk = 0
            while kk < pointers.count {
                var v = Double(cache[pointers[kk] + (x - 1)])  // leaves the kernel
                sum -= v
                sum2 -= v * v
                v = Double(cache[pointers[kk + 1] + x])  // enters the kernel
                sum += v
                sum2 += v * v
                kk += 2
            }
            sum0 += sum
            sum1 += sum2
        }

        /// `getMedian`: splits the kernel's values at `guess` and finds the
        /// median in the larger part. The kernel has an odd number of points.
        @inline(__always)
        func median(_ x: Int, guess: Float) -> Float {
            var nAbove = 0, nBelow = 0
            let above = buf1.baseAddress!, below = buf2.baseAddress!
            var kk = 0
            while kk < pointers.count {
                var p = pointers[kk] + x
                let end = pointers[kk + 1] + x
                while p <= end {
                    let v = cache[p]
                    // Branch-free form of: if v > guess {append to above} else if v < guess {append to below}
                    above[nAbove] = v
                    nAbove &+= v > guess ? 1 : 0
                    below[nBelow] = v
                    nBelow &+= v < guess ? 1 : 0
                    p += 1
                }
                kk += 2
            }
            let half = kNPoints / 2
            if nAbove > half {
                return RankFilters.nthLowest(above, count: nAbove, n: nAbove - half - 1)
            } else if nBelow > half {
                return RankFilters.nthLowest(below, count: nBelow, n: half)
            }
            return guess
        }

        /// `getNaNAwareMedian`: the median of the non-NaN values, NaN if
        /// there are none.
        @inline(__always)
        func nanAwareMedian(_ x: Int, guess: Float) -> Float {
            var nAbove = 0, nBelow = 0, nPoints = kNPoints
            let above = buf1.baseAddress!, below = buf2.baseAddress!
            var kk = 0
            while kk < pointers.count {
                var p = pointers[kk] + x
                let end = pointers[kk + 1] + x
                while p <= end {
                    let v = cache[p]
                    nPoints &-= v.isNaN ? 1 : 0
                    above[nAbove] = v
                    nAbove &+= v > guess ? 1 : 0
                    below[nBelow] = v
                    nBelow &+= v < guess ? 1 : 0
                    p += 1
                }
                kk += 2
            }
            if nPoints == 0 { return .nan }
            let half = nPoints / 2
            if nAbove > half {
                return RankFilters.nthLowest(above, count: nAbove, n: nAbove - half - 1)
            } else if nBelow > half {
                return RankFilters.nthLowest(below, count: nBelow, n: half)
            }
            return guess
        }
    }

    /// `findNthLowestNumber`: Hoare's selection; reorders `buf`.
    @inline(__always)
    static func nthLowest(_ buf: UnsafeMutablePointer<Float>, count: Int, n: Int) -> Float {
        var l = 0
        var m = count - 1
        var med = buf[n]
        while l < m {
            var i = l
            var j = m
            repeat {
                while buf[i] < med { i += 1 }
                while med < buf[j] { j -= 1 }
                let dum = buf[j]
                buf[j] = buf[i]
                buf[i] = dum
                i += 1
                j -= 1
            } while j >= n && i <= n
            if j < n { l = i }
            if n < i { m = j }
            med = buf[n]
        }
        return med
    }
}
