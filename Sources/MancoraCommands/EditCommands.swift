public import MancoraCore
import MancoraProcess

/// Edit ▸ Selection ▸ Select All and Select None, and Edit ▸ Fill, Clear
/// and Clear Outside (ImageJ's `Selection` and `Filler`).
public enum EditCommands {
    static var all: [CommandDefinition] { [selectNone, selectAll, fill, clear, clearOutside] }

    static let selectNone = CommandDefinition("Select None", menu: "Edit>Selection") { context, _ in
        try context.withCurrent("Select None") { (open: inout OpenImage) throws(CommandError) in open.roi = nil }
    }

    static let selectAll = CommandDefinition("Select All", menu: "Edit>Selection") { context, _ in
        try context.withCurrent("Select All") { (open: inout OpenImage) throws(CommandError) in
            open.roi = Roi(.rectangle(.integer(x: 0, y: 0, width: Int32(open.image.width), height: Int32(open.image.height))))
        }
    }

    /// Fills the selection with the foreground color (or a macro's `setColor` value).
    static let fill = CommandDefinition("Fill", menu: "Edit") { context, options in
        let value = context.settings.fillValue
        let color = context.settings.fillColor ?? context.settings.foreground
        try paint("Fill", &context, options, inside: true) { open in value ?? fillValue(color: color, for: open) }
    }

    /// Fills the selection with the background color.
    static let clear = CommandDefinition("Clear", menu: "Edit") { context, options in
        let color = context.settings.background
        try paint("Clear", &context, options, inside: true) { open in fillValue(color: color, for: open) }
    }

    /// Fills everything outside the selection with the background color.
    static let clearOutside = CommandDefinition("Clear Outside", menu: "Edit") { context, options in
        let color = context.settings.background
        try paint("Clear Outside", &context, options, inside: false) { open in fillValue(color: color, for: open) }
    }

    /// `Filler`: an area selection is required; each target plane is filled
    /// inside (or outside) its mask.
    private static func paint(
        _ name: String, _ context: inout CommandContext, _ options: MacroOptions, inside: Bool,
        _ value: (OpenImage) -> Double
    ) throws {
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard let roi = open.roi else { throw CommandError.failed(command: name, detail: "This command requires a selection") }
        if !roi.isArea {
            try SelectionDrawing.paintNonArea(name, roi, value: value(open), &context, options)
            return
        }
        guard roi.kind != .composite else { throw CommandError.notNative(name) }
        let width = open.image.width, height = open.image.height
        let region: MeasurementRegion
        do { region = try roi.measurementRegion(width: width, height: height) } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
        let v = value(open)
        try FilterCommands.apply(name, &context, options) { plane, _, _ in
            var out = plane
            for y in 0..<height {
                for x in 0..<width {
                    let inRect = x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
                    let inMask = inRect && region.contains(x, y)
                    if inMask == inside { putFill(&out, y * width + x, v) }
                }
            }
            return out
        }
    }

    /// The value `ImageProcessor.setColor(color)` fills with: the LUT entry
    /// closest to the color, mapped through the display range for 16- and
    /// 32-bit images; the color itself (`0xRRGGBB`) for RGB.
    public static func fillValue(color: UInt32, for open: OpenImage) -> Double {
        let display = open.image.channels[min(open.channel, open.image.channels.count - 1)]
        switch open.image.pixelType {
        case .rgb8: return Double(color & 0xFF_FFFF)
        case .gray8: return Double(bestIndex(color, display.lut))
        case .gray16, .gray32Float:
            let best = Double(bestIndex(color, display.lut))
            let range = display.displayRange
            let v = range.lowerBound + (range.upperBound - range.lowerBound) * (best / 255.0)
            return open.image.pixelType == .gray16 ? Double(JavaNumerics.int32(v)) : Double(Float(v))
        }
    }

    /// `ImageProcessor.getBestIndex(Color)`: the LUT entry closest to the color.
    public static func bestIndex(_ color: UInt32, _ lut: LUT) -> Int {
        let r = Int((color >> 16) & 0xFF), g = Int((color >> 8) & 0xFF), b = Int(color & 0xFF)
        var minDistance = Double.greatestFiniteMagnitude
        var minIndex = 0
        for i in 0..<256 {
            let rd = Double(r - Int(lut.reds[i])), gd = Double(g - Int(lut.greens[i])), bd = Double(b - Int(lut.blues[i]))
            let distance = rd * rd + gd * gd + bd * bd
            if distance < minDistance {
                minDistance = distance
                minIndex = i
            }
            if distance == 0 { break }
        }
        return minIndex
    }

    /// How `ip.fill()` stores the fill value: clamped to the type's range,
    /// truncated for integer types.
    public static func putFill(_ plane: inout Plane, _ i: Int, _ v: Double) {
        // Each case lets go of `plane` before writing, so the pixels are changed in place.
        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            p[i] = UInt8(max(0, min(255, Int(JavaNumerics.int32(v)))))
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            p[i] = UInt16(max(0, min(65535, Int(JavaNumerics.int32(v)))))
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            p[i] = Float(v)
            plane = .gray32Float(p)
        case .rgb8(var p):
            plane = .gray8([])
            p[i] = 0xFF00_0000 | (UInt32(bitPattern: JavaNumerics.int32(v)) & 0xFF_FFFF)
            plane = .rgb8(p)
        }
    }
}
