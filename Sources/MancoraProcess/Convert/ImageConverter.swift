public import MancoraCore

/// Image ▸ Type: converts a whole image to another pixel type, changing its
/// display ranges, LUTs and calibration the way ImageJ does.
///
/// A port of `ij.plugin.Converter` and the classes it calls:
/// `ij.process.ImageConverter` for single images, `ij.process.StackConverter`
/// for stacks and hyperstacks, and `ij.plugin.RGBStackConverter` for
/// multichannel images converted to RGB. ImageJ's "Calibrate" conversion
/// option and inverting-LUT preference (both off by default) are not
/// modeled.
public enum ImageConverter {
    /// Converts `image` to `type`.
    ///
    /// - 16- and 32-bit to 8-bit maps each channel's display range to 0–255
    ///   (or clamps, with `options.scale` off); 32-bit to 16-bit maps the
    ///   display range to 0–65535 (or rounds and clamps).
    /// - RGB to gray uses `options.rgbWeights`.
    /// - 8-bit with a pseudocolor LUT to 8-bit swaps in a gray LUT; with any
    ///   other color LUT, the colors are converted to gray.
    /// - To RGB, every plane is drawn through its LUT and display range; a
    ///   multichannel image becomes the blend of its visible channels in
    ///   composite mode, or (in color and grayscale mode) the first channel,
    ///   one RGB plane per slice and frame. A multichannel image without
    ///   slices or frames in color or grayscale mode gives one RGB plane per
    ///   channel, as ImageJ does.
    /// - Calibration follows `Calibration.setImage`: the value function is
    ///   dropped when the bit depth changes, and 8- and 16-bit values pass
    ///   through it on the way to 32-bit (so signed 16-bit data becomes
    ///   −32768…32767).
    ///
    /// - Throws: ``ConversionError/unsupported(from:to:)`` for an RGB stack
    ///   to 16-bit, which ImageJ refuses.
    public static func convert(
        _ image: Hyperstack,
        to type: PixelType,
        options: ConversionOptions = ConversionOptions()
    ) throws(ConversionError) -> Hyperstack {
        switch type {
        case .gray8: return toGray8(image, options)
        case .gray16: return try toGray16(image, options)
        case .gray32Float: return toGray32(image, options)
        case .rgb8: return toRGB(image)
        }
    }

    // MARK: 8-bit (ImageConverter.convertToGray8, StackConverter.convertToGray8)

    static func toGray8(_ image: Hyperstack, _ options: ConversionOptions) -> Hyperstack {
        let src = image.pixelType
        let planes = image.stack.planes
        let dims = image.dimensions
        var channels = image.channels
        let lut0 = channels[0].lut, range0 = channels[0].displayRange
        let composite = ImageJRules.isComposite(image)
        let w = options.rgbWeights
        let gray8Display = ChannelDisplay(lut: .grays, displayRange: 0...255)

        func output(_ planes: [Plane], _ channels: [ChannelDisplay]) -> Hyperstack {
            ImageJRules.image(
                like: image, planes: planes, labels: image.stack.labels, dimensions: dims, channels: channels,
                calibration: ImageJRules.calibration(image.calibration, from: src, to: .gray8))
        }
        func grayLUT(for lut: LUT) -> LUT { ImageJRules.isInvertedLUT(lut) ? ImageJRules.invertedGrays : .grays }
        func viaRGB(_ plane: Plane) -> Plane {
            .gray8(TypeConverter.rgbToGray8(ImageJRules.render(plane, lut: lut0, range: range0), w))
        }

        if planes.count == 1 {
            switch src {
            case .gray16, .gray32Float:
                channels[0].displayRange = 0...255
                return output([TypeConverter.toGray8(planes[0], displayRange: range0, scale: options.scale)], channels)
            case .rgb8:
                return output([TypeConverter.toGray8(planes[0], displayRange: range0, rgbWeights: w)], [gray8Display])
            case .gray8:
                if ImageJRules.isPseudoColorLUT(lut0) {
                    channels[0].lut = grayLUT(for: lut0)
                    return output(planes, channels)
                }
                return output([viaRGB(planes[0])], [gray8Display])
            }
        }

        let colorLUT = src != .rgb8 && ImageJRules.isColorLUT(lut0)
        if src == .gray8, colorLUT, !composite, ImageJRules.isPseudoColorLUT(lut0) {
            channels[0].lut = grayLUT(for: lut0)
            return output(planes, channels)
        }
        if !composite, src == .rgb8 || colorLUT {
            // StackConverter.convertRGBToGray8
            let out = planes.map { plane -> Plane in
                if case .gray8 = plane { return viaRGB(plane) }
                return TypeConverter.toGray8(plane, displayRange: range0, scale: options.scale, rgbWeights: w)
            }
            let lut: LUT = src == .gray16 || src == .gray32Float ? lut0 : .grays
            return output(out, Array(repeating: ChannelDisplay(lut: lut, displayRange: 0...255), count: dims.channels))
        }

        let c = dims.channels
        let out = planes.enumerated().map { k, plane in
            TypeConverter.toGray8(
                plane, displayRange: composite ? channels[k % c].displayRange : range0, scale: options.scale)
        }
        for i in channels.indices where !composite || options.scale {
            channels[i].displayRange = 0...255
        }
        return output(out, channels)
    }

