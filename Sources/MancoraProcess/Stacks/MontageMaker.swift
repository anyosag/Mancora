public import MancoraCore

/// Image ▸ Stacks ▸ Make Montage: a port of ImageJ's `ij.plugin.MontageMaker`,
/// without slice labels (which need text rendering).
public enum MontageMaker {
    /// The dialog's settings.
    public struct Layout: Sendable, Equatable {
        public var columns: Int
        public var rows: Int
        public var scale: Double
        /// 1-based, as in the dialog.
        public var first: Int
        public var last: Int
        public var increment: Int
        public var borderWidth: Int

        public init(columns: Int, rows: Int, scale: Double, first: Int, last: Int, increment: Int, borderWidth: Int) {
            self.columns = columns
            self.rows = rows
            self.scale = scale
            self.first = first
            self.last = last
            self.increment = increment
            self.borderWidth = borderWidth
        }

        /// The layout a macro starts from (`makeMontage`): a near-square
        /// grid of every slice, at half or a quarter size when it would be
        /// wider than 800 or 1600 pixels.
        public static func defaults(slices n: Int, width: Int) -> Layout {
            var columns = Int(Double(n).squareRoot())
            let rows = columns
            let extra = n - columns * rows
            if extra > 0 { columns += Int((Double(extra) / Double(rows)).rounded(.up)) }
            var scale = 1.0
            if width * columns > 800 { scale = 0.5 }
            if width * columns > 1600 { scale = 0.25 }
            return Layout(columns: columns, rows: rows, scale: scale, first: 1, last: n, increment: 1, borderWidth: 0)
        }
    }

    /// The slices a montage shows: a stack's planes, or a hyperstack's
    /// slices (frames when it has no slices).
    public static func slices(of image: Hyperstack) -> Int {
        let d = image.dimensions
        if isChannelHyperstack(image) { return d.slices > 1 ? d.slices : d.frames }
        return image.stack.count
    }

    /// Whether ImageJ makes a montage per channel and merges them: a
    /// hyperstack with several channels.
    public static func isChannelHyperstack(_ image: Hyperstack) -> Bool {
        ImageJRules.isHyperStack(image.dimensions) && image.dimensions.channels > 1
    }

