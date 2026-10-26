import MancoraCore

/// One plane as ImageJ's `ImagePlus.getBufferedImage()` presents it to
/// ImageIO, which its PNG and GIF writers save:
///
/// - a composite (more than one channel) as the RGB image on screen;
/// - RGB as is;
/// - 8-bit with the default gray LUT as gray, with the display range
///   applied to the values; with any other LUT as indexed colour, the raw
///   values and the LUT stretched over the display range;
/// - 16- and 32-bit scaled to 8 bits through the display range
///   (`convertToByte(true)`), then as 8-bit with their LUT.
enum ImageJView {
    case gray([UInt8])
    case indexed([UInt8], palette: LUT)
    case rgb([UInt32])

    init(_ image: Hyperstack, channel: Int, slice: Int, frame: Int) {
        let dims = image.dimensions
        let c = min(max(channel, 0), dims.channels - 1)
        let z = min(max(slice, 0), dims.slices - 1)
        let t = min(max(frame, 0), dims.frames - 1)
        let plane = image.plane(channel: c, slice: z, frame: t)
        if image.pixelType == .rgb8 {
            if case .rgb8(let pixels) = plane { self = .rgb(pixels) } else { self = .rgb([]) }
            return
        }
        if dims.channels > 1 {
            self = .rgb(DisplayMapper.render(image, channel: c, slice: z, frame: t))
            return
        }
        let display = image.channels[0]
        let isDefault = display.lut.hasSameColors(as: .grays)
        if case .gray8(let pixels) = plane {
            if isDefault {
                self = .gray(DisplayMapper.lutIndices(for: plane, displayRange: display.displayRange))
            } else {
                self = .indexed(pixels, palette: Self.stretched(display.lut, over: display.displayRange))
            }
            return
        }
        let indices = DisplayMapper.lutIndices(for: plane, displayRange: display.displayRange)
        self = isDefault ? .gray(indices) : .indexed(indices, palette: display.lut)
    }

    /// The LUT as `ByteProcessor.setMinAndMax` stretches it over `range`.
    static func stretched(_ lut: LUT, over range: ClosedRange<Double>) -> LUT {
        let remap = DisplayMapper.lutIndices(for: .gray8((0...255).map { UInt8($0) }), displayRange: range)
        let r = remap.map { lut.reds[Int($0)] }, g = remap.map { lut.greens[Int($0)] }, b = remap.map { lut.blues[Int($0)] }
        return (try? LUT(name: lut.name, reds: r, greens: g, blues: b)) ?? lut
    }
}
