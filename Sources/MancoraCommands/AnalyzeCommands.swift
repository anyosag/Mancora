import MancoraCore
import MancoraProcess

/// Analyze ▸ Measure for every kind of selection, Summarize, Image ▸ Stacks
/// ▸ Measure Stack and Statistics, as ImageJ's `Analyzer`, the
/// `MeasureStack` macro and `Stack_Statistics` run them.
enum AnalyzeCommands {
    static var all: [CommandDefinition] { [summarize, measureStack, statistics] }

    /// The image Set Measurements redirects to, or `nil` for none: the same
    /// size as `open` (`getRedirectImage`), at `open`'s stack position when
    /// the stacks are as deep (`getRedirectImageOrStack`, which moves it there).
    static func redirectTarget(_ name: String, for open: OpenImage, _ context: inout CommandContext) throws(CommandError) -> OpenImage? {
        guard let id = context.settings.measurementRedirect else { return nil }
        guard let target = context.images.first(where: { $0.id == id }) else {
            context.settings.measurementRedirect = nil
            throw .failed(command: name, detail: "Redirect image not found.")
        }
        guard target.image.width == open.image.width, target.image.height == open.image.height else {
            throw .failed(command: name, detail: "Redirect image (\"\(target.title)\") \nis not the same size as the current image.")
        }
        let depth = target.image.stack.count
        guard depth > 1, depth == open.image.stack.count else { return target }
        let index = open.image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
        let position = target.image.dimensions.position(ofPlane: index)
        let current = context.current?.id
        try context.select(id: id)
        let moved = try context.withCurrent(name) { (t: inout OpenImage) throws(CommandError) -> OpenImage in
            (t.channel, t.slice, t.frame) = (position.channel, position.slice, position.frame)
            return t
        }
        if let current { try context.select(id: current) }
        return moved
    }

    /// `Calibration.getUnits()`: the unit, plural where ImageJ makes it so.
    static func units(_ cal: Calibration) -> String {
        switch cal.unit {
        case "pixel", "": "pixels"
        case "micron": "microns"
        case "inch": "inches"
        default: cal.unit
        }
    }

    /// Set Measurements' `redirect=`: `nil` for None, the ID of the first
    /// image with the title, or the current setting when not given.
    static func redirectChoice(_ options: MacroOptions, _ context: CommandContext) throws(CommandError) -> Int? {
        guard let title = options.value(forLabel: "Redirect to:") else { return context.settings.measurementRedirect }
        if title == "None" { return nil }
        guard let image = context.images.first(where: { $0.title == title }) else {
            throw .invalidOption(command: "Set Measurements...", detail: "\"\(title)\" is not a valid choice for \"Redirect to:\"")
        }
        return image.id
    }

    /// Set Measurements' `ResultsTable.update` of the Results table when the
    /// measurements change, as ImageJ does with its Results window open (the
    /// app and the bridge): summary rows go, and the columns follow the new
    /// measurements of the current image and selection.
    static func updateResults(_ context: inout CommandContext, from old: Measurements) {
        let new = context.settings.measurements
        guard old.subtracting(.scientificNotation) != new.subtracting(.scientificNotation) else { return }
        Analyzer.clearSummary(&context.results)
        let open = context.current
        Analyzer.update(
            &context.results, options: new, image: open?.image, channel: open?.channel ?? 0, slice: open?.slice ?? 0,
            frame: open?.frame ?? 0, roi: open?.roi)
    }

    /// The raw threshold an image's statistics are limited to, if any.
    static func thresholdRange(_ open: OpenImage) -> ClosedRange<Double>? {
        open.threshold.flatMap { $0.lower <= $0.upper ? $0.lower...$0.upper : nil }
    }

