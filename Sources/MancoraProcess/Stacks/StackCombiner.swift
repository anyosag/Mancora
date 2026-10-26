public import MancoraCore

extension Plane {
    /// `ImageProcessor.insert(ip, x, y)`: `source` (of the same type,
    /// `sourceWidth` wide) copied in at (`x`, `y`), clipped to this plane.
    public func inserting(_ source: Plane, sourceWidth: Int, at x: Int, _ y: Int, width: Int) -> Plane {
        let height = count / Swift.max(width, 1)
        let sourceHeight = source.count / Swift.max(sourceWidth, 1)
        func place<T>(_ dst: [T], _ src: [T]) -> [T] {
            var out = dst
            let x0 = Swift.max(x, 0), x1 = Swift.min(x + sourceWidth, width)
            let y0 = Swift.max(y, 0), y1 = Swift.min(y + sourceHeight, height)
            guard x1 > x0, y1 > y0 else { return out }
            for row in y0..<y1 {
                let from = (row - y) * sourceWidth + (x0 - x), to = row * width + x0
                for i in 0..<(x1 - x0) { out[to + i] = src[from + i] }
            }
            return out
        }
        switch (self, source) {
        case (.gray8(let d), .gray8(let s)): return .gray8(place(d, s))
        case (.gray16(let d), .gray16(let s)): return .gray16(place(d, s))
        case (.gray32Float(let d), .gray32Float(let s)): return .gray32Float(place(d, s))
        case (.rgb8(let d), .rgb8(let s)): return .rgb8(place(d, s))
        default: preconditionFailure("insert needs planes of the same type")
        }
    }

    /// A plane of `count` pixels set to `value` as `ImageProcessor.fill()`
    /// stores it: truncated and clamped for 8- and 16-bit, a `float` for
    /// 32-bit, a packed `0xRRGGBB` color for RGB.
    static func filled(_ type: PixelType, count: Int, with value: Double) -> Plane {
        let int = Int(JavaNumerics.int32(value))
        switch type {
        case .gray8: return .gray8(Array(repeating: UInt8(Swift.min(Swift.max(int, 0), 255)), count: count))
        case .gray16: return .gray16(Array(repeating: UInt16(Swift.min(Swift.max(int, 0), 65535)), count: count))
        case .gray32Float: return .gray32Float(Array(repeating: Float(value), count: count))
        case .rgb8:
            return .rgb8(Array(repeating: 0xFF00_0000 | UInt32(bitPattern: Int32(truncatingIfNeeded: int)) & 0xFF_FFFF, count: count))
        }
    }

    /// `ImageProcessor.invert()` of an 8-bit or RGB plane (every value, or
    /// every color component, `v` becomes `255 - v`).
    func invertedBytes() -> Plane {
        switch self {
        case .gray8(let p): return .gray8(p.map { 255 - $0 })
        case .rgb8(let p): return .rgb8(p.map { ($0 & 0xFF00_0000) | (~$0 & 0xFF_FFFF) })
        default: preconditionFailure("only 8-bit and RGB planes")
        }
    }
}

/// What a fill color is in a processor of `type` with `lut` and display
/// `range`: `setColor(Color)` followed by `fill()`.
func fillValue(_ color: UInt32, type: PixelType, lut: LUT, range: ClosedRange<Double>, signed16: Bool = false) -> Double {
    let best = GeometryProcessor.bestIndex(color, lut)
    let (min, max) = (range.lowerBound, range.upperBound)
    let black = color & 0xFF_FFFF == 0
    switch type {
    case .rgb8: return Double(color & 0xFF_FFFF)
    case .gray8: return Double(best)
    case .gray16:
        if best > 0 && min == 0 && max == 0 { return Double(best) }
        if best == 0 && min > 0 && black { return signed16 ? 32768 : 0 }
        return Double(ImageJRules.int(min + (max - min) * (Double(best) / 255.0)))
    case .gray32Float:
        if best > 0 && min == 0 && max == 0 { return Double(best) }
        if best == 0 && min > 0 && black { return 0 }
        return Double(Float(min + (max - min) * (Double(best) / 255.0)))
    }
}

