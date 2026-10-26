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

    /// Runs `filter` on each target plane of the current image. Run on the
    /// current plane alone (not as a stack), the filter clears an invisible
    /// binary threshold, as `PlugInFilterRunner` does.
    static func apply(
        _ name: String, _ context: inout CommandContext, _ options: MacroOptions,
        _ filter: (Plane, Int, OpenImage) throws -> Plane
    ) throws {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let snapshot = open
            let targets = targetPlanes(snapshot, options)
            if targets.count == 1 { open.resetBinaryThreshold() }
            for index in targets {
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

    /// `PlugInFilterRunner.prepareProcessor`: the region an area selection
    /// gives the filter, or `nil` for none (lines and points count as none).
    /// Selections whose mask Mancora can't compute are left to ImageJ.
    static func selectionRegion(_ name: String, _ open: OpenImage) throws(CommandError) -> FilterRegion? {
        guard open.image.encodedROI != nil else { return nil }
        guard let roi = open.roi else { throw .notNative(name) }  // a selection Mancora can't read
        // Text and image selections are rectangles to ImageJ; composite ones need their mask.
        if case .opaque = roi.shape { throw .notNative(name) }
        do {
            return try FilterRegion(selection: roi, width: open.image.width, height: open.image.height)
        } catch {
            throw .notNative(name)
        }
    }

    /// The area selection as the pixels it measures (its bounds clipped to
    /// the image, and a mask unless it's a rectangle), or `nil` for none or
    /// a line or point selection.
    static func measurementRegion(_ open: OpenImage, _ name: String) throws(CommandError) -> MeasurementRegion? {
        guard let roi = open.roi, roi.isArea else { return nil }
        guard roi.kind != .composite else { throw .notNative(name) }  // ShapeRoi masks: ImageJ
        do {
            return try roi.measurementRegion(width: open.image.width, height: open.image.height)
        } catch {
            throw .notNative(name)
        }
    }

    /// Runs `filter` on each target plane within the selection, as
    /// `PlugInFilterRunner` runs a filter: `filter` gets the selection's
    /// bounds (`nil` without an area selection) and, for filters that
    /// support masking, the pixels of the bounds outside a non-rectangular
    /// selection are put back afterwards (`ip.reset(mask)`).
    static func applyInSelection(
        _ name: String, _ context: inout CommandContext, _ options: MacroOptions, masking: Bool = true,
        _ filter: (Plane, Int, OpenImage, FilterRegion?) throws -> Plane
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        let region = try selectionRegion(name, open)
        try apply(name, &context, options) { plane, width, open in
            let filtered = try filter(plane, width, open, region)
            guard masking, let region else { return filtered }
            return region.restoringOutsideMask(filtered, snapshot: plane, width: width)
        }
    }

    /// The current channel's LUT is inverted (`ImageProcessor.isInvertedLut`).
    static func hasInvertedLUT(_ open: OpenImage) -> Bool {
        open.image.pixelType.usesLUT && open.image.channels[open.channel].lut.isInverted
    }

    // MARK: Process ▸ Filters

    /// `GaussianBlur`: `sigma=` (or an old macro's `radius=`, 2.5 sigmas),
    /// in calibrated units with `scaled` when the image has a scale. A
    /// negative sigma, which the dialog listener takes as given, blurs
    /// nothing.
    static let gaussianBlur = CommandDefinition("Gaussian Blur...", menu: "Process>Filters") { context, options in
        var macro = options
        var oldMacro = false
        if options.text.contains("radius=") {
            oldMacro = true
            macro = MacroOptions(options.text.replacing("radius=", with: "sigma="))
        }
        var sigma = macro.number(forLabel: "Sigma (Radius):", default: 2)
        if oldMacro { sigma /= 2.5 }
        try applyInSelection("Gaussian Blur...", &context, macro) { plane, width, open, region in
            let cal = open.image.calibration
            let scaled = cal.unit != "pixel" && cal.unit != "pixels" && macro.flag(forLabel: "Scaled Units")
            let sigmaX = scaled ? sigma / cal.pixelWidth : sigma
            let sigmaY = scaled ? sigma / cal.pixelHeight : sigma
            return plane.gaussianBlurred(sigmaX: sigmaX, sigmaY: sigmaY, width: width, rect: region?.rect)
        }
    }

    static let smooth = CommandDefinition("Smooth", menu: "Process") { context, options in
        try applyInSelection("Smooth", &context, options) { plane, width, _, region in
            plane.smoothed(width: width, rect: region?.rect)
        }
    }

    static let sharpen = CommandDefinition("Sharpen", menu: "Process") { context, options in
        try applyInSelection("Sharpen", &context, options) { plane, width, _, region in
            plane.sharpened(width: width, rect: region?.rect)
        }
    }

    static let findEdges = CommandDefinition("Find Edges", menu: "Process") { context, options in
        try applyInSelection("Find Edges", &context, options) { plane, width, _, region in
            plane.findingEdges(width: width, rect: region?.rect)
        }
    }

    /// `RankFilters`: Mean, Minimum, Maximum, Variance, Median, Remove
    /// Outliers and Remove NaNs, each with `radius=` (default 2).
    static let rankCommands: [CommandDefinition] = [
        rank("Mean...", .mean), rank("Minimum...", .minimum), rank("Maximum...", .maximum),
        rank("Variance...", .variance), rank("Median...", .median), rank("Remove NaNs...", .removeNaNs),
        CommandDefinition("Remove Outliers...", menu: "Process>Noise") { context, options in
            let radius = try rankRadius(options, "Remove Outliers...")
            let threshold = options.number(forLabel: "Threshold:", default: 50)
            let dark = options.value(forLabel: "Which outliers") == "Dark"
            try applyInSelection("Remove Outliers...", &context, options) { plane, width, open, region in
                // ImageJ swaps the sides for an image shown with an inverted LUT.
                let side: RankFilter.Outliers = dark != hasInvertedLUT(open) ? .dark : .bright
                return plane.rankFiltered(
                    .removeOutliers(side, threshold: Double(Float(threshold))), radius: radius, width: width,
                    rect: region?.rect)
            }
        },
    ]

    static func rank(_ name: String, _ filter: RankFilter) -> CommandDefinition {
        CommandDefinition(name, menu: name == "Remove NaNs..." ? "Process>Noise" : "Process>Filters") { context, options in
            let radius = try rankRadius(options, name)
            try applyInSelection(name, &context, options) { plane, width, _, region in
                plane.rankFiltered(filter, radius: radius, width: width, rect: region?.rect)
            }
            if filter == .variance { try varianceDisplayRange(name, &context) }
        }
    }

    /// The `radius=` a rank filter runs with. RankFilters' dialog listener
    /// rejects a negative radius but keeps it, and `makeLineRadii` squares it.
    static func rankRadius(_ options: MacroOptions, _ name: String) throws(CommandError) -> Double {
        let radius = options.number(forLabel: "Radius", default: 2)
        guard radius.isFinite, radius.magnitude <= 1000 else {
            throw .invalidOption(command: name, detail: "radius \(radius) is out of range")
        }
        return radius
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
        try applyInSelection("Despeckle", &context, options) { plane, width, _, region in
            plane.despeckled(width: width, rect: region?.rect)
        }
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
        try applyInSelection(name, &context, options) { plane, width, _, region in
            plane.convolved(with: kernel, normalize: normalize, width: width, rect: region?.rect)
        }
        // The final step resets the display range only without a selection (of any kind).
        if context.current?.image.encodedROI == nil { try resetDisplayRange(name, &context) }
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

    /// `Convolver.decodeKernel` (and, for one line, `decodeSquareKernel`,
    /// which takes the largest square of the values, at least 3×3 and odd).
    static func parseKernel(_ text: String, command: String) throws(CommandError) -> ConvolutionKernel {
        // Tools.split's default delimiters.
        func split(_ s: Substring, _ separators: String = " \t\n\r") -> [Substring] {
            s.split(whereSeparator: { separators.contains($0) })
        }
        func value(_ s: Substring) -> Float { Float(Double(String(s)) ?? 0) }
        // String.trim(): everything up to the space character.
        let trimmed = text.drop { $0.asciiValue.map { $0 <= 32 } ?? false }
            .reversed().drop { $0.asciiValue.map { $0 <= 32 } ?? false }.reversed()
        var width = 0, height = 0
        var values: [Float] = []
        if !text.contains("\n") {
            let cells = split(Substring(text))
            let n = Int(Double(cells.count).squareRoot())
            guard n >= 3, n % 2 == 1 else {
                throw .invalidOption(command: command, detail: "Kernel must be square with odd width. This one is \(n)x\(n).")
            }
            // Tools.parseDouble(s): NaN for what isn't a number.
            values = cells.prefix(n * n).map { Float(Double(String($0)) ?? .nan) }
            (width, height) = (n, n)
        } else {
            // Tools.split(text, "\n") reads lines (BufferedReader.readLine), empty ones too.
            var rows = String(trimmed).replacing("\r\n", with: "\n").replacing("\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            if rows.last?.isEmpty == true { rows.removeLast() }
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
        // PlugInFilterRunner keeps a snapshot of a single image (for undo)
        // and of a stack plane it masks; Outline then reads it (Binary runs
        // in snapshot copy mode).
        let masked = try selectionRegion(name, open)?.mask != nil
        let singlePlane = targetPlanes(open, options).count == 1
        let readsSnapshot = singlePlane || masked
        // Skeletonize resets the processor's selection, and its mask with it.
        try applyInSelection(name, &context, options, masking: operation != .skeletonize) { plane, width, open, region in
            let inverted = hasInvertedLUT(open)
            let black = operation == .outline ? settings.blackBackground : settings.blackBackground != inverted
            let binaryOptions = BinaryOptions(
                blackBackground: black, iterations: settings.binaryIterations, count: settings.binaryCount,
                padEdges: settings.padEdges, invertedLUT: inverted, outlineReadsSnapshot: readsSnapshot)
            return try plane.binary(operation, options: binaryOptions, width: width, rect: region?.rect)
        }
        // Binary.run ends with ip.setBinaryThreshold(), which only the image's
        // own processor (one image, not a stack) keeps.
        guard singlePlane else { return }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let inverted = hasInvertedLUT(open)
            open.setBinaryThreshold(inverted == settings.blackBackground ? 0 : 255)
        }
    }

    /// Process ▸ Binary ▸ Options: iterations, count, Black background, Pad
    /// edges and EDM output, then `do=` one of the binary commands.
    /// Iterations or a count out of range are limited, and then
    /// `dialogItemChanged` stops before it reads `do=`.
    static let binaryOptions = CommandDefinition("Options...", menu: "Process>Binary") { context, options in
        let name = "Options..."
        var settings = context.settings
        // (int)gd.getNextNumber()
        let iterations = Int(JavaNumerics.int32(options.number(forLabel: "Iterations (1-100):", default: Double(settings.binaryIterations))))
        let count = Int(JavaNumerics.int32(options.number(forLabel: "Count (1-8):", default: Double(settings.binaryCount))))
        settings.binaryIterations = min(max(iterations, 1), 100)
        settings.binaryCount = min(max(count, 1), 8)
        settings.blackBackground = options.flag(forLabel: "Black background")
        settings.padEdges = options.flag(forLabel: "Pad edges when eroding")
        if let edm = options.value(forLabel: "EDM output:") {
            guard let index = EDMOutput.names.firstIndex(of: edm), let output = EDMOutput(rawValue: index) else {
                throw CommandError.invalidOption(command: name, detail: "\"\(edm)\" is not a valid choice for \"EDM output:\"")
            }
            settings.edmOutput = output
        }
        context.settings = settings
        guard (1...100).contains(iterations), (1...8).contains(count) else { return }
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
