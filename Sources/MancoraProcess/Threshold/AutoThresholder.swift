import MancoraCore

/// ImageJ's automatic threshold methods: a port of
/// `ij.process.AutoThresholder` (ImageJ 1.54p), Gabriel Landini's
/// Auto_Threshold methods for histograms.
///
/// Every method takes a histogram, one count per bin, and returns the bin
/// that ends the background class: pixels in bins `0...threshold` are one
/// class and the rest the other. ``threshold(_:histogram:bilevelSubtractOne:)``
/// is `getThreshold(Method, int[])`, which Image ▸ Adjust ▸ Threshold and
/// `setAutoThreshold` use; ``methodThreshold(_:_:)`` and ``huang2(_:)`` run
/// one method on its own, as ImageJ's public static methods do.
///
/// Counts are ImageJ's 32-bit `int`s: larger values keep their low 32
/// bits, and sums and products wrap around as they do in Java, so very
/// large images (whose weighted sums pass 2³¹) give the same thresholds as
/// in ImageJ. Logarithms are fdlibm's, as Java's `StrictMath` computes
/// them; see `StrictMath`.
///
/// Where ImageJ throws an exception or never returns, the methods here
/// return -1 instead, which ``threshold(_:histogram:bilevelSubtractOne:)``
/// turns into 0 as it does for ImageJ's own -1 results:
/// - Mean and MinError on an all-zero histogram (ImageJ divides by zero).
/// - Li and MinError when their iteration cycles forever, or when a
///   threshold beyond the histogram follows from 32-bit overflow (ImageJ
///   reads past the array).
/// - Huang2 when 32-bit overflow sends its mean outside the histogram.
///
/// ``threshold(_:histogram:bilevelSubtractOne:)`` on an all-zero histogram
/// longer than 256 bins, where ImageJ also reads past the array, runs the
/// method on a single empty bin.
public enum AutoThresholder {
    /// ImageJ's `AutoThresholder.Method`, in ImageJ's order: the methods
    /// the Threshold dialog lists. The raw value is ImageJ's name.
    public enum Method: String, CaseIterable, Sendable, Hashable {
        /// ImageJ's default: IJ_IsoData with the most populated bin first
        /// capped at 1.5 times the second (`defaultIsoData`).
        case `default` = "Default"
        /// Huang and Wang's fuzzy thresholding (`Huang`).
        case huang = "Huang"
        /// The midpoint between the two peaks of the histogram smoothed until
        /// it is bimodal (`Intermodes`, Prewitt and Mendelsohn).
        case intermodes = "Intermodes"
        /// Ridler and Calvard's iterative intermeans (`IsoData`).
        case isoData = "IsoData"
        /// ImageJ's original iterative intermeans, ignoring the first and
        /// last bins (`IJIsoData`; also `ImageProcessor.getAutoThreshold`).
        case ijIsoData = "IJ_IsoData"
        /// Li's minimum cross entropy (`Li`).
        case li = "Li"
        /// Kapur, Sahoo and Wong's maximum entropy (`MaxEntropy`).
        case maxEntropy = "MaxEntropy"
        /// The mean gray level (`Mean`, Glasbey).
        case mean = "Mean"
        /// Kittler and Illingworth's minimum error, iterated from the mean
        /// (`MinErrorI`).
        case minError = "MinError"
        /// The valley between the two peaks of the histogram smoothed until
        /// it is bimodal (`Minimum`, Prewitt and Mendelsohn).
        case minimum = "Minimum"
        /// Tsai's moment-preserving thresholding (`Moments`).
        case moments = "Moments"
        /// Otsu's maximum between-class variance (`Otsu`).
        case otsu = "Otsu"
        /// The median: half the pixels in each class (`Percentile`, Doyle).
        case percentile = "Percentile"
        /// Kapur, Sahoo and Wong's method with Rényi entropies
        /// (`RenyiEntropy`).
        case renyiEntropy = "RenyiEntropy"
        /// Shanbhag's information measure (`Shanbhag`).
        case shanbhag = "Shanbhag"
        /// Zack's triangle method, toward the longer tail (`Triangle`).
        case triangle = "Triangle"
        /// Yen, Chang and Chang's maximum correlation criterion (`Yen`).
        case yen = "Yen"
    }

    // MARK: Public API

