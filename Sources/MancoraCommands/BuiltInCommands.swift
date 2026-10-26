import MancoraCore

/// Commands Mancora implements natively, named as in ImageJ's menus.
enum BuiltInCommands {
    static var all: [CommandDefinition] {
        lutCommands + [invertLUT, enhanceContrast, rename, close, closeAll, duplicate, properties, setScale]
    }

    // MARK: Image ▸ Lookup Tables

    /// `ij.plugin.LutLoader("fire")` and friends: the current channel's LUT
    /// (every channel's, for a composite shown in grayscale, which turns to
    /// color), remembered in the `CurrentLUT` property.
    static let lutCommands: [CommandDefinition] = LUT.builtIn.map { lut in
        CommandDefinition(lut.name, menu: "Image>Lookup Tables") { context, _ in
            try context.withCurrent(lut.name) { (open: inout OpenImage) throws(CommandError) in
                guard open.image.pixelType.usesLUT else {
                    throw .failed(command: lut.name, detail: "LUTs cannot be assigned to RGB images.")
                }
                let all = open.image.channels.count > 1 && open.image.compositeMode == .grayscale
                if all { open.image.compositeMode = .color }
                for channel in all ? Array(open.image.channels.indices) : [open.channel] {
                    var display = open.image.channels[channel]
                    display.lut = lut
                    open.image.setDisplay(display, forChannel: channel)
                }
                let name = lutLoaderArgument(lut.name)
                open.image.properties[currentLUTKey] = name == "grays" ? nil : name
            }
        }
    }

    /// `LUT.nameKey`.
    static let currentLUTKey = "CurrentLUT"

    /// The argument the menu passes to LutLoader, which it saves as the LUT's name.
    static func lutLoaderArgument(_ command: String) -> String {
        switch command {
        case "3-3-2 RGB": command
        case "Red/Green": "redgreen"
        default: command.lowercased()
        }
    }

