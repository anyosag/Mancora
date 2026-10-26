import MancoraCore
import MancoraProcess

/// Process ▸ Binary ▸ Convert to Mask and Make Binary (ImageJ's
/// `ij.plugin.Thresholder`) as a macro runs them.
enum ThresholdCommands {
    static var all: [CommandDefinition] {
        ["Convert to Mask", "Make Binary"].map { name in
            CommandDefinition(name, menu: "Process>Binary") { context, options in
                try thresholder(name, &context, options)
            }
        }
    }

    static let backgrounds = ["Default", "Dark", "Light"]

    static func thresholder(_ name: String, _ context: inout CommandContext, _ options: MacroOptions) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        if open.image.pixelType == .rgb8, open.image.stack.count > 1 { throw CommandError.notNative(name) }  // RGB stacks: ImageJ
        // Thresholder works on the whole image: it deletes the selection first.
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in open.roi = nil }
        if open.image.pixelType == .rgb8 {
            // convertToByte: an RGB image is thresholded as its 8-bit conversion.
            let options = ConversionOptions(scale: true)
            try ProcessCommands.replaceCurrent(name, &context) { open in try ImageConverter.convert(open.image, to: .gray8, options: options) }
        }
        if open.image.stack.count == 1 {
            let black = context.settings.blackBackground
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                try apply(&open, name: name, onePlane: false, blackBackground: black)
            }
        } else {
            try convertStack(name, &context, options)
        }
    }

    /// `Thresholder.convertStack`, from a macro: Convert Stack to Binary's
    /// options, with Black background as given (off unless `black`).
    static func convertStack(_ name: String, _ context: inout CommandContext, _ options: MacroOptions) throws {
        var text = options.text.hasSuffix(" ") ? options.text : options.text + " "
        text = text.replacing("slice ", with: "only ")
        let macro = MacroOptions(text)
        let methodName = macro.value(forLabel: "Method:") ?? "Default"
        guard let method = AutoThresholder.Method(rawValue: methodName) else {
            throw CommandError.invalidOption(command: name, detail: "unknown method \"\(methodName)\"")
        }
        let background = macro.value(forLabel: "Background:") ?? "Default"
        guard backgrounds.contains(background) else {
            throw CommandError.invalidOption(command: name, detail: "unknown background \"\(background)\"")
        }
        var calculate = macro.flag(forLabel: "Calculate threshold for each image")
        let only = macro.flag(forLabel: "Only convert current image")
        let black = macro.flag(forLabel: "Black background (of binary masks)")
        let create = macro.flag(forLabel: "Create new stack")
        guard let original = context.current else { throw CommandError.noImage(name) }
        if only {
            calculate = false
            if original.image.pixelType != .gray8 {
                throw CommandError.failed(command: name, detail: "8-bit stack required to process a single slice.")
            }
        }
        var target = original
        if create { target.image.title = "MASK_" + original.title }
        if calculate {
            try convertStackToBinary(&target, method: method, background: background, blackBackground: black)
        } else {
            try apply(&target, name: name, onePlane: only, blackBackground: black)
        }
        if create {
            context.add(target.image)
            let mask = target
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                open.threshold = mask.threshold
                if mask.thresholdIsBinary, let level = mask.threshold?.lower { open.setBinaryThreshold(level) }
            }
        } else {
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in open = target }
        }
    }

    /// `Thresholder.applyThreshold`: the image's threshold (or ImageJ's
    /// legacy IsoData one) becomes a 0/255 mask with a gray LUT, inverted
    /// unless Black background is on.
    static func apply(_ open: inout OpenImage, name: String, onePlane: Bool, blackBackground: Bool) throws(CommandError) {
        // applyThreshold: an invisible threshold left by Make Binary or Convert to Mask doesn't count.
        open.resetBinaryThreshold()
        let image = open.image
        if image.pixelType == .gray16 || image.pixelType == .gray32Float {
            try shortOrFloat(&open, name: name, blackBackground: blackBackground)
            return
        }
        let current = image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
        var lut = image.channels[open.channel].lut
        let levels: ThresholdLevels
        do {
            levels = try open.threshold ?? Threshold.legacyIsoData(image.stack[current], invertedLUT: lut.isInverted).levels
        } catch {
            throw .failed(command: name, detail: "\(error)")
        }
        if !lut.isGray { lut = .grays }  // a color LUT gives way to gray
        let inverted = lut.isInverted
        var result = image
        for index in onePlane ? [current] : Array(0..<image.stack.count) {
            guard case .gray8(let p) = image.stack[index] else { continue }
            let mask: [UInt8] = p.map { Double($0) >= levels.lower && Double($0) <= levels.upper ? 255 : 0 }
            do { try result.setPlane(.gray8(mask), at: index) } catch { throw .failed(command: name, detail: "\(error)") }
        }
        if !onePlane, inverted == blackBackground { lut = lut.inverted() }
        for channel in result.channels.indices {
            var display = result.channels[channel]
            display.lut = lut
            result.setDisplay(display, forChannel: channel)
        }
        open.image = result
        open.setBinaryThreshold(255)
    }

    /// `Thresholder.applyShortOrFloatThreshold`: thresholds 16- and 32-bit
    /// images through their display range into an 8-bit mask.
    static func shortOrFloat(_ open: inout OpenImage, name: String, blackBackground: Bool) throws(CommandError) {
        let image = open.image
        let t1: Float, t2: Float
        if let threshold = open.threshold {
            (t1, t2) = (Float(threshold.lower), Float(threshold.upper))
        } else {
            let range = image.channels[open.channel].displayRange
            let byte = TypeConverter.toGray8(open.currentPlane, displayRange: range)
            let levels: ThresholdLevels
            do { levels = try Threshold.legacyIsoData(byte).levels } catch { throw .failed(command: name, detail: "\(error)") }
            let (min, max) = (range.lowerBound, range.upperBound)
            t1 = Float(min + (max - min) * (levels.lower / 255.0))
            t2 = Float(max == min ? min : min + (max - min) * (levels.upper / 255.0))
        }
        let planes = image.stack.planes.map { plane -> Plane in
            .gray8((0..<plane.count).map { i in
                let v = Float(plane.value(at: i))
                return v >= t1 && v <= t2 ? 255 : 0
            })
        }
        try replace(&open, planes: planes, name: name, blackBackground: blackBackground)
    }

    /// `Thresholder.convertStackToBinary`: each plane gets its own threshold
    /// (`method` with `background`, or the legacy IsoData for Default/Default).
    static func convertStackToBinary(
        _ open: inout OpenImage, method: AutoThresholder.Method, background: String, blackBackground: Bool
    ) throws(CommandError) {
        let name = "Convert to Mask"
        // The stack's processors (and their 8-bit conversions) have its LUT,
        // whose inversion swaps the side thresholded.
        let image = open.image
        let invertedLUT = image.channels.count == 1 && image.pixelType.usesLUT && image.channels[0].lut.isInverted
        var planes: [Plane] = []
        for plane in image.stack.planes {
            // Other types go to 8-bit through each plane's own range.
            let byte = plane.pixelType == .gray8
                ? plane : TypeConverter.toGray8(plane, displayRange: plane.valueRange() ?? 0...0)
            let levels: ThresholdLevels
            do {
                if method == .default && background == "Default" {
                    levels = try Threshold.legacyIsoData(byte, invertedLUT: invertedLUT).levels
                } else {
                    // A stack's processors never had setAutoThreshold("…"), so addOne is off.
                    levels = try Threshold.auto(
                        byte, method: method,
                        options: AutoThresholdOptions(darkBackground: background != "Light", invertedLUT: invertedLUT),
                        addOne: false
                    ).levels
                }
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
            guard case .gray8(let p) = byte else { continue }
            planes.append(.gray8(p.map { Double($0) >= levels.lower && Double($0) <= levels.upper ? 255 : 0 }))
        }
        try replace(&open, planes: planes, name: name, blackBackground: blackBackground)
    }

    /// The image's planes replaced by 8-bit masks: gray (inverted without
    /// Black background) and full display range; a composite keeps its
    /// channel LUTs and is shown in grayscale.
    static func replace(_ open: inout OpenImage, planes: [Plane], name: String, blackBackground: Bool) throws(CommandError) {
        let image = open.image
        let gray: LUT = blackBackground ? .grays : LUT.grays.inverted()
        let composite = image.channels.count > 1
        var calibration = image.calibration
        calibration.valueFunction = nil
        do {
            let stack = try ImageStack(width: image.width, height: image.height, planes: planes, labels: image.stack.labels)
            var result = try Hyperstack(
                title: image.title, stack: stack, dimensions: image.dimensions, calibration: calibration,
                channels: image.channels.map { ChannelDisplay(lut: composite ? $0.lut : gray, displayRange: 0...255) },
                compositeMode: composite ? .grayscale : image.compositeMode, info: image.info,
                properties: image.properties)
            result.encodedROI = image.encodedROI
            result.encodedOverlay = image.encodedOverlay
            open.image = result
        } catch {
            throw .failed(command: name, detail: "\(error)")
        }
        open.setBinaryThreshold(255)
    }
}