    /// The threshold `AutoThresholder.getThreshold(method, histogram)`
    /// returns, as a bin of `histogram`.
    ///
    /// - A histogram with one or two non-empty bins gets ImageJ's
    ///   ``bilevel(_:subtractOne:)`` threshold without running the method
    ///   (unless that is negative).
    /// - A histogram longer than 256 bins (a 16-bit histogram) is first
    ///   trimmed to its non-empty range; the result is mapped back.
    /// - A method's -1 ("not found") becomes the first bin.
    ///
    /// `bilevelSubtractOne` is `setBilevelSubractOne`: ImageJ's `true` by
    /// default, `false` for `setAutoThreshold("… 16-bit")`.
    public static func threshold(_ method: Method, histogram: [Int], bilevelSubtractOne: Bool = true) -> Int {
        Int(getThreshold(method, javaInts(histogram), bilevelSubtractOne: bilevelSubtractOne))
    }

    /// `AutoThresholder.bilevel`: for a histogram with exactly one or two
    /// non-empty bins, the last of them (minus one if `subtractOne`);
    /// otherwise -1.
    public static func bilevel(_ histogram: [Int], subtractOne: Bool = true) -> Int {
        Int(bilevel(javaInts(histogram), subtractOne: subtractOne))
    }

    /// One method on its own, as ImageJ's static `AutoThresholder.Huang(data)`,
    /// `Otsu(data)`, … (and the package-private `defaultIsoData` and
    /// `IJIsoData`) compute it: no bilevel shortcut, no trimming, and -1
    /// when the method finds no threshold. Otsu returns `Int32.min` when no
    /// split has any between-class variance.
    public static func methodThreshold(_ method: Method, _ data: [Int]) -> Int {
        precondition(!data.isEmpty, "empty histogram")
        return Int(run(method, javaInts(data)))
    }

    /// `AutoThresholder.Huang2`: Johannes Schindelin's faster form of
    /// Huang's method, which ImageJ doesn't offer as a `Method`.
    public static func huang2(_ data: [Int]) -> Int {
        precondition(!data.isEmpty, "empty histogram")
        return Int(huang2(javaInts(data)))
    }

    // MARK: getThreshold

    static func javaInts(_ histogram: [Int]) -> [Int32] {
        histogram.map { Int32(truncatingIfNeeded: $0) }
    }

    static func getThreshold(_ method: Method, _ histogram: [Int32], bilevelSubtractOne: Bool) -> Int32 {
        precondition(!histogram.isEmpty, "empty histogram")
        var threshold = bilevel(histogram, subtractOne: bilevelSubtractOne)
        if threshold >= 0 { return threshold }
        var minBin = 0
        var data = histogram
        if histogram.count > 256 {
            var maxBin = -1
            minBin = -1
            for i in histogram.indices where histogram[i] > 0 { maxBin = i }
            for i in histogram.indices.reversed() where histogram[i] > 0 { minBin = i }
            // An all-zero histogram makes ImageJ read histogram[-1].
            data = minBin < 0 ? [0] : Array(histogram[minBin...maxBin])
            minBin = Swift.max(minBin, 0)
        }
        threshold = run(method, data)
        if threshold == -1 { threshold = 0 }
        return threshold &+ Int32(minBin)
    }

    static func run(_ method: Method, _ data: [Int32]) -> Int32 {
        switch method {
        case .default: defaultIsoData(data)
        case .huang: huang(data)
        case .intermodes: intermodes(data)
        case .isoData: isoData(data)
        case .ijIsoData: ijIsoData(data)
        case .li: li(data)
        case .maxEntropy: maxEntropy(data)
        case .mean: mean(data)
        case .minError: minErrorI(data)
        case .minimum: minimum(data)
        case .moments: moments(data)
        case .otsu: otsu(data)
        case .percentile: percentile(data)
        case .renyiEntropy: renyiEntropy(data)
        case .shanbhag: shanbhag(data)
        case .triangle: triangle(data)
        case .yen: yen(data)
        }
    }

    static func bilevel(_ data: [Int32], subtractOne: Bool) -> Int32 {
        var first: Int32 = -1, second: Int32 = -1
        var nonZero = 0
        for (i, count) in data.enumerated() where count > 0 {
            nonZero += 1
            if nonZero > 2 { return -1 }
            if first == -1 { first = Int32(i) } else { second = Int32(i) }
        }
        let one: Int32 = subtractOne ? 1 : 0
        switch nonZero {
        case 1: return first - one
        case 2: return second - one
        default: return -1
        }
    }

    // MARK: The methods

    /// Java's `(double)` of an `int` index or count.
    @inline(__always) private static func d(_ value: Int) -> Double { Double(value) }
    @inline(__always) private static func d(_ value: Int32) -> Double { Double(value) }
    /// Java's `int` product `i * data[i]`, wrapping on overflow.
    @inline(__always) private static func times(_ i: Int, _ count: Int32) -> Int32 {
        Int32(truncatingIfNeeded: i) &* count
    }

    private static let epsilon = 2.220446049250313E-16  // DBL_EPSILON

