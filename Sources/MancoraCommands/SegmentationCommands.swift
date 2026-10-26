import MancoraCore
import MancoraProcess

/// Process ▸ Subtract Background, Process ▸ Find Maxima and the distance map
/// commands of Process ▸ Binary (Distance Map, Ultimate Points, Watershed,
/// Voronoi), as ImageJ runs them from a macro.
enum SegmentationCommands {
    static var all: [CommandDefinition] { [subtractBackground, findMaxima] + edmCommands }

    // MARK: Process ▸ Subtract Background

    /// `BackgroundSubtracter`: `rolling=` (default 50 in a macro), `light`
    /// (or an old macro's `white`), `separate` (RGB), `create`, `sliding`,
    /// `disable` and `stack`. Afterwards the current plane's display range
    /// is reset, as the filter's final step does.
    static let subtractBackground = CommandDefinition("Subtract Background...", menu: "Process") { context, options in
        let name = "Subtract Background..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let macro = MacroOptions(options.text.replacing("white", with: "light"))
        var settings = BackgroundOptions()
        settings.radius = macro.number(forLabel: "Rolling ball radius:", default: 50)
        // dialogItemChanged reads the checkboxes only after a valid radius.
        if settings.radius > 0.0001 {
            settings.lightBackground = macro.flag(forLabel: "Light background")
            if open.image.pixelType == .rgb8 { settings.separateColors = macro.flag(forLabel: "Separate colors") }
            settings.createBackground = macro.flag(forLabel: "Create background (don't subtract)")
            settings.useParaboloid = macro.flag(forLabel: "Sliding paraboloid")
            settings.presmooth = !macro.flag(forLabel: "Disable smoothing")
        }
        let invertedLUT = FilterCommands.hasInvertedLUT(open)
        try FilterCommands.apply(name, &context, options) { plane, width, _ in
            do {
                return try plane.subtractingBackground(settings, width: width, invertedLUT: invertedLUT)
            } catch {
                throw CommandError.notNative(name)  // too small to shrink: ImageJ fails its own way
            }
        }
        // The final resetMinAndMax: a composite keeps its channels' ranges.
        if open.image.channels.count == 1 { try FilterCommands.resetDisplayRange(name, &context) }
    }

    // MARK: Process ▸ Find Maxima