    // MARK: 16-bit (ImageConverter.convertToGray16, StackConverter.convertToGray16)

    static func toGray16(_ image: Hyperstack, _ options: ConversionOptions) throws(ConversionError) -> Hyperstack {
        let src = image.pixelType
        if src == .gray16 { return image }
        let planes = image.stack.planes
        let dims = image.dimensions
        var channels = image.channels
        let range0 = channels[0].displayRange

        func output(_ planes: [Plane], _ channels: [ChannelDisplay]) -> Hyperstack {
            ImageJRules.image(
                like: image, planes: planes, labels: image.stack.labels, dimensions: dims, channels: channels,
                calibration: ImageJRules.calibration(image.calibration, from: src, to: .gray16))
        }

        if planes.count == 1 {
            let out = TypeConverter.toGray16(
                planes[0], displayRange: range0, scale: options.scale, rgbWeights: options.rgbWeights)
            if src == .rgb8 { channels[0].lut = .grays }
            channels[0].displayRange = ImageJRules.resetRange(out)
            return output([out], channels)
        }
        if src == .rgb8 { throw .unsupported(from: .rgb8, to: .gray16) }

        let c = dims.channels
        let scale = src == .gray32Float && options.scale
        let out = planes.enumerated().map { k, plane in
            TypeConverter.toGray16(plane, displayRange: c > 1 ? channels[k % c].displayRange : range0, scale: scale)
        }
        if ImageJRules.isComposite(image) {
            if scale { for i in channels.indices { channels[i].displayRange = 0...65535 } }
        } else {
            channels[0].displayRange = scale ? 0...65535 : ImageJRules.resetRange(out[0])
        }
        return output(out, channels)
    }

    // MARK: 32-bit (ImageConverter.convertToGray32, StackConverter.convertToGray32)

    static func toGray32(_ image: Hyperstack, _ options: ConversionOptions) -> Hyperstack {
        let src = image.pixelType
        if src == .gray32Float { return image }
        let planes = image.stack.planes
        let dims = image.dimensions
        let composite = ImageJRules.isComposite(image)
        let function = image.calibration.valueFunction
        var channels = image.channels
        if src == .rgb8 {
            channels = Array(repeating: ChannelDisplay(lut: .grays, displayRange: 0...255), count: dims.channels)
        }

        // ImagePlus.getDisplayRangeMin/Max, then Calibration.getCValue.
        let shown: (min: Double, max: Double)
        if src == .rgb8 {
            shown = (0, 255)
        } else if composite {
            shown = ImageJRules.reportedRange(image.channels[0].displayRange, type: src)
        } else {
            let r = ImageJRules.setRange(image.channels[0].displayRange, on: planes[0])
            shown = (r.lowerBound, r.upperBound)
        }
        let cmin = function?.apply(shown.min) ?? shown.min
        let cmax = function?.apply(shown.max) ?? shown.max

        let out = planes.map { TypeConverter.toGray32($0, calibration: function, rgbWeights: options.rgbWeights) }
        let output = { (channels: [ChannelDisplay]) in
            ImageJRules.image(
                like: image, planes: out, labels: image.stack.labels, dimensions: dims, channels: channels,
                calibration: ImageJRules.calibration(image.calibration, from: src, to: .gray32Float))
        }
        // IJ.setMinAndMax(imp, cmin, cmax) on the current (first) channel.
        func setCurrentRange(_ lo: Double, _ hi: Double) {
            if composite {
                channels[0].displayRange = ImageJRules.closed(Swift.min(lo, hi), Swift.max(lo, hi))
            } else {
                channels[0].displayRange = ImageJRules.setRange(
                    ImageJRules.closed(Swift.min(lo, hi), Swift.max(lo, hi)), on: out[0])
            }
        }

        if planes.count == 1 {
            setCurrentRange(cmin, cmax)
            return output(channels)
        }

        // ImagePlus.setStack resets the display ranges (CompositeImage.resetDisplayRanges).
        if composite {
            for i in channels.indices where i < out.count {
                channels[i].displayRange = ImageJRules.resetRange(out[i])
            }
        } else {
            channels[0].displayRange = ImageJRules.resetRange(out[0])
        }
        if composite, ImageJRules.isHyperStack(dims), function == nil {
            for i in channels.indices { channels[i].displayRange = image.channels[i].displayRange }
        } else if function == nil {
            setCurrentRange(shown.min, shown.max)
        }
        setCurrentRange(cmin, cmax)
        return output(channels)
    }