    /// `AutoThresholder.defaultIsoData`.
    static func defaultIsoData(_ data: [Int32]) -> Int32 {
        var data2 = data
        var mode = 0
        var maxCount: Int32 = 0
        for i in data2.indices where data2[i] > maxCount {
            maxCount = data2[i]
            mode = i
        }
        var maxCount2: Int32 = 0
        for i in data2.indices where data2[i] > maxCount2 && i != mode {
            maxCount2 = data2[i]
        }
        if maxCount > maxCount2 &* 2 && maxCount2 != 0 {
            data2[mode] = JavaNumerics.int32(d(maxCount2) * 1.5)
        }
        return ijIsoData(data2)
    }

    /// `AutoThresholder.IJIsoData`, identical to
    /// `ImageProcessor.getAutoThreshold(int[])`.
    static func ijIsoData(_ histogram: [Int32]) -> Int32 {
        var data = histogram
        let maxValue = data.count - 1
        data[0] = 0  // so erased areas aren't included
        data[maxValue] = 0
        var min = 0
        while data[min] == 0 && min < maxValue { min += 1 }
        var max = maxValue
        while data[max] == 0 && max > 0 { max -= 1 }
        if min >= max { return Int32(data.count / 2) }
        var movingIndex = min
        var result: Double
        repeat {
            var sum1 = 0.0, sum2 = 0.0, sum3 = 0.0, sum4 = 0.0
            for i in min...movingIndex {
                sum1 += d(i) * d(data[i])
                sum2 += d(data[i])
            }
            for i in stride(from: movingIndex + 1, through: max, by: 1) {
                sum3 += d(i) * d(data[i])
                sum4 += d(data[i])
            }
            result = (sum1 / sum2 + sum3 / sum4) / 2.0
            movingIndex += 1
        } while d(movingIndex + 1) <= result && movingIndex < max - 1
        return JavaNumerics.roundToInt32(result)
    }

    /// `AutoThresholder.Huang`.
    static func huang(_ data: [Int32]) -> Int32 {
        let n = data.count
        var firstBin = 0
        for ih in 0..<n where data[ih] != 0 {
            firstBin = ih
            break
        }
        var lastBin = n - 1
        for ih in stride(from: n - 1, through: firstBin, by: -1) where data[ih] != 0 {
            lastBin = ih
            break
        }
        let term = 1.0 / d(lastBin - firstBin)
        var mu0 = [Double](repeating: 0, count: n)
        var sumPix: Int32 = 0, numPix: Int32 = 0
        for ih in firstBin..<n {
            sumPix &+= times(ih, data[ih])
            numPix &+= data[ih]
            mu0[ih] = d(sumPix) / d(numPix)
        }
        var mu1 = [Double](repeating: 0, count: n)
        sumPix = 0
        numPix = 0
        for ih in stride(from: lastBin, to: 0, by: -1) {
            sumPix &+= times(ih, data[ih])
            numPix &+= data[ih]
            mu1[ih - 1] = d(sumPix) / d(numPix)
        }
        var threshold: Int32 = -1
        var minEnt = Double.greatestFiniteMagnitude
        for it in 0..<n {
            var ent = 0.0
            for ih in 0...it {
                let muX = 1.0 / (1.0 + term * abs(d(ih) - mu0[it]))
                if !(muX < 1e-06 || muX > 0.999999) {
                    ent += d(data[ih]) * (-muX * StrictMath.log(muX) - (1.0 - muX) * StrictMath.log(1.0 - muX))
                }
            }
            for ih in (it + 1)..<n {
                let muX = 1.0 / (1.0 + term * abs(d(ih) - mu1[it]))
                if !(muX < 1e-06 || muX > 0.999999) {
                    ent += d(data[ih]) * (-muX * StrictMath.log(muX) - (1.0 - muX) * StrictMath.log(1.0 - muX))
                }
            }
            if ent < minEnt {
                minEnt = ent
                threshold = Int32(it)
            }
        }
        return threshold
    }