    /// `run` and `makeMontage2`: a new image "Montage" with the slices
    /// `first`, `first + increment`, … to `last`, scaled (bilinear,
    /// averaging when the tiles are under 200 pixels wide) and laid out in
    /// rows, on the background color (white when the bottom of 8-bit or RGB
    /// slices is mostly white, unless `useForegroundColor`) and separated by
    /// borders in the foreground color. The montage keeps the LUT, display
    /// range and calibration (the pixel size divided by the scale), and
    /// records its grid in its Info.
    ///
    /// A composite of channels is drawn in RGB first, each channel in its
    /// color at the current slice and frame; a hyperstack's channels are
    /// made into montages one by one and merged into a composite.
    public static func montage(
        _ image: Hyperstack, layout: Layout, channel: Int = 0, slice: Int = 0, frame: Int = 0,
        useForegroundColor: Bool = false, foreground: UInt32 = 0xFFFFFF, background: UInt32 = 0
    ) -> Hyperstack {
        if isChannelHyperstack(image) {
            let parts = ChannelSplitter.split(image).map { part -> Hyperstack in
                var l = layout
                (l.first, l.last) = (1, part.stack.count)
                var tile = MontageMaker.montage(
                    part, layout: l, useForegroundColor: useForegroundColor, foreground: foreground, background: background)
                // A single image's stack is labeled with its title and Info (ImagePlus.getStack).
                if let info = tile.info { tile = StackEditor.setLabel(tile, at: 0, to: tile.title + "\n" + info) }
                tile.properties = [:]
                return tile
            }
            do {
                var merged = try RGBStackMerge.composite(parts, slots: Array(parts.indices), ignoreLUTs: false)
                merged.title = "Montage"
                merged.calibration = parts[0].calibration
                merged.info = nil
                merged.properties = [:]
                return merged
            } catch {
                preconditionFailure("Make Montage merged mismatched channels: \(error)")
            }
        }
        var source = image
        var display = image.channels[Swift.min(channel, image.channels.count - 1)]
        if ImageJRules.isComposite(image) {
            // Each channel drawn in color at the current position (a channels-only composite).
            let planes = (0..<image.dimensions.channels).map { c in
                Plane.rgb8(CompositeRenderer.channel(colorMode(image), channel: c, slice: slice, frame: frame))
            }
            source = ImageJRules.image(
                like: image, planes: planes, labels: nil, dimensions: HyperstackDimensions(slices: planes.count),
                channels: [ChannelDisplay(lut: .grays, displayRange: 0...255)],
                calibration: ImageJRules.calibration(image.calibration, from: image.pixelType, to: .rgb8), compositeMode: .color)
            display = source.channels[0]
        }
        let type = source.pixelType
        let current = ImageJRules.isComposite(image) ? 0 : image.dimensions.planeIndex(channel: channel, slice: slice, frame: frame)
        let width = ImageJRules.int(Double(source.width) * layout.scale)
        let height = ImageJRules.int(Double(source.height) * layout.scale)
        let border = layout.borderWidth
        let montageWidth = width * layout.columns + border * (layout.columns - 1)
        let montageHeight = height * layout.rows + border * (layout.rows - 1)

        var fg: UInt32 = 0xFFFFFF, bg: UInt32 = 0
        if useForegroundColor {
            (fg, bg) = (foreground, background)
        } else if type == .gray8 || type == .rgb8 {
            var white = bottomMode(source.stack[current], width: source.width) >= 200
            if type == .gray8 && ImageJRules.isInvertedLUT(display.lut) { white = !white }
            if white { (fg, bg) = (0, 0xFFFFFF) }
        }
        let fill = { (color: UInt32) in fillValue(color, type: type, lut: display.lut, range: display.displayRange) }
        var montage = Plane.filled(type, count: montageWidth * montageHeight, with: fill(bg))
        var x = 0, y = 0
        var s = layout.first
        while s <= layout.last {
            var tile = source.stack[s - 1]
            if layout.scale != 1 {
                var ip = GeometryProcessor(tile, width: source.width, displayRange: type == .rgb8 ? nil : display.displayRange)
                ip.interpolation = .bilinear
                tile = ip.resized(width: width, height: height, averaging: width < 200).plane
            }
            montage = montage.inserting(tile, sourceWidth: width, at: x, y, width: montageWidth)
            x += width + border
            if x >= montageWidth {
                x = 0
                y += height + border
                if y >= montageHeight { break }
            }
            s += layout.increment
        }
        if border > 0 {
            let line = Plane.filled(type, count: border * montageHeight, with: fill(fg))
            var bx = width
            while bx < montageWidth {
                montage = montage.inserting(line, sourceWidth: border, at: bx, 0, width: montageWidth)
                bx += width + border
            }
            let row = Plane.filled(type, count: montageWidth * border, with: fill(fg))
            var by = height
            while by < montageHeight {
                montage = montage.inserting(row, sourceWidth: montageWidth, at: 0, by, width: montageWidth)
                by += height + border
            }
        }
        var cal = source.calibration
        if cal.pixelWidth != 1 || cal.pixelHeight != 1 || cal.pixelDepth != 1 || cal.unit != "pixel" {
            cal.pixelWidth /= layout.scale
            cal.pixelHeight /= layout.scale
        }
        let range = type == .rgb8 ? 0...255 : ImageJRules.setRange(display.displayRange, on: montage)
        let stack = ImageJRules.stack([montage], width: montageWidth, height: montageHeight, labels: nil)
        do {
            return try Hyperstack(
                title: "Montage", stack: stack, calibration: cal,
                channels: [ChannelDisplay(lut: type == .rgb8 ? .grays : display.lut, displayRange: range)],
                info: "xMontage=\(layout.columns)\nyMontage=\(layout.rows)\n")
        } catch {
            preconditionFailure("Make Montage built an invalid image: \(error)")
        }
    }

    /// The composite shown in color mode, as MontageMaker switches it.
    static func colorMode(_ image: Hyperstack) -> Hyperstack {
        var shown = image
        shown.compositeMode = .color
        return shown
    }

    /// The most common value (`ImageStatistics` MODE) of the bottom 12 rows,
    /// as luminance (the unweighted mean, rounded) for RGB.
    static func bottomMode(_ plane: Plane, width: Int) -> Int {
        let height = plane.count / width
        let top = Swift.max(height - 12, 0)
        var histogram = [Int](repeating: 0, count: 256)
        for i in (top * width)..<plane.count {
            switch plane {
            case .gray8(let p): histogram[Int(p[i])] += 1
            case .rgb8(let p):
                let c = p[i]
                let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
                histogram[ImageJRules.int(r * (1.0 / 3.0) + g * (1.0 / 3.0) + b * (1.0 / 3.0) + 0.5)] += 1
            default: return 0
            }
        }
        var mode = 0
        for v in 1..<256 where histogram[v] > histogram[mode] { mode = v }
        return mode
    }
}
