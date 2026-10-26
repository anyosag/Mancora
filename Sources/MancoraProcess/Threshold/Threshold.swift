public import MancoraCore

/// A threshold on an image: the pixels from `lower` to `upper` (inclusive)
/// are thresholded. ImageJ's `getMinThreshold()` and `getMaxThreshold()`,
/// in raw pixel values.
public struct ThresholdLevels: Sendable, Hashable {
    public var lower: Double
    public var upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

/// Why an image can't be thresholded.
public enum ThresholdError: Error, Equatable, Sendable {
    /// RGB images have ImageJ's separate color thresholder, not ported yet.
    case unsupportedPixelType(PixelType)
}

/// The keywords of ImageJ's `setAutoThreshold("Method dark 16-bit no-reset")`.
public struct AutoThresholdOptions: Sendable, Hashable {
    /// `dark`: the objects are brighter than the background, so the
    /// threshold covers the bins above the method's threshold.
    public var darkBackground: Bool
    /// `16-bit`: for a 16-bit image, run the method on the full
    /// 65536-value histogram and set the levels in pixel values, leaving the
    /// display range alone. As in ImageJ, the keyword also stops the
    /// threshold's "+1" for a dark background and in
    /// ``AutoThresholder/bilevel(_:subtractOne:)``, whatever the image type.
    public var sixteenBitHistogram: Bool
    /// `no-reset`: keep a 16- or 32-bit image's display range instead of
    /// resetting it to the data range first. The 256-bin histogram then
    /// covers only the display range.
    public var noReset: Bool
    /// Whether the image is shown with an inverted LUT
    /// (`ImageProcessor.isInvertedLut()`), which swaps the side thresholded.
    public var invertedLUT: Bool

    public init(darkBackground: Bool = false, sixteenBitHistogram: Bool = false, noReset: Bool = false, invertedLUT: Bool = false) {
        self.darkBackground = darkBackground
        self.sixteenBitHistogram = sixteenBitHistogram
        self.noReset = noReset
        self.invertedLUT = invertedLUT
    }
}

/// What an automatic threshold leaves on an image.
public struct AutoThresholdResult: Sendable, Equatable {
    /// The threshold, in pixel values.
    public var levels: ThresholdLevels
    /// The display range of a 16- or 32-bit image afterwards (ImageJ's
    /// `getMin()` and `getMax()`), which the levels were scaled with; `nil`
    /// for 8-bit images and for 32-bit images with no non-NaN pixels.
    public var displayRange: ClosedRange<Double>?
    /// The bin the method returned, in the histogram it ran on: 0–255, or a
    /// pixel value with ``AutoThresholdOptions/sixteenBitHistogram``.
    public var threshold: Int

    public init(levels: ThresholdLevels, displayRange: ClosedRange<Double>?, threshold: Int) {
        self.levels = levels
        self.displayRange = displayRange
        self.threshold = threshold
    }
}

/// Automatic and manual thresholds on images, as ImageJ's
/// `ImageProcessor` computes and stores them.
///
/// Images are thresholded through a 256-bin histogram. 8-bit images use
/// their own histogram. 16- and 32-bit images are first converted to 8 bits
/// through the display range (`convertToByte(true)`), and the resulting
/// 0–255 levels are scaled back with `scaleAndSetThreshold`: a lower level
/// of 0 becomes 0 for 16-bit and −10³⁰ for 32-bit images, an upper level of
/// 255 becomes 65535 or +10³⁰, and the rest map linearly onto the display
/// range. 16-bit images store levels rounded to integers (`ShortProcessor`),
/// 8-bit images clamp them to 0–255 (`ByteProcessor`).
///
/// Selections and masks are not supported yet: the whole plane is used.
public enum Threshold {
    /// The threshold `ImageProcessor.setAutoThreshold(String)` sets, as
    /// `setAutoThreshold("Otsu dark")` in a macro or the Threshold dialog's
    /// method menu do for a single image.
    ///
    /// - Parameters:
    ///   - displayRange: the display range a 16- or 32-bit image has before
    ///     (`getMin()`/`getMax()`); `nil` for the data range, which ImageJ
    ///     resets to anyway unless ``AutoThresholdOptions/noReset`` is set.
    ///     It's stored as ImageJ stores it: rounded for 16-bit images, as
    ///     `Float` for 32-bit ones. Ignored for 8-bit images.
    ///   - addOne: ImageJ's `addOne`: whether a dark-background threshold
    ///     starts one bin above the method's threshold (and two-valued
    ///     histograms subtract one). `setAutoThreshold("…")` sets it unless
    ///     the method string says 16-bit, which is the default here; it is
    ///     off for a processor that never had that call, as in Convert to
    ///     Mask on a stack.
    public static func auto(
        _ plane: Plane,
        method: AutoThresholder.Method,
        options: AutoThresholdOptions = .init(),
        displayRange: ClosedRange<Double>? = nil,
        addOne: Bool? = nil
    ) throws(ThresholdError) -> AutoThresholdResult {
        let processor = try Processor(plane, displayRange: displayRange, invertedLUT: options.invertedLUT)
        return processor.setAutoThreshold(
            method,
            darkBackground: options.darkBackground,
            histogram16: options.sixteenBitHistogram && plane.pixelType == .gray16,
            addOne: addOne ?? !options.sixteenBitHistogram,
            noReset: options.noReset
        ).result
    }