    /// `AutoThresholder.Huang2`.
    static func huang2(_ data: [Int32]) -> Int32 {
        let n = data.count
        var first = 0
        while first < n && data[first] == 0 { first += 1 }
        var last = n - 1
        while last > first && data[last] == 0 { last -= 1 }
        if first == last { return 0 }

        // The cumulative and weighted cumulative counts.
        var s = [Double](repeating: 0, count: last + 1)
        var w = [Double](repeating: 0, count: last + 1)
        s[0] = d(data[0])
        for i in stride(from: Swift.max(1, first), through: last, by: 1) {
            s[i] = s[i - 1] + d(data[i])
            w[i] = w[i - 1] + d(times(i, data[i]))
        }

        // The entropy terms for each distance from the mean.
        let c = d(last - first)
        var smu = [Double](repeating: 0, count: Swift.max(last + 1 - first, 0))
        for i in stride(from: 1, to: smu.count, by: 1) {
            let mu = 1 / (1 + d(i) / c)
            smu[i] = -mu * StrictMath.log(mu) - (1 - mu) * StrictMath.log(1 - mu)
        }

        var bestThreshold: Int32 = 0
        var bestEntropy = Double.greatestFiniteMagnitude
        for threshold in stride(from: first, through: last, by: 1) {
            var entropy = 0.0
            var mu = Int(JavaNumerics.roundToInt32(w[threshold] / s[threshold]))
            for i in first...threshold {
                let k = abs(i - mu)
                guard k < smu.count else { return -1 }
                entropy += smu[k] * d(data[i])
            }
            mu = Int(JavaNumerics.roundToInt32((w[last] - w[threshold]) / (s[last] - s[threshold])))
            for i in stride(from: threshold + 1, through: last, by: 1) {
                let k = abs(i - mu)
                guard k < smu.count else { return -1 }
                entropy += smu[k] * d(data[i])
            }
            if bestEntropy > entropy {
                bestEntropy = entropy
                bestThreshold = Int32(threshold)
            }
        }
        return bestThreshold
    }

    /// `AutoThresholder.bimodalTest`: whether `y` has exactly two local
    /// maxima.
    static func bimodalTest(_ y: [Double]) -> Bool {
        var modes = 0
        for k in stride(from: 1, to: y.count - 1, by: 1) where y[k - 1] < y[k] && y[k + 1] < y[k] {
            modes += 1
            if modes > 2 { return false }
        }
        return modes == 2
    }

    /// `AutoThresholder.Intermodes`.
    static func intermodes(_ data: [Int32]) -> Int32 {
        let n = data.count
        var iHisto = data.map { d($0) }
        var iter = 0
        while !bimodalTest(iHisto) {
            // Smooth with a 3-point running mean.
            var previous = 0.0, current = 0.0, next = iHisto[0]
            for i in 0..<(n - 1) {
                previous = current
                current = next
                next = iHisto[i + 1]
                iHisto[i] = (previous + current + next) / 3
            }
            iHisto[n - 1] = (current + next) / 3
            iter += 1
            if iter > 10000 { return -1 }  // ImageJ logs "not found after 10000 iterations"
        }
        // The threshold is the mean of the two peaks.
        var tt: Int32 = 0
        for i in stride(from: 1, to: n - 1, by: 1) where iHisto[i - 1] < iHisto[i] && iHisto[i + 1] < iHisto[i] {
            tt &+= Int32(i)
        }
        return JavaNumerics.int32((d(tt) / 2.0).rounded(.down))
    }

    /// `AutoThresholder.IsoData`.
    static func isoData(_ data: [Int32]) -> Int32 {
        let n = data.count
        var g = 0
        for i in stride(from: 1, to: n, by: 1) where data[i] > 0 {
            g = i + 1
            break
        }
        while true {
            var l: Int32 = 0, totl: Int32 = 0
            for i in 0..<g {
                totl &+= data[i]
                l &+= times(i, data[i])
            }
            var h: Int32 = 0, toth: Int32 = 0
            for i in stride(from: g + 1, to: n, by: 1) {
                toth &+= data[i]
                h &+= times(i, data[i])
            }
            if totl > 0 && toth > 0 {
                l /= totl
                h /= toth
                if g == Int(JavaNumerics.roundToInt32(d(l &+ h) / 2.0)) { break }
            }
            g += 1
            if g > n - 2 { return -1 }  // ImageJ logs "IsoData Threshold not found."
        }
        return Int32(g)
    }