/// The rank ImageJ gives each type when stacking images of several
/// (`ImagesToStack.stackType`): 8 < 16 < 32 < RGB.
func stackRank(_ type: PixelType) -> Int {
    switch type {
    case .gray8: 8
    case .gray16: 16
    case .gray32Float: 32
    case .rgb8: 33
    }
}

/// Image ▸ Stacks ▸ Images to Stack: a port of ImageJ's `ij.plugin.ImagesToStack`.
public enum ImagesToStack {
    /// The "Method" choices, offered when the images differ in size.
    public enum Method: Int, Sendable, CaseIterable {
        case copyCenter, copyTopLeft, scaleSmallest, scaleLargest

        public static let names = ["Copy (center)", "Copy (top-left)", "Scale (smallest)", "Scale (largest)"]
    }

    /// `findMinMaxSize`: the largest width and height, and the sizes of the
    /// smallest and largest images by area.
    public struct Sizes: Sendable, Equatable {
        public var width = 0, height = 0
        public var minWidth = Int.max, minHeight = Int.max
        public var maxWidth = 0, maxHeight = 0

        public var differ: Bool { width != minWidth || height != minHeight }
    }

    public static func sizes(_ images: [Hyperstack]) -> Sizes {
        var s = Sizes()
        var minSize = Int.max, maxSize = 0
        for image in images {
            let (w, h) = (image.width, image.height)
            s.width = Swift.max(s.width, w)
            s.height = Swift.max(s.height, h)
            if w * h < minSize {
                minSize = w * h
                (s.minWidth, s.minHeight) = (w, h)
            }
            if w * h > maxSize {
                maxSize = w * h
                (s.maxWidth, s.maxHeight) = (w, h)
            }
        }
        return s
    }

