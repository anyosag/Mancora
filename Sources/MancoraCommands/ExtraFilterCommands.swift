import MancoraCore
import MancoraProcess

/// More of Process ▸ Filters, Binary, Math and Shadows: Unsharp Mask, Top
/// Hat, the 3D filters, binary Median, NaN Background and the shadows.
enum ExtraFilterCommands {
    static var all: [CommandDefinition] {
        [unsharpMask, topHat, gaussianBlur3D, binaryMedian, nanBackground, addNoise, addSpecifiedNoise, saltAndPepper]
            + shadows + filters3D
    }

    /// ImageJ's `isHyperStack()` for an image opened as one: more than three dimensions.
    static func isHyperstack(_ image: Hyperstack) -> Bool {
        let d = image.dimensions
        return [d.channels, d.slices, d.frames].filter { $0 > 1 }.count > 1
    }

    /// A composite image with one plane per channel, which the 3D filters refuse.
    static func isCompositeColor(_ image: Hyperstack) -> Bool {
        image.channels.count > 1 && image.stack.count == image.channels.count
    }

    // MARK: Process ▸ Filters

    /// `UnsharpMask`: `radius=` (sigma; an old macro's `gaussian=` is 2.5
    /// sigmas) and `mask=` weight, values the dialog listener takes as given.
    static let unsharpMask = CommandDefinition("Unsharp Mask...", menu: "Process>Filters") { context, options in
        let name = "Unsharp Mask..."
        var macro = options
        let oldMacro = options.text.contains("gaussian=")
        if oldMacro { macro = MacroOptions(options.text.replacing("gaussian=", with: "radius=")) }
        var sigma = macro.number(forLabel: "Radius (Sigma)", default: 1)
        let weight = Float(macro.number(forLabel: "Mask Weight (0.1-0.9)", default: 0.6))
        if oldMacro { sigma /= 2.5 }
        try FilterCommands.applyInSelection(name, &context, macro) { plane, width, _, region in
            plane.unsharpMasked(sigma: sigma, weight: weight, width: width, rect: region?.rect)
        }
    }

    /// `RankFilters("tophat")`: `radius=`, `light` (background) and
    /// `don't` (subtract, a grayscale open). Subtracting ends with a 0.5%
    /// saturated display range for 16- and 32-bit images.
    static let topHat = CommandDefinition("Top Hat...", menu: "Process>Filters") { context, options in
        let name = "Top Hat..."
        let radius = try FilterCommands.rankRadius(options, name)
        let light = options.flag(forLabel: "Light Background")
        let dontSubtract = options.flag(forLabel: "Don't subtract (grayscale open)")
        try FilterCommands.applyInSelection(name, &context, options) { plane, width, open, region in
            plane.topHat(
                radius: radius, lightBackground: light, dontSubtract: dontSubtract,
                invertedLUT: FilterCommands.hasInvertedLUT(open), width: width, rect: region?.rect)
        }
        if !dontSubtract { try FilterCommands.varianceDisplayRange(name, &context) }
    }

