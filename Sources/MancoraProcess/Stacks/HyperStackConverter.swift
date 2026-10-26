public import MancoraCore

/// Image ▸ Hyperstacks ▸ Stack to Hyperstack and Hyperstack to Stack: a
/// port of ImageJ's `ij.plugin.HyperStackConverter`.
public enum HyperStackConverter {
    /// The "Order" choices: how the stack's planes are laid out.
    public static let orders = ["xyczt(default)", "xyctz", "xyzct", "xyztc", "xytcz", "xytzc"]

    /// `shuffle`: planes (and labels) laid out in `order` (an index into
    /// ``orders``) put into ImageJ's channel, slice, frame order.
    public static func shuffled(_ stack: ImageStack, _ dims: HyperstackDimensions, order: Int) -> ImageStack {
        guard order != 0 else { return stack }
        let (c, z, t) = (dims.channels, dims.slices, dims.frames)
        // first, middle and last: which of (c, z, t) varies fastest in the source.
        let axes: [Int]
        switch order {
        case 1: axes = [0, 2, 1]  // xyctz
        case 2: axes = [1, 0, 2]  // xyzct
        case 3: axes = [1, 2, 0]  // xyztc
        case 4: axes = [2, 0, 1]  // xytcz
        default: axes = [2, 1, 0]  // xytzc
        }
        let counts = [c, z, t]
        var planes = stack.planes
        var labels = stack.labels
        let source = stack.planes, sourceLabels = stack.labels
        for f in 0..<t {
            for s in 0..<z {
                for ch in 0..<c {
                    let index = [ch, s, f]
                    let dst = ch + s * c + f * c * z
                    let src = index[axes[0]] + index[axes[1]] * counts[axes[0]] + index[axes[2]] * counts[axes[0]] * counts[axes[1]]
                    planes[dst] = source[src]
                    labels[dst] = sourceLabels[src]
                }
            }
        }
        return ImageJRules.stack(planes, width: stack.width, height: stack.height, labels: labels)
    }

    /// `convertStackToHS` for a grayscale stack (or an RGB one kept in one
    /// channel): `dims` in `order`. Several channels make a new composite in
    /// `mode` whose channels show ImageJ's colors and the image's display
    /// range; the image keeps its calibration, Info, properties, selection
    /// and overlay.
    public static func toHyperstack(
        _ image: Hyperstack, dimensions dims: HyperstackDimensions, order: Int, mode: CompositeMode
    ) -> Hyperstack {
        let stack = shuffled(image.stack, dims, order: order)
        let channels: [ChannelDisplay]
        var compositeMode = image.compositeMode
        if dims.channels > 1 && image.pixelType != .rgb8 {
            let range = image.channels[0].displayRange
            channels = (0..<dims.channels).map { ChannelDisplay(lut: CompositeConverter.channelLUT($0, of: dims.channels), displayRange: range) }
            compositeMode = dims.channels > 8 && mode == .composite ? .color : mode
        } else {
            channels = Array(repeating: image.channels[0], count: dims.channels)
        }
        return ImageJRules.image(
            like: image, planes: stack.planes, labels: stack.labels, dimensions: dims, channels: channels,
            calibration: image.calibration, compositeMode: compositeMode)
    }

    /// `convertHSToStack` for a composite of channels only: no longer a
    /// composite, every channel is shown through a gray LUT with the
    /// current channel's display range.
    public static func toStack(_ image: Hyperstack, channel: Int) -> Hyperstack {
        let range = ImageJRules.setRange(image.channels[Swift.min(channel, image.channels.count - 1)].displayRange, on: image.stack[0])
        return ImageJRules.image(
            like: image, planes: image.stack.planes, labels: image.stack.labels, dimensions: image.dimensions,
            channels: Array(repeating: ChannelDisplay(lut: .grays, displayRange: range), count: image.dimensions.channels),
            calibration: image.calibration, compositeMode: .color)
    }
}