    /// `MaximumFinder` on the current plane: `prominence=` (an old macro's
    /// `noise=`), `strict`, `exclude`, `above` (with a threshold), `light`
    /// and `output=`. Image outputs open a new 8-bit image; Point Selection
    /// selects the maxima, List replaces the Results table with their
    /// coordinates and Count adds a row.
    static let findMaxima = CommandDefinition("Find Maxima...", menu: "Process") { context, options in
        let name = "Find Maxima..."
        guard var open = context.current else { throw CommandError.noImage(name) }
        // `ip.resetBinaryThreshold()`: Convert to Mask's invisible threshold goes.
        if let threshold = open.threshold, threshold.lower == threshold.upper { open.threshold = nil }
        let thresholded = open.threshold != nil

        var text = options.text
        let oldMacro = text.contains("noise=")
        if oldMacro { text = text.replacing("noise=", with: "prominence=") }
        let macro = MacroOptions(text)
        let image = open.image
        guard image.calibration.valueFunction == nil else { throw CommandError.notNative(name) }  // calibrated values
        let tolerance = max(macro.number(forLabel: "Prominence >", default: 10), 0)
        let strict = macro.flag(forLabel: "Strict")
        let excludeOnEdges = macro.flag(forLabel: "Exclude edge maxima")
        let useMinThreshold = thresholded && macro.flag(forLabel: "Above lower threshold")
        let lightBackground = macro.flag(forLabel: "Light background")
        let outputName = macro.value(forLabel: "Output type:") ?? MaximaOutput.names[MaximaOutput.pointSelection.rawValue]
        guard let outputIndex = MaximaOutput.names.firstIndex(of: outputName), let output = MaximaOutput(rawValue: outputIndex)
        else {
            throw CommandError.invalidOption(command: name, detail: "\"\(outputName)\" is not a valid choice for \"Output type:\"")
        }
        let invertedLUT = FilterCommands.hasInvertedLUT(open)
        let findMinima = invertedLUT != lightBackground
        // ImageJ asks whether to go on without the threshold when finding minima.
        if useMinThreshold && findMinima { throw CommandError.notNative(name) }

        // run(ip): a line or point selection, or any with segmentation, is removed.
        var roi = open.roi
        if let selection = roi, !selection.isArea || output == .segmented {
            open.roi = nil
            roi = nil
        }
        var region: MaximaRegion?
        if let roi {
            // The rectangle (clipped to the image) and mask that `ip.setRoi(roi)` sets.
            guard let mask = try? roi.mask(width: image.width, height: image.height), mask.bounds.width > 0,
                mask.bounds.height > 0
            else { throw CommandError.notNative(name) }
            // Points are reported where `Roi.contains(x, y)`, whose test differs by shape.
            if output.isPointList && roi.containsPixel(x: 0, y: 0) == nil { throw CommandError.notNative(name) }
            var isRectangle = false
            if case .rectangle(_, cornerDiameter: 0) = roi.shape { isRectangle = true }
            let contains: @Sendable (Int, Int) -> Bool = { x, y in roi.containsPixel(x: x, y: y) ?? true }
            region = MaximaRegion(bounds: mask.bounds, mask: isRectangle ? nil : mask.pixels, contains: contains)
        }

        let plane = open.currentPlane
        var values = TypeConverter.toGray32(plane).gray32Values
        var threshold: Double? = useMinThreshold ? open.threshold?.lower : nil
        if findMinima {
            threshold = nil
            values = invertedValues(plane, values: values, displayRange: image.channels[open.channel].displayRange)
        }
        let isEDM = image.pixelType == .gray32Float && image.title.hasPrefix("EDM of ")
        let result = MaximumFinder.find(
            values: values, width: image.width, height: image.height, isFloat: image.pixelType == .gray32Float,
            tolerance: tolerance, strict: oldMacro ? excludeOnEdges : strict, threshold: threshold, output: output,
            excludeOnEdges: excludeOnEdges, isEDM: isEDM, region: region)

        let currentIndex = image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
        switch output {
        case .pointSelection:
            let n = result.points.count
            if n > 0 {
                let vertices = result.points.map { Roi.FloatPoint(x: Float($0.x), y: Float($0.y)) }
                // PointRoi: Small, or Large for fewer than 15 points, XL for one.
                open.roi = Roi(.points(Roi.Points(.subpixel(vertices), size: n == 1 ? 4 : n < 15 ? 3 : 1)))
            }
            try replace(open, in: &context, name)
        case .list:
            try replace(open, in: &context, name)
            context.results.reset()  // Analyzer.resetCounter()
            for point in result.points {
                let row = context.results.addRow()
                context.results.set("X", row: row, Double(point.x))
                context.results.set("Y", row: row, Double(point.y))
            }
        case .count:
            try replace(open, in: &context, name)
            let row = context.results.addRow()
            context.results.set("Count", row: row, Double(result.points.count))
            if context.settings.measurements.contains(.labels) {
                var label = image.title
                if let roiName = roi?.name { label += ":" + roiName }
                if image.stack.count > 1 {
                    let short = Analyzer.shortSliceLabel(image.stack.labels[currentIndex]) ?? ""
                    let colon = label.isEmpty ? "" : ":"
                    label += colon + (short.isEmpty ? String(currentIndex + 1) : short)
                }
                context.results.setLabel(label, row: row)
            }
        case .singlePoints, .inTolerance, .segmented:
            try replace(open, in: &context, name)
            guard let pixels = result.image else { return }
            var title = image.title
            if image.dimensions.slices > 1 { title += "(\(currentIndex + 1))" }
            title += output == .segmented ? " Segmented" : " Maxima"
            if context.images.contains(where: { $0.title == title }) {
                title = BuiltInCommands.uniqueName(title, among: context.images.map(\.title))
            }
            var calibration = image.calibration
            calibration.valueFunction = nil  // disableDensityCalibration
            calibration.valueUnit = "Gray Value"
            try addImage(
                title: title, planes: [.gray8(pixels)], calibration: calibration,
                lut: context.settings.blackBackground ? .grays : LUT.grays.inverted(), displayRange: 0...255, &context, name)
        }
    }

    /// Writes back the changes Find Maxima made to the current image (its
    /// threshold and selection).
    static func replace(_ open: OpenImage, in context: inout CommandContext, _ name: String) throws {
        try context.withCurrent(name) { (current: inout OpenImage) throws(CommandError) in current = open }
    }

    /// The values MaximumFinder sees when it looks for minima: the plane as
    /// `ImageProcessor.invert()` inverts a duplicate of it (8-bit and RGB
    /// against 255, 16-bit against the data range, 32-bit against the
    /// display range).
    static func invertedValues(_ plane: Plane, values: [Float], displayRange: ClosedRange<Double>) -> [Float] {
        switch plane {
        case .gray8(let p): return p.map { Float(255 - $0) }
        case .gray16(let p):
            guard let lo = p.min(), let hi = p.max() else { return values }
            return p.map { Float(Int(hi) - (Int($0) - Int(lo))) }
        case .gray32Float(let p):
            let min2 = Float(displayRange.lowerBound), max2 = Float(displayRange.upperBound)
            return p.map { max2 - ($0 - min2) }
        case .rgb8(let p):
            return TypeConverter.toGray32(.rgb8(p.map { $0 ^ 0x00FF_FFFF })).gray32Values
        }
    }

    // MARK: Process ▸ Binary ▸ Distance Map, Ultimate Points, Watershed, Voronoi