    /// The threshold `setAutoThreshold("Method … stack")` sets from the
    /// histogram of the whole stack: ImageJ's `IJ.setStackThreshold`, which
    /// the Threshold dialog's "Stack histogram" uses.
    ///
    /// The 256-bin histogram is `StackStatistics`' (see
    /// ``ImageStatistics/init(stack:)``) and the levels are scaled with the
    /// stack's range, which also becomes the display range of a 16- or
    /// 32-bit image. ``AutoThresholdOptions/noReset`` has no effect.
    ///
    /// - Parameter currentPlane: the plane shown, whose own range ImageJ
    ///   falls back on when the stack's range is 0–0.
    public static func auto(
        stack: ImageStack,
        method: AutoThresholder.Method,
        options: AutoThresholdOptions = .init(),
        currentPlane: Int = 0
    ) throws(ThresholdError) -> AutoThresholdResult {
        let type = stack.pixelType
        let stats: ImageStatistics
        do { stats = try ImageStatistics(stack: stack) } catch { throw .unsupportedPixelType(type) }
        let histo16 = type == .gray16 && options.sixteenBitHistogram
        let addOne = !options.sixteenBitHistogram
        var min = 0.0, max = 255.0
        if type != .gray8 {
            min = stats.min
            max = stats.max
        }
        let histogram: [Int32]
        if histo16, let counts = stats.histogram16 {
            histogram = counts.map { Int32(clamping: $0) }  // StackStatistics clamps its counts
        } else {
            histogram = AutoThresholder.javaInts(stats.histogram)
        }
        let threshold = AutoThresholder.getThreshold(method, histogram, bilevelSubtractOne: true)
        var (lower, upper) = sides(
            threshold, tmax: histogram.count > 256 ? 65535 : 255, darkBackground: options.darkBackground,
            invertedLUT: options.invertedLUT, addOne: addOne)
        var processor = try Processor(stack[currentPlane], displayRange: nil, invertedLUT: options.invertedLUT)
        if !histo16 {
            if lower > 255 { lower = 255 }
            if max > min {
                lower = min + (lower / 255.0) * (max - min)
                upper = min + (upper / 255.0) * (max - min)
            } else {
                lower = min
                upper = min
            }
            processor.setMinAndMax(min, max)
        }
        let levels = processor.setThreshold(lower, upper)!
        return AutoThresholdResult(levels: levels, displayRange: processor.displayRange, threshold: Int(threshold))
    }

    /// The threshold `setAutoThreshold()` without a method sets: ImageJ's
    /// legacy `setAutoThreshold(ISODATA2, …)`, which Convert to Mask uses
    /// on an image without a threshold.
    ///
    /// The threshold is ``AutoThresholder/Method/ijIsoData`` on the 256-bin
    /// histogram with its mode capped as ``AutoThresholder/Method/default``
    /// caps it. The side is chosen from the histogram smoothed with a
    /// Gaussian (σ = 2 bins): if its peak stands out (more than 1.5 times
    /// the average), the side farther from the peak is thresholded;
    /// otherwise the dark side, or the bright side with an inverted LUT. The
    /// levels never add one to the threshold. 16- and 32-bit images have
    /// their display range reset first.
    public static func legacyIsoData(_ plane: Plane, invertedLUT: Bool = false) throws(ThresholdError) -> AutoThresholdResult {
        var processor = try Processor(plane, displayRange: nil, invertedLUT: invertedLUT)
        return processor.setLegacyAutoThreshold()
    }

