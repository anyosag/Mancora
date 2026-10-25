/// Turns planes into display pixels, reproducing ImageJ's scaling rules.
///
/// This CPU version defines the expected output; GPU renderers (Metal,
/// Direct3D) are tested against it.
///
/// Output pixels are `UInt32` values `0xAARRGGBB`. In little-endian memory
/// that is B, G, R, A byte order, which Metal (`.bgra8Unorm`), DXGI
/// (`B8G8R8A8`) and Core Graphics (`byteOrder32Little`, alpha first) take
/// without conversion.
public enum DisplayMapper {
    /// LUT indices (0–255) for every pixel of a grayscale plane.
    ///
    /// - 8-bit: ImageJ's `ByteProcessor.setMinAndMax` remap.
    /// - 16-bit: `ShortProcessor.create8BitImage`, with integer bounds and
    ///   `256 / (max - min + 1)` scaling.
    /// - 32-bit float: `FloatProcessor.create8BitImage`; NaN maps to 0.
    /// - RGB has no indices; this returns per-pixel luminance indices.
    public static func lutIndices(for plane: Plane, displayRange: ClosedRange<Double>) -> [UInt8] {
        switch plane {
        case .gray8(let pixels):
            let table = byteRemap(displayRange)
            return pixels.map { table[Int($0)] }
        case .gray16(let pixels):
            let min2 = Int(JavaNumerics.int32(displayRange.lowerBound))
            let max2 = Int(JavaNumerics.int32(displayRange.upperBound))
            let scale = 256.0 / Double(max2 - min2 + 1)
            return pixels.map { raw in
                let value = max(Int(raw) - min2, 0)
                return UInt8(clamping: min(Int(JavaNumerics.int32(Double(value) * scale + 0.5)), 255))
            }
        case .gray32Float(let pixels):
            let min2 = displayRange.lowerBound
            let scale = 255.0 / (displayRange.upperBound - min2)
            return pixels.map { raw in
                var value = Double(raw) - min2
                if value < 0 { value = 0 }
                let index = JavaNumerics.int32(value * scale + 0.5)
                return UInt8(clamping: min(Int(index), 255))
            }
        case .rgb8(let pixels):
            return pixels.map { c in
                UInt8((Int((c >> 16) & 0xFF) + Int((c >> 8) & 0xFF) + Int(c & 0xFF)) / 3)
            }
        }
    }

    /// Display pixels for one plane shown through `display`. RGB planes are
    /// passed through unchanged (alpha forced opaque).
    public static func render(_ plane: Plane, display: ChannelDisplay) -> [UInt32] {
        if case .rgb8(let pixels) = plane {
            return pixels.map { $0 | 0xFF00_0000 }
        }
        let lut = display.lut
        var palette = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { palette[i] = lut.argb(i) }
        return lutIndices(for: plane, displayRange: display.displayRange).map { palette[Int($0)] }
    }

    /// Display pixels for one (slice, frame) position: the active channel in
    /// `color`/`grayscale` mode, or all visible channels added together and
    /// clamped in `composite` mode.
    public static func render(_ image: Hyperstack, channel: Int = 0, slice: Int = 0, frame: Int = 0) -> [UInt32] {
        let dims = image.dimensions
        switch image.compositeMode {
        case .composite where dims.channels > 1 && image.pixelType != .rgb8:
            var sumR = [UInt16](repeating: 0, count: image.stack.pixelsPerPlane)
            var sumG = sumR, sumB = sumR
            for c in 0..<dims.channels where image.channels[c].isVisible {
                let display = image.channels[c]
                let plane = image.plane(channel: c, slice: slice, frame: frame)
                let indices = lutIndices(for: plane, displayRange: display.displayRange)
                for (i, index) in indices.enumerated() {
                    let k = Int(index)
                    sumR[i] += UInt16(display.lut.reds[k])
                    sumG[i] += UInt16(display.lut.greens[k])
                    sumB[i] += UInt16(display.lut.blues[k])
                }
            }
            return (0..<sumR.count).map { i in
                0xFF00_0000 | UInt32(min(sumR[i], 255)) << 16 | UInt32(min(sumG[i], 255)) << 8
                    | UInt32(min(sumB[i], 255))
            }
        case .grayscale where dims.channels > 1:
            var display = image.channels[channel]
            display.lut = .grays
            return render(image.plane(channel: channel, slice: slice, frame: frame), display: display)
        default:
            return render(image.plane(channel: channel, slice: slice, frame: frame), display: image.channels[channel])
        }
    }

    /// ImageJ's `ByteProcessor.setMinAndMax` index table.
    static func byteRemap(_ range: ClosedRange<Double>) -> [UInt8] {
        let min = range.lowerBound, max = range.upperBound
        // Java's Math.round: floor(x + 0.5).
        let roundedMin = Int(JavaNumerics.int32((min + 0.5).rounded(.down)))
        return (0..<256).map { i in
            if Double(i) < min { return 0 }
            if Double(i) > max { return 255 }
            let offset = Double(i - roundedMin)
            let index = JavaNumerics.int32(256.0 * offset / (max - min))
            return UInt8(clamping: Swift.max(0, Swift.min(Int(index), 255)))
        }
    }
}
