public import MancoraCore

/// Errors from the hyperstack tools.
public enum HyperstackToolError: Error, Equatable, Sendable {
    /// A slice, channel or frame list ImageJ can't parse, or an index out of range.
    case invalidList(String)
    /// Merge Channels needs at least two images for a composite, or one for RGB.
    case tooFewChannels
    /// The images to merge differ in size, plane count, dimensions or type.
    case mismatchedImages
    /// Merge Channels into a composite takes single-channel grayscale images.
    case unsupportedImage
}

/// Image ▸ Color ▸ Split Channels: a port of ImageJ's `ij.plugin.ChannelSplitter`.
public enum ChannelSplitter {
    /// Splits `image` into one image per channel.
    ///
    /// Each channel keeps its slices and frames, slice labels, LUT (gray when
    /// the image is in grayscale mode), display range and calibration, and
    /// is titled `C<n>-<title>`. An RGB image splits into its red, green and
    /// blue components as 8-bit images titled `<title> (red)` and so on.
    /// A single-channel image is returned as is.
    ///
    /// ImageJ gives the components of an RGB hyperstack as plain stacks;
    /// Mancora keeps their slices and frames.
    public static func split(_ image: Hyperstack) -> [Hyperstack] {
        let dims = image.dimensions
        if image.pixelType == .rgb8 {
            let names = ["red", "green", "blue"]
            return [UInt32(16), 8, 0].enumerated().map { k, shift in
                let planes = image.stack.planes.map { plane -> Plane in
                    guard case .rgb8(let p) = plane else { preconditionFailure("mixed plane types") }
                    return .gray8(p.map { UInt8(truncatingIfNeeded: $0 >> shift) })
                }
                return ImageJRules.image(
                    like: image, planes: planes, labels: nil, dimensions: dims,
                    channels: Array(repeating: ChannelDisplay(lut: .grays, displayRange: 0...255), count: dims.channels),
                    calibration: ImageJRules.calibration(image.calibration, from: .rgb8, to: .gray8),
                    compositeMode: .color, title: image.title + " (\(names[k]))")
            }
        }
        guard dims.channels > 1 else { return [image] }
        return (0..<dims.channels).map { c in
            var planes: [Plane] = []
            var labels: [String?] = []
            for t in 0..<dims.frames {
                for z in 0..<dims.slices {
                    let index = dims.planeIndex(channel: c, slice: z, frame: t)
                    planes.append(image.stack[index])
                    labels.append(image.stack.labels[index])
                }
            }
            let display = image.channels[c]
            let lut = image.compositeMode == .grayscale ? LUT.grays : display.lut
            // The channel processor's min and max (rounded like the processor).
            let range = ImageJRules.setRange(display.displayRange, on: planes[0])
            return ImageJRules.image(
                like: image, planes: planes, labels: labels,
                dimensions: HyperstackDimensions(slices: dims.slices, frames: dims.frames),
                channels: [ChannelDisplay(lut: lut, displayRange: range)], calibration: image.calibration,
                compositeMode: .color, title: "C\(c + 1)-" + image.title)
        }
    }
}

/// Image ▸ Color ▸ Merge Channels: a port of ImageJ's `ij.plugin.RGBStackMerge`.
public enum RGBStackMerge {
    /// The colors ImageJ assigns to the seven channel slots: red, green,
    /// blue, gray, cyan, magenta and yellow.
    public static let slotColors: [LUT] = [.red, .green, .blue, .grays, .cyan, .magenta, .yellow]

