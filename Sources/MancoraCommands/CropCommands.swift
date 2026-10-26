import MancoraCore
import MancoraIO
import MancoraProcess

/// Image ▸ Crop and Image ▸ Adjust ▸ Canvas Size (ImageJ's `Resizer("crop")`
/// and `CanvasResizer`), and the cropping Duplicate does
/// (`Duplicator.crop` and `cropRoi`).
enum CropCommands {
    static var all: [CommandDefinition] { [crop, canvasSize] }

    /// The selection, or `nil` for none. One Mancora can't read, or keeps
    /// only as ImageJ's bytes (composite, text and image selections), is
    /// left to ImageJ.
    static func selection(_ name: String, _ open: OpenImage) throws(CommandError) -> Roi? {
        guard open.image.encodedROI != nil else { return nil }
        guard let roi = open.roi else { throw .notNative(name) }
        if case .opaque = roi.shape { throw .notNative(name) }
        return roi
    }

    /// An area selection's bounds clipped to a `width × height` image: the
    /// rectangle ImageJ crops to (`ip.getRoi()`, or the bounds of
    /// `cropRoi`'s intersection with the image). A non-rectangular
    /// selection partly outside the image becomes a composite selection in
    /// ImageJ, which is left to it, as is one entirely outside.
    static func cropRectangle(_ name: String, _ roi: Roi, width: Int, height: Int) throws(CommandError) -> RoiBounds {
        let b = roi.bounds
        let inside = b.x >= 0 && b.y >= 0 && b.x + b.width <= width && b.y + b.height <= height
        if inside { return b }
        guard roi.kind == .rectangle else { throw .notNative(name) }
        let x1 = max(b.x, 0), y1 = max(b.y, 0)
        let x2 = min(b.x + b.width, width), y2 = min(b.y + b.height, height)
        guard x2 > x1, y2 > y1 else { throw .notNative(name) }  // "Selection is outside image"
        return RoiBounds(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// `roi.setLocation(0, 0)` for the non-rectangular area selections Crop
    /// and Duplicate move onto their result; `nil` for shapes Mancora can't
    /// move (composite and parametric ones), which are left to ImageJ.
    static func atOrigin(_ roi: Roi) -> Roi? {
        var moved = roi
        let b = roi.bounds
        switch roi.shape {
        case .oval(.integer(_, _, let w, let h)):
            moved.shape = .oval(.integer(x: 0, y: 0, width: w, height: h))
        case .oval(.subpixel(_, _, let w, let h)):
            moved.shape = .oval(.subpixel(x: 0, y: 0, width: w, height: h))
        case .polygon(var p) where p.parametric == nil && !p.isSplineFit:
            switch p.vertices {
            case .integer(let points):
                let dx = Int32(b.x), dy = Int32(b.y)
                p.vertices = .integer(points.map { Roi.IntPoint(x: $0.x &- dx, y: $0.y &- dy) })
            case .subpixel(let points):
                // The vertices relative to the polygon's base, which moves to (0, 0).
                let fx = points.map(\.x).min() ?? 0, fy = points.map(\.y).min() ?? 0
                p.vertices = .subpixel(points.map { Roi.FloatPoint(x: $0.x - fx, y: $0.y - fy) })
            }
            moved.shape = .polygon(p)
        default:
            return nil
        }
        return moved
    }

    /// `Calibration` after cropping at `(x, y)`: ImageJ moves a set origin.
    static func shiftedOrigin(_ cal: Calibration, by bounds: RoiBounds) -> Calibration {
        var cal = cal
        if cal.xOrigin != 0 || cal.yOrigin != 0 {
            cal.xOrigin -= Double(bounds.x)
            cal.yOrigin -= Double(bounds.y)
        }
        return cal
    }

    /// `image` with `stack` (same plane count) in place of its own, its
    /// channel displays, dimensions and metadata kept.
    static func replacingStack(_ image: Hyperstack, with stack: ImageStack) throws -> Hyperstack {
        var out = try Hyperstack(
            title: image.title, stack: stack, dimensions: image.dimensions, calibration: image.calibration,
            channels: image.channels, compositeMode: image.compositeMode, info: image.info, properties: image.properties)
        out.encodedROI = image.encodedROI
        out.encodedOverlay = image.encodedOverlay
        return out
    }

    // MARK: Image ▸ Crop

    /// `Resizer("crop")`: every plane cropped to an area selection's bounds.
    /// A set origin moves with the crop; a non-rectangular selection moves
    /// to (0, 0) on the result, and a rectangle goes away (unless the image
    /// keeps its size). Display ranges stay as they were.
    static let crop = CommandDefinition("Crop", menu: "Image") { context, _ in
        let name = "Crop"
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard let roi = try selection(name, open), roi.isArea else {
            throw CommandError.failed(command: name, detail: "Area selection required")
        }
        guard open.image.encodedOverlay.isEmpty else { throw CommandError.notNative(name) }  // ImageJ crops overlays
        let image = open.image
        let rect = try cropRectangle(name, roi, width: image.width, height: image.height)
        let restore = roi.kind != .rectangle
        var moved: Roi?
        if restore {
            guard let roi = atOrigin(roi) else { throw CommandError.notNative(name) }
            moved = roi
        }
        try ProcessCommands.replaceCurrent(name, &context) { _ in
            var out = try replacingStack(image, with: image.stack.cropped(to: rect))
            out.calibration = shiftedOrigin(image.calibration, by: rect)
            if restore {
                out.encodedROI = moved.map(RoiCodec.encode)
            } else if rect.width != image.width || rect.height != image.height {
                out.encodedROI = nil  // ImagePlus drops the selection when the size changes
            }
            return out
        }
    }

    // MARK: Image ▸ Adjust ▸ Canvas Size

    static let canvasPositions = [
        "Top-Left", "Top-Center", "Top-Right", "Center-Left", "Center", "Center-Right", "Bottom-Left",
        "Bottom-Center", "Bottom-Right",
    ]

    /// `CanvasResizer`: `width=`, `height=`, `position=` and `zero` (fill
    /// with zero rather than the background color). The image keeps its
    /// calibration and display ranges; the selection goes away when the
    /// size changes.
    static let canvasSize = CommandDefinition("Canvas Size...", menu: "Image>Adjust") { context, options in
        let name = "Canvas Size..."
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard open.image.encodedOverlay.isEmpty else { throw CommandError.notNative(name) }  // ImageJ moves overlays
        let image = open.image
        let wOld = image.width, hOld = image.height
        let wNew = Int(JavaNumerics.int32(options.number(forLabel: "Width:", default: Double(wOld))))
        let hNew = Int(JavaNumerics.int32(options.number(forLabel: "Height:", default: Double(hOld))))
        guard wNew > 0, hNew > 0 else { throw CommandError.invalidOption(command: name, detail: "width and height must be positive") }
        let position = options.value(forLabel: "Position:") ?? "Center"
        guard let iPos = canvasPositions.firstIndex(of: position) else {
            throw CommandError.invalidOption(command: name, detail: "\"\(position)\" is not a valid choice for \"Position:\"")
        }
        let zeroFill = options.flag(forLabel: "Zero Fill")
        let xC = (wNew - wOld) / 2, xR = wNew - wOld, yC = (hNew - hOld) / 2, yB = hNew - hOld
        let xOff = [0, xC, xR][iPos % 3], yOff = [0, yC, yB][iPos / 3]
        let channel = open.channel
        let (fill, displayRange) = zeroFill
            ? (0, nil) : backgroundFill(context.settings.background, image: image, channel: channel)
        try ProcessCommands.replaceCurrent(name, &context) { _ in
            let stack = try image.stack.onCanvas(newWidth: wNew, newHeight: hNew, xOffset: xOff, yOffset: yOff, fill: fill)
            var out = try replacingStack(image, with: stack)
            if let displayRange {
                var display = out.channels[channel]
                display.displayRange = displayRange
                out.setDisplay(display, forChannel: channel)
            }
            if wNew != wOld || hNew != hOld { out.encodedROI = nil }
            return out
        }
    }

    /// `ipNew.setGlobalBackgroundColor()` on a processor made by the image's
    /// `createProcessor` (which has the current channel's LUT and display
    /// range): the value it fills with, and the display range it sets when
    /// that range was 0–0 (`ShortProcessor` and `FloatProcessor.setColor`).
    static func backgroundFill(_ color: UInt32, image: Hyperstack, channel: Int) -> (Double, ClosedRange<Double>?) {
        let display = image.channels[min(channel, image.channels.count - 1)]
        let best = EditCommands.bestIndex(color, display.lut)
        let lo = display.displayRange.lowerBound, hi = display.displayRange.upperBound
        let black = color & 0xFF_FFFF == 0
        switch image.pixelType {
        case .rgb8: return (Double(color & 0xFF_FFFF), nil)
        case .gray8: return (Double(best), nil)
        case .gray16:
            if best > 0 && lo == 0 && hi == 0 { return (Double(best), 0...255) }
            if best == 0 && lo > 0 && black {
                if case .straightLine(-32768, 1)? = image.calibration.valueFunction { return (32768, nil) }
                return (0, nil)
            }
            return (Double(JavaNumerics.int32(lo + (hi - lo) * (Double(best) / 255.0))), nil)
        case .gray32Float:
            if best > 0 && lo == 0 && hi == 0 { return (Double(best), 0...255) }
            if best == 0 && lo > 0 && black { return (0, nil) }
            return (Double(Float(lo + (hi - lo) * (Double(best) / 255.0))), nil)
        }
    }
}
