public import MancoraCore

/// Errors from the stack editing commands, with ImageJ's messages.
public enum StackEditError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The command needs a stack (or a hyperstack); the message is ImageJ's.
    case stackRequired(String)
    /// The images can't be combined; the message is ImageJ's.
    case incompatible(String)
    /// An option ImageJ rejects; the message is ImageJ's.
    case invalidOption(String)
    /// Something ImageJ does that Mancora doesn't model yet (overlays by
    /// slice, fill colors, LUT combinations), so ImageJ should run it.
    case unsupported

    public var description: String {
        switch self {
        case .stackRequired(let message), .incompatible(let message), .invalidOption(let message): message
        case .unsupported: "not supported natively"
        }
    }
}

/// A hyperstack dimension, as Add Slice and Delete Slice name them.
public enum HyperstackAxis: String, Sendable, CaseIterable {
    case channel, slice, frame
}

/// Image ▸ Stacks ▸ Add Slice, Delete Slice and Stack to Images, and
/// Image ▸ Stacks ▸ Tools ▸ Set Label, Remove Slice Labels and Reduce: a
/// port of ImageJ's `ij.plugin.StackEditor`, `SimpleCommands("set")`,
/// `SimpleCommands("remove")` and `ij.plugin.StackReducer`.
///
/// Stack indices here are 0-based; ImageJ's are 1-based.
public enum StackEditor {
    /// The `Slice_Label` property, which ImageJ keeps for a single image's label.
    public static let sliceLabelKey = "Slice_Label"

    /// `ImagePlus.verifyDimensions` after the stack changed size: a time
    /// series or a channels-only image keeps its kind, anything else that no
    /// longer fits becomes a plain stack.
    public static func verifiedDimensions(_ dims: HyperstackDimensions, count: Int) -> HyperstackDimensions {
        var d = dims
        if d.slices == 1 {
            if d.channels > 1 && d.frames == 1 {
                d.channels = count
            } else if d.frames > 1 && d.channels == 1 {
                d.frames = count
            }
        }
        if d.planeCount != count { d = HyperstackDimensions(slices: count) }
        return d
    }

    /// Whether ImageJ runs the hyperstack version of Add Slice and Delete
    /// Slice: two or more dimensions besides x and y (`isHyperStack`), or a
    /// composite (`isComposite`).
    public static func isHyperstackOrComposite(_ image: Hyperstack) -> Bool {
        ImageJRules.isHyperStack(image.dimensions) || ImageJRules.isComposite(image)
    }

    /// `ImagePlus.isHyperStack`: two or more dimensions besides x and y.
    public static func isHyperStack(_ dims: HyperstackDimensions) -> Bool { ImageJRules.isHyperStack(dims) }

    /// `ImagePlus.isComposite`: several channels of grayscale data.
    public static func isComposite(_ image: Hyperstack) -> Bool { ImageJRules.isComposite(image) }

    // MARK: Add Slice

    /// `StackEditor.addSlice` for a stack: a blank plane after plane `index`
    /// (the current one); the new plane becomes current, which is returned.
    public static func addSlice(_ image: Hyperstack, after index: Int) -> (image: Hyperstack, current: Int) {
        var planes = image.stack.planes
        var labels = image.stack.labels
        planes.insert(Plane(zeroed: image.pixelType, count: image.stack.pixelsPerPlane), at: index + 1)
        labels.insert(nil, at: index + 1)
        let dims = verifiedDimensions(image.dimensions, count: planes.count)
        return (rebuilt(image, planes: planes, labels: labels, dimensions: dims, channels: image.channels), index + 1)
    }

    /// The axis Add Slice offers first for a hyperstack: frame for a time
    /// series without slices, slice when there are slices, channel otherwise.
    public static func defaultAddAxis(_ dims: HyperstackDimensions) -> HyperstackAxis {
        if dims.frames > 1 && dims.slices == 1 { return .frame }
        return dims.slices > 1 ? .slice : .channel
    }