    /// Merges single-channel images into one image.
    ///
    /// - Parameters:
    ///   - slots: Up to seven images in ImageJ's slots C1 (red) … C7
    ///     (yellow); `nil` leaves a slot empty.
    ///   - createComposite: "Create composite": a multichannel composite
    ///     image (`mergeHyperstacks`), in which each channel takes its slot's
    ///     color when every source has a gray LUT (or `ignoreLUTs` is set) and
    ///     its source's LUT otherwise, and the source's display range.
    ///     Without it, slots C1–C3 become the red, green and blue of an RGB
    ///     image (`mergeStacks`), 16- and 32-bit sources scaled through their
    ///     display ranges and inverted LUTs undone; images in slots C4–C7
    ///     make it a composite again, drawn as RGB when it has a single plane.
    public static func mergeChannels(
        _ slots: [Hyperstack?],
        createComposite: Bool = true,
        ignoreLUTs: Bool = false
    ) throws(HyperstackToolError) -> Hyperstack {
        let filled = slots.prefix(7).enumerated().compactMap { i, image in image.map { (slot: i, image: $0) } }
        guard let first = filled.first?.image else { throw .tooFewChannels }
        for (_, image) in filled {
            guard image.width == first.width, image.height == first.height,
                image.stack.count == first.stack.count
            else { throw .mismatchedImages }
            guard image.dimensions.channels == 1 else { throw .unsupportedImage }
        }
        let hyper = filled.contains { ImageJRules.isHyperStack($0.image.dimensions) }
        let extraSlots = filled.contains { $0.slot > 2 }
        if createComposite || hyper || extraSlots {
            let merged = try composite(filled.map(\.image), slots: filled.map(\.slot), ignoreLUTs: ignoreLUTs)
            if !createComposite, !hyper, merged.dimensions.slices == 1, merged.dimensions.frames == 1 {
                return ImageConverter.toRGB(merged)
            }
            return merged
        }
        return rgb(filled.map(\.image), slots: filled.map(\.slot))
    }

    /// `mergeHyperstacks`.
    static func composite(_ images: [Hyperstack], slots: [Int], ignoreLUTs: Bool) throws(HyperstackToolError) -> Hyperstack {
        guard images.count >= 2 else { throw .tooFewChannels }
        let first = images[0]
        guard images.allSatisfy({ $0.pixelType == first.pixelType && $0.dimensions == first.dimensions }),
            first.pixelType != .rgb8
        else { throw first.pixelType == .rgb8 ? .unsupportedImage : .mismatchedImages }
        let c = images.count
        var planes: [Plane] = []
        var labels: [String?] = []
        planes.reserveCapacity(c * first.stack.count)
        for i in 0..<first.stack.count {
            for image in images {
                planes.append(image.stack[i])
                labels.append(image.stack.labels[i])
            }
        }
        let allGray = images.allSatisfy { !ImageJRules.isColorLUT($0.channels[0].lut) }
        let channels = zip(images, slots).map { image, slot in
            let display = image.channels[0]
            let range = ImageJRules.setRange(display.displayRange, on: image.stack[0])
            let lut = ignoreLUTs || allGray ? slotColors[slot] : display.lut
            return ChannelDisplay(lut: lut, displayRange: range)
        }
        let dims = HyperstackDimensions(channels: c, slices: first.dimensions.slices, frames: first.dimensions.frames)
        var title = first.title
        if title.hasPrefix("C1-") { title.removeFirst(3) } else { title = dims.frames > 1 ? "Merged" : "Composite" }
        return ImageJRules.image(
            like: first, planes: planes, labels: labels, dimensions: dims, channels: channels,
            calibration: first.calibration, compositeMode: .composite, title: title)
    }

    /// `mergeStacks`: an RGB image from up to three 8-bit components.
    static func rgb(_ images: [Hyperstack], slots: [Int]) -> Hyperstack {
        let first = images[0]
        let n = first.width * first.height
        var components: [[[UInt8]]?] = [nil, nil, nil]
        for (image, slot) in zip(images, slots) {
            let display = image.channels[0]
            let inverted = ImageJRules.isInvertedLUT(display.lut) && image.pixelType != .rgb8
            components[slot] = image.stack.planes.map { plane in
                var bytes: [UInt8]
                switch plane {
                case .gray8(let p): bytes = p
                case .rgb8(let p): bytes = p.map { UInt8(truncatingIfNeeded: $0 >> UInt32(16 - 8 * slot)) }
                default:
                    guard case .gray8(let p) = TypeConverter.toGray8(plane, displayRange: display.displayRange) else {
                        preconditionFailure()
                    }
                    bytes = p
                }
                return inverted ? bytes.map { 255 - $0 } : bytes
            }
        }
        let blank = [UInt8](repeating: 0, count: n)
        let planes = (0..<first.stack.count).map { i -> Plane in
            let r = components[0]?[i] ?? blank, g = components[1]?[i] ?? blank, b = components[2]?[i] ?? blank
            return .rgb8((0..<n).map { 0xFF00_0000 | UInt32(r[$0]) << 16 | UInt32(g[$0]) << 8 | UInt32(b[$0]) })
        }
        return ImageJRules.image(
            like: first, planes: planes, labels: nil,
            dimensions: HyperstackDimensions(slices: first.dimensions.slices, frames: first.dimensions.frames),
            channels: [ChannelDisplay(lut: .grays, displayRange: 0...255)],
            calibration: ImageJRules.calibration(first.calibration, from: first.pixelType, to: .rgb8),
            compositeMode: .color, title: "RGB")
    }
}