/// Image ▸ Hyperstacks ▸ Re-order Hyperstack: a port of Fiji's
/// `fiji.stacks.Hyperstack_rearranger` (Fiji_Plugins, GPL-2.0-or-later).
public enum HyperstackRearranger {
    /// The dialog's choices, by dimension: channels, slices, frames.
    public static let choices = ["Channels (c)", "Slices (z)", "Frames (t)"]

    /// `reorderHyperstack(imp, targetChannels, targetSlices, targetFrames)`:
    /// the new channels run along the dimension `channels` names (0, 1 or
    /// 2 for channels, slices or frames), and likewise for slices and
    /// frames. The result is a new composite in composite mode (color
    /// beyond eight channels) with the title, calibration and labels; it
    /// keeps the channel LUTs and ranges when channels stay channels, and
    /// otherwise shows ImageJ's channel colors with the current channel's range.
    public static func reorder(_ image: Hyperstack, channels tc: Int, slices tz: Int, frames tt: Int, current: Int = 0) -> Hyperstack {
        let d = image.dimensions
        let old = [d.channels, d.slices, d.frames]
        let (c2, z2, t2) = (old[tc], old[tz], old[tt])
        var planes: [Plane] = []
        var labels: [String?] = []
        var index = [0, 0, 0]
        for t in 0..<t2 {
            for z in 0..<z2 {
                for c in 0..<c2 {
                    index[tc] = c
                    index[tz] = z
                    index[tt] = t
                    let i = d.planeIndex(channel: index[0], slice: index[1], frame: index[2])
                    planes.append(image.stack[i])
                    labels.append(image.stack.labels[i])
                }
            }
        }
        let channels: [ChannelDisplay]
        if tc == 0 && ImageJRules.isComposite(image) {
            channels = image.channels
        } else {
            let range = image.channels[Swift.min(current, image.channels.count - 1)].displayRange
            channels = (0..<c2).map { ChannelDisplay(lut: CompositeConverter.channelLUT($0, of: c2), displayRange: range) }
        }
        let stack = ImageJRules.stack(planes, width: image.width, height: image.height, labels: labels)
        do {
            return try Hyperstack(
                title: image.title, stack: stack, dimensions: HyperstackDimensions(channels: c2, slices: z2, frames: t2),
                calibration: image.calibration, channels: channels, compositeMode: c2 > 8 ? .color : .composite)
        } catch {
            preconditionFailure("Re-order Hyperstack built an invalid image: \(error)")
        }
    }
}

/// Image ▸ Color ▸ Invert LUTs: a port of ImageJ's `InvertAllLuts` macro
/// (by Kevin Terretaz and Nicolás De Francesco), which
/// `SimpleCommands("invert")` runs.
public enum LUTInverter {
    /// One LUT made inverting (or back): each entry's complement has its
    /// hue turned half way round, keeping saturation and brightness, so
    /// black to red becomes white to red.
    public static func inverted(_ lut: LUT) -> LUT {
        var reds = [UInt8](repeating: 0, count: 256), greens = reds, blues = reds
        for i in 0..<256 {
            var (h, s, v) = hsv(255 - Double(lut.reds[i]), 255 - Double(lut.greens[i]), 255 - Double(lut.blues[i]))
            h = (h + 128).truncatingRemainder(dividingBy: 256)
            let (r, g, b) = rgb(h, s, v)
            (reds[i], greens[i], blues[i]) = (byte(r), byte(g), byte(b))
        }
        do {
            return try LUT(name: lut.name, reds: reds, greens: greens, blues: blues)
        } catch {
            preconditionFailure("Invert LUTs built an invalid LUT: \(error)")
        }
    }

    /// The macro's `round()` stored by `setLut` as a byte.
    static func byte(_ x: Double) -> UInt8 { UInt8(truncatingIfNeeded: ImageJRules.round(x)) }

