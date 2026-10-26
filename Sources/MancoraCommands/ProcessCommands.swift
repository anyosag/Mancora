import MancoraCore
import MancoraProcess

/// Image ▸ Type, Process ▸ Math, Edit ▸ Invert, Process ▸ Image Calculator
/// and the stack and channel tools, as ImageJ runs them from a macro.
enum ProcessCommands {
    static var all: [CommandDefinition] {
        typeCommands + mathCommands
            + [invert, imageCalculator, zProject, splitChannels, mergeChannels, makeSubstack, reduceDimensionality,
               arrangeChannels]
    }

    /// Replaces the current image with `transform` of it, keeping its title.
    static func replaceCurrent(
        _ name: String, _ context: inout CommandContext, _ transform: (OpenImage) throws -> Hyperstack
    ) throws {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            do {
                var result = try transform(open)
                result.title = open.image.title
                open.image = result
                let dims = result.dimensions
                open.channel = min(open.channel, dims.channels - 1)
                open.slice = min(open.slice, dims.slices - 1)
                open.frame = min(open.frame, dims.frames - 1)
            } catch let error as CommandError {
                throw error
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
        }
    }

    // MARK: Image ▸ Type

    /// `ij.plugin.Converter`, with Edit ▸ Options ▸ Conversions' scaling.
    static let typeCommands: [CommandDefinition] = [
        ("8-bit", PixelType.gray8), ("16-bit", .gray16), ("32-bit", .gray32Float), ("RGB Color", .rgb8),
    ].map { name, type in
        CommandDefinition(name, menu: "Image>Type") { context, _ in
            guard let open = context.current else { throw CommandError.noImage(name) }
            // A composite hyperstack to RGB asks which slices and frames to keep: ImageJ does that.
            if type == .rgb8, open.image.channels.count > 1, open.image.stack.count > open.image.channels.count {
                throw CommandError.notNative(name)
            }
            if open.image.pixelType == type, type != .gray8 { return }  // nothing to do
            let options = ConversionOptions(scale: context.settings.scaleConversions)
            try replaceCurrent(name, &context) { open in try ImageConverter.convert(open.image, to: type, options: options) }
        }
    }

    // MARK: Process ▸ Math and Edit ▸ Invert

    static let mathCommands: [CommandDefinition] = {
        let valued: [(String, @Sendable (Double) -> ImageMath.Operation, Double)] = [
            ("Add...", { .add($0) }, 25), ("Subtract...", { .subtract($0) }, 25), ("Multiply...", { .multiply($0) }, 1.25),
            ("Divide...", { .divide($0) }, 1.25), ("Min...", { .min($0) }, 0), ("Max...", { .max($0) }, 255),
            ("Gamma...", { .gamma($0) }, 0.5), ("Set...", { .set($0) }, 25),
        ]
        let plain: [(String, ImageMath.Operation)] = [
            ("Log", .log), ("Exp", .exp), ("Square", .square), ("Square Root", .squareRoot),
            ("Reciprocal", .reciprocal), ("Abs", .abs),
        ]
        let bitwise: [(String, @Sendable (Int) -> ImageMath.Operation)] = [
            ("AND...", { .and($0) }), ("OR...", { .or($0) }), ("XOR...", { .xor($0) }),
        ]
        return valued.map { name, operation, fallback in
            CommandDefinition(name, menu: "Process>Math") { context, options in
                let value = options.number(forLabel: "Value:", default: fallback)
                try math(name, operation(value), &context, options)
            }
        }
            + plain.map { name, operation in
                CommandDefinition(name, menu: "Process>Math") { context, options in
                    try math(name, operation, &context, options)
                }
            }
            + bitwise.map { name, operation in
                CommandDefinition(name, menu: "Process>Math") { context, options in
                    // ImageMath reads the value as binary digits.
                    let text = options.value(forLabel: "Value (binary):") ?? "11110000"
                    guard let value = Int(text, radix: 2) else {
                        throw CommandError.invalidOption(command: name, detail: "\(text) isn't a binary number")
                    }
                    try math(name, operation(value), &context, options)
                }
            }
    }()

    /// Edit ▸ Invert (`Filters("invert")`).
    static let invert = CommandDefinition("Invert", menu: "Edit") { context, options in
        try math("Invert", .invert, &context, options)
    }