    /// `AutoThresholder.Li`.
    static func li(_ data: [Int32]) -> Int32 {
        let n = data.count
        let tolerance = 0.5
        var numPixels: Int32 = 0
        for ih in 0..<n { numPixels &+= data[ih] }
        var mean = 0.0
        for ih in 0..<n { mean += d(times(ih, data[ih])) }
        mean /= d(numPixels)

        var newThresh = mean
        var oldThresh: Double
        var threshold: Int32
        var seen: Set<UInt64> = []
        repeat {
            oldThresh = newThresh
            seen.insert(oldThresh.bitPattern)
            threshold = JavaNumerics.int32(oldThresh + 0.5)
            // ImageJ reads outside the histogram here (only after overflow).
            guard threshold >= -1 && Int(threshold) < n else { return -1 }
            // Background
            var sumBack: Int32 = 0, numBack: Int32 = 0
            for ih in stride(from: 0, through: Int(threshold), by: 1) {
                sumBack &+= times(ih, data[ih])
                numBack &+= data[ih]
            }
            let meanBack = numBack == 0 ? 0.0 : d(sumBack) / d(numBack)
            // Object
            var sumObj: Int32 = 0, numObj: Int32 = 0
            for ih in stride(from: Int(threshold) + 1, to: n, by: 1) {
                sumObj &+= times(ih, data[ih])
                numObj &+= data[ih]
            }
            let meanObj = numObj == 0 ? 0.0 : d(sumObj) / d(numObj)
            // Equation (7) in Li and Tam (1998), rounded away from zero.
            let temp = (meanBack - meanObj) / (StrictMath.log(meanBack) - StrictMath.log(meanObj))
            if temp < -epsilon {
                newThresh = d(JavaNumerics.int32(temp - 0.5))
            } else {
                newThresh = d(JavaNumerics.int32(temp + 0.5))
            }
            // A revisited estimate means ImageJ iterates forever.
            if abs(newThresh - oldThresh) > tolerance && seen.contains(newThresh.bitPattern) { return -1 }
        } while abs(newThresh - oldThresh) > tolerance
        return threshold
    }

    /// The normalized histogram and its cumulative sums, shared by
    /// MaxEntropy, RenyiEntropy and Shanbhag; and the first and last bins
    /// with a cumulative sum (from each end) above DBL_EPSILON.
    private struct Cumulative {
        var normHisto: [Double]
        var p1: [Double]
        var p2: [Double]
        var firstBin: Int
        var lastBin: Int

        init(_ data: [Int32]) {
            let n = data.count
            var total: Int32 = 0
            for count in data { total &+= count }
            normHisto = data.map { Double($0) / Double(total) }
            p1 = [Double](repeating: 0, count: n)
            p2 = [Double](repeating: 0, count: n)
            p1[0] = normHisto[0]
            p2[0] = 1.0 - p1[0]
            for ih in 1..<n {
                p1[ih] = p1[ih - 1] + normHisto[ih]
                p2[ih] = 1.0 - p1[ih]
            }
            firstBin = 0
            for ih in 0..<n where !(abs(p1[ih]) < AutoThresholder.epsilon) {
                firstBin = ih
                break
            }
            lastBin = n - 1
            for ih in stride(from: n - 1, through: firstBin, by: -1) where !(abs(p2[ih]) < AutoThresholder.epsilon) {
                lastBin = ih
                break
            }
        }

        /// Kapur, Sahoo and Wong's total entropy for a split after `it`.
        func shannonEntropy(_ data: [Int32], splitAfter it: Int) -> Double {
            var entBack = 0.0
            for ih in 0...it where data[ih] != 0 {
                entBack -= (normHisto[ih] / p1[it]) * StrictMath.log(normHisto[ih] / p1[it])
            }
            var entObj = 0.0
            for ih in (it + 1)..<data.count where data[ih] != 0 {
                entObj -= (normHisto[ih] / p2[it]) * StrictMath.log(normHisto[ih] / p2[it])
            }
            return entBack + entObj
        }
    }

    /// `AutoThresholder.MaxEntropy`.
    static func maxEntropy(_ data: [Int32]) -> Int32 {
        let c = Cumulative(data)
        var threshold: Int32 = -1
        var maxEnt = Double.leastNonzeroMagnitude  // Java's Double.MIN_VALUE
        for it in c.firstBin...c.lastBin {
            let totEnt = c.shannonEntropy(data, splitAfter: it)
            if maxEnt < totEnt {
                maxEnt = totEnt
                threshold = Int32(it)
            }
        }
        return threshold
    }

    /// `AutoThresholder.Mean`.
    static func mean(_ data: [Int32]) -> Int32 {
        var tot: Int64 = 0, sum: Int64 = 0
        for (i, count) in data.enumerated() {
            tot &+= Int64(count)
            sum &+= Int64(i) &* Int64(count)
        }
        if tot == 0 { return -1 }  // ImageJ: ArithmeticException (/ by zero)
        let quotient = sum.dividedReportingOverflow(by: tot).partialValue  // Java's long division
        return JavaNumerics.int32(Double(quotient).rounded(.down))
    }

