public import MancoraCore
import MancoraProcess

extension OpenImage {
    /// ImageJ's `IJ.doWand(imp, x, y, tolerance, mode)`, as the wand tool
    /// and the macro `doWand` use it: the traced selection from (x, y) on the
    /// current plane, or `nil` if there is none. With a threshold set it
    /// traces the thresholded area; otherwise the pixels within `tolerance`
    /// of the one clicked. `mode` starting with "4" or "8" picks 4- or
    /// 8-connected tracing, else ImageJ's legacy mode.
    public func wandSelection(x: Int, y: Int, tolerance: Double = 0, mode: String? = nil) -> Roi? {
        let plane = currentPlane
        let width = image.width
        if case .gray32Float(let pixels) = plane, x >= 0, x < width, y >= 0, y < image.height,
            pixels[y * width + x].isNaN
        {
            return nil
        }
        let wandMode: Wand.Mode =
            mode?.hasPrefix("4") == true ? .fourConnected : mode?.hasPrefix("8") == true ? .eightConnected : .legacy
        var wand = Wand(values: Self.wandValues(plane, exactColors: tolerance == 0), width: width)
        if let threshold, image.pixelType != .rgb8 {
            wand.autoOutline(x: x, y: y, lower: threshold.lower, upper: threshold.upper, mode: wandMode)
        } else {
            wand.autoOutline(x: x, y: y, tolerance: tolerance, mode: wandMode)
        }
        guard !wand.xs.isEmpty else { return nil }
        let points = zip(wand.xs, wand.ys).map { Roi.IntPoint(x: $0, y: $1) }
        return Roi(.polygon(.init(.traced, .integer(points))))
    }

    /// The values ImageJ's Wand reads: 8- and 16-bit values, floats, and for
    /// RGB the colors (exact matching) or ColorProcessor's gray values.
    private static func wandValues(_ plane: Plane, exactColors: Bool) -> [Float] {
        switch plane {
        case .gray8(let p): return p.map { Float($0) }
        case .gray16(let p): return p.map { Float($0) }
        case .gray32Float(let p): return p
        case .rgb8(let p):
            if exactColors { return p.map { Float($0 & 0xFFFFFF) } }
            let w = 1.0 / 3.0
            return p.map { c in
                Float(Double((c >> 16) & 0xFF) * w + Double((c >> 8) & 0xFF) * w + Double(c & 0xFF) * w)
            }
        }
    }
}
