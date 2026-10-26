import MancoraCore
import MancoraIO
import MancoraProcess

/// Commands Mancora implements natively, named as in ImageJ's menus.
enum BuiltInCommands {
    static var all: [CommandDefinition] {
        lutCommands + [invertLUT, enhanceContrast, rename, close, closeAll, duplicate, duplicateImage, properties, setScale]
            + [setMeasurements, measure, clearResults, analyzeParticles] + FilterCommands.all + ProcessCommands.all + ThresholdCommands.all + EditCommands.all
            + CropCommands.all + TransformCommands.all
            + GeometryCommands.all + StackCommands.all + HyperstackCommands.all
            + SegmentationCommands.all
            + ExtraFilterCommands.all + AnalyzeCommands.all + SelectionDrawing.all + FFTCommands.all
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

    /// `ij.plugin.ContrastEnhancer` without `equalize`: sets the current
    /// channel's display range from the saturated histogram (of the
    /// selection, if any), or with `normalize` (which `process_all` implies)
    /// stretches the pixels to the full range.
    static let enhanceContrast = CommandDefinition("Enhance Contrast...", menu: "Process") { context, options in
        let name = "Enhance Contrast..."
        var text = options.text
        if text.contains("normalize_all") { text = text.replacing("normalize_all", with: "process_all") }
        let macro = MacroOptions(text)
        guard !macro.flag(forLabel: "Equalize histogram") else {
            throw CommandError.notNative(name)  // it changes pixels; the bridge can run it
        }
        let saturated = min(max(macro.number(forLabel: "Saturated pixels:", default: ContrastEnhancer.defaultSaturated), 0), 100)
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let image = open.image
            guard image.pixelType != .rgb8 else { throw .notNative(name) }
            // The histogram is the selection's (`ip.setRoi(imp.getRoi())`).
            if let roi = open.roi, !roi.isArea { throw .notNative(name) }
            let region = try FilterCommands.measurementRegion(open, name)
            let filterRegion = try FilterCommands.selectionRegion(name, open)
            let width = image.width
            func selected(_ plane: Plane) -> Plane { region.map { plane.values(in: $0, width: width) } ?? plane }
            // showDialog: a composite (several channels) counts as one image and has no Normalize.
            let composite = image.channels.count > 1
            let stackSize = composite ? 1 : image.stack.count
            var normalize = !composite && macro.flag(forLabel: "Normalize")
            let areaSelection = open.roi != nil && !composite
            let updateSelectionOnly = areaSelection && !macro.flag(forLabel: "Update all when normalizing") && normalize
            let processStack = stackSize > 1 && macro.flag(forLabel: "Process_all")
            let useStack = stackSize > 1 && macro.flag(forLabel: "Use stack histogram")
            if processStack { normalize = true }
            let current = image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
            guard selected(image.stack[current]).count > 0 else { return }
            do {
                let stackStatistics = useStack
                    ? try ImageStatistics(stack: ImageStack(
                        width: selected(image.stack[0]).count, height: 1, planes: image.stack.planes.map(selected)))
                    : nil
                for index in processStack ? Array(0..<image.stack.count) : [current] {
                    let statistics = try stackStatistics ?? ImageStatistics(selected(image.stack[index]))
                    if !normalize {
                        guard let range = ContrastEnhancer.displayRange(for: statistics, saturated: saturated) else { continue }
                        var display = open.image.channels[open.channel]
                        display.displayRange = range
                        open.image.setDisplay(display, forChannel: open.channel)
                        continue
                    }
                    guard let (lo, hi) = ContrastEnhancer.limits(for: statistics, saturated: saturated) else { continue }
                    let original = image.stack[index]
                    var plane = ContrastEnhancer.normalized(original, min: lo, max: hi)
                    // The table applies within the selection (normalizeFloat ignores it).
                    if updateSelectionOnly, let filterRegion, image.pixelType != .gray32Float {
                        plane = filterRegion.restoringOutsideMask(
                            plane.merged(into: original, width: width, within: filterRegion.rect), snapshot: original,
                            width: width)
                    }
                    try open.image.setPlane(plane, at: index)
                }
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
            if normalize {
                // run(): the current processor shows the full range.
                var display = open.image.channels[open.channel]
                display.displayRange = image.pixelType == .gray32Float ? 0...1 : image.pixelType == .gray16 ? 0...65535 : 0...255
                open.image.setDisplay(display, forChannel: open.channel)
            }
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
    ///
    /// An area selection crops the copy to its bounds, and a
    /// non-rectangular one moves onto the copy at (0, 0); `ignore` (offered
    /// for images that aren't hyperstacks) copies the whole image and the
    /// selection as it is. Any selection moves a set origin by its position.
    static let duplicate = CommandDefinition("Duplicate...", menu: "Image") { context, options in
        let name = "Duplicate..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let dims = image.dimensions
        let wholeStack = options.flag(forLabel: "duplicate")
        let isHyper = dims.channels > 1 || (dims.slices > 1 && dims.frames > 1)
        let roi = try CropCommands.selection(name, open)
        var crop: RoiBounds?
        var copiedROI: [UInt8]?
        if let roi {
            let b = roi.bounds
            if b.x >= image.width || b.y >= image.height || b.x + b.width <= 0 || b.y + b.height <= 0 {
                throw CommandError.notNative(name)  // a selection outside the image
            }
            if case .polygon(let p) = roi.shape, case .rotatedRectangle? = p.parametric {
                throw CommandError.notNative(name)  // ImageJ straightens rotated rectangles
            }
            if !isHyper && options.flag(forLabel: "Ignore selection") {
                copiedROI = image.encodedROI
            } else if roi.isArea {
                crop = try CropCommands.cropRectangle(name, roi, width: image.width, height: image.height)
                if roi.kind != .rectangle {
                    guard let moved = CropCommands.atOrigin(roi) else { throw CommandError.notNative(name) }
                    copiedROI = RoiCodec.encode(moved)
                }
            }
            if crop != nil, !image.encodedOverlay.isEmpty { throw CommandError.notNative(name) }  // ImageJ crops overlays
        }
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
            let planes = indices.map { index in crop.map { image.stack[index].cropped(width: image.width, to: $0) } ?? image.stack[index] }
            let stack = try ImageStack(
                width: crop?.width ?? image.width, height: crop?.height ?? image.height, planes: planes,
                labels: indices.map { image.stack.labels[$0] })
            let calibration = roi.map { CropCommands.shiftedOrigin(image.calibration, by: $0.bounds) } ?? image.calibration
            var copy = try Hyperstack(
                title: title, stack: stack, dimensions: newDims, calibration: calibration,
                channels: channels, compositeMode: image.compositeMode, info: image.info,
                properties: image.properties)
            copy.encodedROI = copiedROI
            // Duplicator marks plain images and stacks, not hyperstacks.
            if !isHyper { copy.properties["UniqueName"] = "true" }
            context.add(copy)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
    }

    /// The image popup menu's Duplicate Image (`Executer.extraCommand`):
    /// Duplicate with the selection ignored (kept on the copy) and no options.
    static let duplicateImage = CommandDefinition("Duplicate Image...", menu: "Image") { context, _ in
        guard let open = context.current else { throw CommandError.noImage("Duplicate Image...") }
        let dims = open.image.dimensions
        if dims.channels > 1 || (dims.slices > 1 && dims.frames > 1) {
            throw CommandError.notNative("Duplicate Image...")  // ImageJ's hyperstack dialog
        }
        try duplicate.run(&context, MacroOptions("ignore"))
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
        guard !options.flag(forLabel: "Global") else { throw CommandError.notNative(name) }  // global calibration: ImageJ
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            var image = open.image
            let dims = image.dimensions
            let c = max(Int(JavaNumerics.int32(options.number(forLabel: "channels", default: Double(dims.channels)))), 1)
            let z = max(Int(JavaNumerics.int32(options.number(forLabel: "slices", default: Double(dims.slices)))), 1)
            let t = max(Int(JavaNumerics.int32(options.number(forLabel: "frames", default: Double(dims.frames)))), 1)
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
        guard !options.flag(forLabel: "Global") else { throw CommandError.notNative("Set Scale...") }  // global calibration: ImageJ
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

    // MARK: Analyze ▸ Measure

    /// `Analyzer("set")`: each checkbox is on only when the macro names it,
    /// as with any ImageJ dialog a macro fills in.
    static let setMeasurements = CommandDefinition("Set Measurements...", menu: "Analyze") { context, options in
        // Older macros use the labels ImageJ had before. ImageJ rewrites the
        // original options each time, so with both, only "slice" is rewritten.
        let padded = options.text.hasSuffix(" ") ? options.text : options.text + " "
        var text = padded
        if padded.contains("circularity ") { text = padded.replacing("circularity ", with: "shape ") }
        if padded.contains("slice ") { text = padded.replacing("slice ", with: "stack ") }
        let macro = MacroOptions(text)
        var measurements = Measurements()
        for (label, option) in Measurements.dialogLabels where macro.flag(forLabel: label) {
            measurements.insert(option)
        }
        let old = context.settings.measurements
        context.settings.measurements = measurements
        AnalyzeCommands.updateResults(&context, from: old)
        context.settings.measurementRedirect = try AnalyzeCommands.redirectChoice(macro, context)
        let precision = Int(JavaNumerics.int32(macro.number(forLabel: "Decimal places (0-9):", default: Double(context.settings.decimalPlaces))))
        context.settings.decimalPlaces = min(max(precision, 0), 9)
        context.results.emptyCellsAreNaN = measurements.contains(.nanEmptyCells)
        if !measurements.contains(.labels) { context.results.removeLabels() }
    }

    /// `Analyzer.measure`: see ``AnalyzeCommands/measure(_:)``.
    static let measure = CommandDefinition("Measure", menu: "Analyze") { context, _ in
        try AnalyzeCommands.measure(&context)
    }

    /// `ParticleAnalyzer` from a macro: `size=` (calibrated unless `pixel`),
    /// `circularity=`, `show=Nothing` or `Masks`, and `display`, `exclude`,
    /// `clear`, `include`, `summarize`, `record`, `four` and `stack`.
    static let analyzeParticles = CommandDefinition("Analyze Particles...", menu: "Analyze") { context, options in
        let name = "Analyze Particles..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let text = options.text
        if ["overlay", "add", "composite", "in_situ"].contains(where: { options.flag(forLabel: $0) || text.contains($0 + " ") }) {
            throw CommandError.notNative(name)  // overlays, the ROI Manager, composite ROIs, in situ: ImageJ
        }
        let show = options.value(forLabel: "Show:") ?? "Nothing"
        guard show == "Nothing" || show == "Masks" else { throw CommandError.notNative(name) }
        let cal = open.image.calibration
        let scaled = cal.unit != "pixel" && cal.unit != "pixels" && cal.unit != ""
        let unitSquared = scaled && !options.flag(forLabel: "Pixel units") ? cal.pixelWidth * cal.pixelHeight : 1
        func range(_ label: String) -> (Double?, Double?) {
            let parts = (options.value(forLabel: label) ?? "").split(whereSeparator: { $0 == " " || $0 == "-" })
            let low = parts.first.flatMap { Double(String($0)) }
            let high = parts.count == 2 ? Double(String(parts[1])) : nil
            return (low, high)
        }
        var particleOptions = ParticleAnalyzer.Options()
        let (minSize, maxSize) = range("Size")
        particleOptions.minSize = max(minSize.map { $0 / unitSquared } ?? 0, 0)
        particleOptions.maxSize = maxSize.map { $0 / unitSquared } ?? .infinity
        if particleOptions.maxSize < particleOptions.minSize { particleOptions.maxSize = .infinity }
        let (minCirc, maxCirc) = range("Circularity:")
        var low = minCirc ?? 0, high = maxCirc ?? 1
        if low < 0 { low = 0 }
        if low > high && high == 1 { low = 0 }
        if low > high { low = high }
        if high < low { high = low }
        if low == 1 && high == 1 { low = 0 }
        (particleOptions.minCircularity, particleOptions.maxCircularity) = (low, high)
        particleOptions.excludeEdges = options.flag(forLabel: "Exclude on edges")
        particleOptions.fourConnected = text.contains("four")
        particleOptions.includeHoles = options.flag(forLabel: "Include holes") || particleOptions.fourConnected
        particleOptions.recordStarts = options.flag(forLabel: "Record starts") || text.contains("record")
        particleOptions.masks = show == "Masks"
        particleOptions.blackBackground = context.settings.blackBackground
        let summarize = options.flag(forLabel: "Summarize")
        if summarize { context.settings.measurements.insert(.area) }
        var measurements = context.settings.measurements
        measurements.remove(.limitToThreshold)

        if options.flag(forLabel: "Clear results") { context.results.reset() }
        let threshold = open.threshold.flatMap { $0.lower <= $0.upper ? $0.lower...$0.upper : nil }
        let dims = open.image.dimensions
        var masks: [Plane] = []
        for index in FilterCommands.targetPlanes(open, options) {
            let (c, z, t) = (index % dims.channels, (index / dims.channels) % dims.slices, index / (dims.channels * dims.slices))
            let result: ParticleAnalyzer.Result
            do {
                result = try ParticleAnalyzer.analyze(
                    open.image, channel: c, slice: z, frame: t, roi: open.roi, threshold: threshold,
                    measurements: measurements, options: particleOptions, into: &context.results)
            } catch ParticleAnalyzer.Failure.noThreshold {
                throw CommandError.failed(
                    command: name,
                    detail: "A threshold has not been set using the Image->Adjust->Threshold tool or the setThreshold(min,max) macro function.")
            } catch {
                throw CommandError.notNative(name)
            }
            if let mask = result.mask { masks.append(mask) }
            if summarize {
                let label: String
                if open.image.stack.count > 1 {
                    let short = Analyzer.shortSliceLabel(open.image.stack.labels[index]) ?? ""
                    label = short.isEmpty ? String(index + 1) : short
                } else {
                    label = open.title
                }
                let title = open.image.stack.count == 1 ? "Summary" : "Summary of " + open.title
                var summary = context.tables[title] ?? ResultsTable()
                ParticleAnalyzer.summarize(
                    label: label, count: result.count, totalArea: result.totalArea, measurements: measurements,
                    results: context.results, into: &summary)
                context.tables[title] = summary
            }
        }
        if particleOptions.masks, !masks.isEmpty {
            do {
                let stack = try ImageStack(width: open.image.width, height: open.image.height, planes: masks)
                let lut: LUT = LUT.grays.inverted()
                let mask = try Hyperstack(
                    title: "Mask of " + open.title, stack: stack, calibration: open.image.calibration,
                    channels: [ChannelDisplay(lut: lut, displayRange: 0...255)])
                context.add(mask)
            } catch {
                throw CommandError.failed(command: name, detail: "\(error)")
            }
        }
    }

    static let clearResults = CommandDefinition("Clear Results", menu: "Analyze") { context, _ in
        context.results.reset()
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