    /// The macro's `HSV_from_RGB`, on a 0–256 scale.
    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let v = max(r, max(g, b))
        let c = v - min(r, min(g, b))
        var h = 0.0
        if c > 0 {
            if v == r { h = 256.0 / 6 * (0 + g - b) / c }
            if v == g { h = 256.0 / 6 * (2 + (b - r) / c) }
            if v == b { h = 256.0 / 6 * (4 + (r - g) / c) }
        }
        h = (h + 256).truncatingRemainder(dividingBy: 256)
        let s = v > 0 ? c / v * 256 : 0
        return (h, s, v)
    }

    /// The macro's `RGB_from_HSV`.
    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        func component(_ n: Double) -> Double {
            let k = (n + h / 256 * 6).truncatingRemainder(dividingBy: 6)
            return v - v * s / 256 * max(0, min(k, min(4 - k, 1)))
        }
        return (component(5), component(3), component(1))
    }

    /// The macro's switch of the `CompositeProjection` property once the
    /// LUTs are inverted, given whether the first channel's now inverts.
    public static func projection(after mode: String?, inverting: Bool) -> String? {
        let mode = mode ?? ""
        if inverting && (mode == "Min" || mode == "Invert") { return mode }
        if !inverting && (mode == "Sum" || mode == "Max") { return mode }
        switch mode {
        case "Invert": return "Sum"
        case "Min": return "Max"
        case "Max": return "Min"
        default: return "Invert"
        }
    }

    /// `ImageProcessor.isInvertedLut`.
    public static func isInverting(_ lut: LUT) -> Bool { ImageJRules.isInvertedLUT(lut) }
}

/// Image ▸ Color ▸ Make Composite: a port of ImageJ's
/// `ij.plugin.CompositeConverter` and the `CompositeImage` constructor.
public enum CompositeConverter {
    /// `CompositeImage.setupLuts`: red, green, blue, gray, cyan, magenta,
    /// yellow, gray, and white for every channel of an image with more than eight.
    static func channelLUT(_ c: Int, of channels: Int) -> LUT {
        channels > 8 ? .grays : Hyperstack.defaultChannelLUT(c)
    }

    /// `new CompositeImage(imp, mode)` for a grayscale stack whose
    /// dimensions are `dims` (the channels, by now, decided): a new
    /// composite with ImageJ's channel colors, each showing the image's
    /// display range or, for 16- and 32-bit data, its first plane's pixel
    /// range (`resetDisplayRanges`). More than eight channels can't be
    /// shown in composite mode, so they are shown in color.
    public static func composite(
        _ image: Hyperstack, dimensions dims: HyperstackDimensions, mode: CompositeMode, labels: [String?]? = nil,
        resetRanges: Bool
    ) -> Hyperstack {
        let range = image.channels[0].displayRange
        let channels = (0..<dims.channels).map { c in
            ChannelDisplay(
                lut: channelLUT(c, of: dims.channels),
                displayRange: resetRanges && c < image.stack.count ? ImageJRules.resetRange(image.stack[c]) : range)
        }
        return ImageJRules.image(
            like: image, planes: image.stack.planes, labels: labels ?? image.stack.labels, dimensions: dims,
            channels: channels, calibration: image.calibration,
            compositeMode: dims.channels > 8 && mode == .composite ? .color : mode)
    }

    /// `new CompositeImage(rgb, COMPOSITE)` for a single RGB image: its red,
    /// green and blue as a three-channel composite.
    public static func rgbComposite(_ image: Hyperstack) -> Hyperstack {
        let channels = (0..<3).map { ChannelDisplay(lut: Hyperstack.defaultChannelLUT($0), displayRange: 0...255) }
        return ImageJRules.image(
            like: image, planes: ColorSpaceConverter.rgbPlanes(image.stack[0]), labels: ["Red", "Green", "Blue"],
            dimensions: HyperstackDimensions(channels: 3), channels: channels,
            calibration: ImageJRules.calibration(image.calibration, from: .rgb8, to: .gray8), compositeMode: .composite)
    }
}