    /// `convert`: one plane per image, in the most capable type among them
    /// (8-bit, then 16-bit, 32-bit, RGB), sized by `method` when they
    /// differ: copied into the largest size (centered or at the top left)
    /// or scaled (bilinear, or bicubic) to the smallest or largest.
    ///
    /// Planes are labeled with the titles (`titlesAsLabels`, else any
    /// `Slice_Label`), plus `"\n"` and the Info. Images with an inverted LUT
    /// are inverted unless all have one. The stack takes the first image's
    /// LUT, the calibration when all share it, and for 16- and 32-bit data
    /// the display range spanning every image's.
    ///
    /// - Throws: ``StackEditError/unsupported`` for a fill color, an
    ///   overlay, or a 16- or 32-bit image to invert.
    public static func convert(
        _ images: [Hyperstack], name: String = "Stack", method: Method = .copyCenter, bicubic: Bool = false,
        titlesAsLabels: Bool = true, fill: UInt32? = nil
    ) throws(StackEditError) -> Hyperstack {
        guard let first = images.first else { throw .stackRequired("At least two open 2D images required.") }
        let sizes = sizes(images)
        var (width, height) = (sizes.width, sizes.height)
        if method == .scaleSmallest { (width, height) = (sizes.minWidth, sizes.minHeight) }
        if method == .scaleLargest { (width, height) = (sizes.maxWidth, sizes.maxHeight) }
        let type = images.map(\.pixelType).max { stackRank($0) < stackRank($1) } ?? first.pixelType
        func inverted(_ image: Hyperstack) -> Bool {
            image.pixelType.usesLUT && ImageJRules.isInvertedLUT(image.channels[0].lut)
        }
        let allInverted = images.allSatisfy(inverted)
        var calibration: Calibration? = first.calibration
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        var planes: [Plane] = []
        var labels: [String?] = []
        for image in images {
            if !image.encodedOverlay.isEmpty { throw .unsupported }  // ImageJ keeps overlays, by slice
            let display = image.channels[0]
            let shown = ImageJRules.reportedRange(display.displayRange, type: image.pixelType)
            let (ipMin, ipMax) = image.pixelType == .rgb8 ? (0.0, 255.0) : shown
            lo = Swift.min(lo, ipMin)
            hi = Swift.max(hi, ipMax)
            if let cal = calibration, !sameCalibration(cal, image.calibration) { calibration = nil }
            var label = titlesAsLabels ? image.title : image.properties[StackEditor.sliceLabelKey]
            if let l = label, let info = image.info { label = l + "\n" + info }
            var plane = image.stack[0]
            switch type {
            case .gray16: plane = TypeConverter.toGray16(plane, displayRange: display.displayRange, scale: false)
            case .gray32Float: plane = TypeConverter.toGray32(plane)
            case .rgb8: plane = TypeConverter.toRGB(plane, lut: display.lut, displayRange: display.displayRange)
            case .gray8: break
            }
            if inverted(image) && !allInverted {
                guard type == .gray8 || type == .rgb8 else { throw .unsupported }
                plane = plane.invertedBytes()
            }
            if image.width != width || image.height != height {
                switch method {
                case .copyCenter, .copyTopLeft:
                    if fill != nil { throw .unsupported }
                    let (x, y) = method == .copyCenter ? ((width - image.width) / 2, (height - image.height) / 2) : (0, 0)
                    plane = plane.onCanvas(
                        width: image.width, newWidth: width, newHeight: height, xOffset: x, yOffset: y, fill: 0)
                case .scaleSmallest, .scaleLargest:
                    var ip = GeometryProcessor(plane, width: image.width)
                    ip.interpolation = bicubic ? .bicubic : .bilinear
                    plane = ip.resized(width: width, height: height).plane
                }
            }
            planes.append(plane)
            labels.append(label)
        }
        var lut = first.pixelType.usesLUT && type != .rgb8 ? first.channels[0].lut : LUT.grays
        if inverted(first) && !allInverted { lut = .grays }
        // The first plane added gives the stack its range (ImageStack.addSlice); 16- and
        // 32-bit stacks then span every image's.
        var range: ClosedRange<Double> = 0...255
        if type == .gray8 { range = ImageJRules.setRange(first.channels[0].displayRange, on: planes[0]) }
        if type == .gray16 || type == .gray32Float { range = ImageJRules.setRange(ImageJRules.closed(lo, hi), on: planes[0]) }
        let stack = ImageJRules.stack(planes, width: width, height: height, labels: labels)
        do {
            return try Hyperstack(
                title: name, stack: stack, dimensions: HyperstackDimensions(slices: planes.count),
                calibration: calibration.map { ImageJRules.calibration($0, from: first.pixelType, to: type) } ?? Calibration(),
                channels: [ChannelDisplay(lut: lut, displayRange: range)])
        } catch {
            preconditionFailure("Images to Stack built an invalid image: \(error)")
        }
    }

    /// `Calibration.equals`: the same voxel size, unit, value unit and value function.
    static func sameCalibration(_ a: Calibration, _ b: Calibration) -> Bool {
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight && a.pixelDepth == b.pixelDepth
            && a.unit == b.unit && a.valueUnit == b.valueUnit && a.valueFunction == b.valueFunction
    }
}

