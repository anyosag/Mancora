/// A histogram and summary statistics of a plane or stack, computed exactly
/// as ImageJ computes them: Mancora's counterpart of
/// `ij.process.ImageStatistics`.
///
/// ``init(_:)`` mirrors `ImageStatistics.getStatistics(ip, MIN_MAX, null)`
/// for a whole plane, which dispatches to `ByteStatistics`,
/// `ShortStatistics` or `FloatStatistics`. ``init(stack:)`` mirrors
/// `StackStatistics(imp)`. Both measure raw (uncalibrated) values of every
/// pixel. The 256-bin ``histogram`` covers:
///
/// - 8-bit: one bin per value, so `histMin` is 0, `histMax` 255 and
///   `binSize` 1.
/// - 16-bit: the smallest to the largest value, with
///   `binSize = (histMax - histMin + 1) / 256`. ``histogram16`` holds the
///   count of every value.
/// - 32-bit float: the smallest to the largest finite value, with
///   `binSize = (histMax - histMin) / 256`. NaN and ±infinity are not
///   counted, because ImageJ only counts values within
///   ±`Float.greatestFiniteMagnitude`. With no finite pixels, `min`, `max`
///   and `binSize` keep ImageJ's starting values
///   (`Double.greatestFiniteMagnitude`, its negation, and −infinity) and
///   `mean` is NaN.
///
/// Not ported yet: selections and masks, value calibration, "limit to
/// threshold", RGB images (`ColorStatistics`), and measurements other than
/// min, max and mean.
///
/// Counts are 64-bit. ImageJ keeps `pixelCount` and stack histogram bins in
/// 32-bit `int`s, which wrap or clamp beyond 2³¹ − 1 pixels.
public struct ImageStatistics: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable, Sendable {
        /// RGB statistics (ImageJ's `ColorStatistics`) are not ported yet.
        case unsupportedPixelType(PixelType)
    }

    /// The pixel type measured.
    public let pixelType: PixelType
    /// ImageJ's `histogram`: ``nBins`` counts from ``histMin`` in steps of
    /// ``binSize``.
    public let histogram: [Int]
    /// ImageJ's `histogram16` for 16-bit data: the count of each value
    /// 0–65535. ImageJ uses a shorter array for small images, ending after
    /// the largest value; the counts are the same. `nil` for other types.
    public let histogram16: [Int]?
    /// The value at the start of the first bin (ImageJ's `histMin`).
    public let histMin: Double
    /// The largest value the histogram covers (ImageJ's `histMax`).
    public let histMax: Double
    /// The width of one bin (ImageJ's `binSize`).
    public let binSize: Double
    /// The number of pixels counted in ``histogram``.
    public let pixelCount: Int
    /// The smallest value counted.
    public let min: Double
    /// The largest value counted.
    public let max: Double
    /// The mean of the values counted, summed in ImageJ's order.
    public let mean: Double

    /// The number of bins in ``histogram``: always 256.
    public var nBins: Int { histogram.count }

    /// The statistics of one whole plane, as
    /// `ImageStatistics.getStatistics(ip, MIN_MAX, null)` computes them.
    ///
    /// ImageJ's `getRawStatistics()`, which the B&C dialog uses, bins the
    /// same way.
    public init(_ plane: Plane) throws(Error) {
        switch plane {
        case .gray8(let pixels):
            var counts = [Int](repeating: 0, count: 256)
            for value in pixels { counts[Int(value)] += 1 }
            self.init(byteHistogram: counts)
        case .gray16(let pixels):
            var counts = [Int](repeating: 0, count: 65536)
            for value in pixels { counts[Int(value)] += 1 }
            self.init(shortHistogram: counts)
        case .gray32Float(let pixels):
            self.init(floatPlanes: [pixels])
        case .rgb8:
            throw .unsupportedPixelType(.rgb8)
        }
    }

    /// The statistics of every plane of a stack together, as
    /// `StackStatistics(imp)` computes them for an uncalibrated image.
    public init(stack: ImageStack) throws(Error) {
        switch stack.pixelType {
        case .gray8:
            // StackStatistics.sum8BitHistograms
            var counts = [Int](repeating: 0, count: 256)
            for case .gray8(let pixels) in stack.planes {
                for value in pixels { counts[Int(value)] += 1 }
            }
            self.init(byteHistogram: counts)
        case .gray16:
            // StackStatistics.sum16BitHistograms
            var counts = [Int](repeating: 0, count: 65536)
            for case .gray16(let pixels) in stack.planes {
                for value in pixels { counts[Int(value)] += 1 }
            }
            self.init(shortHistogram: counts)
        case .gray32Float:
            // StackStatistics.doCalculations
            var planes: [[Float]] = []
            for case .gray32Float(let pixels) in stack.planes { planes.append(pixels) }
            self.init(floatPlanes: planes)
        case .rgb8:
            throw .unsupportedPixelType(.rgb8)
        }
    }

    private init(
        pixelType: PixelType,
        histogram: [Int],
        histogram16: [Int]?,
        histMin: Double,
        histMax: Double,
        binSize: Double,
        pixelCount: Int,
        min: Double,
        max: Double,
        mean: Double
    ) {
        self.pixelType = pixelType
        self.histogram = histogram
        self.histogram16 = histogram16
        self.histMin = histMin
        self.histMax = histMax
        self.binSize = binSize
        self.pixelCount = pixelCount
        self.min = min
        self.max = max
        self.mean = mean
    }

    /// `ByteStatistics.getRawStatistics` and `getRawMinAndMax` (and the same
    /// steps in `StackStatistics.sum8BitHistograms`).
    private init(byteHistogram counts: [Int]) {
        var pixelCount = 0
        var sum = 0.0
        for (value, count) in counts.enumerated() {
            pixelCount += count
            sum += Double(value) * Double(count)
        }
        var min = Double.nan, max = Double.nan
        if pixelCount > 0 {
            var lo = 0
            while counts[lo] == 0 && lo < 255 { lo += 1 }
            var hi = 255
            while counts[hi] == 0 && hi > 0 { hi -= 1 }
            min = Double(lo)
            max = Double(hi)
        }
        self.init(
            pixelType: .gray8, histogram: counts, histogram16: nil, histMin: 0, histMax: 255, binSize: 1,
            pixelCount: pixelCount, min: min, max: max, mean: sum / Double(pixelCount)
        )
    }

    /// `ShortStatistics.getRawMinAndMax` and `getStatistics` (and
    /// `StackStatistics.get16BitStatistics`): 256 bins from the smallest to
    /// the largest value present.
    private init(shortHistogram counts: [Int]) {
        var lo = 0
        while counts[lo] == 0 && lo < 65535 { lo += 1 }
        var hi = 65535
        while counts[hi] == 0 && hi > 0 { hi -= 1 }
        let histMin = Double(lo), histMax = Double(hi)
        let binSize = (histMax - histMin + 1) / 256
        let scale = 1 / binSize
        var bins = [Int](repeating: 0, count: 256)
        var pixelCount = 0
        var sum = 0.0
        for value in stride(from: lo, through: hi, by: 1) {
            let count = counts[value]
            pixelCount += count
            sum += Double(value) * Double(count)
            let index = Int(JavaNumerics.int32(scale * Double(value - lo)))
            bins[Swift.min(index, 255)] += count
        }
        self.init(
            pixelType: .gray16, histogram: bins, histogram16: counts, histMin: histMin, histMax: histMax,
            binSize: binSize, pixelCount: pixelCount, min: histMin, max: histMax, mean: sum / Double(pixelCount)
        )
    }

    /// `FloatStatistics.getStatistics` for one plane, and
    /// `StackStatistics.doCalculations` for several: one pass for the range
    /// of finite values, a second to bin them.
    private init(floatPlanes planes: [[Float]]) {
        // ImageJ keeps values within ±Float.MAX_VALUE, which for floats
        // means the finite ones.
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for pixels in planes {
            for value in pixels where value.isFinite {
                let v = Double(value)
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        let binSize = (hi - lo) / 256
        let scale = 256 / (hi - lo)
        var bins = [Int](repeating: 0, count: 256)
        var pixelCount = 0
        var sum = 0.0
        for pixels in planes {
            // Every finite value lies within lo...hi, the histogram's range.
            for value in pixels where value.isFinite {
                let v = Double(value)
                pixelCount += 1
                sum += v
                // A constant plane has an infinite scale; Java's (int) of the
                // resulting NaN is 0.
                let index = Int(JavaNumerics.int32(scale * (v - lo)))
                bins[Swift.min(index, 255)] += 1
            }
        }
        self.init(
            pixelType: .gray32Float, histogram: bins, histogram16: nil, histMin: lo, histMax: hi, binSize: binSize,
            pixelCount: pixelCount, min: lo, max: hi, mean: sum / Double(pixelCount)
        )
    }
}