    /// `Analyzer.measure`: a row for the image or its area selection (of
    /// the redirect image's pixels, if one is set), or for a line, the
    /// points of a point selection, or an angle.
    static func measure(_ context: inout CommandContext) throws {
        let name = "Measure"
        guard let open = context.current else { throw CommandError.noImage(name) }
        let options = context.settings.measurements
        let roi = open.roi
        if open.image.encodedROI != nil && roi == nil { throw CommandError.notNative(name) }  // unreadable selection
        if let roi, roi.kind == .composite { throw CommandError.notNative(name) }  // ShapeRoi masks: ImageJ
        if roi != nil && options.contains(.addToOverlay) { throw CommandError.notNative(name) }  // overlays: ImageJ
        let target = try redirectTarget(name, for: open, &context)
        Analyzer.prepareForMeasure(&context.results)
        let current = open.image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
        let label = Analyzer.label(
            title: target?.title ?? open.title, image: open.image, stackIndex: current, roiName: roi?.name)
        do {
            if let roi, !roi.isArea {
                guard target == nil else { throw CommandError.notNative(name) }  // ImageJ moves the selection to it
                switch roi.kind {
                case .point:
                    try Analyzer.measurePoints(
                        roi, in: open.image, channel: open.channel, slice: open.slice, frame: open.frame, options: options,
                        threshold: thresholdRange(open), label: label, into: &context.results)
                case .angle:
                    Analyzer.measureAngle(
                        roi, in: open.image, channel: open.channel, slice: open.slice, frame: open.frame, options: options,
                        label: label, into: &context.results)
                default:
                    try Analyzer.measureLine(
                        roi, in: open.image, channel: open.channel, slice: open.slice, frame: open.frame, options: options,
                        threshold: thresholdRange(open), label: label, into: &context.results)
                }
                return
            }
            guard let target else {
                try Analyzer.measure(
                    open.image, channel: open.channel, slice: open.slice, frame: open.frame, roi: roi, options: options,
                    threshold: thresholdRange(open), into: &context.results)
                return
            }
            // getRedirectStats: the redirect image's plane, calibration and threshold.
            if open.title == "mask" && open.image.pixelType == .gray8 { throw CommandError.notNative(name) }
            let region = try roi.map { roi throws(RoiMaskError) in
                try roi.measurementRegion(width: open.image.width, height: open.image.height)
            }
            let stats = MeasurementStatistics(
                plane: target.currentPlane, width: target.image.width, region: region, options: options,
                calibration: target.image.calibration, threshold: thresholdRange(target))
            Analyzer.saveResults(
                stats, image: open.image, channel: open.channel, slice: open.slice, frame: open.frame, roi: roi,
                options: options, label: label, into: &context.results)
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError.notNative(name)
        }
    }

    /// `Analyzer.summarize`: Mean, SD, Min and Max rows of every column,
    /// once there are two rows and no summary yet.
    static let summarize = CommandDefinition("Summarize", menu: "Analyze") { context, _ in
        var table = context.results
        let n = table.count
        guard n >= 2, table.labels[n - 1] != "Max" else { return }
        let columns = table.columns
        guard !columns.isEmpty else { return }
        var low = [Double](repeating: Double.greatestFiniteMagnitude, count: columns.count)
        var high = [Double](repeating: -Double.greatestFiniteMagnitude, count: columns.count)
        var sum = [Double](repeating: 0, count: columns.count)
        var sum2 = [Double](repeating: 0, count: columns.count)
        for row in 0..<n {
            for (c, column) in columns.enumerated() {
                let v = table.number(column, row: row)
                if v < low[c] { low[c] = v }
                if v > high[c] { high[c] = v }
                sum[c] += v
                sum2[c] += v * v
            }
        }
        let count = Double(n)
        for (label, value) in [
            ("Mean", { (c: Int) in sum[c] / count }),
            ("SD", { (c: Int) in ((sum2[c] - sum[c] * sum[c] / count) / (count - 1)).squareRoot() }),
            ("Min", { (c: Int) in low[c] }), ("Max", { (c: Int) in high[c] }),
        ] {
            let row = table.addRow(label: label)
            for (c, column) in columns.enumerated() { table.set(column, row: row, value(c)) }
        }
        context.results = table
    }

