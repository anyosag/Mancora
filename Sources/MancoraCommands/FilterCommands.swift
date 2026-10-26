import MancoraCore
import MancoraProcess

/// Process ▸ Filters, Noise, Binary and the 3×3 filters, run as ImageJ's
/// PlugInFilters run them from a macro.
enum FilterCommands {
    static var all: [CommandDefinition] {
        [gaussianBlur, smooth, sharpen, findEdges, despeckle, convolve, binaryOptions]
            + rankCommands + binaryCommands
    }

    /// `IJ.setupDialog`: the stack indices a filter processes. All of them
    /// with `stack` (and for a composite shown as one, unless `slice`),
    /// otherwise the current plane.
    static func targetPlanes(_ open: OpenImage, _ options: MacroOptions) -> [Int] {
        let image = open.image
        let current = image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
        guard image.stack.count > 1 else { return [current] }
        let text = options.text.hasSuffix(" ") ? options.text : options.text + " "
        if image.channels.count > 1, image.compositeMode == .composite, !text.contains("slice") {
            return Array(0..<image.stack.count)
        }
        return text.contains("stack ") ? Array(0..<image.stack.count) : [current]
    }

    /// Runs `filter` on each target plane of the current image.
    static func apply(
        _ name: String, _ context: inout CommandContext, _ options: MacroOptions,
        _ filter: (Plane, Int, OpenImage) throws -> Plane
    ) throws {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let snapshot = open
            for index in targetPlanes(snapshot, options) {
                do {
                    try open.image.setPlane(filter(snapshot.image.stack[index], snapshot.image.width, snapshot), at: index)
                } catch let error as CommandError {
                    throw error
                } catch {
                    throw .failed(command: name, detail: "\(error)")
                }
            }
        }
    }

    /// The current channel's LUT is inverted (`ImageProcessor.isInvertedLut`).
    static func hasInvertedLUT(_ open: OpenImage) -> Bool {
        open.image.pixelType.usesLUT && open.image.channels[open.channel].lut.isInverted
    }

    // MARK: Process ▸ Filters

    /// `GaussianBlur`: `sigma=` (or an old macro's `radius=`, 2.5 sigmas),
    /// in calibrated units with `scaled` when the image has a scale.
    static let gaussianBlur = CommandDefinition("Gaussian Blur...", menu: "Process>Filters") { context, options in
        var macro = options
        var oldMacro = false
        if options.text.contains("radius=") {
            oldMacro = true
            macro = MacroOptions(options.text.replacing("radius=", with: "sigma="))
        }
        var sigma = abs(macro.number(forLabel: "Sigma (Radius):", default: 2))
        if oldMacro { sigma /= 2.5 }
        try apply("Gaussian Blur...", &context, macro) { plane, width, open in
            let cal = open.image.calibration
            let scaled = cal.unit != "pixel" && cal.unit != "pixels" && macro.flag(forLabel: "Scaled Units")
            let sigmaX = scaled ? sigma / cal.pixelWidth : sigma
            let sigmaY = scaled ? sigma / cal.pixelHeight : sigma
            return plane.gaussianBlurred(sigmaX: sigmaX, sigmaY: sigmaY, width: width)
        }
    }

    static let smooth = CommandDefinition("Smooth", menu: "Process") { context, options in
        try apply("Smooth", &context, options) { plane, width, _ in plane.smoothed(width: width) }
    }

    static let sharpen = CommandDefinition("Sharpen", menu: "Process") { context, options in
        try apply("Sharpen", &context, options) { plane, width, _ in plane.sharpened(width: width) }
    }

    static let findEdges = CommandDefinition("Find Edges", menu: "Process") { context, options in
        try apply("Find Edges", &context, options) { plane, width, _ in plane.findingEdges(width: width) }
    }

    /// `RankFilters`: Mean, Minimum, Maximum, Variance, Median, Remove
    /// Outliers and Remove NaNs, each with `radius=` (default 2).
    static let rankCommands: [CommandDefinition] = [
        rank("Mean...", .mean), rank("Minimum...", .minimum), rank("Maximum...", .maximum),
        rank("Variance...", .variance), rank("Median...", .median), rank("Remove NaNs...", .removeNaNs),
        CommandDefinition("Remove Outliers...", menu: "Process>Noise") { context, options in
            let radius = options.number(forLabel: "Radius", default: 2)
            let threshold = options.number(forLabel: "Threshold:", default: 50)
            let dark = options.value(forLabel: "Which outliers") == "Dark"
            try apply("Remove Outliers...", &context, options) { plane, width, open in
                // ImageJ swaps the sides for an image shown with an inverted LUT.
                let side: RankFilter.Outliers = dark != hasInvertedLUT(open) ? .dark : .bright
                return plane.rankFiltered(.removeOutliers(side, threshold: Double(Float(threshold))), radius: radius, width: width)
            }
        },
    ]

    static func rank(_ name: String, _ filter: RankFilter) -> CommandDefinition {
        CommandDefinition(name, menu: name == "Remove NaNs..." ? "Process>Noise" : "Process>Filters") { context, options in
            let radius = options.number(forLabel: "Radius", default: 2)
            try apply(name, &context, options) { plane, width, _ in plane.rankFiltered(filter, radius: radius, width: width) }
            if filter == .variance { try varianceDisplayRange(name, &context) }
        }
    }

    /// RankFilters' final step after Variance: a 0.5% saturated display
    /// range for 16- and 32-bit images.
    static func varianceDisplayRange(_ name: String, _ context: inout CommandContext) throws {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            guard open.image.pixelType == .gray16 || open.image.pixelType == .gray32Float else { return }
            guard let range = try? ContrastEnhancer.displayRange(for: open.currentPlane, saturated: 0.5) else { return }
            var display = open.image.channels[open.channel]
            display.displayRange = range
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    /// `RankFilters("despeckle")`: a radius-1 median.
    static let despeckle = CommandDefinition("Despeckle", menu: "Process>Noise") { context, options in
        try apply("Despeckle", &context, options) { plane, width, _ in plane.despeckled(width: width) }
    }

    /// `Convolver`: the kernel in `text1=` (rows on separate lines, or
    /// n² values on one), with `normalize`.
    static let convolve = CommandDefinition("Convolve...", menu: "Process>Filters") { context, options in
        let name = "Convolve..."
        guard let text = options.value(forLabel: "text1") else {
            throw CommandError.invalidOption(command: name, detail: "no kernel (text1=)")
        }
        let kernel = try parseKernel(text, command: name)
        let normalize = options.flag(forLabel: "Normalize Kernel")
        try apply(name, &context, options) { plane, width, _ in plane.convolved(with: kernel, normalize: normalize, width: width) }
        try resetDisplayRange(name, &context)
    }

    /// `ImageProcessor.resetMinAndMax` on the current plane, as filters with
    /// a final processing step do: the data's range (0–255 for 8-bit).
    static func resetDisplayRange(_ name: String, _ context: inout CommandContext) throws {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            guard open.image.pixelType.usesLUT else { return }
            var display = open.image.channels[open.channel]
            if open.image.pixelType == .gray8 {
                display.displayRange = 0...255
            } else if let range = open.currentPlane.valueRange() {
                display.displayRange = range
            }
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    /// `Convolver.decodeKernel` (and `decodeSquareKernel` for one line).
    static func parseKernel(_ text: String, command: String) throws(CommandError) -> ConvolutionKernel {
        func split(_ s: Substring, _ separators: String) -> [Substring] {
            s.split(whereSeparator: { separators.contains($0) })
        }
        func value(_ s: Substring) -> Float { Float(Double(String(s)) ?? 0) }
        let trimmed = Substring(MacroOptions.trimmed(text))
        var width = 0, height = 0
        var values: [Float] = []
        if !text.contains("\n") {
            values = split(trimmed, " \t\r,").map(value)
            let n = Int(Double(values.count).squareRoot())
            guard n * n == values.count else {
                throw .invalidOption(command: command, detail: "a one-line kernel needs a square number of values")
            }
            (width, height) = (n, n)
        } else {
            let rows = split(trimmed, "\n")
            height = rows.count
            width = rows.first.map { split($0, " \t\r").count } ?? 0
            for row in rows {
                let cells = split(row, " \t\r")
                guard cells.count == width else {
                    throw .invalidOption(command: command, detail: "every row must be as long as the first")
                }
                values += cells.map(value)
            }
        }
        do {
            return try ConvolutionKernel(width: width, height: height, values: values)
        } catch {
            throw .invalidOption(command: command, detail: "Kernel must have odd width and height. This one is \(width)x\(height).")
        }
    }

    // MARK: Process ▸ Binary

    static let binaryCommands: [CommandDefinition] = [
        ("Erode", BinaryOperation.erode), ("Dilate", .dilate), ("Open", .open), ("Close-", .close),
        ("Outline", .outline), ("Fill Holes", .fillHoles), ("Skeletonize", .skeletonize),
    ].map { name, operation in
        CommandDefinition(name, menu: "Process>Binary") { context, options in
            try binary(name, operation, &context, options)
        }
    }

    /// `Binary`: 8-bit images of 0 and 255 only; the foreground follows
    /// Black background (swapped for an inverted LUT, except by Outline).
    static func binary(
        _ name: String, _ operation: BinaryOperation, _ context: inout CommandContext, _ options: MacroOptions
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard case .gray8(let pixels) = open.currentPlane, pixels.allSatisfy({ $0 == 0 || $0 == 255 }) else {
            throw CommandError.failed(command: name, detail: "8-bit binary (0 and 255 only) image required.")
        }
        let settings = context.settings
        let singlePlane = targetPlanes(open, options).count == 1
        try apply(name, &context, options) { plane, width, open in
            if operation == .outline, settings.blackBackground, singlePlane {
                return try snapshotOutline(plane, width: width)
            }
            let black = operation == .outline ? settings.blackBackground : settings.blackBackground != hasInvertedLUT(open)
            let binaryOptions = BinaryOptions(
                blackBackground: black, iterations: settings.binaryIterations, count: settings.binaryCount,
                padEdges: settings.padEdges)
            return try plane.binary(operation, options: binaryOptions, width: width)
        }
    }

    /// Outline with Black background on one plane, as ImageJ computes it:
    /// `Binary.outline` inverts the plane, but the undo snapshot ImageJ took
    /// of a single plane is what `BinaryProcessor` then reads (snapshot copy
    /// mode), so it outlines the original's black regions and inverts that.
    /// The outline ends up on the background side of white objects; edge
    /// pixels keep their values.
    static func snapshotOutline(_ plane: Plane, width: Int) throws -> Plane {
        guard case .gray8(let original) = plane,
            case .gray8(let outlined) = try plane.binary(.outline, options: BinaryOptions(blackBackground: false), width: width)
        else { return plane }
        let height = original.count / width
        var out = original
        for y in 1..<max(height - 1, 1) {
            for x in 1..<max(width - 1, 1) {
                out[y * width + x] = 255 - outlined[y * width + x]
            }
        }
        return .gray8(out)
    }

    /// Process ▸ Binary ▸ Options: iterations, count, Black background, Pad
    /// edges and EDM output, then `do=` one of the binary commands.
    static let binaryOptions = CommandDefinition("Options...", menu: "Process>Binary") { context, options in
        let name = "Options..."
        var settings = context.settings
        settings.binaryIterations = min(max(Int(options.number(forLabel: "Iterations (1-100):", default: Double(settings.binaryIterations))), 1), 100)
        settings.binaryCount = min(max(Int(options.number(forLabel: "Count (1-8):", default: Double(settings.binaryCount))), 1), 8)
        settings.blackBackground = options.flag(forLabel: "Black background")
        settings.padEdges = options.flag(forLabel: "Pad edges when eroding")
        if let edm = options.value(forLabel: "EDM output:") {
            guard let index = EDMOutput.names.firstIndex(of: edm), let output = EDMOutput(rawValue: index) else {
                throw CommandError.invalidOption(command: name, detail: "\"\(edm)\" is not a valid choice for \"EDM output:\"")
            }
            settings.edmOutput = output
        }
        context.settings = settings
        let operations: [String: (String, BinaryOperation)] = [
            "Erode": ("Erode", .erode), "Dilate": ("Dilate", .dilate), "Open": ("Open", .open),
            "Close": ("Close-", .close), "Outline": ("Outline", .outline), "Fill Holes": ("Fill Holes", .fillHoles),
            "Skeletonize": ("Skeletonize", .skeletonize),
        ]
        guard let operation = options.value(forLabel: "Do:"), operation != "Nothing" else { return }
        guard let (command, op) = operations[operation] else { throw CommandError.notNative(name) }
        try binary(command, op, &context, options)
    }
}