    static let edmCommands: [CommandDefinition] = [
        ("Distance Map", EDMOperation.distanceMap), ("Ultimate Points", .ultimatePoints), ("Watershed", .watershed),
        ("Voronoi", .voronoi),
    ].map { name, operation in
        CommandDefinition(name, menu: "Process>Binary") { context, options in
            try edm(name, operation, &context, options)
        }
    }

    /// `EDM`: 8-bit binary images; the background is 0 or 255 by Black
    /// background (swapped for an inverted LUT). Watershed and the Overwrite
    /// output change the image; the other outputs of Process ▸ Binary ▸
    /// Options open a new image titled "EDM of", "UEPs of" or "Voronoi of".
    static func edm(_ name: String, _ operation: EDMOperation, _ context: inout CommandContext, _ options: MacroOptions) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard case .gray8(let current) = open.currentPlane, current.allSatisfy({ $0 == 0 || $0 == 255 }) else {
            throw CommandError.failed(command: name, detail: "8-bit binary (0 and 255) required.")
        }
        let image = open.image
        let lut = image.channels[open.channel].lut
        // DOES_8G: ImageJ refuses 8-bit images with a color LUT.
        guard lut.hasSameColors(as: .grays) || lut.hasSameColors(as: LUT.grays.inverted()) else {
            throw CommandError.notNative(name)
        }
        let invertedLUT = FilterCommands.hasInvertedLUT(open)
        let black = context.settings.blackBackground
        let background255 = (invertedLUT && black) || (!invertedLUT && !black)
        let output: EDMOutput = operation == .watershed ? .overwrite : context.settings.edmOutput
        let targets = FilterCommands.targetPlanes(open, options)
        let doStack = image.stack.count > 1 && targets.count == image.stack.count

        func run(_ index: Int) -> EDM.Result {
            guard case .gray8(let pixels) = image.stack[index] else { return EDM.Result() }
            return EDM.run(operation, on: pixels, width: image.width, background255: background255, output: output)
        }

        if output == .overwrite {
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                var last = EDM.Result()
                for index in targets {
                    last = run(index)
                    guard let pixels = last.overwritten else { continue }
                    do { try open.image.setPlane(.gray8(pixels), at: index) } catch { throw .failed(command: name, detail: "\(error)") }
                }
                // Only the image's own processor keeps a display range and threshold;
                // a stack's planes are processed on processors of their own.
                guard !doStack else { return }
                if let range = last.displayRange {
                    var display = open.image.channels[open.channel]
                    display.displayRange = range
                    open.image.setDisplay(display, forChannel: open.channel)
                }
                if operation == .watershed {
                    // ip.setBinaryThreshold()
                    let level: Double = background255 ? 0 : 255
                    open.threshold = ThresholdLevels(lower: level, upper: level)
                } else if let threshold = open.threshold, threshold.lower == threshold.upper {
                    open.threshold = nil  // resetBinaryThreshold
                }
            }
            return
        }

        // A new image of the EDM values.
        let dims = image.dimensions
        if doStack && (dims.channels > 1 || (dims.slices > 1 && dims.frames > 1)) {
            throw CommandError.notNative(name)  // hyperstack output: ImageJ
        }
        let planes = targets.compactMap { run($0).output }
        guard let first = planes.first else { return }
        let range: ClosedRange<Double> = first.pixelType == .gray8 ? 0...255 : first.valueRange() ?? 0...0
        try addImage(
            title: operation.titlePrefix + shortTitle(image.title), planes: planes,
            dimensions: doStack ? dims : nil, labels: doStack ? image.stack.labels : nil, calibration: Calibration(),
            lut: context.settings.blackBackground ? .grays : LUT.grays.inverted(), displayRange: range, &context, name)
    }

    /// `ImagePlus.getShortTitle`: the title without its extension (and then
    /// without spaces), or up to its first space.
    static func shortTitle(_ title: String) -> String {
        let trimmed = String(title.drop { $0 <= " " }.reversed().drop { $0 <= " " }.reversed())
        if let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex {
            return String(trimmed[..<dot]).replacing(" ", with: "")
        }
        if let space = trimmed.firstIndex(of: " ") { return String(trimmed[..<space]) }
        return trimmed
    }

    /// Opens a new single-channel image and makes it current.
    static func addImage(
        title: String, planes: [Plane], dimensions: HyperstackDimensions? = nil, labels: [String?]? = nil,
        calibration: Calibration, lut: LUT, displayRange: ClosedRange<Double>, _ context: inout CommandContext,
        _ name: String
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        do {
            let stack = try ImageStack(width: open.image.width, height: open.image.height, planes: planes, labels: labels)
            let image = try Hyperstack(
                title: title, stack: stack, dimensions: dimensions, calibration: calibration,
                channels: [ChannelDisplay(lut: lut, displayRange: displayRange)])
            context.add(image)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
    }
}

extension Plane {
    /// The values of a 32-bit plane (empty for other types).
    fileprivate var gray32Values: [Float] {
        if case .gray32Float(let p) = self { return p }
        return []
    }
}