/// Image ▸ Stacks ▸ Tools ▸ Combine: a port of ImageJ's `ij.plugin.StackCombiner`.
public enum StackCombiner {
    /// Puts `b` beside `a` (or below it, `vertical`), plane by plane, in
    /// "Combined Stacks"; space neither covers is filled with `background`
    /// (`0xRRGGBB`, the background color) when the sizes differ.
    ///
    /// Composites are shown in color first; the result keeps `a`'s
    /// calibration, Info and properties, its dimensions when it is a
    /// hyperstack or composite, and its LUTs (with each channel's display
    /// range reset to its first plane's pixels).
    ///
    /// - Parameter channel: `a`'s current channel, whose LUT and display
    ///   range give the fill value.
    /// - Throws: ImageJ's errors for different types or hyperstack
    ///   dimensions; ``StackEditError/unsupported`` for two composites with
    ///   different LUTs, which ImageJ converts to RGB first.
    public static func combine(
        _ a: Hyperstack, _ b: Hyperstack, vertical: Bool, background: UInt32 = 0, channel: Int = 0
    ) throws(StackEditError) -> Hyperstack {
        guard a.pixelType.bitDepth == b.pixelType.bitDepth else {
            throw .incompatible("This command requires two stacks\nthat are the same data type.")
        }
        let compositeA = ImageJRules.isComposite(a), compositeB = ImageJRules.isComposite(b)
        if compositeA && compositeB {
            let differ = a.channels.count != b.channels.count
                || zip(a.channels, b.channels).contains { x, y in
                    let rx = ImageJRules.reportedRange(x.displayRange, type: a.pixelType)
                    let ry = ImageJRules.reportedRange(y.displayRange, type: b.pixelType)
                    return !x.lut.hasSameColors(as: y.lut) || rx.min != ry.min || rx.max != ry.max
                }
            if differ { throw .unsupported }
        }
        if ImageJRules.isHyperStack(a.dimensions) || ImageJRules.isHyperStack(b.dimensions), a.dimensions != b.dimensions {
            throw .incompatible("Hyperstacks must have identical CZT dimensions")
        }
        let (w1, h1, w2, h2) = (a.width, a.height, b.width, b.height)
        let (d1, d2) = (a.stack.count, b.stack.count)
        let w3 = vertical ? Swift.max(w1, w2) : w1 + w2
        let h3 = vertical ? h1 + h2 : Swift.max(h1, h2)
        let display = a.channels[Swift.min(channel, a.channels.count - 1)]
        let fill = (vertical ? w1 != w2 : h1 != h2)
            ? fillValue(background, type: a.pixelType, lut: display.lut, range: display.displayRange) : 0
        var planes: [Plane] = []
        for i in 0..<Swift.max(d1, d2) {
            var plane = Plane.filled(a.pixelType, count: w3 * h3, with: fill)
            if i < d1 { plane = plane.inserting(a.stack[i], sourceWidth: w1, at: 0, 0, width: w3) }
            if i < d2 {
                plane = plane.inserting(b.stack[i], sourceWidth: w2, at: vertical ? 0 : w1, vertical ? h1 : 0, width: w3)
            }
            planes.append(plane)
        }
        let hyper = ImageJRules.isHyperStack(a.dimensions) || compositeA
        let dims = hyper ? a.dimensions : HyperstackDimensions(slices: planes.count)
        let channels: [ChannelDisplay]
        if compositeA {
            channels = a.channels.enumerated().map { c, x in ChannelDisplay(lut: x.lut, displayRange: ImageJRules.resetRange(planes[c])) }
        } else {
            // The first plane added gives the stack its LUT and range (ImageStack.addSlice).
            let lut = a.pixelType == .rgb8 ? LUT.grays : display.lut
            let range = a.pixelType == .rgb8 ? 0...255 : ImageJRules.setRange(display.displayRange, on: planes[0])
            channels = Array(repeating: ChannelDisplay(lut: lut, displayRange: range), count: dims.channels)
        }
        let stack = ImageJRules.stack(planes, width: w3, height: h3, labels: nil)
        do {
            return try Hyperstack(
                title: "Combined Stacks", stack: stack, dimensions: dims, calibration: a.calibration, channels: channels,
                compositeMode: .color, info: a.info, properties: a.properties)
        } catch {
            preconditionFailure("Combine built an invalid image: \(error)")
        }
    }
}

