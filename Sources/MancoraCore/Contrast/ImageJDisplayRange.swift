/// How ImageJ's image processors store a display range: what `getMin()` and
/// `getMax()` return after `setMinAndMax` or `resetMinAndMax`.
enum ImageJDisplayRange {
    /// The range a processor holds after `ip.setMinAndMax(min, max)`, for
    /// `min <= max`; `nil` when the processor resets instead.
    ///
    /// - 8-bit (`ByteProcessor`): both ends rounded with `Math.round`.
    /// - 16-bit (`ShortProcessor`): `(0, 0)` means `resetMinAndMax()`;
    ///   otherwise both ends rounded with `Math.round`.
    /// - 32-bit (`FloatProcessor`): `(0, 0)` means `resetMinAndMax()`;
    ///   otherwise both ends are cast to `float`.
    static func set(_ min: Double, _ max: Double, for type: PixelType) -> ClosedRange<Double>? {
        let lo: Double, hi: Double
        switch type {
        case .gray8, .rgb8:
            lo = Double(JavaNumerics.roundToInt32(min))
            hi = Double(JavaNumerics.roundToInt32(max))
        case .gray16:
            if min == 0 && max == 0 { return nil }
            lo = Double(JavaNumerics.roundToInt32(min))
            hi = Double(JavaNumerics.roundToInt32(max))
        case .gray32Float:
            if min == 0 && max == 0 { return nil }
            lo = Double(Float(min))
            hi = Double(Float(max))
        }
        // Rounding keeps lo <= hi; this only fails for NaN, which callers
        // never pass.
        return lo <= hi ? lo...hi : nil
    }

    /// The range a processor holds after `ip.resetMinAndMax()`; `nil` when
    /// ImageJ's range is NaN (a 32-bit plane with no non-NaN pixel) or the
    /// plane is empty.
    ///
    /// - 8-bit and RGB: `0...255`.
    /// - 16-bit: `ShortProcessor.findMinAndMax`, the data's range.
    /// - 32-bit: `FloatProcessor.findMinAndMax`, which skips NaN but, unlike
    ///   ``ImageStatistics``, includes ±infinity.
    static func reset(_ plane: Plane) -> ClosedRange<Double>? {
        switch plane {
        case .gray8, .rgb8:
            return 0...255
        case .gray16(let pixels):
            guard var lo = pixels.first else { return nil }
            var hi = lo
            for value in pixels {
                if value < lo { lo = value } else if value > hi { hi = value }
            }
            return Double(lo)...Double(hi)
        case .gray32Float(let pixels):
            guard let first = pixels.firstIndex(where: { !$0.isNaN }) else { return nil }
            var lo = pixels[first], hi = lo
            for value in pixels[first...] {
                if value < lo { lo = value } else if value > hi { hi = value }
            }
            return Double(lo)...Double(hi)
        }
    }
}