/// Image ▸ Color ▸ Arrange Channels: a port of ImageJ's `ij.plugin.ChannelArranger`.
public enum ChannelArranger {
    /// Reorders (or drops) channels: `order` lists the 0-based source
    /// channels in their new order. As in ImageJ, the image is split and
    /// merged again, so channels keep their LUTs (or get red, green, blue …
    /// when every LUT is gray) and display ranges, and the composite mode is kept.
    public static func arrange(_ image: Hyperstack, order: [Int]) throws(HyperstackToolError) -> Hyperstack {
        let channels = ChannelSplitter.split(image)
        guard !order.isEmpty, order.allSatisfy({ channels.indices.contains($0) }) else {
            throw .invalidList(order.map(String.init).joined(separator: ","))
        }
        let picked = order.prefix(channels.count).map { channels[$0] }
        var out: Hyperstack
        if picked.count == 1 {
            out = picked[0]
        } else {
            out = try RGBStackMerge.composite(picked, slots: Array(picked.indices), ignoreLUTs: false)
            out.compositeMode = image.compositeMode
        }
        // ImagePlus.copyAttributes
        out.title = image.title
        out.calibration = image.calibration
        return out
    }
}

/// Image ▸ Stacks ▸ Tools ▸ Make Substack: a port of ImageJ's
/// `ij.plugin.SubstackMaker` and, for hyperstacks, `ij.plugin.SubHyperstackMaker`.
public enum SubstackMaker {
    /// Copies the planes `list` names from a stack: a range (`"2-14"`), a
    /// range with an increment (`"2-14-3"`) or a list (`"7,9,25"`), 1-based
    /// and in the given order. Planes keep their labels, and the substack
    /// keeps the LUT, display range and calibration. A time series stays a
    /// time series.
    public static func makeSubstack(_ image: Hyperstack, _ list: String) throws(HyperstackToolError) -> Hyperstack {
        let n = image.stack.count
        var indices: [Int] = []
        let text = list.filter { !$0.isWhitespace }
        if let dash = text.firstIndex(of: "-"), dash != text.startIndex {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3, let first = Int(parts[0]), let last = Int(parts[1]),
                let step = parts.count == 3 ? Int(parts[2]) : 1, step > 0
            else { throw .invalidList(list) }
            var i = first
            while i <= last {
                indices.append(i - 1)
                i += step
            }
        } else {
            for part in text.split(separator: ",", omittingEmptySubsequences: false) {
                guard let i = Int(part) else { throw .invalidList(list) }
                indices.append(i - 1)
            }
        }
        guard !indices.isEmpty, indices.allSatisfy({ (0..<n).contains($0) }) else { throw .invalidList(list) }
        let display = image.channels[0]
        let range = ImageJRules.setRange(display.displayRange, on: image.stack[indices[0]])
        let timeSeries = image.dimensions.frames == n
        return ImageJRules.image(
            like: image, planes: indices.map { image.stack[$0] }, labels: indices.map { image.stack.labels[$0] },
            dimensions: timeSeries ? HyperstackDimensions(frames: indices.count) : HyperstackDimensions(slices: indices.count),
            channels: [ChannelDisplay(lut: display.lut, displayRange: range, isVisible: display.isVisible)],
            calibration: image.calibration, compositeMode: .color, title: "Substack (\(list))")
    }

    /// `SubHyperstackMaker.makeSubhyperstack`: the channels, slices and
    /// frames the three lists name (each a list of ranges, `"1-3,5"`,
    /// 1-based, in the given order).
    ///
    /// Channels keep their LUTs and display ranges; as in ImageJ they are
    /// all visible, and the image of a single-channel source gets a gray LUT
    /// and its pixel range.
    public static func makeSubhyperstack(
        _ image: Hyperstack,
        channels: String,
        slices: String,
        frames: String
    ) throws(HyperstackToolError) -> Hyperstack {
        let dims = image.dimensions
        let cList = try parseList(channels, count: dims.channels)
        let zList = try parseList(slices, count: dims.slices)
        let tList = try parseList(frames, count: dims.frames)
        var planes: [Plane] = []
        var labels: [String?] = []
        for t in tList {
            for z in zList {
                for c in cList {
                    let index = dims.planeIndex(channel: c, slice: z, frame: t)
                    planes.append(image.stack[index])
                    labels.append(image.stack.labels[index])
                }
            }
        }
        let displays: [ChannelDisplay]
        if ImageJRules.isComposite(image) {
            displays = cList.map { c in
                let r = ImageJRules.reportedRange(image.channels[c].displayRange, type: image.pixelType)
                return ChannelDisplay(lut: image.channels[c].lut, displayRange: ImageJRules.closed(r.min, r.max))
            }
        } else {
            displays = cList.map { _ in ChannelDisplay(lut: .grays, displayRange: ImageJRules.resetRange(planes[0])) }
        }
        return ImageJRules.image(
            like: image, planes: planes, labels: labels,
            dimensions: HyperstackDimensions(channels: cList.count, slices: zList.count, frames: tList.count),
            channels: displays, calibration: image.calibration)
    }