    /// `StackEditor.addHyperstackChannelSliceOrFrame`: a blank channel,
    /// slice or frame after the current one (`channel`, `slice`, `frame`,
    /// 0-based) or, with `prepend`, before the first. A new channel of a
    /// composite gets a gray LUT and the other channels keep theirs.
    ///
    /// Returns the image and its current plane: ImageJ keeps the plane
    /// number (`setStack`), or shows the first after `prepend`.
    public static func addHyperstack(
        _ image: Hyperstack, axis: HyperstackAxis, prepend: Bool, channel: Int, slice: Int, frame: Int
    ) -> (image: Hyperstack, current: Int) {
        let d = image.dimensions
        let current = d.planeIndex(channel: channel, slice: slice, frame: frame)
        var (c, z, t) = (d.channels, d.slices, d.frames)
        var planes = image.stack.planes
        var labels = image.stack.labels
        let blank = Plane(zeroed: image.pixelType, count: image.stack.pixelsPerPlane)
        /// `ImageStack.addSlice(null, ip, n)`: after (1-based) plane `n`.
        func insert(after n: Int) {
            planes.insert(blank, at: n)
            labels.insert(nil, at: n)
        }
        /// `ImagePlus.getStackIndex(c, z, t)`, all 1-based.
        func stackIndex(_ c1: Int, _ z1: Int, _ t1: Int) -> Int { (t1 - 1) * c * z + (z1 - 1) * c + c1 }
        var displays = image.channels
        switch axis {
        case .frame:
            let index = prepend ? 0 : stackIndex(c, z, frame + 1)
            for _ in 0..<(c * z) { insert(after: index) }
            t += 1
        case .slice:
            for t1 in stride(from: t, through: 1, by: -1) {
                let index = prepend ? (t1 - 1) * c * z : stackIndex(c, slice + 1, t1)
                for _ in 0..<c { insert(after: index) }
            }
            z += 1
        case .channel:
            var c1 = channel + 1
            var index = stackIndex(c1, z, t)
            var minIndex = 1
            if prepend {
                index = c * z * t - c
                minIndex = 0
                c1 = 0
            }
            while index >= minIndex {
                insert(after: index)
                index -= c
            }
            c += 1
            // The new channel's LUT is white, with no display range set.
            displays.insert(ChannelDisplay(lut: .grays, displayRange: 0...0), at: c1)
        }
        let dims = HyperstackDimensions(channels: c, slices: z, frames: t)
        let out = rebuilt(image, planes: planes, labels: labels, dimensions: dims, channels: displays)
        return (out, prepend ? 0 : current)
    }

    // MARK: Delete Slice

    /// `StackEditor.deleteSlice` for a stack: removes plane `index` (the
    /// current one). The plane before becomes current (the first stays
    /// first); a stack left with one plane keeps that plane's label in the
    /// `Slice_Label` property.
    public static func deleteSlice(_ image: Hyperstack, at index: Int) throws(StackEditError) -> (image: Hyperstack, current: Int) {
        guard image.stack.count >= 2 else { throw .stackRequired("\"Delete Slice\" requires a stack") }
        var planes = image.stack.planes
        var labels = image.stack.labels
        planes.remove(at: index)
        labels.remove(at: index)
        var out = rebuilt(
            image, planes: planes, labels: labels, dimensions: verifiedDimensions(image.dimensions, count: planes.count),
            channels: image.channels)
        if planes.count == 1, let label = labels[0] { out.properties[sliceLabelKey] = label }
        return (out, Swift.max(index - 1, 0))
    }

    /// The axes Delete Slice offers for a hyperstack (those with more than
    /// one position), and the one it picks when a macro names none.
    public static func deleteAxes(_ dims: HyperstackDimensions) -> (choices: [HyperstackAxis], default: HyperstackAxis) {
        var choices: [HyperstackAxis] = []
        if dims.channels > 1 { choices.append(.channel) }
        if dims.slices > 1 { choices.append(.slice) }
        if dims.frames > 1 { choices.append(.frame) }
        if dims.frames > 1 && dims.slices == 1 { return (choices, .frame) }
        if dims.slices > 1 { return (choices, .slice) }
        return (choices, choices.first ?? .channel)
    }

