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
/// Not ported, because they change pixels or aren't display ranges:
/// Normalize, Equalize, "Process all slices", and RGB images. Selections
/// aren't supported yet; the whole plane is measured. For a multichannel
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
        let histogram = statistics.histogram16 ?? statistics.histogram
        let (hmin, hmax) = saturatedBins(histogram, pixelCount: statistics.pixelCount, saturated: saturated)
        guard hmax > hmin else { return nil }
        let min: Double, max: Double
        if statistics.histogram16 != nil {
            min = Double(hmin)
            max = Double(hmax)
        } else {
            min = statistics.histMin + Double(hmin) * statistics.binSize
            max = statistics.histMin + Double(hmax) * statistics.binSize
        }
        // max > min, so this never takes setMinAndMax's (0, 0) reset path.
        return ImageJDisplayRange.set(min, max, for: statistics.pixelType)
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
