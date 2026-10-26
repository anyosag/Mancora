public import MancoraCore

/// Converts single planes between pixel types: a port of ImageJ's
/// `ij.process.TypeConverter` (what `ImageProcessor.convertToByte`,
/// `convertToShort`, `convertToFloat` and `convertToRGB` call).
///
/// `displayRange` plays the role of the processor's min and max, with
/// ImageJ's rounding: integers for 16-bit data, `float` for 32-bit data, and
/// the plane's own pixel range when it is `0...0`. For a whole image, use
/// ``ImageConverter``, which also updates display ranges, LUTs and
/// calibration the way Image ▸ Type does.
public enum TypeConverter {
    /// `TypeConverter.convertToByte`.
    ///
    /// - 16-bit: `displayRange` maps to 0–255 with `256/(max-min+1)` steps,
    ///   or values above 255 clamp when `scale` is off.
    /// - 32-bit: `displayRange` maps to 0–255 (`create8BitImage`), or values
    ///   round and clamp to 0–255 when `scale` is off. NaN becomes 0.
    /// - RGB: `(byte)(r*wr + g*wg + b*wb + 0.5)`.
    /// - 8-bit planes are returned unchanged.
    public static func toGray8(
        _ plane: Plane,
        displayRange: ClosedRange<Double>,
        scale: Bool = true,
        rgbWeights: RGBWeights = .unweighted
    ) -> Plane {
        switch plane {
        case .gray8:
            return plane
        case .gray16(let p):
            if scale { return .gray8(ImageJRules.lutIndices(plane, displayRange)) }
            return .gray8(p.map { UInt8(Swift.min($0, 255)) })
        case .gray32Float(let p):
            if scale { return .gray8(ImageJRules.lutIndices(plane, displayRange)) }
            return .gray8(p.map(floatToByte))
        case .rgb8(let p):
            return .gray8(rgbToGray8(p, rgbWeights))
        }
    }

    /// `TypeConverter.convertToShort`.
    ///
    /// - 8-bit: values are widened.
    /// - 32-bit: `displayRange` maps to 0–65535 (scale 1 when it is empty),
    ///   or values round and clamp to 0–65535 when `scale` is off.
    /// - RGB: converted to 8-bit gray first, then widened.
    /// - 16-bit planes are returned unchanged.
    public static func toGray16(
        _ plane: Plane,
        displayRange: ClosedRange<Double>,
        scale: Bool = true,
        rgbWeights: RGBWeights = .unweighted
    ) -> Plane {
        switch plane {
        case .gray8(let p):
            return .gray16(p.map { UInt16($0) })
        case .gray16:
            return plane
        case .gray32Float(let p):
            let (min, max) = ImageJRules.floatMinMax(displayRange, p)
            let factor = max - min == 0 ? 1.0 : 65535.0 / (max - min)
            return .gray16(
                p.map { v in
                    var value = scale ? (Double(v) - min) * factor : Double(v)
                    if value < 0 { value = 0 }
                    if value > 65535 { value = 65535 }
                    return UInt16(truncatingIfNeeded: ImageJRules.int(value + 0.5))
                })
        case .rgb8(let p):
            return .gray16(rgbToGray8(p, rgbWeights).map { UInt16($0) })
        }
    }

    /// `TypeConverter.convertToFloat`: 8- and 16-bit values pass through the
    /// calibration function when there is one (ImageJ's calibration table,
    /// `(float)(intercept + raw*slope)`); RGB becomes `(float)(r*wr + g*wg + b*wb)`.
    /// 32-bit planes are returned unchanged.
    public static func toGray32(
        _ plane: Plane,
        calibration: Calibration.ValueFunction? = nil,
        rgbWeights: RGBWeights = .unweighted
    ) -> Plane {
        switch plane {
        case .gray8(let p):
            guard let calibration else { return .gray32Float(p.map { Float($0) }) }
            return .gray32Float(p.map { Float(calibration.apply(Double($0))) })
        case .gray16(let p):
            guard let calibration else { return .gray32Float(p.map { Float($0) }) }
            return .gray32Float(p.map { Float(calibration.apply(Double($0))) })
        case .gray32Float:
            return plane
        case .rgb8(let p):
            let w = rgbWeights
            return .gray32Float(
                p.map { c in
                    let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
                    return Float(r * w.red + g * w.green + b * w.blue)
                })
        }
    }

    /// `TypeConverter.convertToRGB`: the plane drawn through `lut` with
    /// `displayRange` (`ImageProcessor.createImage`). RGB planes are
    /// returned unchanged.
    public static func toRGB(_ plane: Plane, lut: LUT, displayRange: ClosedRange<Double>) -> Plane {
        if case .rgb8 = plane { return plane }
        return .rgb8(ImageJRules.render(plane, lut: lut, range: displayRange))
    }

    // MARK: Helpers

    /// `ByteProcessor.setPixels(channel, FloatProcessor)`: `(byte)` of the
    /// value plus 0.5, clamped to 0–255.
    @inline(__always)
    static func floatToByte(_ v: Float) -> UInt8 {
        var value = v + 0.5
        if value < 0 { value = 0 }
        if value > 255 { value = 255 }
        return UInt8(truncatingIfNeeded: ImageJRules.int(value))
    }

    /// `ShortProcessor.setPixels(channel, FloatProcessor)`.
    @inline(__always)
    static func floatToShort(_ v: Float) -> UInt16 {
        var value = v + 0.5
        if value < 0 { value = 0 }
        if value > 65535 { value = 65535 }
        return UInt16(truncatingIfNeeded: ImageJRules.int(value))
    }

    /// `TypeConverter.convertRGBToByte`.
    static func rgbToGray8(_ pixels: [UInt32], _ w: RGBWeights) -> [UInt8] {
        pixels.map { c in
            let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
            return JavaNumerics.byte(r * w.red + g * w.green + b * w.blue + 0.5)
        }
    }
}