    /// `SubHyperstackMaker.parseList`: comma-separated numbers and ranges
    /// (`"2"`, `"1-4"`, `"1-10-3"`), 1-based within `1...count`, returned 0-based.
    public static func parseList(_ list: String, count: Int) throws(HyperstackToolError) -> [Int] {
        var out: [Int] = []
        for rawToken in list.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.filter { !$0.isWhitespace }
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let i = Int(parts[0]), (1...count).contains(i) else { throw .invalidList(list) }
                out.append(i - 1)
            case 2, 3:
                guard let lo = Int(parts[0]), let hi = Int(parts[1]), let step = parts.count == 3 ? Int(parts[2]) : 1,
                    lo >= 1, lo <= hi, hi <= count, step >= 1
                else { throw .invalidList(list) }
                out.append(contentsOf: stride(from: lo - 1, through: hi - 1, by: step))
            default:
                throw .invalidList(list)
            }
        }
        guard !out.isEmpty else { throw .invalidList(list) }
        return out
    }
}

/// Image ▸ Hyperstacks ▸ Reduce Dimensionality ("Keep source"): a port of
/// ImageJ's `ij.plugin.HyperStackReducer`.
public enum HyperStackReducer {
    /// Keeps the chosen dimensions; each dropped one is fixed at the given
    /// 0-based position (ImageJ's current channel, slice and frame).
    ///
    /// Keeping all channels of a multichannel image keeps their LUTs,
    /// display ranges and composite mode; otherwise the image takes the
    /// LUT and display range of `channel` (gray in grayscale mode).
    public static func reduce(
        _ image: Hyperstack,
        keepChannels: Bool,
        keepSlices: Bool,
        keepFrames: Bool,
        channel: Int = 0,
        slice: Int = 0,
        frame: Int = 0
    ) -> Hyperstack {
        let dims = image.dimensions
        let cs = keepChannels ? Array(0..<dims.channels) : [Swift.min(Swift.max(channel, 0), dims.channels - 1)]
        let zs = keepSlices ? Array(0..<dims.slices) : [Swift.min(Swift.max(slice, 0), dims.slices - 1)]
        let ts = keepFrames ? Array(0..<dims.frames) : [Swift.min(Swift.max(frame, 0), dims.frames - 1)]
        var planes: [Plane] = []
        var labels: [String?] = []
        for t in ts {
            for z in zs {
                for c in cs {
                    let index = dims.planeIndex(channel: c, slice: z, frame: t)
                    planes.append(image.stack[index])
                    labels.append(image.stack.labels[index])
                }
            }
        }
        let displays: [ChannelDisplay]
        var mode = image.compositeMode
        if cs.count > 1, ImageJRules.isComposite(image) {
            displays = image.channels
        } else {
            // imp2.setDisplayRange(imp.getDisplayRangeMin(), imp.getDisplayRangeMax()) of the current channel.
            let source = image.channels[cs[0]]
            let shown = ImageJRules.reportedRange(source.displayRange, type: image.pixelType)
            let lut = ImageJRules.isComposite(image) && image.compositeMode == .grayscale ? LUT.grays : source.lut
            let range = ImageJRules.setRange(ImageJRules.closed(shown.min, shown.max), on: planes[0])
            displays = Array(repeating: ChannelDisplay(lut: lut, displayRange: range), count: cs.count)
            mode = .color
        }
        return ImageJRules.image(
            like: image, planes: planes, labels: labels,
            dimensions: HyperstackDimensions(channels: cs.count, slices: zs.count, frames: ts.count),
            channels: displays, calibration: image.calibration, compositeMode: mode)
    }
}
