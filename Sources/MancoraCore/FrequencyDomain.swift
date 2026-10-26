/// ImageJ's "FHT" property of an "FFT of" image (an `ij.process.FHT`): the
/// Hartley transform behind the power spectrum, and what Process ▸ FFT ▸
/// Inverse FFT needs to rebuild the original image.
public struct FrequencyDomain: Sendable, Hashable {
    /// The transform, `size × size` floats row by row (unswapped quadrants).
    public var transform: [Float]
    /// The transform's width and height, a power of 2.
    public var size: Int
    /// The image's size before padding (`originalWidth`, `originalHeight`),
    /// 0 when it wasn't padded.
    public var originalWidth: Int
    public var originalHeight: Int
    /// The original image's type (`originalBitDepth`).
    public var originalType: PixelType
    /// The original channel's LUT (`originalColorModel`), `nil` for RGB.
    public var originalLUT: LUT?
    /// The RGB pixels whose brightness the inverse transform replaces (`rgb`).
    public var rgb: [UInt32]?
    /// The power spectrum's mean (`powerSpectrumMean`), to tell whether it was edited.
    public var powerSpectrumMean: Double

    public init(
        transform: [Float], size: Int, originalWidth: Int, originalHeight: Int, originalType: PixelType,
        originalLUT: LUT?, rgb: [UInt32]?, powerSpectrumMean: Double
    ) {
        self.transform = transform
        self.size = size
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalType = originalType
        self.originalLUT = originalLUT
        self.rgb = rgb
        self.powerSpectrumMean = powerSpectrumMean
    }
}