    /// Image ▸ Stacks ▸ Measure Stack (ImageJ's `MeasureStack` macro):
    /// Measure on every slice with Stack position on, then for a calibrated
    /// stack a column of each row's depth; a hyperstack measures the
    /// `channels`, `slices` and `frames` ticked (the current position for
    /// the others) in `order=`.
    static let measureStack = CommandDefinition("Measure Stack...", menu: "Image>Stacks") { context, options in
        let name = "Measure Stack..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let saved = context.settings
        context.settings.measurements.insert(.stackPosition)
        defer { context.settings = saved }
        let dims = open.image.dimensions
        let hyperstack = ExtraFilterCommands.isHyperstack(open.image)
        func moveTo(_ c: Int, _ z: Int, _ t: Int) throws {
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                (open.channel, open.slice, open.frame) = (c, z, t)
            }
        }
        guard hyperstack else {
            for index in 0..<open.image.stack.count {
                let p = dims.position(ofPlane: index)
                try moveTo(p.channel, p.slice, p.frame)
                try measure(&context)
            }
            let cal = open.image.calibration
            let unit = units(cal)
            if unit != "pixels" {
                for row in 0..<context.results.count { context.results.set(unit, row: row, Double(row) * cal.pixelDepth) }
            }
            return
        }
        // The dialog: checkboxes off unless named, "czt(default)" order.
        let all = (c: options.flag(forLabel: "Channels"), z: options.flag(forLabel: "Slices"), t: options.flag(forLabel: "Frames"))
        let order = options.value(forLabel: "Order:") ?? "czt(default)"
        let channels = all.c ? Array(0..<dims.channels) : [open.channel]
        let slices = all.z ? Array(0..<dims.slices) : [open.slice]
        let frames = all.t ? Array(0..<dims.frames) : [open.frame]
        // Outermost first.
        let loops: [Character]
        switch order {
        case "ctz": loops = ["z", "t", "c"]
        case "zct": loops = ["t", "c", "z"]
        case "ztc": loops = ["c", "t", "z"]
        case "tcz": loops = ["z", "c", "t"]
        case "tzc": loops = ["c", "z", "t"]
        case "czt(default)": loops = ["t", "z", "c"]
        default: throw CommandError.invalidOption(command: name, detail: "\"\(order)\" is not a valid choice for \"Order:\"")
        }
        func values(_ axis: Character) -> [Int] { axis == "c" ? channels : axis == "z" ? slices : frames }
        var position = (c: open.channel, z: open.slice, t: open.frame)
        func set(_ axis: Character, _ v: Int) {
            switch axis {
            case "c": position.c = v
            case "z": position.z = v
            default: position.t = v
            }
        }
        for a in values(loops[0]) {
            set(loops[0], a)
            for b in values(loops[1]) {
                set(loops[1], b)
                for c in values(loops[2]) {
                    set(loops[2], c)
                    try moveTo(position.c, position.z, position.t)
                    try measure(&context)
                }
            }
        }
        try moveTo(open.channel, open.slice, open.frame)
    }

    /// `Stack_Statistics`: one row of the whole stack's statistics within
    /// the area selection (a line or point selection is removed), limited
    /// to the threshold: Voxels, Volume, %Volume, Mean, StdDev, Min, Max,
    /// Mode and Median.
    static let statistics = CommandDefinition("Statistics", menu: "Image>Stacks") { context, _ in
        let name = "Statistics"
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        guard image.calibration.valueFunction == nil else { throw CommandError.notNative(name) }
        let roi = open.roi
        if image.encodedROI != nil && roi == nil { throw CommandError.notNative(name) }
        // Composites need ShapeRoi masks; a line or point selection is measured within its bounds.
        if let r = roi, r.kind == .composite || !r.isArea { throw CommandError.notNative(name) }
        let row = context.results.addRow()
        let region: MeasurementRegion?
        do {
            region = try roi.map { r throws(RoiMaskError) in try r.measurementRegion(width: image.width, height: image.height) }
        } catch {
            throw CommandError.notNative(name)
        }
        let planes = image.stack.planes
        let threshold = image.pixelType == .rgb8 ? nil : thresholdRange(open)
        let stats = StackStatistics(planes: planes, width: image.width, region: region, threshold: threshold)
        let images = Double(planes.count)
        let stackVoxels: Double
        if let roi {
            if case .rectangle(_, 0) = roi.shape {
                let b = roi.bounds
                stackVoxels = Double(b.width * b.height) * images
            } else {
                stackVoxels = Double(StackStatistics(planes: planes, width: image.width, region: region, threshold: nil).pixelCount)
            }
        } else {
            stackVoxels = Double(image.width * image.height) * images
        }
        let cal = image.calibration
        let unitName = units(cal)
        let scale = cal.pixelWidth * cal.pixelHeight * cal.pixelDepth
        var results = context.results
        results.set("Voxels", row: row, Double(stats.pixelCount))
        if scale != 1.0 { results.set("Volume(\(unitName)^3)", row: row, Double(stats.pixelCount) * scale) }
        results.set("%Volume", row: row, Double(stats.pixelCount) * 100.0 / stackVoxels)
        results.set("Mean", row: row, stats.mean)
        results.set("StdDev", row: row, stats.standardDeviation)
        results.set("Min", row: row, stats.min)
        results.set("Max", row: row, stats.max)
        results.set("Mode", row: row, stats.mode)
        results.set("Median", row: row, stats.median)
        context.results = results
    }
}
