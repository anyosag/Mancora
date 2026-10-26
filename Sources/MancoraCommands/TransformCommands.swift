import MancoraCore
import MancoraProcess

/// Image ▸ Transform's flips and 90-degree rotations (ImageJ's
/// `filter.Transformer`), and Flip Z and Image ▸ Stacks ▸ Tools ▸ Reverse
/// (`StackReverser`).
enum TransformCommands {
    static var all: [CommandDefinition] {
        [flip("Flip Horizontally", horizontal: true), flip("Flip Vertically", horizontal: false),
         rotate("Rotate 90 Degrees Right", clockwise: true), rotate("Rotate 90 Degrees Left", clockwise: false),
         reverse("Flip Z", menu: "Image>Transform"), reverse("Reverse", menu: "Image>Stacks>Tools")]
    }

    /// `Transformer("fliph")` and `("flipv")`: each target plane (`stack`
    /// for all of a stack) flips within an area selection's bounds; there
    /// is no masking. Flipping the whole image mirrors a set origin, once
    /// for every plane flipped, as ImageJ does.
    static func flip(_ name: String, horizontal: Bool) -> CommandDefinition {
        CommandDefinition(name, menu: "Image>Transform") { context, options in
            guard let open = context.current else { throw CommandError.noImage(name) }
            let image = open.image
            var rect: RoiBounds?
            if let roi = try CropCommands.selection(name, open), roi.isArea {
                // ip.setRoi(roi): the bounds within the image.
                let b = roi.bounds
                let x1 = max(b.x, 0), y1 = max(b.y, 0)
                let x2 = min(b.x + b.width, image.width), y2 = min(b.y + b.height, image.height)
                rect = RoiBounds(x: x1, y: y1, width: max(x2 - x1, 0), height: max(y2 - y1, 0))
            }
            let whole = rect.map { $0.x == 0 && $0.y == 0 && $0.width == image.width && $0.height == image.height } ?? true
            let planes = FilterCommands.targetPlanes(open, options).count
            try FilterCommands.apply(name, &context, options) { plane, width, _ in
                horizontal ? plane.flippedHorizontally(width: width, rect: rect) : plane.flippedVertically(width: width, rect: rect)
            }
            guard whole else { return }
            try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
                var cal = open.image.calibration
                for _ in 0..<planes where cal.xOrigin != 0 || cal.yOrigin != 0 {
                    if horizontal {
                        cal.xOrigin = Double(image.width - 1) - cal.xOrigin
                    } else {
                        cal.yOrigin = Double(image.height - 1) - cal.yOrigin
                    }
                }
                open.image.calibration = cal
            }
        }
    }

    /// `Transformer("right")` and `("left")`: every plane of the image
    /// rotates, whatever the selection. The pixel width and height (and
    /// differing x and y units) swap, a set origin rotates with the image,
    /// and the selection goes away unless the image is square.
    static func rotate(_ name: String, clockwise: Bool) -> CommandDefinition {
        CommandDefinition(name, menu: "Image>Transform") { context, _ in
            guard let open = context.current else { throw CommandError.noImage(name) }
            guard open.image.encodedOverlay.isEmpty else { throw CommandError.notNative(name) }  // ImageJ rotates overlays
            let image = open.image
            try ProcessCommands.replaceCurrent(name, &context) { _ in
                var out = try CropCommands.replacingStack(image, with: image.stack.rotated90(clockwise: clockwise))
                var cal = image.calibration
                if cal.xOrigin != 0 || cal.yOrigin != 0 {
                    (cal.xOrigin, cal.yOrigin) = clockwise
                        ? (Double(image.height - 1) - cal.yOrigin, cal.xOrigin)
                        : (cal.yOrigin, Double(image.width - 1) - cal.xOrigin)
                }
                (cal.pixelWidth, cal.pixelHeight) = (cal.pixelHeight, cal.pixelWidth)
                if let yUnit = cal.yUnit, yUnit != cal.unit { (cal.unit, cal.yUnit) = (yUnit, cal.unit) }
                out.calibration = cal
                if image.width != image.height { out.encodedROI = nil }
                return out
            }
        }
    }

    /// `StackReverser`: the planes of a stack (not a hyperstack) in reverse
    /// order, with their labels; the display range stays.
    static func reverse(_ name: String, menu: String) -> CommandDefinition {
        CommandDefinition(name, menu: menu) { context, _ in
            guard let open = context.current else { throw CommandError.noImage(name) }
            let image = open.image
            let dims = image.dimensions
            guard image.stack.count > 1 else {
                throw CommandError.failed(command: name, detail: "This command requires a stack")
            }
            if dims.slices > 1 && dims.frames > 1 || dims.channels > 1 && image.stack.count > dims.channels {
                throw CommandError.failed(command: name, detail: "This command does not currently work with hyperstacks.")
            }
            guard dims.channels == 1 else { throw CommandError.notNative(name) }  // a composite's channels: ImageJ resets it
            try ProcessCommands.replaceCurrent(name, &context) { _ in
                try CropCommands.replacingStack(image, with: image.stack.reversed())
            }
        }
    }
}