    /// The binary mask of a threshold, as `ImageProcessor.createMask()`
    /// (and `ImagePlus.createThresholdMask()`) make it: an 8-bit plane with
    /// 255 where `lower <= value <= upper` and 0 elsewhere.
    ///
    /// The levels are cast as ImageJ casts them: to `Int` (toward zero) for
    /// 8- and 16-bit images, to `Float` for 32-bit images, where NaN pixels
    /// are never in the mask.
    public static func createMask(_ plane: Plane, levels: ThresholdLevels) throws(ThresholdError) -> Plane {
        switch plane {
        case .gray8(let pixels):
            let lo = Int(JavaNumerics.int32(levels.lower)), hi = Int(JavaNumerics.int32(levels.upper))
            return .gray8(pixels.map { Int($0) >= lo && Int($0) <= hi ? 255 : 0 })
        case .gray16(let pixels):
            let lo = Int(JavaNumerics.int32(levels.lower)), hi = Int(JavaNumerics.int32(levels.upper))
            return .gray8(pixels.map { Int($0) >= lo && Int($0) <= hi ? 255 : 0 })
        case .gray32Float(let pixels):
            let lo = Float(levels.lower), hi = Float(levels.upper)
            return .gray8(pixels.map { $0 >= lo && $0 <= hi ? 255 : 0 })
        case .rgb8:
            throw .unsupportedPixelType(.rgb8)
        }
    }

    /// The levels for a threshold bin: `0...threshold`, or
    /// `threshold+1...tmax` for a dark background (the `+1` only with
    /// `addOne`), swapped for an inverted LUT.
    static func sides(_ threshold: Int32, tmax: Double, darkBackground: Bool, invertedLUT: Bool, addOne: Bool)
        -> (lower: Double, upper: Double)
    {
        let above = Double(threshold &+ (addOne ? 1 : 0))
        if darkBackground != invertedLUT {
            return (above, tmax)
        }
        return (0, Double(threshold))
    }
}

/// The state of an ImageJ `ImageProcessor` that thresholding reads and
/// changes: the pixels, the display range and whether the LUT is inverted.
struct Processor {
    /// ImageJ's `ImageProcessor.NO_THRESHOLD`.
    static let noThreshold = -808080.0

    let plane: Plane
    /// `getMin()` and `getMax()`: NaN for a 32-bit plane without non-NaN
    /// pixels; 0–255 for 8-bit planes, where it isn't used.
    var min: Double
    var max: Double
    let invertedLUT: Bool

    init(_ plane: Plane, displayRange: ClosedRange<Double>?, invertedLUT: Bool) throws(ThresholdError) {
        if case .rgb8 = plane { throw .unsupportedPixelType(.rgb8) }
        self.plane = plane
        self.invertedLUT = invertedLUT
        (min, max) = (0, 255)
        if let range = displayRange {
            setMinAndMax(range.lowerBound, range.upperBound)
        } else {
            resetMinAndMax()
        }
    }

    var type: PixelType { plane.pixelType }

    var displayRange: ClosedRange<Double>? {
        type == .gray8 || !(min <= max) ? nil : min...max
    }

    /// `resetMinAndMax()`: `findMinAndMax` of a 16- or 32-bit plane (NaN
    /// skipped, infinities included).
    mutating func resetMinAndMax() {
        switch plane {
        case .gray8, .rgb8:
            (min, max) = (0, 255)
        case .gray16, .gray32Float:
            if let range = plane.valueRange() {
                (min, max) = (range.lowerBound, range.upperBound)
            } else {
                (min, max) = (.nan, .nan)
            }
        }
    }

    /// `setMinAndMax(min, max)`: rounded for 16-bit, cast to `Float` for
    /// 32-bit planes; `(0, 0)` resets instead.
    mutating func setMinAndMax(_ lo: Double, _ hi: Double) {
        switch plane {
        case .gray16:
            if lo == 0 && hi == 0 { return resetMinAndMax() }
            min = Double(JavaNumerics.roundToInt32(lo))
            max = Double(JavaNumerics.roundToInt32(hi))
        case .gray32Float:
            if lo == 0 && hi == 0 { return resetMinAndMax() }
            min = Double(Float(lo))
            max = Double(Float(hi))
        case .gray8, .rgb8:
            break
        }
    }

