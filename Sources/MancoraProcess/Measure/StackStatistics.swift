public import MancoraCore

/// Image ▸ Stacks ▸ Statistics: a port of ImageJ 1.54p's
/// `ij.process.StackStatistics` with its default histogram (256 bins over
/// the stack's range), for images without a value calibration.
public struct StackStatistics: Sendable, Hashable {
    public var pixelCount = 0
    public var mean = 0.0
    public var standardDeviation = 0.0
    public var min = 0.0
    public var max = 0.0
    /// ImageJ's `dmode`.
    public var mode = 0.0
    public var median = 0.0

    /// Every plane's pixels within `region` (the whole plane for `nil`),
    /// limited to `threshold` when given: 8-bit and RGB data (RGB as its
    /// luminance) sum the planes' histograms, 16-bit data their 65536-bin
    /// histograms, 32-bit data a 256-bin histogram between the minimum and
    /// maximum, whose median ImageJ leaves NaN without a threshold.
    public init(planes: [Plane], width: Int, region: MeasurementRegion?, threshold: ClosedRange<Double>?) {
        guard let first = planes.first else { return }
        let height = first.count / width
        let r = region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height)
        func forEachPixel(_ body: (Int) -> Void) {
            for y in r.y..<(r.y + r.height) {
                for x in r.x..<(r.x + r.width) where r.contains(x, y) { body(y * width + x) }
            }
        }
        switch first {
        case .gray8, .rgb8:
            var histogram = [Int](repeating: 0, count: 256)
            for plane in planes {
                switch plane {
                case .gray8(let p): forEachPixel { histogram[Int(p[$0])] += 1 }
                case .rgb8(let p):
                    // ColorProcessor's histogram: the unweighted luminance, rounded.
                    let w = 1.0 / 3.0
                    forEachPixel { i in
                        let c = p[i]
                        let v = Double((c >> 16) & 0xFF) * w + Double((c >> 8) & 0xFF) * w + Double(c & 0xFF) * w
                        histogram[Int(v + 0.5)] += 1
                    }
                default: break
                }
            }
            var minT = 0, maxT = 255
            if let threshold {
                minT = Int(JavaNumerics.int32(threshold.lowerBound))
                maxT = Int(JavaNumerics.int32(threshold.upperBound))
            }
            sum8BitHistograms(histogram, minT, maxT)
        case .gray16:
            var histogram = [Int](repeating: 0, count: 65536)
            for case .gray16(let p) in planes { forEachPixel { histogram[Int(p[$0])] += 1 } }
            var minT = 0, maxT = 65535
            if let threshold {
                minT = Int(JavaNumerics.int32(threshold.lowerBound))
                maxT = Int(JavaNumerics.int32(threshold.upperBound))
            }
            sum16BitHistograms(histogram, minT, maxT)
        case .gray32Float:
            var minT = -Double(Float.greatestFiniteMagnitude), maxT = Double(Float.greatestFiniteMagnitude)
            if let threshold { (minT, maxT) = (threshold.lowerBound, threshold.upperBound) }
            var values: [Double] = []
            for case .gray32Float(let p) in planes { forEachPixel { values.append(Double(p[$0])) } }
            floatStatistics(values, minT, maxT)
        }
    }

    /// `sum8BitHistograms`: raw statistics of the summed histogram.
    private mutating func sum8BitHistograms(_ histogram: [Int], _ minT: Int, _ maxT: Int) {
        var sum = 0.0, sum2 = 0.0, count = 0, maxCount = 0, modeIndex = 0
        for i in stride(from: minT, through: maxT, by: 1) {
            let n = histogram[i]
            count += n
            sum += Double(i) * Double(n)
            sum2 += (Double(i) * Double(i)) * Double(n)
            if n > maxCount {
                maxCount = n
                modeIndex = i
            }
        }
        pixelCount = count
        mean = sum / Double(count)
        mode = Double(modeIndex)
        standardDeviation = MeasurementStatistics.standardDeviation(Double(count), sum, sum2)
        var low = minT
        while histogram[low] == 0 && low < 255 { low += 1 }
        var high = maxT
        while histogram[high] == 0 && high > 0 { high -= 1 }
        (min, max) = (Double(low), Double(high))
        median = Self.median(histogram, minT, maxT, count)
    }

    /// `sum16BitHistograms`: the range, then statistics with a 256-bin
    /// histogram over it for the mode.
    private mutating func sum16BitHistograms(_ histogram: [Int], _ minT: Int, _ maxT: Int) {
        var low = minT
        while histogram[low] == 0 && low < 65535 { low += 1 }
        var high = maxT
        while histogram[high] == 0 && high > 0 { high -= 1 }
        (min, max) = (Double(low), Double(high))
        let binSize = (max - min + 1) / 256
        let scale = 1.0 / binSize
        var bins = [Int](repeating: 0, count: 256)
        var sum = 0.0, sum2 = 0.0, count = 0
        if low <= high {
            for i in low...high {
                let n = histogram[i]
                count += n
                let value = Double(i)
                sum += value * Double(n)
                sum2 += (value * value) * Double(n)
                bins[Swift.min(Int(JavaNumerics.int32(scale * Double(i - low))), 255)] += n
            }
        }
        pixelCount = count
        mean = sum / Double(count)
        standardDeviation = MeasurementStatistics.standardDeviation(Double(count), sum, sum2)
        mode = min + Double(Self.modeIndex(bins)) * binSize
        median = Self.median(histogram, minT, maxT, count)
    }

    /// `doCalculations` for float data.
    private mutating func floatStatistics(_ values: [Double], _ minT: Double, _ maxT: Double) {
        var roiMin = Double.greatestFiniteMagnitude, roiMax = -Double.greatestFiniteMagnitude
        for v in values where v >= minT && v <= maxT {
            if v < roiMin { roiMin = v }
            if v > roiMax { roiMax = v }
        }
        (min, max) = (roiMin, roiMax)
        let scale = 256 / (roiMax - roiMin)
        var bins = [Int](repeating: 0, count: 256)
        var sum = 0.0, sum2 = 0.0, count = 0
        for v in values where v >= minT && v <= maxT && v >= roiMin && v <= roiMax {
            count += 1
            sum += v
            sum2 += v * v
            bins[Swift.min(Int(JavaNumerics.int32(scale * (v - roiMin))), 255)] += 1
        }
        pixelCount = count
        mean = sum / Double(count)
        standardDeviation = MeasurementStatistics.standardDeviation(Double(count), sum, sum2)
        mode = roiMin + Double(Self.modeIndex(bins)) * ((roiMax - roiMin) / 256)
        // getMedian(longHistogram, (int)minThreshold, (int)maxThreshold): bin indices.
        median = Self.median(bins, Int(JavaNumerics.int32(minT)), Int(JavaNumerics.int32(maxT)), count)
    }

    /// The first bin with the most counts.
    static func modeIndex(_ bins: [Int]) -> Int {
        var maxCount = 0, index = 0
        for (i, n) in bins.enumerated() where n > maxCount {
            maxCount = n
            index = i
        }
        return index
    }

    /// `StackStatistics.getMedian`: the first index past half the pixels,
    /// counting from `first`; NaN without pixels or for a range outside
    /// the histogram.
    static func median(_ histogram: [Int], _ first: Int, _ last: Int, _ pixelCount: Int) -> Double {
        if pixelCount == 0 || first < 0 || last > histogram.count { return .nan }
        var sum = 0.0
        var i = first - 1
        let halfCount = Double(pixelCount) / 2.0
        repeat {
            i += 1
            sum += Double(i < histogram.count ? histogram[i] : 0)
        } while sum <= halfCount && i < last
        return Double(i)
    }
}
