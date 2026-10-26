import MancoraCore
import MancoraProcess

/// Image ▸ Scale, Image ▸ Adjust ▸ Size and Image ▸ Transform ▸ Rotate,
/// Translate and Bin: ports of ImageJ's `Scaler`, `Resizer`, `Rotator`,
/// `Translator` and `Binner` as a macro drives them, on the interpolation
/// of ``GeometryProcessor``.
enum GeometryCommands {
    static var all: [CommandDefinition] { [scale, size, rotate, translate, bin] }

    // MARK: Shared rules

    /// `Tools.parseDouble(s, default)`: Java's `Double.parseDouble`, which
    /// ignores surrounding whitespace and a `d` or `f` suffix.
    static func parseDouble(_ text: String?) -> Double? {
        guard let text else { return nil }
        var s = Substring(text)
        while let c = s.first, c.isASCII, c.asciiValue! <= 0x20 { s.removeFirst() }
        while let c = s.last, c.isASCII, c.asciiValue! <= 0x20 { s.removeLast() }
        if let last = s.last, "dDfF".contains(last), s.count > 1 { s.removeLast() }
        let lowered = s.lowercased()
        if lowered.contains("inf") || lowered.contains("nan") {
            switch s {
            case "NaN": return .nan
            case "Infinity", "+Infinity": return .infinity
            case "-Infinity": return -.infinity
            default: return nil
            }
        }
        return Double(String(s))
    }

    /// Java's `(int)Math.round(x)`.
    static func round(_ x: Double) -> Int { Int(JavaNumerics.roundToInt32(x)) }

    /// Java's `(int)x`.
    static func int(_ x: Double) -> Int { Int(JavaNumerics.int32(x)) }

