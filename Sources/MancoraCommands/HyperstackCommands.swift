import MancoraCore
import MancoraProcess

/// Image ▸ Hyperstacks, Image ▸ Color's Make Composite and Stack to RGB,
/// and Image ▸ Type's color-space stacks, as ImageJ runs them for images
/// without a window (a macro in batch mode).
enum HyperstackCommands {
    static var all: [CommandDefinition] {
        [stackToHyperstack, hyperstackToStack, makeSubset, reorderHyperstack, makeComposite, stackToRGB, invertLUTs]
            + colorSpaceCommands
    }

    /// `SimpleCommands("invert")` (the `InvertAllLuts` macro, from the
    /// Channels tool): every channel's LUT inverted, the first channel
    /// shown, and the `CompositeProjection` property switched to match.
    static let invertLUTs = CommandDefinition("Invert LUTs", menu: "Image>Color") { context, _ in
        let name = "Invert LUTs"
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            // RGB images have no LUT; in grayscale mode the macro's setLut doesn't reach the channels.
            guard open.image.pixelType != .rgb8, !(StackEditor.isComposite(open.image) && open.image.compositeMode == .grayscale)
            else { throw .notNative(name) }
            for c in open.image.channels.indices {
                var display = open.image.channels[c]
                display.lut = LUTInverter.inverted(display.lut)
                open.image.setDisplay(display, forChannel: c)
            }
            open.channel = 0
            let key = "CompositeProjection"
            open.image.properties[key] = LUTInverter.projection(
                after: open.image.properties[key], inverting: LUTInverter.isInverting(open.image.channels[0].lut))
        }
    }

    /// Fiji's `Hyperstack_rearranger`: `channels=`, `slices=` and `frames=`
    /// each name the dimension (`[Slices (z)]`, …) the new one runs along;
    /// the result, a new composite, replaces the image. A mapping that
    /// doesn't use each dimension once is reported in the log.
    static let reorderHyperstack = CommandDefinition("Re-order Hyperstack ...", menu: "Image>Hyperstacks") { context, options in
        let name = "Re-order Hyperstack ..."
        guard let open = context.current else {
            context.log.append("No images open.")
            return
        }
        let image = open.image
        let choices = HyperstackRearranger.choices
        var targets: [Int] = []
        for (label, fallback) in zip(["Channels (c) -> ", "Slices (z) -> ", "Frames (t) -> "], choices) {
            let picked = try StackCommands.choice(options, label, choices, default: fallback, command: name)
            targets.append(choices.firstIndex(of: picked) ?? 0)
        }
        guard Set(targets).count == 3 else {
            context.log.append(
                "Mapping is inconsistent: each - channel, slices and frames have to be assigned to an input dimension.")
            return
        }
        let d = [image.dimensions.channels, image.dimensions.slices, image.dimensions.frames]
        // An RGB stack can't be a composite; one channel would be a one-channel composite.
        guard image.pixelType != .rgb8, d[targets[0]] > 1 else { throw CommandError.notNative(name) }
        let result = HyperstackRearranger.reorder(
            image, channels: targets[0], slices: targets[1], frames: targets[2], current: open.channel)
        context.close(id: open.id)
        context.add(result)
    }

    /// Replaces the image `id` with `image`, keeping its place and ID, and
    /// shows plane `index` (clamped to the new stack).
    static func replace(_ context: inout CommandContext, _ name: String, with image: Hyperstack, index: Int) throws(CommandError) {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            open.image = image
            open.threshold = nil
            StackCommands.show(&open, index: min(max(index, 0), image.stack.count - 1))
        }
    }

    /// Shows plane `index` of the current image (`ImagePlus.setSlice`).
    static func showPlane(_ context: inout CommandContext, _ name: String, _ index: Int) throws(CommandError) {
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in StackCommands.show(&open, index: index) }
    }

    // MARK: Stack to Hyperstack and Hyperstack to Stack

    /// `HyperStackConverter("stacktohs")`: `channels=`, `slices=`, `frames=`
    /// (whose product is the stack size) in `order=`. Several channels make
    /// a new composite shown in `display=` mode (Color), which replaces the
    /// stack; an RGB stack with `convert` becomes a three-channel composite.
    static let stackToHyperstack = CommandDefinition("Stack to Hyperstack...", menu: "Image>Hyperstacks") { context, options in
        let name = "Stack to Hyperstack..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let n = image.stack.count
        guard n > 1 else { throw CommandError.failed(command: name, detail: "Stack required") }
        let orders = HyperStackConverter.orders
        let order = orders.firstIndex(of: try StackCommands.choice(options, "Order:", orders, default: orders[0], command: name)) ?? 0
        let d = image.dimensions
        func count(_ label: String, _ value: Int) -> Int { Int(JavaNumerics.int32(options.number(forLabel: label, default: Double(value)))) }
        let c = count("Channels (c):", d.channels), z = count("Slices (z):", d.slices), t = count("Frames (t):", d.frames)
        let modes = ["Composite", "Color", "Grayscale"]
        let modeName = try StackCommands.choice(options, "Display Mode:", modes, default: modes[1], command: name)
        let mode: CompositeMode = modeName == "Composite" ? .composite : modeName == "Color" ? .color : .grayscale
        let rgb = image.pixelType == .rgb8
        if rgb && options.flag(forLabel: "Convert RGB to 3 Channel Hyperstack") {
            try makeComposite(&context, name, arg: mode == .composite ? .composite : .color, options: MacroOptions(""))
            return
        }
        if rgb && c > 1 { throw CommandError.failed(command: name, detail: "RGB stacks are limited to one channel") }
        guard c > 0, z > 0, t > 0, c * z * t == n else {
            throw CommandError.failed(command: name, detail: "channels x slices x frames <> stack size")
        }
        let dims = HyperstackDimensions(channels: c, slices: z, frames: t)
        let result = HyperStackConverter.toHyperstack(image, dimensions: dims, order: order, mode: mode)
        if c > 1 && !rgb {
            // A new CompositeImage replaces the stack.
            context.close(id: open.id)
            context.add(result)
        } else {
            try replace(&context, name, with: result, index: StackCommands.currentIndex(open))
        }
    }

    /// `HyperStackConverter("hstostack")`: in ImageJ 1.54p a hyperstack
    /// keeps its dimensions; a composite of channels becomes a new image
    /// that isn't a composite, its channels shown in gray.
    static let hyperstackToStack = CommandDefinition("Hyperstack to Stack", menu: "Image>Hyperstacks") { context, _ in
        let name = "Hyperstack to Stack"
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        guard StackEditor.isComposite(image) else { return }
        // A composite hyperstack saved this way shows ImageJ's channel colors
        // again when reopened: ImageJ keeps the state Mancora can't.
        if StackEditor.isHyperStack(image.dimensions) { throw CommandError.notNative(name) }
        var result = HyperStackConverter.toStack(image, channel: open.channel)
        result.encodedROI = nil
        context.close(id: open.id)
        context.add(result)
    }

    /// `SubstackMaker` from Image ▸ Hyperstacks: the same as Make Substack.
    static let makeSubset = CommandDefinition("Make Subset...", menu: "Image>Hyperstacks") { context, options in
        try ProcessCommands.makeSubstack.run(&context, options)
    }

    // MARK: Make Composite

    /// `CompositeConverter`: a new composite in the image's place, made from
    /// an RGB image's colors or a three-slice stack's planes (labeled Red,
    /// Green and Blue, shown in `display=` mode); a composite just switches
    /// to composite mode. Other stacks become one-channel composites in
    /// ImageJ, which ImageJ makes.
    static let makeComposite = CommandDefinition("Make Composite", menu: "Image>Color") { context, options in
        try makeComposite(&context, "Make Composite", arg: nil, options: options)
    }

    /// `CompositeConverter.run(arg)`; `arg` is Stack to Hyperstack's mode
    /// for an RGB stack.
    static func makeComposite(
        _ context: inout CommandContext, _ name: String, arg: CompositeMode?, options: MacroOptions
    ) throws(CommandError) {
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        if StackEditor.isComposite(image) {
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in open.image.compositeMode = .composite }
            return
        }
        let d = image.dimensions
        let result: Hyperstack
        if image.pixelType == .rgb8 {
            if image.stack.count == 1 {
                result = CompositeConverter.rgbComposite(image)
            } else {
                result = ColorSpaceConverter.rgbComposite(image, mode: arg == .color ? .color : .composite)
            }
        } else {
            let threeSlices = image.stack.count == 3 && d.slices == 3
            let modes = ["Composite", "Color", "Grayscale"]
            let preferred = d.channels == 1 && d.slices * d.frames > 7 ? modes[2] : modes[0]
            let modeName = try StackCommands.choice(options, "Display Mode:", modes, default: preferred, command: name)
            let mode: CompositeMode = modeName == "Composite" ? .composite : modeName == "Color" ? .color : .grayscale
            // A stack of one channel stays one channel when ImageJ knows its
            // dimensions (as for any opened file): a one-channel composite,
            // which Mancora doesn't have.
            guard threeSlices else { throw CommandError.notNative(name) }
            result = CompositeConverter.composite(
                image, dimensions: HyperstackDimensions(channels: 3), mode: mode, labels: ["Red", "Green", "Blue"],
                resetRanges: image.pixelType != .gray8)
        }
        context.close(id: open.id)
        context.add(result)
        if image.pixelType == .rgb8, image.stack.count > 1 { try showPlane(&context, name, StackCommands.currentIndex(open)) }
    }

    // MARK: Stack to RGB

    /// `RGBStackConverter`: a composite drawn as RGB (`slices`, `frames`:
    /// every slice or frame rather than the current one; `keep`: a new
    /// image beside the composite rather than in its place), or a 2- or
    /// 3-plane 8- or 16-bit stack as the red, green and blue of a new image.
    static let stackToRGB = CommandDefinition("Stack to RGB", menu: "Image>Color") { context, options in
        try stackToRGB(&context, "Stack to RGB", options)
    }

    static func stackToRGB(_ context: inout CommandContext, _ name: String, _ options: MacroOptions) throws(CommandError) {
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let n = image.stack.count
        guard StackEditor.isComposite(image) else {
            guard (2...3).contains(n) else {
                throw CommandError.failed(command: name, detail: "A 2 or 3 image stack, or a HyperStack, required")
            }
            guard image.pixelType == .gray8 || image.pixelType == .gray16 else {
                throw CommandError.failed(command: name, detail: "8-bit or 16-bit grayscale stack required")
            }
            // ImageJ crops 16-bit planes to the selection first.
            if image.pixelType == .gray16, image.encodedROI != nil { throw CommandError.notNative(name) }
            context.add(RGBStackConverter.stackToRGB(image))
            return
        }
        guard image.encodedOverlay.isEmpty else { throw CommandError.notNative(name) }  // ImageJ crops overlays
        let d = image.dimensions
        if d.channels == n {
            context.add(RGBStackConverter.channelsToRGB(image))
            // imp2.setSlice(c): the plane of the current channel.
            try context.withCurrent(name) { (new: inout OpenImage) throws(CommandError) in
                StackCommands.show(&new, index: open.channel)
            }
            return
        }
        let slices = d.slices > 1 && options.flag(forLabel: "Slices")
        let frames = d.frames > 1 && options.flag(forLabel: "Frames")
        let keep = options.flag(forLabel: "Keep source")
        let title = keep ? BuiltInCommands.uniqueName(image.title, among: context.images.map(\.title)) : image.title
        var result = RGBStackConverter.hyperstackToRGB(
            image, slices: slices, frames: frames, channel: open.channel, slice: open.slice, frame: open.frame, title: title)
        if keep {
            context.add(result)
        } else {
            // ImageJ fails to put the RGB version in place of a composite showing a later channel.
            guard open.channel == 0 else { throw CommandError.notNative(name) }
            // ImagePlus.setImage: the image takes the new one's stack, calibration and (lack of) Info and properties.
            result.info = nil
            result.properties = [:]
            result.encodedROI = image.encodedROI
            try replace(&context, name, with: result, index: StackCommands.currentIndex(open))
        }
    }

    // MARK: Image ▸ Type: color spaces

    /// `Converter`'s message for a conversion it doesn't do.
    static let supportedConversions = """
        Supported Conversions:
         \n8-bit -> 16-bit*
        8-bit -> 32-bit*
        8-bit -> RGB Color*
        16-bit -> 8-bit*
        16-bit -> 32-bit*
        16-bit -> RGB Color*
        32-bit -> 8-bit*
        32-bit -> 16-bit
        32-bit -> RGB Color*
        8-bit Color -> 8-bit (grayscale)*
        8-bit Color -> RGB Color
        RGB -> 8-bit (grayscale)*
        RGB -> 8-bit Color*
        RGB -> RGB Stack*
        RGB -> HSB Stack*
        RGB -> Lab Stack
        RGB Stack -> RGB Color
        HSB Stack -> RGB Color
         \n* works with stacks\n
        """

    /// `Converter("RGB Stack")`, `("HSB Stack")`, `("HSB (32-bit)")` and
    /// `("Lab Stack")`. A single RGB image becomes three channels in its
    /// place; an RGB stack becomes a new three-channel composite (Lab
    /// Stack takes single images only). RGB Stack also turns a composite
    /// of channels into a stack of each channel drawn in RGB.
    static let colorSpaceCommands: [CommandDefinition] = ["RGB Stack", "HSB Stack", "HSB (32-bit)", "Lab Stack"].map { name in
        CommandDefinition(name, menu: "Image>Type") { context, _ in
            guard let open = context.current else { throw CommandError.noImage(name) }
            let image = open.image
            let n = image.stack.count
            // A composite of channels becomes RGB planes that ImageJ still
            // counts as channels, which Mancora has no way to hold.
            if name == "RGB Stack", StackEditor.isComposite(image), image.dimensions.channels == n {
                throw CommandError.notNative(name)
            }
            guard image.pixelType == .rgb8, !(name == "Lab Stack" && n > 1) else {
                throw CommandError.failed(command: name, detail: supportedConversions)
            }
            if n > 1 {
                let result = name == "RGB Stack"
                    ? ColorSpaceConverter.rgbComposite(image) : ColorSpaceConverter.hsbHyperstack(image, float: name == "HSB (32-bit)")
                context.close(id: open.id)
                context.add(result)
                // CompositeConverter shows the plane the stack showed.
                if name == "RGB Stack" { try showPlane(&context, name, StackCommands.currentIndex(open)) }
                return
            }
            let result: Hyperstack
            switch name {
            case "RGB Stack": result = ColorSpaceConverter.rgbStack(image)
            case "HSB Stack": result = ColorSpaceConverter.hsbStack(image)
            case "HSB (32-bit)": result = ColorSpaceConverter.hsb32Stack(image)
            default: result = ColorSpaceConverter.labStack(image)
            }
            try replace(&context, name, with: result, index: 0)
        }
    }

    /// `Converter("RGB Color")` for what isn't a plain type conversion: a
    /// color-space stack recombined into one RGB image in its place, or a
    /// composite drawn as RGB (Stack to RGB). Returns `false` for anything else.
    static func rgbColor(_ context: inout CommandContext, _ options: MacroOptions) throws(CommandError) -> Bool {
        let name = "RGB Color"
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        if let space = ColorSpaceConverter.space(of: image) {
            try replace(&context, name, with: ColorSpaceConverter.toRGB(image, from: space), index: 0)
            return true
        }
        guard StackEditor.isComposite(image) else { return false }
        try stackToRGB(&context, name, options)
        return true
    }
}