/// Image ▸ Stacks ▸ Tools ▸ Concatenate: a port of ImageJ's `ij.plugin.Concatenator`.
public enum Concatenator {
    /// `concatenate`: the images' planes one after another in a new image
    /// titled `title`, each centered in the largest width and height.
    ///
    /// When the first image has several channels, all must have the same
    /// type and channels, and the slices (or, for time series, frames)
    /// follow one another (`concatenateHyperstacks`); the result keeps the
    /// first image's LUTs, display ranges and mode, and its calibration
    /// when every voxel size matches. Otherwise (`createHypervol`) the
    /// result has the first image's LUT, display range and calibration;
    /// with `open4D`, when every image has as many slices, each image is a
    /// time frame. It keeps the first image's Info.
    ///
    /// - Throws: ImageJ's error for hyperstacks that don't match, and
    ///   ``StackEditError/unsupported`` when the types differ (ImageJ
    ///   leaves those images out, saying so in the log).
    public static func concatenate(
        _ images: [Hyperstack], title: String = "Untitled", open4D: Bool = true
    ) throws(StackEditError) -> Hyperstack {
        guard let first = images.first else { throw .invalidOption("Please select at least 2 images") }
        var out = try ImageJRules.isComposite(first) ? hyperstacks(images, title: title) : volume(images, title: title, open4D: open4D)
        out.info = first.info
        return out
    }

    /// `createHypervol`.
    static func volume(_ images: [Hyperstack], title: String, open4D: Bool) throws(StackEditError) -> Hyperstack {
        let first = images[0]
        guard images.allSatisfy({ $0.pixelType == first.pixelType }) else { throw .unsupported }
        let maxWidth = images.map(\.width).max() ?? first.width
        let maxHeight = images.map(\.height).max() ?? first.height
        let stackSize = first.dimensions.slices
        var im4D = open4D
        var planes: [Plane] = []
        var labels: [String?] = []
        for image in images {
            if image.dimensions.slices != stackSize { im4D = false }
            for i in 0..<image.stack.count {
                planes.append(centered(image.stack[i], image, maxWidth, maxHeight))
                labels.append(image.stack.labels[i])
            }
        }
        let dims = im4D
            ? HyperstackDimensions(slices: stackSize, frames: planes.count / stackSize)
            : HyperstackDimensions(slices: planes.count)
        let display = first.channels[0]
        let range = first.pixelType == .rgb8 ? 0...255 : ImageJRules.setRange(display.displayRange, on: planes[0])
        let stack = ImageJRules.stack(planes, width: maxWidth, height: maxHeight, labels: labels)
        do {
            return try Hyperstack(
                title: title, stack: stack, dimensions: dims, calibration: first.calibration,
                channels: [ChannelDisplay(lut: display.lut, displayRange: range)])
        } catch {
            preconditionFailure("Concatenate built an invalid image: \(error)")
        }
    }

    /// `concatenateHyperstacks`.
    static func hyperstacks(_ images: [Hyperstack], title: String) throws(StackEditError) -> Hyperstack {
        let first = images[0]
        let d = first.dimensions
        var concatSlices = d.slices > 1 && d.frames == 1
        var keepCalibration = true
        for image in images.dropFirst() {
            if image.dimensions.frames > 1 { concatSlices = false }
            if image.pixelType.bitDepth != first.pixelType.bitDepth || image.dimensions.channels != d.channels
                || (!concatSlices && image.dimensions.slices != d.slices)
            {
                throw .incompatible("Images do not all have the same dimensions or type")
            }
            let (a, b) = (first.calibration, image.calibration)
            if a.pixelWidth != b.pixelWidth || a.pixelHeight != b.pixelHeight || a.pixelDepth != b.pixelDepth {
                keepCalibration = false
            }
        }
        let maxWidth = images.map(\.width).max() ?? first.width
        let maxHeight = images.map(\.height).max() ?? first.height
        var planes: [Plane] = []
        var labels: [String?] = []
        var (slices2, frames2) = (0, 0)
        var frames = d.frames
        for image in images {
            let slices = image.dimensions.slices
            if concatSlices {
                slices2 += slices
                frames2 = frames
            } else {
                frames = image.dimensions.frames
                frames2 += frames
                slices2 = slices
            }
            for i in 0..<(d.channels * slices * frames) {
                planes.append(centered(image.stack[i], image, maxWidth, maxHeight))
                labels.append(image.stack.labels[i])
            }
        }
        let stack = ImageJRules.stack(planes, width: maxWidth, height: maxHeight, labels: labels)
        do {
            return try Hyperstack(
                title: title, stack: stack,
                dimensions: HyperstackDimensions(channels: d.channels, slices: slices2, frames: frames2),
                calibration: keepCalibration ? first.calibration : Calibration(), channels: first.channels,
                compositeMode: first.compositeMode)
        } catch {
            preconditionFailure("Concatenate built an invalid image: \(error)")
        }
    }

