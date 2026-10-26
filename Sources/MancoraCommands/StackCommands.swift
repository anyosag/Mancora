import MancoraCore
import MancoraProcess

/// Image ▸ Stacks and Image ▸ Stacks ▸ Tools: adding, deleting and moving
/// between slices, labels, and splitting, joining and reducing stacks, as
/// ImageJ runs them for images without a window (a macro in batch mode).
enum StackCommands {
    static var all: [CommandDefinition] {
        [addSlice, deleteSlice, nextSlice, previousSlice, setSlice, stackToImages, setLabel, removeLabels, reduce]
            + StackCombineCommands.all
    }

    /// The current plane's stack index (0-based; ImageJ's `getCurrentSlice() - 1`).
    static func currentIndex(_ open: OpenImage) -> Int {
        open.image.dimensions.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
    }

    /// `ImagePlus.setSlice(n)`: shows plane `index`, if there is one.
    static func show(_ open: inout OpenImage, index: Int) {
        guard (0..<open.image.stack.count).contains(index) else { return }
        let p = open.image.dimensions.position(ofPlane: index)
        (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
    }

    /// A dialog choice from the options (`Macro.getValue`), or `fallback`;
    /// throws ImageJ's error for a value that isn't one of `choices`.
    static func choice(
        _ options: MacroOptions, _ label: String, _ choices: [String], default fallback: String, command: String
    ) throws(CommandError) -> String {
        let value = options.value(forLabel: label) ?? fallback
        guard choices.contains(value) else {
            throw .invalidOption(command: command, detail: "\"\(value)\" is not a valid choice for \"\(label)\"")
        }
        return value
    }

    /// A stack edit's failure, as ImageJ's error message.
    static func failure(_ command: String, _ error: StackEditError) -> CommandError {
        .failed(command: command, detail: error.description)
    }

    // MARK: Add Slice and Delete Slice

    /// `StackEditor("add")`: a blank slice after the current one, which
    /// becomes current. For a hyperstack or composite, `add=` chooses a
    /// channel, slice or frame, and `prepend` puts it first.
    static let addSlice = CommandDefinition("Add Slice", menu: "Image>Stacks") { context, options in
        let name = "Add Slice"
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let image = open.image
            guard StackEditor.isHyperstackOrComposite(image) else {
                let (out, current) = StackEditor.addSlice(image, after: currentIndex(open))
                open.image = out
                show(&open, index: current)
                return
            }
            let axisName = try choice(
                options, "Add", HyperstackAxis.allCases.map(\.rawValue),
                default: StackEditor.defaultAddAxis(image.dimensions).rawValue, command: name)
            let axis = HyperstackAxis(rawValue: axisName) ?? .slice
            // A channel added to an image that isn't a composite leaves ImageJ
            // with several channels shown as one: Mancora has no such image.
            if axis == .channel, !StackEditor.isComposite(image) { throw .notNative(name) }
            let (out, current) = StackEditor.addHyperstack(
                image, axis: axis, prepend: options.flag(forLabel: "Prepend"), channel: open.channel, slice: open.slice,
                frame: open.frame)
            open.image = out
            show(&open, index: current)
        }
    }