/// Image ▸ Color ▸ Stack to RGB (and RGB Color for composites): a port of
/// ImageJ's `ij.plugin.RGBStackConverter`.
public enum RGBStackConverter {
    /// How a composite is drawn at one position: its visible channels
    /// blended in composite mode, otherwise `channel` through its LUT (gray
    /// in grayscale mode). An 8-bit composite marked `HSB_Stack` with three
    /// channels is converted from hue, saturation and brightness instead.
    static func rendered(_ image: Hyperstack, channel: Int, slice: Int, frame: Int) -> Plane {
        if image.properties["HSB_Stack"] != nil, image.dimensions.channels == 3, image.pixelType == .gray8 {
            return ColorSpaceConverter.rgb(hsb: (0..<3).map { image.plane(channel: $0, slice: slice, frame: frame) })
        }
        if image.compositeMode == .composite { return .rgb8(CompositeRenderer.blend(image, slice: slice, frame: frame)) }
        return .rgb8(CompositeRenderer.channel(image, channel: channel, slice: slice, frame: frame))
    }

    /// `compositeImageToRGB`, for a composite of channels only: in composite
    /// mode one RGB image of the blended channels; otherwise one RGB plane
    /// per channel. The new image, titled `<title> (RGB)`, keeps the
    /// calibration, Info and properties.
    public static func channelsToRGB(_ image: Hyperstack) -> Hyperstack {
        let planes: [Plane]
        if image.compositeMode == .composite {
            planes = [rendered(image, channel: 0, slice: 0, frame: 0)]
        } else {
            planes = (0..<image.dimensions.channels).map { rendered(image, channel: $0, slice: 0, frame: 0) }
        }
        return rgbImage(image, planes: planes, dimensions: HyperstackDimensions(slices: planes.count), title: image.title + " (RGB)")
    }

    /// `compositeToRGB` for a hyperstack: the composite drawn as RGB at the
    /// current channel, for every slice (`slices`, else the current one)
    /// and frame (`frames`, else the current one).
    public static func hyperstackToRGB(
        _ image: Hyperstack, slices: Bool, frames: Bool, channel: Int, slice: Int, frame: Int, title: String
    ) -> Hyperstack {
        let d = image.dimensions
        let zs = slices ? Array(0..<d.slices) : [slice]
        let ts = frames ? Array(0..<d.frames) : [frame]
        var planes: [Plane] = []
        for t in ts {
            for z in zs { planes.append(rendered(image, channel: channel, slice: z, frame: t)) }
        }
        return rgbImage(image, planes: planes, dimensions: HyperstackDimensions(slices: zs.count, frames: ts.count), title: title)
    }

    /// `convertRGBStackToRGB` for a 2- or 3-plane 8- or 16-bit stack: the
    /// planes as red, green and (if there is one) blue of a new image
    /// titled `<title> (RGB)`. 16-bit planes are scaled to 8 bits through
    /// the display range first; with an inverted LUT the colors are inverted.
    public static func stackToRGB(_ image: Hyperstack) -> Hyperstack {
        let display = image.channels[0]
        let planes = (0..<image.stack.count).map { TypeConverter.toGray8(image.stack[$0], displayRange: display.displayRange) }
        var plane = ColorSpaceConverter.rgb(red: planes[0], green: planes[1], blue: planes.count > 2 ? planes[2] : nil)
        if ImageJRules.isInvertedLUT(display.lut) { plane = plane.invertedBytes() }
        return rgbImage(image, planes: [plane], dimensions: HyperstackDimensions(), title: image.title + " (RGB)")
    }

    static func rgbImage(_ image: Hyperstack, planes: [Plane], dimensions: HyperstackDimensions, title: String) -> Hyperstack {
        var out = ImageJRules.image(
            like: image, planes: planes, labels: nil, dimensions: dimensions,
            channels: [ChannelDisplay(lut: .grays, displayRange: 0...255)],
            calibration: ImageJRules.calibration(image.calibration, from: image.pixelType, to: .rgb8), compositeMode: .color,
            title: title)
        out.encodedROI = nil
        out.encodedOverlay = []
        return out
    }
}
