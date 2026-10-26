/// Process ▸ Enhance Contrast, as a display-range change: ImageJ's
/// `ij.plugin.ContrastEnhancer.stretchHistogram` with Normalize and
/// Equalize off.
///
/// The display range is stretched so that `saturated` percent of the pixels
/// (half at each end) fall outside it. Values are taken from the histogram
/// in ``ImageStatistics``: for 16-bit data, the full 65536-value histogram;
/// otherwise the 256-bin one, mapped back with `histMin + bin * binSize`.
/// The result is what the image's processor then holds: rounded to integers
/// for 8- and 16-bit data, cast to `float` for 32-bit data.
///
/// ``normalized(_:min:max:)`` is Normalize's pixel mapping. Not ported:
/// Equalize and RGB images. The statistics passed in decide which pixels
/// are measured (a selection's, or the whole plane's). For a multichannel
/// 32-bit `CompositeImage`, ImageJ keeps the unrounded `double` range in
/// the channel's LUT; this returns the `float`-rounded range a single image
/// holds.
public enum ContrastEnhancer {
    /// ImageJ's default, `saturated=0.35` (percent).
    public static let defaultSaturated = 0.35

    /// The display range Enhance Contrast sets for one plane, or `nil` when
    /// ImageJ leaves the range unchanged: all counted pixels in one bin, or
    /// a 32-bit plane with no finite values.
    public static func displayRange(
        for plane: Plane,
        saturated: Double = defaultSaturated
    ) throws(ImageStatistics.Error) -> ClosedRange<Double>? {
        displayRange(for: try ImageStatistics(plane), saturated: saturated)
    }

    /// The display range Enhance Contrast sets with "Use stack histogram":
    /// the same for every plane, computed from ``ImageStatistics/init(stack:)``.
    public static func displayRange(
        forStack stack: ImageStack,
        saturated: Double = defaultSaturated
    ) throws(ImageStatistics.Error) -> ClosedRange<Double>? {
        displayRange(for: try ImageStatistics(stack: stack), saturated: saturated)
    }

    /// The display range Enhance Contrast sets from precomputed statistics:
    /// `stretchHistogram(ip, saturated, stats)`.
    public static func displayRange(
        for statistics: ImageStatistics,
        saturated: Double = defaultSaturated
    ) -> ClosedRange<Double>? {
        guard let (min, max) = limits(for: statistics, saturated: saturated) else { return nil }
        // max > min, so this never takes setMinAndMax's (0, 0) reset path.
        return ImageJDisplayRange.set(min, max, for: statistics.pixelType)
    }

    /// The values `stretchHistogram` stretches between, before a processor
    /// stores them as its display range (or Normalize maps them to the full
    /// range); `nil` when ImageJ changes nothing.
    public static func limits(for statistics: ImageStatistics, saturated: Double) -> (min: Double, max: Double)? {
        let histogram = statistics.histogram16 ?? statistics.histogram
        let (hmin, hmax) = saturatedBins(histogram, pixelCount: statistics.pixelCount, saturated: saturated)
        guard hmax > hmin else { return nil }
        if statistics.histogram16 != nil { return (Double(hmin), Double(hmax)) }
        return (statistics.histMin + Double(hmin) * statistics.binSize, statistics.histMin + Double(hmax) * statistics.binSize)
    }

    /// `ContrastEnhancer.normalize`: `min...max` stretched to the type's full
    /// range (0–255, 0–65535, or 0–1 for 32-bit data) through ImageJ's
    /// table, values outside clipped. RGB planes are returned unchanged.
    public static func normalized(_ plane: Plane, min: Double, max: Double) -> Plane {
        func table(_ size: Int, _ top: Int) -> [Int] {
            (0..<size).map { i in
                let v = Double(i)
                if v <= min { return 0 }
                if v >= max { return top }
                return Int(JavaNumerics.int32((v - min) / (max - min) * Double(top)))
            }
        }
        switch plane {
        case .gray8(let p):
            let lut = table(256, 255)
            return .gray8(p.map { UInt8(truncatingIfNeeded: lut[Int($0)]) })
        case .gray16(let p):
            let lut = table(65536, 65535)
            return .gray16(p.map { UInt16(truncatingIfNeeded: lut[Int($0)]) })
        case .gray32Float(let p):
            // normalizeFloat
            let scale = max > min ? 1.0 / (max - min) : 1.0
            return .gray32Float(p.map { value in
                var v = Double(value) - min
                if v < 0 { v = 0 }
                v *= scale
                if v > 1 { v = 1 }
                return Float(v)
            })
        case .rgb8:
            return plane
        }
    }

    /// `ContrastEnhancer.getMinAndMax`: the first and last bins at which
    /// more than the saturated pixel count has accumulated, counting from
    /// each end.
    ///
    /// The count is `(int)(pixelCount * saturated / 200)`, so with the
    /// default 0.35% and fewer than 572 pixels, no pixels saturate.
    static func saturatedBins(_ histogram: [Int], pixelCount: Int, saturated: Double) -> (lower: Int, upper: Int) {
        let threshold = saturated > 0 ? Int(JavaNumerics.int32(Double(pixelCount) * saturated / 200)) : 0
        var i = -1
        var count = 0
        repeat {
            i += 1
            count += histogram[i]
        } while count <= threshold && i < histogram.count - 1
        let lower = i
        i = histogram.count
        count = 0
        repeat {
            i -= 1
            count += histogram[i]
        } while count <= threshold && i > 0
        return (lower, i)
    }
}