    // MARK: RGB (ImageConverter.convertToRGB, StackConverter.convertToRGB, RGBStackConverter)

    static func toRGB(_ image: Hyperstack) -> Hyperstack {
        let src = image.pixelType
        if src == .rgb8 { return image }
        let dims = image.dimensions
        let calibration = ImageJRules.calibration(image.calibration, from: src, to: .rgb8)
        let rgbDisplay = ChannelDisplay(lut: .grays, displayRange: 0...255)

        func output(_ planes: [Plane], _ labels: [String?]?, _ dims: HyperstackDimensions) -> Hyperstack {
            ImageJRules.image(
                like: image, planes: planes, labels: labels, dimensions: dims, channels: [rgbDisplay],
                calibration: calibration, compositeMode: .color)
        }

        guard ImageJRules.isComposite(image) else {
            let display = image.channels[0]
            let planes = image.stack.planes.map {
                TypeConverter.toRGB($0, lut: display.lut, displayRange: display.displayRange)
            }
            return output(planes, image.stack.labels, dims)
        }

        // RGBStackConverter.compositeToRGB
        let blend = image.compositeMode == .composite
        if dims.channels == image.stack.count {
            if blend {
                return output([.rgb8(CompositeRenderer.blend(image, slice: 0, frame: 0))], nil, HyperstackDimensions())
            }
            let planes = (0..<dims.channels).map {
                Plane.rgb8(CompositeRenderer.channel(image, channel: $0, slice: 0, frame: 0))
            }
            return output(planes, nil, HyperstackDimensions(slices: dims.channels))
        }
        var planes: [Plane] = []
        planes.reserveCapacity(dims.slices * dims.frames)
        for t in 0..<dims.frames {
            for z in 0..<dims.slices {
                planes.append(
                    .rgb8(
                        blend
                            ? CompositeRenderer.blend(image, slice: z, frame: t)
                            : CompositeRenderer.channel(image, channel: 0, slice: z, frame: t)))
            }
        }
        return output(planes, nil, HyperstackDimensions(slices: dims.slices, frames: dims.frames))
    }
}

/// How ImageJ draws a multichannel image (`CompositeImage.updateImage`).
enum CompositeRenderer {
    /// Composite mode: the visible channels drawn through their LUTs and
    /// display ranges, added and clamped per color component
    /// (`ImageProcessor.updateComposite`, sum projection).
    static func blend(_ image: Hyperstack, slice: Int, frame: Int) -> [UInt32] {
        let n = image.width * image.height
        var red = [UInt16](repeating: 0, count: n), green = red, blue = red
        for c in 0..<image.dimensions.channels where image.channels[c].isVisible {
            let display = image.channels[c]
            let plane = image.plane(channel: c, slice: slice, frame: frame)
            let indices = ImageJRules.lutIndices(plane, display.displayRange)
            let lut = display.lut
            for i in 0..<n {
                let k = Int(indices[i])
                red[i] += UInt16(lut.reds[k])
                green[i] += UInt16(lut.greens[k])
                blue[i] += UInt16(lut.blues[k])
            }
        }
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = 0xFF00_0000 | UInt32(min(red[i], 255)) << 16 | UInt32(min(green[i], 255)) << 8
                | UInt32(min(blue[i], 255))
        }
        return out
    }

    /// Color or grayscale mode: one channel through its own LUT (or gray).
    static func channel(_ image: Hyperstack, channel: Int, slice: Int, frame: Int) -> [UInt32] {
        let display = image.channels[channel]
        let lut = image.compositeMode == .grayscale ? LUT.grays : display.lut
        return ImageJRules.render(
            image.plane(channel: channel, slice: slice, frame: frame), lut: lut, range: display.displayRange)
    }
}