    /// The rectangle a plugin's processor works on: an area selection's
    /// bounds clipped to the image (`ImageProcessor.setRoi(Rectangle)`), or
    /// `nil` for no selection or a line or point selection.
    static func selectionBounds(_ open: OpenImage) -> RoiBounds? {
        guard let roi = open.roi, roi.isArea else { return nil }
        let b = roi.bounds
        let x1 = max(b.x, 0), y1 = max(b.y, 0)
        let x2 = min(b.x + b.width, open.image.width), y2 = min(b.y + b.height, open.image.height)
        guard x2 > x1, y2 > y1 else { return nil }
        return RoiBounds(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    static func currentIndex(_ open: OpenImage) -> Int {
        open.image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
    }

    /// The display a new single-channel image gets from the current
    /// channel's LUT and the range its first processor shows.
    static func display(_ open: OpenImage, _ first: GeometryProcessor) -> ChannelDisplay {
        let lut = open.image.channels[min(open.channel, open.image.channels.count - 1)].lut
        let range = open.image.pixelType == .rgb8 ? 0...255 : StackGeometry.displayRange(of: first)
        return ChannelDisplay(lut: lut, displayRange: range)
    }

    /// The interpolation method a dialog's "Interpolation" choice names.
    static func method(_ macro: MacroOptions, _ command: String, default fallback: String) throws(CommandError)
        -> InterpolationMethod
    {
        let name = macro.value(forLabel: "Interpolation:") ?? fallback
        guard let method = InterpolationMethod(name: name) else {
            throw .invalidOption(command: command, detail: "\"\(name)\" is not a valid choice for \"Interpolation:\"")
        }
        return method
    }

    /// Scaler and Rotator's macro rewrite: `interpolate` means bilinear, and
    /// no interpolation given means none.
    static func withInterpolation(_ text: String) -> String {
        if text.contains(" interpolate") { return text.replacing(" interpolate", with: " interpolation=Bilinear") }
        if !text.contains(" interpolation=") { return text + " interpolation=None" }
        return text
    }

    static func makeImage(
        _ command: String, _ like: Hyperstack, title: String, planes: [Plane], width: Int, height: Int, labels: [String?]?,
        dimensions: HyperstackDimensions, calibration: Calibration, channels: [ChannelDisplay]
    ) throws(CommandError) -> Hyperstack {
        do {
            let stack = try ImageStack(width: width, height: height, planes: planes, labels: labels)
            return try Hyperstack(
                title: title, stack: stack, dimensions: dimensions, calibration: calibration, channels: channels,
                compositeMode: like.compositeMode, info: like.info, properties: like.properties)
        } catch {
            throw .failed(command: command, detail: "\(error)")
        }
    }

    // MARK: Image ▸ Scale

    /// `ij.plugin.Scaler`: `x=` and `y=` factors (or `width=` and
    /// `height=`), `z=` or `depth=` for stacks, `interpolation=`, `fill`,
    /// `average`, `process` and `create` with `title=`. A new window holds
    /// the selection scaled (the whole stack, with `process`, or Z scaled);
    /// otherwise the image is scaled in place about the selection's center.
    static let scale = CommandDefinition("Scale...", menu: "Image") { context, options in
        let name = "Scale..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let text = withInterpolation(options.text)
        let macro = MacroOptions(text)
        var xstr = "0.5", ystr = "0.5", zstr = "1.0"
        if text.contains("width=") && text.contains(" height=") {
            xstr = "-"
            ystr = "-"
            zstr = text.contains(" depth=") ? "-" : "1.0"
        }
        let dims = image.dimensions
        let stackSize = image.stack.count
        let isStack = stackSize > 1
        let hyper = StackGeometry.isHyperStack(image)
        let hyperOrComposite = hyper || StackGeometry.isComposite(image)
        var oldDepth = stackSize
        let r = selectionBounds(open) ?? RoiBounds(x: 0, y: 0, width: image.width, height: image.height)

        var width = r.width
        var height = round(Double(width) * Double(r.height) / Double(r.width))
        var xscale = parseDouble(xstr) ?? 0, yscale = parseDouble(ystr) ?? 0
        var zscale = 1.0
        if xscale != 0 && yscale != 0 {
            width = round(Double(r.width) * xscale)
            height = round(Double(r.height) * yscale)
        } else {
            xstr = "-"
            ystr = "-"
        }
        if isStack, hyper { oldDepth = dims.slices == 1 && dims.frames > 1 ? dims.frames : dims.slices }
        xstr = macro.value(forLabel: "X Scale:") ?? xstr
        ystr = macro.value(forLabel: "Y Scale:") ?? ystr
        xscale = parseDouble(xstr) ?? 0
        yscale = parseDouble(ystr) ?? 0
        if isStack {
            zstr = macro.value(forLabel: "Z Scale:") ?? zstr
            zscale = parseDouble(zstr) ?? 0
        }
        let wstr = macro.value(forLabel: "Width (pixels):") ?? String(width)
        var newWidth = round(parseDouble(wstr) ?? 0)
        var newHeight = round(parseDouble(macro.value(forLabel: "Height (pixels):") ?? String(height)) ?? 0)
        if newHeight != 0 && (wstr == "-" || wstr == "0") {
            newWidth = round(Double(newHeight) * Double(r.width) / Double(r.height))
        } else if newWidth != 0 && newHeight == 0 {
            newHeight = round(Double(newWidth) * Double(r.height) / Double(r.width))
        } else if newHeight != 0 && newWidth == 0 {
            newWidth = round(Double(newHeight) * Double(r.width) / Double(r.height))
        }
        guard newWidth != 0, newHeight != 0 else { throw CommandError.failed(command: name, detail: "Width or height is 0") }
        if xscale > 0 && yscale > 0 {
            newWidth = round(Double(r.width) * xscale)
            newHeight = round(Double(r.height) * yscale)
        }
        guard newWidth > 0, newHeight > 0 else { throw CommandError.invalidOption(command: name, detail: "negative size") }
        var newDepth = 0
        if isStack {
            newDepth = round(parseDouble(macro.value(forLabel: "Depth (images):") ?? String(oldDepth)) ?? 0)
            if zscale > 0 {
                var nSlices = stackSize
                if hyper { nSlices = dims.slices == 1 && dims.frames > 1 ? dims.frames : dims.slices }
                newDepth = round(Double(nSlices) * zscale)
            }
        }
        let method = try method(macro, name, default: "Bilinear")
        let bitDepth = image.pixelType.bitDepth
        let fill = (bitDepth == 8 || bitDepth == 24) && macro.flag(forLabel: "Fill with background color")
        let average = macro.flag(forLabel: "Average when downsizing")
        var processStack = true
        if isStack && !hyperOrComposite { processStack = macro.flag(forLabel: "Process entire stack") }
        var newWindow = macro.flag(forLabel: "Create new window")
        if xscale == 0 {
            xscale = Double(newWidth) / Double(r.width)
            yscale = Double(newHeight) / Double(r.height)
        }
        let title = macro.value(forLabel: "Title:") ?? BuiltInCommands.uniqueName(image.title, among: context.images.map(\.title))
        var bgValue = 0.0
        if fill {
            let background = context.settings.background
            if bitDepth == 8 {
                bgValue = Double(GeometryProcessor.bestIndex(background, image.channels[min(open.channel, image.channels.count - 1)].lut))
            } else {
                bgValue = Double(Int32(bitPattern: 0xFF00_0000 | (background & 0xFF_FFFF)))
            }
        }

        let doZScaling = newDepth > 0 && newDepth != oldDepth
        if doZScaling {
            newWindow = true
            processStack = true
        }
        let ipMethod: InterpolationMethod = (image.width > 1 && image.height > 1) || newWindow ? method : .none
        var cal = image.calibration
        if StackGeometry.isScaled(cal) {
            cal.pixelWidth *= 1.0 / xscale
            cal.pixelHeight *= 1.0 / yscale
        }
        cal.xOrigin *= xscale
        cal.yOrigin *= yscale

        if newWindow && stackSize > 1 && processStack {
            // createNewStack
            let crop = r.width != image.width || r.height != image.height
            let stackMethod: InterpolationMethod = image.width == 1 || image.height == 1 ? .none : method
            var first: GeometryProcessor?
            let planes = (0..<stackSize).map { i -> Plane in
                var ip1 = StackGeometry.processor(image, plane: i, channel: open.channel)
                if crop {
                    ip1.setRoi(r)
                    ip1 = ip1.cropped()
                }
                ip1.interpolation = stackMethod
                let ip2 = ip1.resized(width: newWidth, height: newHeight, averaging: average)
                if first == nil { first = ip2 }
                return ip2.plane
            }
            let channels = StackGeometry.isComposite(image) ? image.channels : [display(open, first!)]
            var scaled = try makeImage(
                name, image, title: title, planes: planes, width: newWidth, height: newHeight, labels: image.stack.labels,
                dimensions: dims, calibration: cal, channels: channels)
            if doZScaling {
                let oldSize = Double(scaled.stack.count)
                scaled = StackGeometry.zScaled(scaled, depth: newDepth, method: method, averaging: average, channel: open.channel)
                scaled.calibration.zOrigin *= Double(scaled.stack.count) / oldSize
            }
            context.add(scaled)
            return
        }
        if newWindow {
            var ip = StackGeometry.processor(image, plane: currentIndex(open), channel: open.channel)
            ip.setRoi(r)
            ip.interpolation = ipMethod
            ip.setBackgroundValue(bgValue)
            let ip2 = ip.resized(width: newWidth, height: newHeight, averaging: average)
            let scaled = try makeImage(
                name, image, title: title, planes: [ip2.plane], width: newWidth, height: newHeight, labels: nil,
                dimensions: HyperstackDimensions(), calibration: cal, channels: [display(open, ip2)])
            context.add(scaled)
            return
        }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let targets = processStack && stackSize > 1 ? Array(0..<stackSize) : [currentIndex(open)]
            // StackProcessor.scale gives each plane the interpolation through
            // setInterpolate, which turns bicubic into bilinear.
            let planeMethod: InterpolationMethod = targets.count > 1 && ipMethod == .bicubic ? .bilinear : ipMethod
            for index in targets {
                var ip = StackGeometry.processor(open.image, plane: index, channel: open.channel)
                ip.setRoi(r)
                ip.interpolation = planeMethod
                ip.setBackgroundValue(bgValue)
                ip.scale(x: xscale, y: yscale)
                do { try open.image.setPlane(ip.plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
            }
            open.roi = nil
        }
    }

    // MARK: Image ▸ Adjust ▸ Size

    /// `ij.plugin.Resizer` ("Size..."): `width=` and `height=` (with
    /// `constrain` keeping the aspect ratio), `depth=` and `time=` for
    /// stacks and hyperstacks, `average` and `interpolation=`. The selection
    /// (or the whole image) is resized in place; a new depth makes a new
    /// image of the same title.
    static let size = CommandDefinition("Size...", menu: "Image>Adjust") { context, options in
        let name = "Size..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let dims = image.dimensions
        let hasRoi = open.roi != nil
        let r = selectionBounds(open) ?? RoiBounds(x: 0, y: 0, width: image.width, height: image.height)
        let origWidth = Double(r.width), origHeight = Double(r.height)
        let stackSize = image.stack.count
        var z1 = stackSize, t1 = 0
        // Resizer's first-run defaults (it remembers the last size).
        var newWidth = int(origWidth) / 2
        var newHeight = int(Double(newWidth) * (origHeight / origWidth))
        if stackSize > 1 {
            newWidth = int(origWidth)
            newHeight = int(origHeight)
        }
        if StackGeometry.isHyperStack(image) {
            z1 = dims.slices
            t1 = dims.frames
        }
        newWidth = int(options.number(forLabel: "Width (pixels):", default: Double(newWidth)))
        newHeight = int(options.number(forLabel: "Height (pixels):", default: Double(newHeight)))
        var z2 = 0, t2 = 0
        if z1 == stackSize || (z1 > 1 && z1 < stackSize) {
            z2 = int(options.number(forLabel: "Depth (images):", default: Double(z1)))
        }
        if t1 > 1 { t2 = int(options.number(forLabel: "Time (frames):", default: Double(t1))) }
        let constrain = options.flag(forLabel: "Constrain aspect ratio")
        let average = options.flag(forLabel: "Average when downsizing")
        let method = try method(options, name, default: "Bilinear")
        var sizeToHeight = constrain && newWidth == 0
        let text = options.text
        if text.contains("constrain") && text.contains("height=") && !text.contains("width=") { sizeToHeight = true }
        if newWidth <= 0 && !constrain { newWidth = 50 }
        if newHeight <= 0 { newHeight = 50 }
        if constrain {
            if sizeToHeight {
                newWidth = round(Double(newHeight) * (origWidth / origHeight))
            } else {
                newHeight = round(Double(newWidth) * (origHeight / origWidth))
            }
        }
        guard newWidth > 0, newHeight > 0 else { throw CommandError.invalidOption(command: name, detail: "Width or height are invalid.") }

        var result = image
        var roiCleared = false
        if hasRoi || newWidth != r.width || newHeight != r.height {
            var first: GeometryProcessor?
            let planes = (0..<stackSize).map { i -> Plane in
                var ip = StackGeometry.processor(image, plane: i, channel: open.channel)
                ip.setRoi(r)
                ip.interpolation = method
                let ip2 = ip.resized(width: newWidth, height: newHeight, averaging: average)
                if first == nil { first = ip2 }
                return ip2.plane
            }
            var cal = image.calibration
            if StackGeometry.isScaled(cal) {
                cal.pixelWidth *= origWidth / Double(newWidth)
                cal.pixelHeight *= origHeight / Double(newHeight)
            }
            let channels = StackGeometry.isComposite(image) ? image.channels : [display(open, first!)]
            result = try makeImage(
                name, image, title: image.title, planes: planes, width: newWidth, height: newHeight,
                labels: image.stack.labels, dimensions: dims, calibration: cal, channels: channels)
            if newWidth != image.width || newHeight != image.height {
                roiCleared = true
            } else {
                result.encodedROI = image.encodedROI
            }
            result.encodedOverlay = []
        }
        var replacement: Hyperstack?
        if z2 > 0 && z2 != z1 {
            replacement = StackGeometry.zScaled(result, depth: z2, method: method, averaging: average, channel: open.channel)
        }
        if t2 > 0 && t2 != t1 {
            replacement = StackGeometry.zScaled(
                replacement ?? result, depth: t2, method: method, averaging: average, scaleTime: true, channel: open.channel)
        }
        if let replacement {
            context.close(id: open.id)
            context.add(replacement)
            return
        }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            open.image = result
            if roiCleared { open.image.encodedROI = nil }
        }
    }

    // MARK: Image ▸ Transform ▸ Rotate

    /// `ij.plugin.filter.Rotator` ("Rotate... "): `angle=` degrees
    /// clockwise, `interpolation=`, `fill` (with the background color,
    /// otherwise 0), `enlarge` (the canvas grows to hold the rotated image,
    /// when there's no selection) and `stack`. A non-rectangular selection
    /// rotates its bounding rectangle and keeps the pixels outside it.
    static let rotate = CommandDefinition("Rotate... ", menu: "Image>Transform") { context, options in
        let name = "Rotate... "
        guard let open = context.current else { throw CommandError.noImage(name) }
        let text = withInterpolation(options.text)
        let macro = MacroOptions(text)
        let image = open.image
        let roi = open.roi.flatMap { $0.isArea ? $0 : nil }
        let full = RoiBounds(x: 0, y: 0, width: image.width, height: image.height)
        let canEnlarge = roi == nil || roi?.bounds == full
        let angle = macro.number(forLabel: "Angle:", default: 15)
        let method = try method(macro, name, default: "None")
        let fill = macro.flag(forLabel: "Fill with background color")
        let enlarge = canEnlarge && macro.flag(forLabel: "Enlarge image")
        let targets = FilterCommands.targetPlanes(open, macro)
        let background = context.settings.background
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            var bounds = selectionBounds(open)
            var mask: RoiMask?
            if let roi, let b = bounds, !roi.shapeIsPlainRectangle {
                mask = try? roi.mask(width: open.image.width, height: open.image.height)
                if mask?.bounds != b { mask = nil }
            }
            if enlarge {
                let (w, h) = StackGeometry.rotatedCanvasSize(width: image.width, height: image.height, angle: angle)
                let like = StackGeometry.processor(image, plane: 0, channel: open.channel)
                let lut = image.channels[min(open.channel, image.channels.count - 1)].lut
                let value = fill ? StackGeometry.colorValue(background, like: like, lut: lut) : 0
                open.image = StackGeometry.expandedCanvas(
                    image, width: w, height: h, xOffset: (w - image.width) / 2, yOffset: (h - image.height) / 2, fill: value)
                open.image.encodedROI = nil
                bounds = nil
                mask = nil
            }
            let lut = open.image.channels[min(open.channel, open.image.channels.count - 1)].lut
            for index in targets {
                var ip = StackGeometry.processor(open.image, plane: index, channel: open.channel)
                let original = ip.plane
                ip.setRoi(bounds)
                ip.interpolation = method
                if fill { ip.setBackgroundColor(background, lut: lut) } else { ip.setBackgroundValue(0) }
                ip.rotate(degrees: angle)
                var plane = ip.plane
                if let mask { plane = restoringOutside(mask, plane, original, width: open.image.width) }
                do { try open.image.setPlane(plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
            }
        }
    }

    /// `ip.reset(mask)`: pixels of the mask's rectangle outside the mask get
    /// their original values back.
    static func restoringOutside(_ mask: RoiMask, _ plane: Plane, _ original: Plane, width: Int) -> Plane {
        let b = mask.bounds
        func restore<T>(_ p: [T], _ o: [T]) -> [T] {
            var p = p
            for my in 0..<b.height {
                for mx in 0..<b.width where !mask.pixels[my * b.width + mx] {
                    let i = (b.y + my) * width + b.x + mx
                    p[i] = o[i]
                }
            }
            return p
        }
        switch (plane, original) {
        case (.gray8(let p), .gray8(let o)): return .gray8(restore(p, o))
        case (.gray16(let p), .gray16(let o)): return .gray16(restore(p, o))
        case (.gray32Float(let p), .gray32Float(let o)): return .gray32Float(restore(p, o))
        case (.rgb8(let p), .rgb8(let o)): return .rgb8(restore(p, o))
        default: return plane
        }
    }

    // MARK: Image ▸ Transform ▸ Translate

    /// `ij.plugin.filter.Translator`: `x=` and `y=` offsets in pixels,
    /// `interpolation=` (none by default) and `stack`. Only the selection's
    /// bounding rectangle moves; what comes from outside the image is 0.
    static let translate = CommandDefinition("Translate...", menu: "Image>Transform") { context, options in
        let name = "Translate..."
        guard context.current != nil else { throw CommandError.noImage(name) }
        let xOffset = options.number(forLabel: "X offset:", default: 15)
        let yOffset = options.number(forLabel: "Y offset:", default: 15)
        let method = try method(options, name, default: "None")
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let bounds = selectionBounds(open)
            for index in FilterCommands.targetPlanes(open, options) {
                var ip = StackGeometry.processor(open.image, plane: index, channel: open.channel)
                ip.setRoi(bounds)
                ip.interpolation = method
                ip.translate(x: xOffset, y: yOffset)
                do { try open.image.setPlane(ip.plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
            }
        }
    }

    // MARK: Image ▸ Transform ▸ Bin

    /// `ij.plugin.Binner`: `x=`, `y=` and (for stacks) `z=` shrink factors,
    /// and `bin=Average`, `Median`, `Min`, `Max` or `Sum`. The image is
    /// replaced by the binned one, with its calibration scaled.
    static let bin = CommandDefinition("Bin...", menu: "Image>Transform") { context, options in
        let name = "Bin..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        var isStack = image.stack.count > 1
        if StackGeometry.isComposite(image) && image.dimensions.channels == image.stack.count { isStack = false }
        let xShrink = int(options.number(forLabel: "X shrink factor:", default: 2))
        let yShrink = int(options.number(forLabel: "Y shrink factor:", default: 2))
        let zShrink = isStack ? int(options.number(forLabel: "Z shrink factor:", default: 1)) : 1
        let methodName = options.value(forLabel: "Bin Method: ") ?? "Average"
        guard let method = StackGeometry.BinMethod(name: methodName) else {
            throw CommandError.invalidOption(command: name, detail: "\"\(methodName)\" is not a valid choice for \"Bin Method:\"")
        }
        // 16- and 32-bit images shown inverted are inverted around their display range: ImageJ can.
        if image.pixelType == .gray16 || image.pixelType == .gray32Float,
            StackGeometry.isInvertedLUT(image.channels[min(open.channel, image.channels.count - 1)].lut)
        {
            throw CommandError.notNative(name)
        }
        guard xShrink >= 1, yShrink >= 1, zShrink >= 1, xShrink <= image.width, yShrink <= image.height,
            zShrink <= image.stack.count
        else {
            throw CommandError.invalidOption(command: name, detail: "invalid shrink factors")
        }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let binned = StackGeometry.binned(
                open.image, xShrink: xShrink, yShrink: yShrink, zShrink: zShrink, method: method, channel: open.channel,
                currentPlane: currentIndex(open))
            open.image = binned
            let dims = binned.dimensions
            if zShrink > 1 {
                (open.channel, open.slice, open.frame) = (0, 0, 0)
            } else {
                open.channel = min(open.channel, dims.channels - 1)
                open.slice = min(open.slice, dims.slices - 1)
                open.frame = min(open.frame, dims.frames - 1)
            }
        }
    }
}

extension Roi {
    /// A rectangle without rounded corners, whose mask is the whole rectangle.
    var shapeIsPlainRectangle: Bool {
        if case .rectangle(_, let corner) = shape { return corner == 0 }
        return false
    }
}