    /// `GaussianBlur3D`: `x=`, `y=` and `z=` sigmas on the whole image or
    /// stack, which loses its selection.
    static let gaussianBlur3D = CommandDefinition("Gaussian Blur 3D...", menu: "Process>Filters") { context, options in
        let name = "Gaussian Blur 3D..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard !isCompositeColor(open.image) else {
            throw CommandError.failed(command: name, detail: "Composite color images not supported")
        }
        let x = options.number(forLabel: "X sigma:", default: 2)
        let y = options.number(forLabel: "Y sigma:", default: 2)
        let z = options.number(forLabel: "Z sigma:", default: 2)
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            open.image.encodedROI = nil
            do {
                open.image = try GaussianBlur3D.blur(
                    open.image, sigmaX: x, sigmaY: y, sigmaZ: z, isHyperstack: isHyperstack(open.image))
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
        }
    }

    // MARK: Process ▸ Binary ▸ Median

    /// `Binary("median")`: a mean of `radius=` (which ImageJ keeps between
    /// runs), then 128 and above become 255 and the rest 0.
    static let binaryMedian = CommandDefinition("Median", menu: "Process>Binary") { context, options in
        let name = "Median"
        let given = options.value(forLabel: "Radius:").flatMap { Double(MacroOptions.trimmed($0)) }
        if let given { context.settings.binaryMedianRadius = given }
        let radius = context.settings.binaryMedianRadius
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard case .gray8(let pixels) = open.currentPlane, pixels.allSatisfy({ $0 == 0 || $0 == 255 }) else {
            throw CommandError.failed(command: name, detail: "8-bit binary (0 and 255 only) image required.")
        }
        guard radius.isFinite, radius.magnitude <= 1000 else {
            throw CommandError.invalidOption(command: name, detail: "radius \(radius) is out of range")
        }
        let singlePlane = FilterCommands.targetPlanes(open, options).count == 1
        try FilterCommands.applyInSelection(name, &context, options) { plane, width, _, region in
            // ip.threshold(128, 255) runs on the whole plane.
            guard case .gray8(let mean) = plane.rankFiltered(.mean, radius: radius, width: width, rect: region?.rect) else {
                return plane
            }
            return .gray8(mean.map { $0 >= 128 ? 255 : 0 })
        }
        // Binary.run ends with ip.setBinaryThreshold(), which only the image's own processor keeps.
        guard singlePlane else { return }
        let black = context.settings.blackBackground
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            open.setBinaryThreshold(FilterCommands.hasInvertedLUT(open) == black ? 0 : 255)
        }
    }

    // MARK: Process ▸ Math ▸ NaN Background

    /// `ImageMath("nan")`: on a thresholded 32-bit image, every pixel
    /// outside the threshold becomes NaN (the whole plane, whatever the
    /// selection); the image's own plane then shows its new range and loses
    /// the threshold.
    static let nanBackground = CommandDefinition("NaN Background", menu: "Process>Math") { context, options in
        let name = "NaN Background"
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard open.image.pixelType == .gray32Float, let levels = open.threshold, !open.thresholdIsBinary else {
            throw CommandError.failed(command: name, detail: "Thresholded 32-bit float image required:\n\"\(open.title)\"")
        }
        let region = try FilterCommands.selectionRegion(name, open)
        let operation = ImageMath.Operation.nanBackground(lower: levels.lower, upper: levels.upper)
        let targets = FilterCommands.targetPlanes(open, options)
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let width = open.image.width
            for index in targets {
                let original = open.image.stack[index]
                let changed = ImageMath.apply(operation, to: original, displayRange: 0...0)
                let plane = region?.restoringOutsideMask(changed, snapshot: original, width: width) ?? changed
                do { try open.image.setPlane(plane, at: index) } catch { throw .failed(command: name, detail: "\(error)") }
                if targets.count == 1 {
                    var channel = open.image.channels[open.channel]
                    channel.displayRange = ImageMath.resetRange(changed)
                    open.image.setDisplay(channel, forChannel: open.channel)
                    open.threshold = nil
                }
            }
        }
    }

    // MARK: Process ▸ Noise

    /// `Filters("add")`: Gaussian noise of standard deviation 25.
    static let addNoise = CommandDefinition("Add Noise", menu: "Process>Noise") { context, options in
        try noise("Add Noise", standardDeviation: 25, &context, options)
    }

    /// `Filters("noise")`: `standard=` deviation, which ImageJ keeps between runs.
    static let addSpecifiedNoise = CommandDefinition("Add Specified Noise...", menu: "Process>Noise") { context, options in
        let sd = options.number(forLabel: "Standard Deviation:", default: context.settings.noiseStandardDeviation)
        context.settings.noiseStandardDeviation = sd
        try noise("Add Specified Noise...", standardDeviation: sd, &context, options)
    }

    /// `ImageProcessor.noise` on each target plane, within the selection,
    /// from the generator all noise filters share: seeded first by a pending
    /// `random("seed", n)` (cast to `int`). Run on the image's own plane,
    /// 16- and 32-bit noise resets its display range.
    static func noise(_ name: String, standardDeviation sd: Double, _ context: inout CommandContext, _ options: MacroOptions) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        var random = context.noiseRandom ?? JavaRandom()
        if !context.randomSeed.isNaN {
            random.setSeed(Int64(JavaNumerics.int32(context.randomSeed)))
            context.randomSeed = .nan
        }
        let single = FilterCommands.targetPlanes(open, options).count == 1
        var changed: Plane?
        try FilterCommands.applyInSelection(name, &context, options) { plane, width, _, region in
            let noisy = plane.addingNoise(standardDeviation: sd, width: width, rect: region?.rect, random: &random)
            changed = noisy
            return noisy
        }
        context.noiseRandom = random
        let type = open.image.pixelType
        guard single, type == .gray16 || type == .gray32Float, let changed else { return }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            var channel = open.image.channels[open.channel]
            channel.displayRange = ImageMath.resetRange(changed)
            open.image.setDisplay(channel, forChannel: open.channel)
        }
    }

    /// `SaltAndPepper`: 2.5% of an 8-bit image's (or selection's) pixels
    /// become 255 and 2.5% 0, at random (ImageJ's generator is never seeded).
    static let saltAndPepper = CommandDefinition("Salt and Pepper", menu: "Process>Noise") { context, options in
        let name = "Salt and Pepper"
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard open.image.pixelType == .gray8 else {
            throw CommandError.failed(command: name, detail: "\"\(name)\" requires an image of type:\n \n8-bit grayscale\n8-bit color")
        }
        var random = JavaRandom()
        try FilterCommands.applyInSelection(name, &context, options) { plane, width, _, region in
            plane.addingSaltAndPepper(width: width, rect: region?.rect, random: &random)
        }
    }

    // MARK: Process ▸ Shadows

    /// `Shadows`: `convolve3x3` with each direction's kernel.
    static let shadows: [CommandDefinition] = [
        ("North", [1, 2, 1, 0, 1, 0, -1, -2, -1]), ("Northeast", [0, 1, 2, -1, 1, 1, -2, -1, 0]),
        ("East", [-1, 0, 1, -2, 1, 2, -1, 0, 1]), ("Southeast", [-2, -1, 0, -1, 1, 1, 0, 1, 2]),
        ("South", [-1, -2, -1, 0, 1, 0, 1, 2, 1]), ("Southwest", [0, -1, -2, 1, 1, -1, 2, 1, 0]),
        ("West", [1, 0, -1, 2, 1, -2, 1, 0, -1]), ("Northwest", [2, 1, 0, 1, 1, -1, 0, -1, -2]),
    ].map { name, kernel in
        CommandDefinition(name, menu: "Process>Shadows") { context, options in
            try FilterCommands.applyInSelection(name, &context, options) { plane, width, _, region in
                plane.convolved3x3(kernel, width: width, rect: region?.rect)
            }
        }
    }

    // MARK: Process ▸ Filters ▸ 3D

    /// `Filters3D`: `x=`, `y=` and `z=` radii over the whole stack (a
    /// hyperstack's channels one by one); Variance 3D makes it 32-bit.
    static let filters3D: [CommandDefinition] = [
        ("Median 3D...", "3D Median", Filters3D.Filter.median), ("Mean 3D...", "3D Mean", .mean),
        ("Minimum 3D...", "3D Minimum", .minimum), ("Maximum 3D...", "3D Maximum", .maximum),
        ("Variance 3D...", "3D Variance", .variance),
    ].map { name, title, filter in
        CommandDefinition(name, menu: "Process>Filters") { context, options in
            guard let open = context.current else { throw CommandError.noImage(name) }
            guard !isCompositeColor(open.image) else {
                throw CommandError.failed(command: name, detail: "\(title): Composite color images not supported")
            }
            let x = Float(options.number(forLabel: "X radius:", default: 2))
            let y = Float(options.number(forLabel: "Y radius:", default: 2))
            let z = Float(options.number(forLabel: "Z radius:", default: 2))
            guard [x, y, z].allSatisfy({ $0.isFinite && $0 > -1 }) else {
                throw CommandError.invalidOption(command: name, detail: "radii must be more than -1")
            }
            let image = open.image
            let d = image.dimensions
            if isHyperstack(image), d.channels > 1, d.slices > 1, d.frames > 1 {
                throw CommandError.failed(command: name, detail: "5D hyperstacks are currently not supported")
            }
            if image.pixelType == .rgb8 && filter == .variance { throw CommandError.notNative(name) }
            // A hyperstack's channels are split, filtered one by one and merged.
            let volumes = (0..<d.channels).map { c in
                (0..<d.frames).flatMap { t in (0..<d.slices).map { z in d.planeIndex(channel: c, slice: z, frame: t) } }
            }
            var planes = image.stack.planes
            for volume in volumes {
                let filtered = Filters3D.filter(volume.map { image.stack[$0] }, width: image.width, filter: filter, x: x, y: y, z: z)
                for (index, plane) in zip(volume, filtered) { planes[index] = plane }
            }
            try ProcessCommands.replaceCurrent(name, &context) { open in try replacingPlanes(open, planes) }
        }
    }

    /// `ImagePlus.setStack` with `planes`: the image with its other
    /// attributes. 16- and 32-bit images show the current plane's new
    /// range; split channels each show their first plane's, merged back.
    static func replacingPlanes(_ open: OpenImage, _ planes: [Plane]) throws -> Hyperstack {
        let image = open.image
        let dims = image.dimensions
        let stack = try ImageStack(width: image.width, height: image.height, planes: planes, labels: image.stack.labels)
        var channels = image.channels
        if stack.pixelType == .gray16 || stack.pixelType == .gray32Float {
            for c in channels.indices {
                let index = channels.count > 1
                    ? dims.planeIndex(channel: c, slice: 0, frame: 0)
                    : dims.planeIndex(channel: open.channel, slice: open.slice, frame: open.frame)
                channels[c].displayRange = stack[index].valueRange() ?? 0...0
            }
        }
        var out = try Hyperstack(
            title: image.title, stack: stack, dimensions: image.dimensions, calibration: image.calibration,
            channels: channels, compositeMode: image.compositeMode, info: image.info, properties: image.properties)
        out.encodedROI = image.encodedROI
        out.encodedOverlay = image.encodedOverlay
        return out
    }
}