    /// A plane centered in a blank `width × height` plane, as ImageJ pads
    /// smaller images.
    static func centered(_ plane: Plane, _ image: Hyperstack, _ width: Int, _ height: Int) -> Plane {
        guard image.width != width || image.height != height else { return plane }
        return plane.onCanvas(
            width: image.width, newWidth: width, newHeight: height, xOffset: (width - image.width) / 2,
            yOffset: (height - image.height) / 2, fill: 0)
    }
}

/// Image ▸ Stacks ▸ Tools ▸ Insert: a port of ImageJ's `ij.plugin.StackInserter`.
public enum StackInserter {
    /// Copies each plane of `source` into the plane of `destination` with the
    /// same number (the last source plane into any beyond), at (`x`, `y`).
    public static func insert(_ source: Hyperstack, into destination: Hyperstack, x: Int, y: Int) -> Hyperstack {
        let n1 = source.stack.count
        var out = destination
        for i in 0..<destination.stack.count {
            let plane = destination.stack[i].inserting(
                source.stack[Swift.min(i, n1 - 1)], sourceWidth: source.width, at: x, y, width: destination.width)
            do { try out.setPlane(plane, at: i) } catch { preconditionFailure("Insert built an invalid plane: \(error)") }
        }
        return out
    }
}

/// Image ▸ Stacks ▸ Tools ▸ Grouped Z Project: a port of ImageJ's
/// `ij.plugin.GroupedZProjector`.
public enum GroupedZProjector {
    /// Projects each run of `groupSize` planes into one (`groupSize` must
    /// divide the stack size): a stack of slices gives one slice per group,
    /// a time series one frame. The result has the stack's calibration
    /// with the voxel depth times `groupSize`.
    ///
    /// As in ImageJ, groups of one give a single plane: the projection then
    /// runs along the groups and stops after the first.
    public static func project(_ image: Hyperstack, method: ZProjector.Method, groupSize: Int) -> Hyperstack {
        let n = image.stack.count
        let groups = n / groupSize
        let d = image.dimensions
        var grouped = image
        var out: Hyperstack
        do {
            try grouped.setDimensions(HyperstackDimensions(slices: groupSize, frames: groups))
            grouped.setDisplay(image.channels[0], forChannel: 0)
            out = ZProjector.project(grouped, method: method, slices: 0...(groupSize - 1), allTimeFrames: true)
            let fixed = HyperstackDimensions(
                channels: d.channels != 1 ? groups : 1, slices: d.slices != 1 ? groups : 1, frames: d.frames != 1 ? groups : 1)
            // ImagePlus.setDimensions ignores dimensions that don't fit.
            if fixed.planeCount == out.stack.count {
                let display = out.channels[0]
                try out.setDimensions(fixed)
                out.setDisplay(display, forChannel: 0)
            }
        } catch {
            preconditionFailure("Grouped Z Project: \(error)")
        }
        var cal = ImageJRules.calibration(image.calibration, from: image.pixelType, to: out.pixelType)
        cal.pixelDepth *= Double(groupSize)
        out.calibration = cal
        return out
    }
}
