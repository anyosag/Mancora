/// The pixel types Mancora stores, matching ImageJ's four core types.
///
/// Other on-disk types are converted on import: signed 16-bit is stored
/// unsigned with a `-32768` value calibration (as ImageJ does), and 32-bit
/// integers become `gray32Float`.
public enum PixelType: String, Sendable, Hashable, CaseIterable {
    /// 8-bit unsigned grayscale, displayed through a LUT.
    case gray8
    /// 16-bit unsigned grayscale, displayed through a LUT.
    case gray16
    /// 32-bit IEEE float grayscale, displayed through a LUT.
    case gray32Float
    /// 8 bits per channel RGB, packed as `0xAARRGGBB` in a `UInt32`.
    case rgb8

    /// Bytes one pixel occupies in memory.
    public var bytesPerPixel: Int {
        switch self {
        case .gray8: 1
        case .gray16: 2
        case .gray32Float, .rgb8: 4
        }
    }

    /// The bit depth ImageJ reports for this type (24 for RGB).
    public var bitDepth: Int {
        switch self {
        case .gray8: 8
        case .gray16: 16
        case .gray32Float: 32
        case .rgb8: 24
        }
    }

    /// Whether pixels are shown through a lookup table.
    public var usesLUT: Bool { self != .rgb8 }
}
