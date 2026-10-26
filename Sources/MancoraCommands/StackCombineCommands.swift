import MancoraCore
import MancoraProcess

/// The Image ▸ Stacks commands that join images or stacks (Images to Stack,
/// Combine, Concatenate, Insert) and Grouped Z Project.
enum StackCombineCommands {
    static var all: [CommandDefinition] { [imagesToStack, combine, concatenate, insert, groupedZProject] }

    /// Changes the image `id`, leaving the current image as it was.
    static func modify(
        _ context: inout CommandContext, id: Int, _ command: String, _ body: (inout OpenImage) throws(CommandError) -> Void
    ) throws(CommandError) {
        let current = context.currentID
        try context.select(id: id)
        try context.withCurrent(command, body)
        if let current { try context.select(id: current) }
    }

    /// `Colors.decode(text, null) != null`: a color name ImageJ knows, or 6 or 8 hex digits.
    static func isColor(_ text: String) -> Bool {
        guard text.count >= 2 else { return false }
        let name = text.lowercased()
        let names = ["black", "white", "red", "blue", "yellow", "green", "magenta", "cyan", "orange", "pink", "gray", "grey"]
        if names.contains(where: name.contains) { return true }
        var hex = Substring(text)
        if hex.hasPrefix("#") { hex = hex.dropFirst() } else if hex.hasPrefix("0x") { hex = hex.dropFirst(2) }
        return (hex.count == 6 || hex.count == 8) && UInt64(hex, radix: 16) != nil
    }

    // MARK: Images to Stack

    /// `ImagesToStack`: every open single image (not stacks), or those
    /// whose title contains `title=`, into one stack named `name=` (Stack).
    /// Images of different sizes are copied (centered or at the top left)
    /// or scaled as `method=` says (`bicubic`). `use` labels the planes with
    /// the titles; `keep` keeps the images, which otherwise close. A macro
    /// that gives no options takes the titles as labels and needs images of
    /// one size.
    static let imagesToStack = CommandDefinition("Images to Stack", menu: "Image>Stacks") { context, options in
        let name = "Images to Stack"
        guard !context.images.isEmpty else { throw CommandError.failed(command: name, detail: "No images are open.") }
        var singles = context.images.filter { $0.image.stack.count == 1 }
        let stacks = context.images.count - singles.count
        guard singles.count >= 2 else {
            let more = stacks > 1 ? "\n \nUse the Image>Stacks>Tools>Concatenate\ncommand to combine stacks." : ""
            throw CommandError.failed(command: name, detail: "At least two open 2D images required." + more)
        }
        let differ = ImagesToStack.sizes(singles.map(\.image)).differ
        var method = ImagesToStack.Method.copyCenter
        var stackName = "Stack"
        var bicubic = false, titles = true, keep = false
        var fill: UInt32?
        if options.text.isEmpty {
            // IJ.macroRunning() without options: no dialog.
            if differ { throw CommandError.failed(command: name, detail: "Images are not all the same size") }
        } else {
            if differ {
                let names = ImagesToStack.Method.names
                let choice = try StackCommands.choice(options, "Method:", names, default: names[0], command: name)
                method = ImagesToStack.Method(rawValue: names.firstIndex(of: choice) ?? 0) ?? .copyCenter
            }
            stackName = options.value(forLabel: "Name:") ?? "Stack"
            let filter = options.value(forLabel: "Title contains:") ?? ""
            if isColor(options.value(forLabel: "Fill color:") ?? "") { fill = 0 }
            bicubic = differ && options.flag(forLabel: "Bicubic interpolation")
            titles = options.flag(forLabel: "Use titles as labels")
            keep = options.flag(forLabel: "Keep source images")
            if !filter.isEmpty && filter != "*" {
                singles = singles.filter { $0.title.contains(filter) }
                if singles.isEmpty {
                    throw CommandError.failed(command: name, detail: "None of the images have a title containing \"\(filter)\"")
                }
            }
        }
        let stack: Hyperstack
        do throws(StackEditError) {
            stack = try ImagesToStack.convert(
                singles.map(\.image), name: stackName, method: method, bicubic: bicubic, titlesAsLabels: titles, fill: fill)
        } catch .unsupported {
            throw CommandError.notNative(name)
        } catch {
            throw StackCommands.failure(name, error)
        }
        if !keep { for image in singles { context.close(id: image.id) } }
        context.add(stack)
    }

    // MARK: Combine

    /// `StackCombiner`: `stack1=` beside `stack2=` (below it with
    /// `combine`) in "Combined Stacks"; both close.
    static let combine = CommandDefinition("Combine...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Combine..."
        let sameType = "This command requires two stacks\nthat are the same data type."
        let images = context.images
        guard images.count >= 2 else { throw CommandError.failed(command: name, detail: sameType) }
        let titles = images.map(\.title)
        let first = try StackCommands.choice(options, "Stack1:", titles, default: titles[0], command: name)
        let second = try StackCommands.choice(options, "Stack2:", titles, default: titles[1], command: name)
        guard let a = images.first(where: { $0.title == first }), let b = images.first(where: { $0.title == second }) else {
            throw CommandError.noSuchImage(first)
        }
        let combined: Hyperstack
        do throws(StackEditError) {
            combined = try StackCombiner.combine(
                a.image, b.image, vertical: options.flag(forLabel: "Combine vertically"),
                background: context.settings.background, channel: a.channel)
        } catch .unsupported {
            throw CommandError.notNative(name)  // ImageJ makes both RGB first
        } catch {
            throw StackCommands.failure(name, error)
        }
        context.close(id: a.id)
        context.close(id: b.id)
        context.add(combined)
    }