    /// `StackEditor("delete")`: removes the current slice; the one before
    /// becomes current. For a hyperstack, or a composite of channels only,
    /// `delete=` names the channel, slice or frame to remove (a macro that
    /// names none removes the slice, or the frame when it just says
    /// `delete`; a composite of channels only, given no options, its channel).
    static let deleteSlice = CommandDefinition("Delete Slice", menu: "Image>Stacks") { context, options in
        let name = "Delete Slice"
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let image = open.image
            let n = image.stack.count
            guard n >= 2 else { throw failure(name, .stackRequired("\"Delete Slice\" requires a stack")) }
            let channelsOnly = StackEditor.isComposite(image) && n == image.dimensions.channels
            guard StackEditor.isHyperStack(image.dimensions) || channelsOnly else {
                do throws(StackEditError) {
                    let (out, current) = try StackEditor.deleteSlice(image, at: currentIndex(open))
                    open.image = out
                    show(&open, index: current)
                } catch {
                    throw failure(name, error)
                }
                return
            }
            let (choices, preferred) = StackEditor.deleteAxes(image.dimensions)
            var macro = options
            if !options.text.contains("delete=") {
                if !options.text.isEmpty {
                    macro = MacroOptions(options.text.contains("delete") ? "delete=frame" : "delete=slice")
                } else if channelsOnly {
                    macro = MacroOptions("delete=channel")
                }
            }
            let axisName = try choice(macro, "Delete current", choices.map(\.rawValue), default: preferred.rawValue, command: name)
            let axis = HyperstackAxis(rawValue: axisName) ?? preferred
            // One channel left is a one-channel composite in ImageJ: Mancora has no such image.
            if axis == .channel, image.dimensions.channels == 2 { throw .notNative(name) }
            let (out, current) = StackEditor.deleteHyperstack(
                image, axis: axis, channel: open.channel, slice: open.slice, frame: open.frame)
            open.image = out
            show(&open, index: current)
        }
    }

    // MARK: Next, Previous and Set Slice

    /// `Animator("next")` and `("previous")` for an image without a window:
    /// the next or previous plane of the stack (`setSlice`), if there is one.
    static func step(_ name: String, by delta: Int) -> CommandDefinition {
        CommandDefinition(name, menu: "Image>Stacks") { context, _ in
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                guard open.image.stack.count >= 2 else { throw .failed(command: name, detail: "Stack required.") }
                show(&open, index: currentIndex(open) + delta)
            }
        }
    }

    static let nextSlice = step("Next Slice [>]", by: 1)
    static let previousSlice = step("Previous Slice [<]", by: -1)

    /// `Animator("set")`: ImageJ asks for the slice only in a stack's
    /// window; an image without one (a macro in batch mode) stays where it is.
    static let setSlice = CommandDefinition("Set Slice...", menu: "Image>Stacks") { context, _ in
        let name = "Set Slice..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard open.image.stack.count >= 2 else { throw CommandError.failed(command: name, detail: "Stack required.") }
    }

    // MARK: Stack to Images

    /// `StackEditor("toimages")`: one image per plane (the last made is
    /// current); the stack closes.
    static let stackToImages = CommandDefinition("Stack to Images", menu: "Image>Stacks") { context, _ in
        let name = "Stack to Images"
        guard let open = context.current else { throw CommandError.noImage(name) }
        // ImageJ moves each overlay element to the image of its slice.
        guard open.image.encodedOverlay.isEmpty else { throw CommandError.notNative(name) }
        let images: [Hyperstack]
        do throws(StackEditError) {
            images = try StackEditor.stackToImages(open.image, channel: open.channel)
        } catch {
            throw failure(name, error)
        }
        for image in images { context.add(image) }
        context.close(id: open.id)
        if let last = context.images.last { try context.select(id: last.id) }
    }

    // MARK: Labels

    /// `SimpleCommands("set")`: `label=` for the current plane (empty for none).
    static let setLabel = CommandDefinition("Set Label...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Set Label..."
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let index = currentIndex(open)
            let label = options.value(forLabel: "Label:") ?? open.image.stack.labels[index] ?? ""
            open.image = StackEditor.setLabel(open.image, at: index, to: label)
        }
    }

    /// `SimpleCommands("remove")`.
    static let removeLabels = CommandDefinition("Remove Slice Labels", menu: "Image>Stacks>Tools") { context, _ in
        try context.withCurrent("Remove Slice Labels") { (open: inout OpenImage) throws(CommandError) in
            open.image = StackEditor.removeLabels(open.image)
        }
    }

    // MARK: Reduce

    /// `StackReducer`: keeps every `reduction=`-th slice (or frame of a
    /// hyperstack; `reduce` picks slices when it has both).
    static let reduce = CommandDefinition("Reduce...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Reduce..."
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let image = open.image
            let n = image.stack.count
            if n == 1 || (StackEditor.isComposite(image) && image.dimensions.channels == n) {
                throw .failed(command: name, detail: "Stack or hyperstack required")
            }
            let d = image.dimensions
            let factor = Int(JavaNumerics.int32(options.number(forLabel: "Reduction Factor:", default: 2)))
            guard factor >= 1 else { throw .notNative(name) }  // ImageJ divides by it and fails
            let hyper = StackEditor.isHyperStack(d)
            var reduceSlices = hyper && d.slices > 1
            if hyper && d.slices > 1 && d.frames > 1 { reduceSlices = options.flag(forLabel: "Reduce in Z-Dimension") }
            let current = currentIndex(open)
            open.image = StackEditor.reduce(image, factor: factor, reduceSlices: reduceSlices)
            // setStack keeps the current plane number when it's still there.
            show(&open, index: min(current, open.image.stack.count - 1))
        }
    }
}