    /// `AutoThresholder.MinErrorI`.
    static func minErrorI(_ data: [Int32]) -> Int32 {
        let n = data.count
        // ImageJ's A, B and C (partial sums of y[i], i*y[i] and i*i*y[i],
        // with int products), accumulated in the same order.
        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var x = 0.0, y = 0.0, z = 0.0
        for i in 0..<n {
            let ii = Int32(truncatingIfNeeded: i)
            x += d(data[i])
            y += d(ii &* data[i])
            z += d(ii &* ii &* data[i])
            a[i] = x
            b[i] = y
            c[i] = z
        }
        // A(y, j) etc.: 0 below the histogram; ImageJ reads past it above.
        func sums(_ j: Int32) -> (a: Double, b: Double, c: Double)? {
            if j < 0 { return (0, 0, 0) }
            return Int(j) < n ? (a[Int(j)], b[Int(j)], c[Int(j)]) : nil
        }
        let all = (a: a[n - 1], b: b[n - 1], c: c[n - 1])

        var threshold = mean(data)  // the initial estimate
        var tPrev: Int32 = -2
        var seen: Set<Int32> = []
        while threshold != tPrev {
            guard let t = sums(threshold) else { return -1 }
            seen.insert(threshold)
            let mu = t.b / t.a
            let nu = (all.b - t.b) / (all.a - t.a)
            let p = t.a / all.a
            let q = (all.a - t.a) / all.a
            let sigma2 = t.c / t.a - (mu * mu)
            let tau2 = (all.c - t.c) / (all.a - t.a) - (nu * nu)

            // The terms of the quadratic equation to be solved.
            let w0 = 1.0 / sigma2 - 1.0 / tau2
            let w1 = mu / sigma2 - nu / tau2
            let w2 = (mu * mu) / sigma2 - (nu * nu) / tau2 + StrictMath.log10((sigma2 * (q * q)) / (tau2 * (p * p)))

            // If the next threshold would be imaginary, keep this one.
            let sqterm = (w1 * w1) - w0 * w2
            if sqterm < 0 { return threshold }  // ImageJ logs "not converging"

            tPrev = threshold
            let temp = (w1 + sqterm.squareRoot()) / w0
            threshold = temp.isNaN ? tPrev : JavaNumerics.int32(temp.rounded(.down))
            // A revisited threshold means ImageJ iterates forever.
            if threshold != tPrev && seen.contains(threshold) { return -1 }
        }
        return threshold
    }

    /// `AutoThresholder.Minimum`.
    static func minimum(_ data: [Int32]) -> Int32 {
        let n = data.count
        if n < 2 { return 0 }
        var max = -1
        var iHisto = [Double](repeating: 0, count: n)
        for i in 0..<n {
            iHisto[i] = d(data[i])
            if data[i] > 0 { max = i }
        }
        var tHisto = [Double](repeating: 0, count: n)
        var iter = 0
        while !bimodalTest(iHisto) {
            // Smooth with a 3-point running mean, with zeros outside.
            for i in stride(from: 1, to: n - 1, by: 1) {
                tHisto[i] = (iHisto[i - 1] + iHisto[i] + iHisto[i + 1]) / 3
            }
            tHisto[0] = (iHisto[0] + iHisto[1]) / 3
            tHisto[n - 1] = (iHisto[n - 2] + iHisto[n - 1]) / 3
            swap(&iHisto, &tHisto)  // every element of tHisto was written
            iter += 1
            if iter > 10000 { return -1 }  // ImageJ logs "not found after 10000 iterations"
        }
        // The threshold is the minimum between the two peaks.
        for i in stride(from: 1, to: max, by: 1) where iHisto[i - 1] > iHisto[i] && iHisto[i + 1] >= iHisto[i] {
            return Int32(i)
        }
        return -1
    }

    /// `AutoThresholder.Moments`.
    static func moments(_ data: [Int32]) -> Int32 {
        var total = 0.0
        for count in data { total += d(count) }
        let histo = data.map { d($0) / total }  // the normalized histogram
        // The first, second and third moments (with int powers of i).
        let m0 = 1.0
        var m1 = 0.0, m2 = 0.0, m3 = 0.0
        for i in histo.indices {
            let ii = Int32(truncatingIfNeeded: i)
            m1 += d(ii) * histo[i]
            m2 += d(ii &* ii) * histo[i]
            m3 += d(ii &* ii &* ii) * histo[i]
        }
        // Match the moments of a two-level image (Tsai's appendix).
        let cd = m0 * m2 - m1 * m1
        let c0 = (-m2 * m2 + m1 * m3) / cd
        let c1 = (m0 * -m3 + m2 * m1) / cd
        let z0 = 0.5 * (-c1 - (c1 * c1 - 4.0 * c0).squareRoot())
        let z1 = 0.5 * (-c1 + (c1 * c1 - 4.0 * c0).squareRoot())
        let p0 = (z1 - m1) / (z1 - z0)  // the fraction of object pixels
        // The threshold is the gray level closest to the p0-tile.
        var sum = 0.0
        for i in histo.indices {
            sum += histo[i]
            if sum > p0 { return Int32(i) }
        }
        return -1
    }