    /// `setThreshold(lower, upper, lutUpdate)` as each processor type stores
    /// it; `nil` for `NO_THRESHOLD`, which removes the threshold.
    func setThreshold(_ lower: Double, _ upper: Double) -> ThresholdLevels? {
        Threshold.manual(type, lower: lower, upper: upper)
    }

    /// `scaleAndSetThreshold(lower, upper, lutUpdate)`: 0–255 levels mapped
    /// onto the display range of a 16- or 32-bit image.
    func scaleAndSetThreshold(_ lower: Double, _ upper: Double) -> ThresholdLevels? {
        var lower = lower, upper = upper
        if type != .gray8 && lower != Self.noThreshold {
            if max > min {
                if lower == 0.0 {
                    // ImageJ avoids -Float.MAX_VALUE, which hangs its particle analyzer.
                    if type == .gray32Float { lower = Swift.min(min, -1e30) }
                } else {
                    lower = min + (lower / 255.0) * (max - min)
                }
                if upper == 255.0 {
                    if type == .gray16 {
                        upper = 65535
                    } else if type == .gray32Float {
                        upper = Swift.max(max, 1e30)
                    }
                } else {
                    upper = min + (upper / 255.0) * (max - min)
                }
            } else {
                lower = min
                upper = min
            }
        }
        return setThreshold(lower, upper)
    }

    /// `convertToByte(true)`: the pixels scaled through the display range,
    /// as `TypeConverter` does for 16-bit and `create8BitImage` for 32-bit
    /// images.
    func convertToByte() -> [UInt8] {
        switch plane {
        case .gray8(let pixels):
            return pixels
        case .gray16(let pixels):
            let lo = Int(JavaNumerics.int32(min)), hi = Int(JavaNumerics.int32(max))
            let scale = 256.0 / Double(hi - lo + 1)
            return pixels.map { pixel in
                let value = Swift.max(Int(pixel) - lo, 0)
                return UInt8(Swift.min(Int(JavaNumerics.int32(Double(value) * scale + 0.5)), 255))
            }
        case .gray32Float(let pixels):
            let scale = 255.0 / (max - min)
            return pixels.map { pixel in
                var value = Double(pixel) - min
                if value < 0.0 { value = 0.0 }
                let ivalue = Swift.min(JavaNumerics.int32(value * scale + 0.5), 255)
                return UInt8(truncatingIfNeeded: ivalue)
            }
        case .rgb8:
            preconditionFailure("RGB planes are rejected on creation")
        }
    }

    /// `setAutoThreshold(Method, darkBackground, lutUpdate)` with the
    /// processor's `histogram16`, `addOne` and `noReset` fields as given.
    /// `setAutoThreshold(String)` sets them from its keywords; on a
    /// processor it never ran on, they are all `false`.
    func setAutoThreshold(
        _ method: AutoThresholder.Method,
        darkBackground: Bool,
        histogram16: Bool,
        addOne: Bool,
        noReset: Bool
    ) -> (result: AutoThresholdResult, processor: Processor) {
        var processor = self
        let histogram: [Int32]
        if case .gray16(let pixels) = plane, histogram16 {
            histogram = Self.shortStatisticsHistogram16(pixels)
        } else {
            if type != .gray8 && !noReset { processor.resetMinAndMax() }
            histogram = Self.byteHistogram(processor.convertToByte())
        }
        let threshold = AutoThresholder.getThreshold(method, histogram, bilevelSubtractOne: addOne)
        var (lower, upper) = Threshold.sides(
            threshold, tmax: histogram.count > 256 ? 65535 : 255, darkBackground: darkBackground,
            invertedLUT: invertedLUT, addOne: addOne)
        let levels: ThresholdLevels?
        if histogram16 {
            levels = processor.setThreshold(lower, upper)
        } else {
            if lower > 255 { lower = 255 }
            levels = processor.scaleAndSetThreshold(lower, upper)
        }
        let result = AutoThresholdResult(levels: levels!, displayRange: processor.displayRange, threshold: Int(threshold))
        return (result, processor)
    }