    // MARK: Concatenate

    /// `Concatenator`: `image1=`, `image2=`, … (or `all_open`) one after
    /// another in a new image titled `title=` (Untitled). `open` makes each
    /// image a time frame when all have as many slices; `keep` keeps the
    /// images, which otherwise close. Without options every open image is
    /// joined (the dialog's first choices), as time frames.
    static let concatenate = CommandDefinition("Concatenate...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Concatenate..."
        var text = options.text
        if text.contains("stack1") && text.contains("stack2") { text = text.replacing("stack", with: "image") }
        let macro = MacroOptions(text)
        let images = context.images
        guard !images.isEmpty else { throw CommandError.failed(command: name, detail: "No windows are open.") }
        guard images.count >= 2 else { throw CommandError.failed(command: name, detail: "Two or more windows must be open") }
        let n = images.count
        let titles = images.map(\.title)
        let none = "-- None --"
        let titlesNone = titles + [none]
        var maxEntries = 18
        var all = false, keep = false, open4D = true
        var title = "Untitled"
        if !text.isEmpty {
            maxEntries = 0
            while text.contains("image\(maxEntries + 1)") { maxEntries += 1 }
            all = macro.flag(forLabel: "All_open windows")
            title = macro.value(forLabel: "Title:") ?? "Untitled"
            keep = macro.flag(forLabel: "Keep original images")
            open4D = macro.flag(forLabel: "Open as 4D_image")
        }
        var selected: [OpenImage] = []
        for i in 0...n {
            var index = i
            if !all {
                if i == min(n + 1, maxEntries) { break }
                let choices = i < 2 ? titles : titlesNone
                let picked = try StackCommands.choice(macro, "Image\(i + 1):", choices, default: choices[i], command: name)
                index = titlesNone.firstIndex(of: picked) ?? n
            }
            if index >= n { break }
            selected.append(images[index])
        }
        guard selected.count >= 2 else { throw CommandError.failed(command: name, detail: "Please select at least 2 images") }
        let result: Hyperstack
        do throws(StackEditError) {
            result = try Concatenator.concatenate(selected.map(\.image), title: title, open4D: open4D)
        } catch .unsupported {
            throw CommandError.notNative(name)  // ImageJ leaves out the images of another type
        } catch {
            throw StackCommands.failure(name, error)
        }
        if !keep { for image in selected { context.close(id: image.id) } }
        context.add(result)
    }

    // MARK: Insert

    /// `StackInserter`: `source=` copied into each plane of `destination=`
    /// at `x=`, `y=`.
    static let insert = CommandDefinition("Insert...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Insert..."
        let images = context.images
        guard !images.isEmpty else { throw CommandError.failed(command: name, detail: "No windows are open.") }
        guard images.count >= 2 else { throw CommandError.failed(command: name, detail: "At least two windows must be open.") }
        let titles = images.map(\.title)
        let source = try StackCommands.choice(options, "Source:", titles, default: titles[0], command: name)
        let destination = try StackCommands.choice(options, "Destination:", titles, default: titles[0], command: name)
        let x = Int(JavaNumerics.int32(options.number(forLabel: "X Location:", default: 0)))
        let y = Int(JavaNumerics.int32(options.number(forLabel: "Y Location:", default: 0)))
        guard let a = images.first(where: { $0.title == source }), let b = images.first(where: { $0.title == destination })
        else { throw CommandError.noSuchImage(source) }
        guard a.image.pixelType == b.image.pixelType else {
            throw CommandError.failed(command: name, detail: "The source and destination must be the same type.")
        }
        guard a.id != b.id else {
            throw CommandError.failed(command: name, detail: "The source and destination must be different.")
        }
        try modify(&context, id: b.id, name) { (open: inout OpenImage) throws(CommandError) in
            open.image = StackInserter.insert(a.image, into: open.image, x: x, y: y)
        }
    }

    // MARK: Grouped Z Project

    /// `GroupedZProjector`: `projection=` of each run of `group=` slices
    /// (which must divide the stack). A hyperstack runs Z Project instead.
    static let groupedZProject = CommandDefinition("Grouped Z Project...", menu: "Image>Stacks>Tools") { context, options in
        let name = "Grouped Z Project..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        let image = open.image
        let size = image.stack.count
        guard size > 1 else { throw CommandError.failed(command: name, detail: "This command requires a stack") }
        if StackEditor.isHyperStack(image.dimensions) {
            try ProcessCommands.zProject.run(&context, options)
            return
        }
        // A composite of channels only becomes a hyperstack for the projection in ImageJ.
        if StackEditor.isComposite(image) { throw CommandError.notNative(name) }
        let methods = ["Average Intensity", "Max Intensity", "Min Intensity", "Sum Slices", "Standard Deviation", "Median"]
        let methodName = try StackCommands.choice(options, "Projection method:", methods, default: methods[0], command: name)
        let groupSize = Int(JavaNumerics.int32(options.number(forLabel: "Group size:", default: Double(size))))
        guard groupSize >= 1, groupSize <= size, size % groupSize == 0 else {
            throw CommandError.failed(command: name, detail: "Group size must divide evenly into the stack size.")
        }
        guard let method = ProcessCommands.projectionMethods[methodName] else { throw CommandError.notNative(name) }
        context.add(GroupedZProjector.project(image, method: method, groupSize: groupSize))
    }
}