    /// Applies `operation` to the planes `IJ.setupDialog` picks: the whole
    /// image (with ImageMath's display-range rules) or one plane of a stack,
    /// within an area selection (restoring the pixels outside its mask).
    static func math(
        _ name: String, _ operation: ImageMath.Operation, _ context: inout CommandContext, _ options: MacroOptions
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        let region = try FilterCommands.selectionRegion(name, open)
        let targets = FilterCommands.targetPlanes(open, options)
        if targets.count == open.image.stack.count {
            try replaceCurrent(name, &context) { open in ImageMath.apply(operation, to: open.image, region: region) }
            return
        }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let display = open.image.channels[open.channel].displayRange
            let signed: Bool
            if case .straightLine(let intercept, let slope)? = open.image.calibration.valueFunction {
                signed = open.image.pixelType == .gray16 && intercept == -32768 && slope == 1
            } else {
                signed = false
            }
            let width = open.image.width
            for index in targets {
                let original = open.image.stack[index]
                var plane = ImageMath.apply(
                    operation, to: original, displayRange: display, signed16: signed, width: width, rect: region?.rect)
                if let region { plane = region.restoringOutsideMask(plane, snapshot: original, width: width) }
                do { try open.image.setPlane(plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
            }
        }
    }

    // MARK: Process ▸ Image Calculator

    static let calculatorOperations: [String: ImageCalculator.Operation] = [
        "Add": .add, "Subtract": .subtract, "Multiply": .multiply, "Divide": .divide, "AND": .and, "OR": .or,
        "XOR": .xor, "Min": .min, "Max": .max, "Average": .average, "Difference": .difference, "Copy": .copy,
        "Transparent-zero": .transparentZero,
    ]

    /// `ij.plugin.ImageCalculator`: `image1=`, `operation=`, `image2=`,
    /// with `create`, `32-bit` and (for a stack) `stack`.
    static let imageCalculator = CommandDefinition("Image Calculator...", menu: "Process") { context, options in
        let name = "Image Calculator..."
        func image(_ label: String) throws(CommandError) -> OpenImage {
            guard let title = options.value(forLabel: label) else {
                throw .invalidOption(command: name, detail: "no \(label.dropLast()) given")
            }
            guard let open = context.images.last(where: { $0.title == title }) else {
                throw .invalidOption(command: name, detail: "no image titled \"\(title)\"")
            }
            return open
        }
        let first = try image("Image1:"), second = try image("Image2:")
        guard let operation = calculatorOperations[options.value(forLabel: "Operation:") ?? "Add"] else {
            throw CommandError.invalidOption(command: name, detail: "unknown operation")
        }
        var create = options.flag(forLabel: "Create new window")
        let float = options.flag(forLabel: "32-bit (float) result")
        if first.image.stack.count > 1, FilterCommands.targetPlanes(first, options).count == 1 {
            throw CommandError.notNative(name)  // one slice of a stack: ImageJ can
        }
        let result: Hyperstack
        do {
            result = try ImageCalculator.calculate(first.image, operation, second.image, float32Result: float)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
        let signed = [first.image, second.image].contains { image in
            if case .straightLine(-32768, 1)? = image.calibration.valueFunction { return image.pixelType == .gray16 }
            return false
        }
        if (float || signed) && !(first.image.pixelType == .gray32Float && second.image.pixelType == .gray32Float) {
            create = true
        }
        if create {
            context.add(result)
        } else {
            try context.select(id: first.id)
            try replaceCurrent(name, &context) { _ in result }
        }
    }

    // MARK: Image ▸ Stacks

    static let projectionMethods: [String: ZProjector.Method] = [
        "Average Intensity": .average, "Max Intensity": .max, "Min Intensity": .min, "Sum Slices": .sum,
        "Standard Deviation": .standardDeviation, "Median": .median,
    ]

    /// `ij.plugin.ZProjector`: `start=`, `stop=`, `projection=` and, for a
    /// hyperstack with slices and frames, `all` time frames.
    static let zProject = CommandDefinition("Z Project...", menu: "Image>Stacks") { context, options in
        let name = "Z Project..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let dims = open.image.dimensions
        guard open.image.stack.count > 1 else {
            throw CommandError.failed(command: name, detail: "This command requires a stack.")
        }
        let methodName = options.value(forLabel: "Projection type") ?? "Max Intensity"
        guard let method = projectionMethods[methodName] else {
            throw CommandError.invalidOption(command: name, detail: "unknown projection \"\(methodName)\"")
        }
        let isHyper = dims.channels > 1 || (dims.slices > 1 && dims.frames > 1)
        let depth = isHyper ? (dims.slices > 1 ? dims.slices : dims.frames) : open.image.stack.count
        let start = Int(options.number(forLabel: "Start slice:", default: 1))
        let stop = Int(options.number(forLabel: "Stop slice:", default: Double(depth)))
        let all = dims.frames > 1 && dims.slices > 1 && options.flag(forLabel: "All time frames")
        let slices = max(start, 1) - 1 <= min(stop, depth) - 1 ? (max(start, 1) - 1)...(min(stop, depth) - 1) : nil
        let result = ZProjector.project(open.image, method: method, slices: slices, allTimeFrames: all, frame: open.frame)
        context.add(result)
    }

    /// `ij.plugin.ChannelSplitter`: one image per channel; the source closes.
    static let splitChannels = CommandDefinition("Split Channels", menu: "Image>Color") { context, _ in
        guard let open = context.current else { throw CommandError.noImage("Split Channels") }
        let parts = ChannelSplitter.split(open.image)
        guard parts.count > 1 else { return }
        context.close(id: open.id)
        for part in parts { context.add(part) }
    }

    /// `ij.plugin.RGBStackMerge`: `c1=` … `c7=` titles, `create`, `keep`, `ignore`.
    static let mergeChannels = CommandDefinition("Merge Channels...", menu: "Image>Color") { context, options in
        let name = "Merge Channels..."
        let labels = ["C1 (red):", "C2 (green):", "C3 (blue):", "C4 (gray):", "C5 (cyan):", "C6 (magenta):", "C7 (yellow):"]
        var sources: [OpenImage?] = []
        for label in labels {
            guard let title = options.value(forLabel: label), title != "*None*" else {
                sources.append(nil)
                continue
            }
            guard let source = context.images.last(where: { $0.title == title }) else {
                throw CommandError.invalidOption(command: name, detail: "no image titled \"\(title)\"")
            }
            sources.append(source)
        }
        let merged: Hyperstack
        do {
            merged = try RGBStackMerge.mergeChannels(
                sources.map { $0?.image }, createComposite: options.flag(forLabel: "Create composite"),
                ignoreLUTs: options.flag(forLabel: "Ignore source LUTs"))
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
        if !options.flag(forLabel: "Keep source images") {
            for source in sources.compactMap({ $0 }) { context.close(id: source.id) }
        }
        context.add(merged)
    }

    /// `ij.plugin.SubstackMaker`: `slices=` (a range, a range with an
    /// increment, or a list), or for a hyperstack `channels=`, `slices=` and
    /// `frames=`; `delete` removes the planes from the source.
    static let makeSubstack = CommandDefinition("Make Substack...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Make Substack..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let dims = open.image.dimensions
        guard !options.flag(forLabel: "Delete slices from original stack") else { throw CommandError.notNative(name) }
        let result: Hyperstack
        do {
            if dims.channels > 1 || (dims.slices > 1 && dims.frames > 1) {
                var sub = try SubstackMaker.makeSubhyperstack(
                    open.image, channels: options.value(forLabel: "channels") ?? "1-\(dims.channels)",
                    slices: options.value(forLabel: "slices") ?? "1-\(dims.slices)",
                    frames: options.value(forLabel: "frames") ?? "1-\(dims.frames)")
                sub.title = BuiltInCommands.uniqueName(open.title, among: context.images.map(\.title))
                result = sub
            } else {
                guard let list = options.value(forLabel: "Slices:") else {
                    throw CommandError.invalidOption(command: name, detail: "no slices= given")
                }
                result = try SubstackMaker.makeSubstack(open.image, list)
            }
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
        context.add(result)
    }

    /// `ij.plugin.HyperStackReducer`: `channels`, `slices`, `frames` keep a
    /// dimension; with `keep` the result is a new image, otherwise it
    /// replaces the source (as ImageJ does for an image without a window).
    static let reduceDimensionality = CommandDefinition("Reduce Dimensionality...", menu: "Image>Hyperstacks") { context, options in
        let name = "Reduce Dimensionality..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let dims = open.image.dimensions
        var result = HyperStackReducer.reduce(
            open.image, keepChannels: dims.channels > 1 && options.flag(forLabel: "Channels"),
            keepSlices: dims.slices > 1 && options.flag(forLabel: "Slices"),
            keepFrames: dims.frames > 1 && options.flag(forLabel: "Frames"),
            channel: open.channel, slice: open.slice, frame: open.frame)
        if options.flag(forLabel: "Keep source") {
            result.title = BuiltInCommands.uniqueName(open.title, among: context.images.map(\.title))
            context.add(result)
        } else {
            try replaceCurrent(name, &context) { _ in result }
        }
    }

    /// `ij.plugin.ChannelArranger`: `new=` the channel order as digits (`"312"`).
    static let arrangeChannels = CommandDefinition("Arrange Channels...", menu: "Image>Color") { context, options in
        let name = "Arrange Channels..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let text = options.value(forLabel: "New channel order:") ?? ""
        let order = text.compactMap { $0.wholeNumberValue }.map { $0 - 1 }
        guard !order.isEmpty, order.allSatisfy({ (0..<open.image.dimensions.channels).contains($0) }) else {
            throw CommandError.invalidOption(command: name, detail: "\"\(text)\" isn't a channel order")
        }
        let result: Hyperstack
        do {
            result = try ChannelArranger.arrange(open.image, order: order)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
        // ImageJ's result takes over the source's attributes, ID included.
        try replaceCurrent(name, &context) { _ in result }
    }
}