    /// `StackEditor.deleteHyperstackChannelSliceOrFrame`: removes the
    /// current channel, slice or frame (0-based `channel`, `slice`,
    /// `frame`). The plane number stays, within the smaller stack.
    public static func deleteHyperstack(
        _ image: Hyperstack, axis: HyperstackAxis, channel: Int, slice: Int, frame: Int
    ) -> (image: Hyperstack, current: Int) {
        let d = image.dimensions
        let current = d.planeIndex(channel: channel, slice: slice, frame: frame)
        var (c, z, t) = (d.channels, d.slices, d.frames)
        var planes = image.stack.planes
        var labels = image.stack.labels
        func stackIndex(_ c1: Int, _ z1: Int, _ t1: Int) -> Int { (t1 - 1) * c * z + (z1 - 1) * c + c1 }
        /// `ImageStack.deleteSlice(n)`, 1-based.
        func delete(_ n: Int) {
            planes.remove(at: n - 1)
            labels.remove(at: n - 1)
        }
        var displays = image.channels
        switch axis {
        case .frame:
            for z1 in stride(from: z, through: 1, by: -1) {
                let index = stackIndex(c, z1, frame + 1)
                for i in 0..<c { delete(index - i) }
            }
            t -= 1
        case .slice:
            for t1 in stride(from: t, through: 1, by: -1) {
                let index = stackIndex(c, slice + 1, t1)
                for i in 0..<c { delete(index - i) }
            }
            z -= 1
        case .channel:
            var index = stackIndex(channel + 1, z, t)
            while index > 0 {
                delete(index)
                index -= c
            }
            c -= 1
            displays.remove(at: channel)
        }
        let dims = HyperstackDimensions(channels: c, slices: z, frames: t)
        let out = rebuilt(image, planes: planes, labels: labels, dimensions: dims, channels: displays)
        return (out, Swift.min(current, planes.count - 1))
    }

    // MARK: Labels

    /// `SimpleCommands.setSliceLabel`: plane `index` gets `label` (none when
    /// empty), which the image also keeps as its `Slice_Label` property.
    /// Nothing changes when the label is the same.
    public static func setLabel(_ image: Hyperstack, at index: Int, to label: String) -> Hyperstack {
        if let old = image.stack.labels[index], old == label { return image }
        var labels = image.stack.labels
        labels[index] = label.isEmpty ? nil : label
        var out = rebuilt(image, planes: image.stack.planes, labels: labels, dimensions: image.dimensions, channels: image.channels)
        out.properties[sliceLabelKey] = label.isEmpty ? nil : label
        return out
    }

    /// `SimpleCommands.removeStackLabels`: every plane loses its label, and
    /// a single image its `Slice_Label` property.
    public static func removeLabels(_ image: Hyperstack) -> Hyperstack {
        var out = rebuilt(
            image, planes: image.stack.planes, labels: Array(repeating: nil, count: image.stack.count),
            dimensions: image.dimensions, channels: image.channels)
        if image.stack.count == 1 { out.properties[sliceLabelKey] = nil }
        return out
    }

    // MARK: Stack to Images

