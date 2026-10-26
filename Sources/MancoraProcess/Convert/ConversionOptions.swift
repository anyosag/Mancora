public import MancoraCore

/// Weights for turning RGB into gray: `gray = r*red + g*green + b*blue`.
///
/// Mirrors `ColorProcessor.setWeightingFactors`, which ImageJ's
/// Edit ▸ Options ▸ Conversions sets.
public struct RGBWeights: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// ImageJ's default: a third each (`1d/3d`).
    public static let unweighted = RGBWeights(red: 1.0 / 3.0, green: 1.0 / 3.0, blue: 1.0 / 3.0)

    /// "Weighted RGB conversions": 0.299, 0.587 and 0.114 (ITU-R BT.601).
    public static let weighted = RGBWeights(red: 0.299, green: 0.587, blue: 0.114)
}

/// The settings of ImageJ's Edit ▸ Options ▸ Conversions that type
/// conversions read.
public struct ConversionOptions: Sendable, Hashable {
    /// "Scale when converting" (`ImageConverter.setDoScaling`): 16- and
    /// 32-bit data are mapped from the display range to 0–255 (or 32-bit
    /// to 0–65535) instead of being clamped.
    public var scale: Bool
    /// The RGB-to-gray weights ("Weighted RGB conversions").
    public var rgbWeights: RGBWeights

    public init(scale: Bool = true, rgbWeights: RGBWeights = .unweighted) {
        self.scale = scale
        self.rgbWeights = rgbWeights
    }
}

/// A conversion ImageJ refuses ("Supported Conversions" in `ij.plugin.Converter`).
public enum ConversionError: Error, Equatable, Sendable {
    /// ImageJ converts a single RGB image to 16-bit but not an RGB stack.
    case unsupported(from: PixelType, to: PixelType)
}