    /// `AutoThresholder.Otsu`.
    static func otsu(_ data: [Int32]) -> Int32 {
        let n = data.count
        var numPixels: Int32 = 0
        for count in data { numPixels &+= count }
        let term = 1.0 / d(numPixels)
        let histo = data.map { term * d($0) }  // the normalized histogram
        var cnh = [Double](repeating: 0, count: n)  // its cumulative sum
        var mean = [Double](repeating: 0, count: n)  // the cumulative mean
        cnh[0] = histo[0]
        for ih in 1..<n { cnh[ih] = cnh[ih - 1] + histo[ih] }
        for ih in 1..<n { mean[ih] = mean[ih - 1] + d(ih) * histo[ih] }
        let totalMean = mean[n - 1]
        // The threshold maximizing the between-class variance.
        var threshold = Int32.min
        var maxBcv = 0.0
        for ih in 0..<n {
            var bcv = totalMean * cnh[ih] - mean[ih]
            bcv *= bcv / (cnh[ih] * (1.0 - cnh[ih]))
            if maxBcv < bcv {
                maxBcv = bcv
                threshold = Int32(ih)
            }
        }
        return threshold
    }

    /// `AutoThresholder.Percentile`.
    static func percentile(_ data: [Int32]) -> Int32 {
        let ptile = 0.5  // the fraction of foreground pixels
        var partial = [Double](repeating: 0, count: data.count)  // partialSum(data, i)
        var x = 0.0
        for i in data.indices {
            x += d(data[i])
            partial[i] = x
        }
        let total = partial[data.count - 1]
        var threshold: Int32 = -1
        var temp = 1.0
        for i in data.indices {
            let avec = abs(partial[i] / total - ptile)
            if avec < temp {
                temp = avec
                threshold = Int32(i)
            }
        }
        return threshold
    }

    /// `AutoThresholder.RenyiEntropy`.
    static func renyiEntropy(_ data: [Int32]) -> Int32 {
        let n = data.count
        let c = Cumulative(data)
        let normHisto = c.normHisto, p1 = c.p1, p2 = c.p2

        // Maximum entropy (alpha = 1).
        var threshold = 0  // ImageJ starts at 0 rather than MIN_INT
        var maxEnt = 0.0
        for it in c.firstBin...c.lastBin {
            let totEnt = c.shannonEntropy(data, splitAfter: it)
            if maxEnt < totEnt {
                maxEnt = totEnt
                threshold = it
            }
        }
        let tStar2 = threshold

        // alpha = 0.5
        threshold = 0
        maxEnt = 0.0
        var term = 1.0 / (1.0 - 0.5)
        for it in c.firstBin...c.lastBin {
            var entBack = 0.0
            for ih in 0...it { entBack += (normHisto[ih] / p1[it]).squareRoot() }
            var entObj = 0.0
            for ih in (it + 1)..<n { entObj += (normHisto[ih] / p2[it]).squareRoot() }
            let totEnt = term * ((entBack * entObj) > 0.0 ? StrictMath.log(entBack * entObj) : 0.0)
            if totEnt > maxEnt {
                maxEnt = totEnt
                threshold = it
            }
        }
        let tStar1 = threshold

        // alpha = 2
        threshold = 0
        maxEnt = 0.0
        term = 1.0 / (1.0 - 2.0)
        for it in c.firstBin...c.lastBin {
            var entBack = 0.0
            for ih in 0...it { entBack += (normHisto[ih] * normHisto[ih]) / (p1[it] * p1[it]) }
            var entObj = 0.0
            for ih in (it + 1)..<n { entObj += (normHisto[ih] * normHisto[ih]) / (p2[it] * p2[it]) }
            let totEnt = term * ((entBack * entObj) > 0.0 ? StrictMath.log(entBack * entObj) : 0.0)
            if totEnt > maxEnt {
                maxEnt = totEnt
                threshold = it
            }
        }
        let tStar3 = threshold

        // Sort the three thresholds.
        var t1 = tStar1, t2 = tStar2, t3 = tStar3
        if t2 < t1 { swap(&t1, &t2) }
        if t3 < t2 { swap(&t2, &t3) }
        if t2 < t1 { swap(&t1, &t2) }

        // Weight them.
        let beta1: Int, beta2: Int, beta3: Int
        if abs(t1 - t2) <= 5 {
            if abs(t2 - t3) <= 5 {
                (beta1, beta2, beta3) = (1, 2, 1)
            } else {
                (beta1, beta2, beta3) = (0, 1, 3)
            }
        } else {
            if abs(t2 - t3) <= 5 {
                (beta1, beta2, beta3) = (3, 1, 0)
            } else {
                (beta1, beta2, beta3) = (1, 2, 1)
            }
        }
        let omega = p1[t3] - p1[t1]
        let opt = d(t1) * (p1[t1] + 0.25 * omega * d(beta1)) + 0.25 * d(t2) * omega * d(beta2)
            + d(t3) * (p2[t3] + 0.25 * omega * d(beta3))
        return JavaNumerics.int32(opt)
    }