    /// `setAutoThreshold(ISODATA2, lutUpdate)`.
    mutating func setLegacyAutoThreshold() -> AutoThresholdResult {
        if type != .gray8 { resetMinAndMax() }
        let pixels = convertToByte()
        var histogram = Self.byteHistogram(pixels)

        // ByteStatistics' mode (the first fullest bin) and its range.
        var mode = 0
        var maxCount: Int32 = 0
        for (i, count) in histogram.enumerated() where count > maxCount {
            maxCount = count
            mode = i
        }
        let statsMin = Double(histogram.firstIndex { $0 != 0 } ?? 0)
        let statsMax = Double(histogram.lastIndex { $0 != 0 } ?? 0)

        // ISODATA2 caps the mode, as AutoThresholder's Default does.
        let originalModeCount = histogram[mode]
        var maxCount2: Int32 = 0
        for i in 0..<256 where histogram[i] > maxCount2 && i != mode {
            maxCount2 = histogram[i]
        }
        if maxCount > maxCount2 &* 2 && maxCount2 != 0 {
            histogram[mode] = JavaNumerics.int32(Double(maxCount2) * 1.5)
        }
        let threshold = AutoThresholder.ijIsoData(histogram)
        histogram[mode] = originalModeCount

        // Which side? Look at the smoothed histogram's peak.
        let smoothed = HistogramBlur.blur(histogram.map { Float($0) }, sigma: 2.0, accuracy: 0.01)
        var peak: Float = 0, sum: Float = 0
        var peakBin = 0
        for (i, count) in smoothed.enumerated() {
            sum += count
            if count > peak {
                peak = count
                peakBin = i
            }
        }
        let average = Double(sum) / 256.0
        let lower: Double, upper: Double
        let thresholdAbove: Bool
        if Double(peak) / average > 1.5 {
            thresholdAbove = (statsMax - Double(peakBin)) > (Double(peakBin) - statsMin)
        } else {
            thresholdAbove = invertedLUT
        }
        if thresholdAbove {
            (lower, upper) = (Double(threshold), 255.0)
        } else {
            (lower, upper) = (0.0, Double(threshold))
        }
        let levels = scaleAndSetThreshold(lower, upper)!
        return AutoThresholdResult(levels: levels, displayRange: displayRange, threshold: Int(threshold))
    }

    /// The 256-bin histogram of 8-bit pixels (`ByteStatistics`).
    static func byteHistogram(_ pixels: [UInt8]) -> [Int32] {
        var counts = [Int32](repeating: 0, count: 256)
        for value in pixels { counts[Int(value)] &+= 1 }
        return counts
    }

    /// `ShortStatistics.histogram16` of a whole plane: ImageJ's
    /// `getHistogram2()`, which ends after the largest value (and has at
    /// least 256 bins), for planes under 250,000 pixels; all 65536 values
    /// otherwise.
    static func shortStatisticsHistogram16(_ pixels: [UInt16]) -> [Int32] {
        var counts = [Int32](repeating: 0, count: 65536)
        var largest = 0
        for value in pixels {
            counts[Int(value)] &+= 1
            largest = Swift.max(largest, Int(value))
        }
        if pixels.count < 250_000 {
            counts.removeLast(65536 - Swift.max(largest + 1, 256))
        }
        return counts
    }
}

extension Threshold {
    /// The levels `setThreshold(lower, upper)` stores on an image of
    /// `pixelType`: 8-bit images clamp them to 0–255, 16-bit images clamp
    /// them to 0–65535 and round them, 32-bit images keep them; `nil` for
    /// ImageJ's `NO_THRESHOLD` (-808080), which removes the threshold.
    public static func manual(_ pixelType: PixelType, lower: Double, upper: Double) -> ThresholdLevels? {
        if lower == Processor.noThreshold { return nil }
        var lo = lower, hi = upper
        switch pixelType {
        case .gray8:  // ByteProcessor
            if lo < 0 { lo = 0 }
            if hi > 255 { hi = 255 }
        case .gray16:  // ShortProcessor
            if lo < 0 { lo = 0 }
            if hi > 65535 { hi = 65535 }
            lo = Double(JavaNumerics.round(lo))
            hi = Double(JavaNumerics.round(hi))
        case .gray32Float, .rgb8:  // FloatProcessor
            break
        }
        return ThresholdLevels(lower: lo, upper: hi)
    }
}