    static let invertLUT = CommandDefinition("Invert LUT", menu: "Image>Lookup Tables") { context, _ in
        try context.withCurrent("Invert LUT") { (open: inout OpenImage) throws(CommandError) in
            guard open.image.pixelType.usesLUT else {
                throw .failed(command: "Invert LUT", detail: "RGB images do not use LUTs")
            }
            var display = open.image.channels[open.channel]
            display.lut = display.lut.inverted()
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    // MARK: Process ▸ Enhance Contrast

    /// `ij.plugin.ContrastEnhancer` without `normalize` or `equalize`: sets
    /// the current channel's display range from the saturated histogram.
    static let enhanceContrast = CommandDefinition("Enhance Contrast...", menu: "Process") { context, options in
        let name = "Enhance Contrast..."
        guard !options.flag(forLabel: "normalize"), !options.flag(forLabel: "equalize") else {
            throw CommandError.notNative(name)  // these change pixels; the bridge can run them
        }
        let saturated = options.number(forLabel: "saturated", default: ContrastEnhancer.defaultSaturated)
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let range: ClosedRange<Double>?
            do {
                range =
                    options.flag(forLabel: "use") && open.image.stack.count > 1
                    ? try ContrastEnhancer.displayRange(forStack: open.image.stack, saturated: saturated)
                    : try ContrastEnhancer.displayRange(for: open.currentPlane, saturated: saturated)
            } catch {
                throw .notNative(name)  // RGB images
            }
            guard let range else { return }
            var display = open.image.channels[open.channel]
            display.displayRange = range
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    // MARK: Image and Window

    static let rename = CommandDefinition("Rename...", menu: "Image") { context, options in
        guard let title = options.value(forLabel: "title"), !title.isEmpty else {
            throw CommandError.invalidOption(command: "Rename...", detail: "title= is required")
        }
        try context.withCurrent("Rename...") { (open: inout OpenImage) throws(CommandError) in open.image.title = title }
    }

    static let close = CommandDefinition("Close", menu: "File") { context, _ in
        guard let id = context.currentID else { return }
        context.close(id: id)
    }

    static let closeAll = CommandDefinition("Close All", menu: "File") { context, _ in
        context.closeAll()
    }

    /// `ij.plugin.Duplicator`: the current plane, or with `duplicate` the
    /// whole stack, optionally limited to `channels=`, `slices=`, `frames=`
    /// (or `range=` for a plain stack), titled `title=` or a unique name.
    /// `ij.plugin.Duplicator` as a macro drives it. Hyperstacks and
    /// composites take `channels=`, `slices=` and `frames=` ranges when
    /// `duplicate` is given, and otherwise the current position (every
    /// channel of a composite shown as one); other images take `range=`
    /// with `duplicate`, and otherwise the current slice.
    static let duplicate = CommandDefinition("Duplicate...", menu: "Image") { context, options in
        let name = "Duplicate..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let dims = image.dimensions
        let wholeStack = options.flag(forLabel: "duplicate")
        let isHyper = dims.channels > 1 || (dims.slices > 1 && dims.frames > 1)
        var indices: [Int] = []
        var newDims: HyperstackDimensions
        var channels = image.channels
        if isHyper {
            /// `showHSDialog`: "2-3" or "2"; out-of-range ends are clamped, and a backwards range means all.
            func range(_ label: String, _ count: Int, _ current: Int) -> ClosedRange<Int> {
                guard wholeStack else { return current...current }
                guard count > 1, let text = options.value(forLabel: label) else { return 0...(count - 1) }
                let parts = splitRange(text)
                let first = max(parts.first.flatMap { $0 } ?? 1, 1)
                let last = min(parts.count == 2 ? parts[1] ?? first : first, count)
                return first > last ? 0...(count - 1) : (first - 1)...(last - 1)
            }
            let singleComposite = dims.channels == image.stack.count
            let allChannels = !wholeStack && !singleComposite && image.compositeMode == .composite
            let c = allChannels ? 0...(dims.channels - 1) : range("channels", dims.channels, open.channel)
            let z = range("slices", dims.slices, open.slice)
            let t = range("frames", dims.frames, open.frame)
            for frame in t {
                for slice in z {
                    for channel in c { indices.append(dims.planeIndex(channel: channel, slice: slice, frame: frame)) }
                }
            }
            newDims = HyperstackDimensions(channels: c.count, slices: z.count, frames: t.count)
            channels = c.map { image.channels[$0] }
        } else {
            let count = image.stack.count
            let current = dims.planeIndex(channel: 0, slice: open.slice, frame: open.frame)
            if count == 1 || !wholeStack {
                indices = [count == 1 ? 0 : current]
            } else {
                // `showDialog`: "2-4", or "2" for 2 to the end.
                let parts = options.value(forLabel: "range").map(splitRange) ?? []
                var first = parts.isEmpty ? 1 : parts[0] ?? 1
                var last = parts.count == 2 ? parts[1] ?? count : count
                first = max(first, 1)
                last = min(last, count)
                if first > last { (first, last) = (1, count) }
                indices = Array((first - 1)...(last - 1))
            }
            let timeSeries = dims.frames == count && count > 1
            newDims = timeSeries
                ? HyperstackDimensions(frames: indices.count) : HyperstackDimensions(slices: indices.count)
        }
        let title = options.value(forLabel: "title") ?? uniqueName(image.title, among: context.images.map(\.title))
        do {
            let stack = try ImageStack(
                width: image.width, height: image.height, planes: indices.map { image.stack[$0] },
                labels: indices.map { image.stack.labels[$0] })
            var copy = try Hyperstack(
                title: title, stack: stack, dimensions: newDims, calibration: image.calibration,
                channels: channels, compositeMode: image.compositeMode, info: image.info,
                properties: image.properties)
            copy.encodedROI = image.encodedROI
            // Duplicator marks plain images and stacks, not hyperstacks.
            if !isHyper { copy.properties["UniqueName"] = "true" }
            context.add(copy)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
    }

    /// `Tools.split(text, " -")`, each part cast to `int` as Java does
    /// (saturating), or `nil` for a part that isn't a number (NaN).
    static func splitRange(_ text: String) -> [Int?] {
        text.split(whereSeparator: { $0 == " " || $0 == "-" }).map { part in
            guard let value = Double(String(part)), !value.isNaN else { return nil }
            return Int(min(max(value, Double(Int32.min)), Double(Int32.max)))
        }
    }

    /// `WindowManager.getUniqueName`: "blobs.gif" → "blobs-1.gif", "a-1.tif" → "a-2.tif".
    static func uniqueName(_ name: String, among titles: [String]) -> String {
        var base = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) < 6, dot != name.index(before: name.endIndex) {
            ext = String(name[dot...])
            base = String(name[..<dot])
        }
        if let dash = base.lastIndex(of: "-"), base.distance(from: dash, to: base.endIndex) < 4,
            dash != base.index(before: base.endIndex)
        {
            let next = base[base.index(after: dash)]
            if next.isNumber, next != "0" { base = String(base[..<dash]) }
        }
        for i in 1...99 where !titles.contains("\(base)-\(i)\(ext)") {
            return "\(base)-\(i)\(ext)"
        }
        return name
    }

    // MARK: Image ▸ Properties and Analyze ▸ Set Scale

    /// `ij.plugin.filter.ImageProperties` as a macro drives it: dimensions,
    /// unit (`unit=`), pixel size, frame interval (`frame=[0.5 min]`),
    /// origin and Invert Y (a checkbox, so off unless named).
    static let properties = CommandDefinition("Properties...", menu: "Image") { context, options in
        let name = "Properties..."
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            var image = open.image
            let dims = image.dimensions
            let c = max(Int(options.number(forLabel: "channels", default: Double(dims.channels))), 1)
            let z = max(Int(options.number(forLabel: "slices", default: Double(dims.slices))), 1)
            let t = max(Int(options.number(forLabel: "frames", default: Double(dims.frames))), 1)
            if c * z * t == image.stack.count {
                try? image.setDimensions(HyperstackDimensions(channels: c, slices: z, frames: t))
            } else {
                throw .invalidOption(
                    command: name,
                    detail: "The product of channels (\(c)), slices (\(z)) and frames (\(t)) must equal the stack size (\(image.stack.count)).")
            }
            var cal = image.calibration
            var unit = cal.unit
            if let given = options.value(forLabel: "unit") {
                if given != cal.unit {
                    cal.yUnit = nil
                    cal.zUnit = nil
                }
                unit = given
            }
            let pixelWidth = options.number(forLabel: "pixel_width", default: cal.pixelWidth)
            let pixelHeight = options.number(forLabel: "pixel_height", default: cal.pixelHeight)
            let pixelDepth = options.number(forLabel: "voxel_depth", default: cal.pixelDepth)
            if unit.isEmpty || unit.lowercased() == "none" || pixelWidth == 0 {
                cal.unit = "pixel"
                cal.pixelWidth = 1
                cal.pixelHeight = 1
                cal.pixelDepth = 1
            } else {
                cal.unit = sanitizedUnit(unit)
                cal.pixelWidth = pixelWidth
                cal.pixelHeight = pixelHeight
                cal.pixelDepth = pixelDepth
            }
            if let interval = options.value(forLabel: "frame") {
                let parts = spacedInterval(interval).split(whereSeparator: { $0 == " " || $0 == "-" })
                let seconds = parts.first.flatMap { Double($0) } ?? .nan
                cal.frameInterval = seconds.isNaN ? 0 : seconds
                var timeUnit = parts.count >= 2 ? String(parts[1]) : "sec"
                if timeUnit == "sec", cal.frameInterval <= 2, cal.frameInterval >= 1.0 / 30 { cal.fps = 1 / cal.frameInterval }
                if timeUnit == "usec" { timeUnit = "µsec" }
                cal.timeUnit = timeUnit
            }
            if let origin = options.value(forLabel: "origin") {
                let parts = origin.split(whereSeparator: { $0 == " " || $0 == "," }).map { Double($0) ?? .nan }
                let x = parts.count >= 1 ? parts[0] : .nan, y = parts.count >= 2 ? parts[1] : .nan
                let zo = parts.count >= 3 ? parts[2] : .nan
                cal.xOrigin = x.isNaN ? 0 : x
                cal.yOrigin = y.isNaN ? cal.xOrigin : y
                cal.zOrigin = zo.isNaN ? 0 : zo
            }
            cal.invertY = options.flag(forLabel: "invert")
            image.calibration = cal
            open.image = image
        }
    }

    /// `ij.plugin.filter.ScaleDialog`: `distance=` pixels are `known=` units
    /// (`unit=`), with `pixel=` the aspect ratio; anything incomplete resets to pixels.
    static let setScale = CommandDefinition("Set Scale...", menu: "Analyze") { context, options in
        try context.withCurrent("Set Scale...") { (open: inout OpenImage) throws(CommandError) in
            var cal = open.image.calibration
            let measured = options.number(forLabel: "distance", default: 0)
            let known = options.number(forLabel: "known", default: 0)
            let aspect = options.number(forLabel: "pixel", default: 1)
            var unit = options.value(forLabel: "unit") ?? cal.unit
            if unit == "A" { unit = "Å" }
            if measured == known, unit == "unit" { unit = "pixel" }
            if measured <= 0 || known <= 0 || unit.hasPrefix("pixel") || unit.hasPrefix("Pixel") || unit.isEmpty {
                cal.pixelWidth = 1
                cal.pixelHeight = 1
                cal.pixelDepth = 1
                cal.unit = "pixel"
            } else {
                cal.pixelWidth = known / measured
                if cal.pixelDepth == 1 { cal.pixelDepth = cal.pixelWidth }
                cal.pixelHeight = aspect != 0 ? cal.pixelWidth * aspect : cal.pixelWidth
                cal.unit = sanitizedUnit(unit)
            }
            open.image.calibration = cal
        }
    }

    /// `Calibration.sanitizeUnit` for a non-empty unit.
    static func sanitizedUnit(_ unit: String) -> String {
        switch unit {
        case "um": "µm"
        case "A": "Å"
        default: unit
        }
    }

    /// `ImageProperties.validateInterval`: "0.5min" → "0.5 min".
    static func spacedInterval(_ interval: String) -> String {
        guard !interval.contains(" "), let letter = interval.firstIndex(where: { $0.isLetter }),
            letter != interval.startIndex, interval.index(after: letter) != interval.endIndex
        else { return interval }
        return String(interval[..<letter]) + " " + String(interval[letter...])
    }
}