    /// `StackEditor.convertStackToImages`: one image per plane, titled by
    /// the plane's short label (unless it has `/`, `\` or `:`) or
    /// `<short title>-0001`. Each keeps the calibration, the LUT and display
    /// range of the current channel (`channel`; a channels-only composite
    /// gives each image its own channel's), and the full label as its Info
    /// when that says more.
    public static func stackToImages(_ image: Hyperstack, channel: Int = 0) throws(StackEditError) -> [Hyperstack] {
        let n = image.stack.count
        guard n >= 2 else { throw .stackRequired("\"Convert Stack to Images\" requires a stack") }
        let composite = ImageJRules.isComposite(image)
        let channelsOnly = composite && image.dimensions.channels == n
        var out: [Hyperstack] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var label = Analyzer.shortSliceLabel(image.stack.labels[i])
            if let l = label, l.contains("/") || l.contains("\\") || l.contains(":") { label = nil }
            let title = label.flatMap { $0.isEmpty ? nil : $0 } ?? numberedTitle(image.title, i + 1)
            let plane = image.stack[i]
            var display = image.channels[channelsOnly ? i : Swift.min(channel, image.channels.count - 1)]
            if composite && !channelsOnly && image.compositeMode == .grayscale { display.lut = .grays }
            let range = ImageJRules.setRange(display.displayRange, on: plane)
            let full = image.stack.labels[i]
            let info = full != nil && full != label ? full : nil
            do {
                let stack = try ImageStack(width: image.width, height: image.height, planes: [plane])
                out.append(
                    try Hyperstack(
                        title: title, stack: stack, calibration: image.calibration,
                        channels: [ChannelDisplay(lut: display.lut, displayRange: range)], info: info))
            } catch {
                preconditionFailure("Stack to Images built an invalid image: \(error)")
            }
        }
        return out
    }

    /// `ImagePlus.getShortTitle`: the trimmed title up to its first space,
    /// without its extension.
    public static func shortTitle(_ title: String) -> String {
        // String.trim(): characters up to U+0020 go from both ends.
        let isSpace = { (c: Character) in c.unicodeScalars.allSatisfy { $0.value <= 0x20 } }
        var short = Substring(title).drop(while: isSpace)
        while let last = short.last, isSpace(last) { short = short.dropLast() }
        if let space = short.firstIndex(of: " ") { short = short[..<space] }
        if let dot = short.lastIndex(of: "."), dot != short.startIndex { short = short[..<dot] }
        return String(short)
    }

    /// `StackEditor.getTitle`: the title up to its first space, without its
    /// extension, then `-` and the 1-based plane number in four digits.
    static func numberedTitle(_ title: String, _ n: Int) -> String {
        var short = Substring(title)
        if let space = short.firstIndex(of: " ") { short = short[..<space] }
        if let dot = short.lastIndex(of: "."), dot != short.startIndex { short = short[..<dot] }
        let digits = String(repeating: "0", count: 8) + String(n)
        return short + "-" + digits.suffix(4)
    }

    // MARK: Reduce

    /// `StackReducer`: for a stack, every `factor`-th plane from the first;
    /// for a hyperstack, every `factor`-th slice (with `reduceSlices`) or
    /// frame, with all channels. A spatially calibrated image's voxel depth
    /// grows by the factor when slices go.
    public static func reduce(_ image: Hyperstack, factor: Int, reduceSlices: Bool) -> Hyperstack {
        let d = image.dimensions
        let step = Swift.max(factor, 1)
        var planes: [Plane] = []
        var labels: [String?] = []
        var dims: HyperstackDimensions
        var zfactor = step
        if ImageJRules.isHyperStack(d) {
            zfactor = reduceSlices ? step : 1
            let tfactor = reduceSlices ? 1 : step
            for t in stride(from: 0, to: d.frames, by: tfactor) {
                for z in stride(from: 0, to: d.slices, by: zfactor) {
                    for c in 0..<d.channels {
                        let i = d.planeIndex(channel: c, slice: z, frame: t)
                        planes.append(image.stack[i])
                        labels.append(image.stack.labels[i])
                    }
                }
            }
            let slices2 = d.slices / zfactor + (d.slices % zfactor != 0 ? 1 : 0)
            let frames2 = d.frames / tfactor + (d.frames % tfactor != 0 ? 1 : 0)
            dims = HyperstackDimensions(channels: d.channels, slices: slices2, frames: frames2)
        } else {
            for i in stride(from: 0, to: image.stack.count, by: step) {
                planes.append(image.stack[i])
                labels.append(image.stack.labels[i])
            }
            dims = verifiedDimensions(d, count: planes.count)
        }
        var out = rebuilt(image, planes: planes, labels: labels, dimensions: dims, channels: image.channels)
        if image.calibration.isSpatiallyCalibrated { out.calibration.pixelDepth *= Double(zfactor) }
        return out
    }

    // MARK: Helpers

    /// `image` with new planes, labels, dimensions and channel displays,
    /// keeping everything else (`ImagePlus.setStack` on the same image).
    static func rebuilt(
        _ image: Hyperstack, planes: [Plane], labels: [String?], dimensions: HyperstackDimensions,
        channels: [ChannelDisplay]
    ) -> Hyperstack {
        ImageJRules.image(
            like: image, planes: planes, labels: labels, dimensions: dimensions, channels: channels,
            calibration: image.calibration)
    }
}
