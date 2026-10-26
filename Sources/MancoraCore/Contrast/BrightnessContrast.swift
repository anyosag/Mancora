/// The automatic parts of ImageJ's Image ▸ Adjust ▸ Brightness/Contrast
/// dialog (`ij.plugin.frame.ContrastAdjuster`): its Auto and Reset buttons.
///
/// RGB images are not supported (ImageJ's Auto changes their pixels), and
/// selections aren't yet; the whole plane is measured.
public enum BrightnessContrast {
    /// What one press of Auto did.
    public struct AutoResult: Sendable, Equatable {
        /// The display range ImageJ shows after the press, or `nil` when
        /// that range is NaN to NaN (a 32-bit plane with no non-NaN pixel).
        public var displayRange: ClosedRange<Double>?
        /// Whether the press found no usable range and did what Reset does
        /// instead, which also restarts the press count.
        public var didReset: Bool

        public init(displayRange: ClosedRange<Double>?, didReset: Bool) {
            self.displayRange = displayRange
            self.didReset = didReset
        }
    }

    /// The Auto button's state for one image: ImageJ's
    /// `ContrastAdjuster.autoThreshold`.
    ///
    /// Each press saturates more pixels than the last. The display range
    /// runs from the first to the last histogram bin holding more than
    /// `pixelCount / divisor` pixels, where the divisor is 5000 on the first
    /// press and halves on each later one (2500, 1250, … 19, 9). Bins with
    /// more than a tenth of all pixels never count, so a large uniform
    /// background doesn't pin the range. When no bin qualifies, the press
    /// resets the display range like the Reset button and the count
    /// restarts. That always happens by the tenth press: its divisor of 9
    /// would need a bin with more than a ninth but at most a tenth of the
    /// pixels.
    ///
    /// Keep one value per image. ImageJ also restarts the count (call
    /// ``reset()``) when Reset is pressed, and when the dialog sees a
    /// different image, pixel type or stack position.
    public struct AutoState: Sendable, Hashable {
        /// ImageJ's `AUTO_THRESHOLD`: the divisor of the first press.
        public static let firstDivisor = 5000

        /// The divisor the last press used, or 0 before the first press and
        /// after a reset.
        public private(set) var autoThreshold: Int

        public init() {
            autoThreshold = 0
        }

        /// Restarts the press count.
        public mutating func reset() {
            autoThreshold = 0
        }

        /// One press of Auto on `plane`: `ContrastAdjuster.autoAdjust` (1.54p
        /// lines 815–864), falling back to `reset` (lines 588–605).
        ///
        /// Throws, without counting the press, for RGB planes.
        public mutating func press(_ plane: Plane) throws(ImageStatistics.Error) -> AutoResult {
            let stats = try ImageStatistics(plane)
            let limit = stats.pixelCount / 10
            autoThreshold = autoThreshold < 10 ? Self.firstDivisor : autoThreshold / 2
            let threshold = stats.pixelCount / autoThreshold
            // ImageJ walks the 256-bin histogram (even for 16-bit data),
            // skipping bins above the limit.
            let histogram = stats.histogram
            func qualifies(_ bin: Int) -> Bool {
                let count = histogram[bin]
                return count <= limit && count > threshold
            }
            var hmin = 0
            while !qualifies(hmin) && hmin < histogram.count - 1 { hmin += 1 }
            var hmax = histogram.count - 1
            while !qualifies(hmax) && hmax > 0 { hmax -= 1 }

            guard hmax >= hmin else {
                autoThreshold = 0
                return AutoResult(displayRange: BrightnessContrast.resetRange(for: plane), didReset: true)
            }
            var min = stats.histMin + Double(hmin) * stats.binSize
            var max = stats.histMin + Double(hmax) * stats.binSize
            if min == max {
                min = stats.min
                max = stats.max
            }
            // A (0, 0) range makes 16- and 32-bit processors reset; that
            // can't arise here, since a constant plane always takes the
            // branch above.
            let range = ImageJDisplayRange.set(min, max, for: plane.pixelType) ?? ImageJDisplayRange.reset(plane)
            return AutoResult(displayRange: range, didReset: false)
        }
    }

    /// The display range the Reset button sets, or `nil` when ImageJ's
    /// range is NaN to NaN (a 32-bit plane with no non-NaN pixel).
    ///
    /// - 8-bit: `0...255`.
    /// - 16-bit: the data's range (`ImagePlus.resetDisplayRange` with the
    ///   default "Automatic" 16-bit range; the fixed 8- to 16-bit ranges of
    ///   Edit ▸ Options ▸ Appearance aren't modeled).
    /// - 32-bit: the range of all non-NaN values, including ±infinity
    ///   (`FloatProcessor.findMinAndMax`).
    public static func resetRange(for plane: Plane) -> ClosedRange<Double>? {
        ImageJDisplayRange.reset(plane)
    }
}