    /// `AutoThresholder.Shanbhag`.
    static func shanbhag(_ data: [Int32]) -> Int32 {
        let n = data.count
        let c = Cumulative(data)
        let normHisto = c.normHisto, p1 = c.p1, p2 = c.p2
        var threshold: Int32 = -1
        var minEnt = Double.greatestFiniteMagnitude
        for it in c.firstBin...c.lastBin {
            var entBack = 0.0
            var term = 0.5 / p1[it]
            for ih in stride(from: 1, through: it, by: 1) {
                entBack -= normHisto[ih] * StrictMath.log(1.0 - term * p1[ih - 1])
            }
            entBack *= term

            var entObj = 0.0
            term = 0.5 / p2[it]
            for ih in (it + 1)..<n {
                entObj -= normHisto[ih] * StrictMath.log(1.0 - term * p2[ih])
            }
            entObj *= term

            let totEnt = abs(entBack - entObj)
            if totEnt < minEnt {
                minEnt = totEnt
                threshold = Int32(it)
            }
        }
        return threshold
    }

    /// `AutoThresholder.Triangle`.
    static func triangle(_ histogram: [Int32]) -> Int32 {
        var data = histogram
        let n = data.count
        // The line runs from the empty bin just outside the data to the peak.
        var min = 0, max = 0, min2 = 0
        var dmax: Int32 = 0
        for i in 0..<n where data[i] > 0 {
            min = i
            break
        }
        if min > 0 { min -= 1 }
        for i in stride(from: n - 1, to: 0, by: -1) where data[i] > 0 {
            min2 = i
            break
        }
        if min2 < n - 1 { min2 += 1 }
        for i in 0..<n where data[i] > dmax {
            max = i
            dmax = data[i]
        }
        // Use the side of the peak where the data reaches furthest.
        var inverted = false
        if (max - min) < (min2 - max) {
            inverted = true
            data.reverse()
            min = n - 1 - min2
            max = n - 1 - max
        }
        if min == max { return Int32(min) }

        // The line nx * x + ny * y - d = 0.
        var nx = d(data[max])
        var ny = d(min - max)
        var dist = (nx * nx + ny * ny).squareRoot()
        nx /= dist
        ny /= dist
        dist = nx * d(min) + ny * d(data[min])

        // The split point.
        var split = min
        var splitDistance = 0.0
        for i in stride(from: min + 1, through: max, by: 1) {
            let newDistance = nx * d(i) + ny * d(data[i]) - dist
            if newDistance > splitDistance {
                split = i
                splitDistance = newDistance
            }
        }
        split -= 1
        return Int32(inverted ? n - 1 - split : split)
    }

    /// `AutoThresholder.Yen`.
    static func yen(_ data: [Int32]) -> Int32 {
        let n = data.count
        var total: Int32 = 0
        for count in data { total &+= count }
        let normHisto = data.map { d($0) / d(total) }
        var p1 = [Double](repeating: 0, count: n)
        var p1Sq = [Double](repeating: 0, count: n)
        var p2Sq = [Double](repeating: 0, count: n)
        p1[0] = normHisto[0]
        for ih in 1..<n { p1[ih] = p1[ih - 1] + normHisto[ih] }
        p1Sq[0] = normHisto[0] * normHisto[0]
        for ih in 1..<n { p1Sq[ih] = p1Sq[ih - 1] + normHisto[ih] * normHisto[ih] }
        p2Sq[n - 1] = 0.0
        for ih in stride(from: n - 2, through: 0, by: -1) {
            p2Sq[ih] = p2Sq[ih + 1] + normHisto[ih + 1] * normHisto[ih + 1]
        }
        // The threshold maximizing the criterion.
        var threshold: Int32 = -1
        var maxCrit = Double.leastNonzeroMagnitude  // Java's Double.MIN_VALUE
        for it in 0..<n {
            let a = (p1Sq[it] * p2Sq[it]) > 0.0 ? StrictMath.log(p1Sq[it] * p2Sq[it]) : 0.0
            let b = (p1[it] * (1.0 - p1[it])) > 0.0 ? StrictMath.log(p1[it] * (1.0 - p1[it])) : 0.0
            let crit = -1.0 * a + 2 * b
            if crit > maxCrit {
                maxCrit = crit
                threshold = Int32(it)
            }
        }
        return threshold
    }
}
