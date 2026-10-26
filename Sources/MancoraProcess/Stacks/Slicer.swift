public import MancoraCore

/// Image ▸ Stacks ▸ Reslice: a port of ImageJ's `ij.plugin.Slicer` for a
/// stack with no selection or a rectangle (line selections and hyperstacks
/// are ImageJ's).
public enum Slicer {
    /// The "Start at" choices: the edge the first output slice is taken at.
    public enum Start: String, Sendable, CaseIterable {
        case top = "Top", left = "Left", bottom = "Bottom", right = "Right"
    }

    /// `reslice` (`resliceRectOrLine` and `getSlice`): the stack seen from
    /// `start`, one output slice every `outputSpacing` (calibrated, as the
    /// dialog's "Output spacing") across `rect` (the whole image when
    /// `nil`). Each output slice holds one line from every input plane
    /// (bottom to top with `flip`; as columns with `rotate`), stretched
    /// (bilinear) to the voxel depth unless `avoidInterpolation`, which
    /// takes one-pixel spacing throughout.
    ///
    /// The result, "Reslice of <short title>", has the stack's LUT and
    /// `displayRange`, and its calibration turned to match.
    ///
    /// - Throws: ImageJ's error when the spacing leaves no output slice.
    public static func reslice(
        _ image: Hyperstack, rect: RoiBounds?, start: Start, outputSpacing: Double, flip: Bool, rotate: Bool,
        avoidInterpolation: Bool, display: ChannelDisplay
    ) throws(StackEditError) -> Hyperstack {
        var original = image.calibration
        original.pixelDepth = abs(original.pixelDepth)
        if original.pixelWidth == 0 { original.pixelWidth = 1 }
        var inputZSpacing = original.pixelDepth
        var outputZSpacing = outputSpacing / original.pixelWidth
        var pixelWidth = original.pixelWidth
        if avoidInterpolation {
            inputZSpacing = 1
            outputZSpacing = 1
            pixelWidth = 1
        }
        let zSpacing = inputZSpacing / pixelWidth
        let r = rect ?? RoiBounds(x: 0, y: 0, width: image.width, height: image.height)
        var (x1, y1, x2, y2, xInc, yInc) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        let outputSlices: Int
        switch start {
        case .top:
            (x1, y1, x2, y2, yInc) = (Double(r.x), Double(r.y), Double(r.x + r.width), Double(r.y), outputZSpacing)
            outputSlices = ImageJRules.int(Double(r.height) / outputZSpacing)
        case .left:
            (x1, y1, x2, y2, xInc) = (Double(r.x), Double(r.y), Double(r.x), Double(r.y + r.height), outputZSpacing)
            outputSlices = ImageJRules.int(Double(r.width) / outputZSpacing)
        case .bottom:
            let y = Double(r.y + r.height - 1)
            (x1, y1, x2, y2, yInc) = (Double(r.x), y, Double(r.x + r.width), y, -outputZSpacing)
            outputSlices = ImageJRules.int(Double(r.height) / outputZSpacing)
        case .right:
            let x = Double(r.x + r.width - 1)
            (x1, y1, x2, y2, xInc) = (x, Double(r.y), x, Double(r.y + r.height), -outputZSpacing)
            outputSlices = ImageJRules.int(Double(r.width) / outputZSpacing)
        }
        guard outputSlices > 0 else {
            let pixels = String(ImageJRules.roundToInt(outputZSpacing))
            throw .invalidOption(
                "Output Z spacing (\(pixels) pixels) is too large.\nIs the voxel size in Image>Properties correct?.")
        }
        var planes: [Plane] = []
        var size = (width: 0, height: 0)
        for _ in 0..<outputSlices {
            let slice = self.slice(image, x1, y1, x2, y2, flip: flip, rotate: rotate, zSpacing: zSpacing)
            planes.append(slice.plane)
            size = (slice.width, slice.height)
            x1 += xInc
            x2 += xInc
            y1 += yInc
            y2 += yInc
        }

        var cal = image.calibration
        let horizontal = start == .top || start == .bottom
        cal.pixelWidth = horizontal ? original.pixelWidth : original.pixelHeight
        cal.pixelHeight = original.pixelDepth / zSpacing
        cal.pixelDepth = (horizontal ? original.pixelHeight : original.pixelWidth) * outputZSpacing
        if rotate { (cal.pixelWidth, cal.pixelHeight) = (cal.pixelHeight, cal.pixelWidth) }
        let type = image.pixelType
        let range = type == .rgb8 ? 0...255 : ImageJRules.setRange(display.displayRange, on: planes[0])
        let stack = ImageJRules.stack(planes, width: size.width, height: size.height, labels: nil)
        do {
            return try Hyperstack(
                title: "Reslice of " + StackEditor.shortTitle(image.title), stack: stack, calibration: cal,
                channels: [ChannelDisplay(lut: type == .rgb8 ? .grays : display.lut, displayRange: range)])
        } catch {
            preconditionFailure("Reslice built an invalid image: \(error)")
        }
    }

    /// `resliceHyperstack` and `resliceTimeLapseHyperstack`: each channel of
    /// each frame resliced along its slices (or, without slices, each
    /// channel along its frames), in "Reslice of <title>". A composite
    /// keeps its LUTs and mode; otherwise the result is gray, showing
    /// `display`'s range. As in ImageJ 1.54p, every frame of a resliced
    /// time lapse holds the first.
    public static func resliceHyperstack(
        _ image: Hyperstack, rect: RoiBounds?, start: Start, outputSpacing: Double, flip: Bool, rotate: Bool,
        avoidInterpolation: Bool, display: ChannelDisplay
    ) throws(StackEditError) -> Hyperstack {
        let d = image.dimensions
        let timeLapse = d.slices == 1
        var parts: [[Plane]] = []  // by frame (one, for a time lapse), then channel
        var first: Hyperstack?
        for t in 0..<(timeLapse ? 1 : d.frames) {
            for c in 0..<d.channels {
                let indices = timeLapse
                    ? (0..<d.frames).map { d.planeIndex(channel: c, slice: 0, frame: $0) }
                    : (0..<d.slices).map { d.planeIndex(channel: c, slice: $0, frame: t) }
                let tmp = ImageJRules.image(
                    like: image, planes: indices.map { image.stack[$0] }, labels: nil,
                    dimensions: HyperstackDimensions(slices: indices.count), channels: [display],
                    calibration: image.calibration, compositeMode: .color, title: "tmp")
                let resliced = try reslice(
                    tmp, rect: rect, start: start, outputSpacing: outputSpacing, flip: flip, rotate: rotate,
                    avoidInterpolation: avoidInterpolation, display: display)
                if first == nil { first = resliced }
                parts.append(resliced.stack.planes)
            }
        }
        guard let first else { throw .unsupported }
        let n2 = first.stack.count
        var planes: [Plane] = []
        for t in 0..<(timeLapse ? 1 : d.frames) {
            for z in 0..<n2 {
                // ImageJ fills every frame of a resliced time lapse with its first (getPixels(z), z = 1).
                for c in 0..<d.channels { planes.append(parts[t * d.channels + c][timeLapse ? 0 : z]) }
            }
        }
        let dims = timeLapse
            ? HyperstackDimensions(channels: d.channels, frames: n2)
            : HyperstackDimensions(channels: d.channels, slices: n2, frames: d.frames)
        let composite = d.channels > 1 && ImageJRules.isComposite(image)
        let channels = composite
            ? image.channels
            : Array(repeating: ChannelDisplay(lut: .grays, displayRange: first.channels[0].displayRange), count: d.channels)
        let stack = ImageJRules.stack(planes, width: first.width, height: first.height, labels: nil)
        do {
            return try Hyperstack(
                title: "Reslice of " + image.title, stack: stack, dimensions: dims, calibration: first.calibration,
                channels: channels, compositeMode: composite ? image.compositeMode : .color)
        } catch {
            preconditionFailure("Reslice built an invalid hyperstack: \(error)")
        }
    }

    /// `getSlice`: the line from (x1, y1) to (x2, y2) in every plane, one
    /// row (or column, rotated) each, stretched by `zSpacing` along the planes.
    static func slice(
        _ image: Hyperstack, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, flip: Bool, rotate: Bool,
        zSpacing: Double
    ) -> (plane: Plane, width: Int, height: Int) {
        let n = image.stack.count
        let type = image.pixelType
        // Java's `a && b && c || d`.
        let ortho = (Double(ImageJRules.int(x1)) == x1 && Double(ImageJRules.int(y1)) == y1 && x1 == x2) || y1 == y2
        var rows: [[Float]] = []
        var rgbRows: [[UInt32]] = []
        for i in 0..<n {
            let plane = image.stack[flip ? n - 1 - i : i]
            if type == .rgb8 {
                rgbRows.append(
                    ortho
                        ? orthoRGB(plane, image.width, ImageJRules.int(x1), ImageJRules.int(y1), ImageJRules.int(x2), ImageJRules.int(y2))
                        : lineRGB(plane, image.width, x1, y1, x2, y2))
            } else {
                rows.append(
                    ortho
                        ? orthoLine(plane, image.width, ImageJRules.int(x1), ImageJRules.int(y1), ImageJRules.int(x2), ImageJRules.int(y2))
                        : line(plane, image.width, x1, y1, x2, y2))
            }
        }
        let length = type == .rgb8 ? rgbRows[0].count : rows[0].count
        let (w, h) = rotate ? (n, length) : (length, n)
        /// Pixel index of value `j` of line `i`: a row, or a column when rotated.
        func at(_ i: Int, _ j: Int) -> Int { rotate ? j * w + i : i * w + j }
        var plane: Plane
        switch type {
        case .rgb8:
            var p = [UInt32](repeating: 0xFF00_0000, count: w * h)
            for i in 0..<n { for j in 0..<length { p[at(i, j)] = 0xFF00_0000 | rgbRows[i][j] } }
            plane = .rgb8(p)
        case .gray8:
            var p = [UInt8](repeating: 0, count: w * h)
            for i in 0..<n { for j in 0..<length { p[at(i, j)] = UInt8(truncatingIfNeeded: JavaNumerics.int32(rows[i][j] + 0.5)) } }
            plane = .gray8(p)
        case .gray16:
            var p = [UInt16](repeating: 0, count: w * h)
            for i in 0..<n { for j in 0..<length { p[at(i, j)] = UInt16(truncatingIfNeeded: JavaNumerics.int32(rows[i][j] + 0.5)) } }
            plane = .gray16(p)
        case .gray32Float:
            var p = [Float](repeating: 0, count: w * h)
            for i in 0..<n { for j in 0..<length { p[at(i, j)] = rows[i][j] } }
            plane = .gray32Float(p)
        }
        guard zSpacing != 1 else { return (plane, w, h) }
        // ip2.setInterpolate(true); ip2.resize(…) along the planes.
        var ip = GeometryProcessor(plane, width: w)
        ip.interpolation = .bilinear
        let stretched = ImageJRules.int(Double(n) * zSpacing)
        let (w2, h2) = rotate ? (stretched, length) : (length, stretched)
        return (ip.resized(width: w2, height: h2).plane, w2, h2)
    }

    /// `getOrthoLine` for grayscale planes: pixel values along a row or column.
    static func orthoLine(_ plane: Plane, _ width: Int, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> [Float] {
        let height = plane.count / width
        let check = x1 < 0 || x1 > width || y1 < 0 || y1 > height || x2 < 0 || x2 > width || y2 < 0 || y2 > height
        let (dx, dy) = (x2 - x1, y2 - y1)
        let n = max(abs(dx), abs(dy))
        guard n > 0 else { return [] }
        let (xinc, yinc) = (dx / n, dy / n)
        var (x, y) = (x1, y1)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if !check || (x > 0 && x < width && y > 0 && y < height) { out[i] = Float(plane.value(at: y * width + x)) }
            x += xinc
            y += yinc
        }
        return out
    }

    /// `getOrthoLine` for RGB planes (`getPixel`, 0 outside).
    static func orthoRGB(_ plane: Plane, _ width: Int, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> [UInt32] {
        guard case .rgb8(let p) = plane else { return [] }
        let height = p.count / width
        let (dx, dy) = (x2 - x1, y2 - y1)
        let n = max(abs(dx), abs(dy))
        guard n > 0 else { return [] }
        var (x, y) = (x1, y1)
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            if x >= 0 && x < width && y >= 0 && y < height { out[i] = p[y * width + x] & 0xFF_FFFF }
            x += dx / n
            y += dy / n
        }
        return out
    }

    /// `getLine` for grayscale planes: interpolated values every pixel
    /// along the line (`getInterpolatedPixel`, or `getInterpolatedValue`
    /// for 32-bit).
    static func line(_ plane: Plane, _ width: Int, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [Float] {
        let (dx, dy) = (x2 - x1, y2 - y1)
        let n = ImageJRules.roundToInt((dx * dx + dy * dy).squareRoot())
        guard n > 0 else { return [] }
        let ip = GeometryProcessor(plane, width: width)
        var (rx, ry) = (x1, y1)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(plane.pixelType == .gray32Float ? ip.interpolatedValue(x: rx, y: ry) : ip.interpolatedPixel(x: rx, y: ry))
            rx += dx / Double(n)
            ry += dy / Double(n)
        }
        return out
    }

    /// `getLine` for RGB planes (`getInterpolatedRGBPixel`).
    static func lineRGB(_ plane: Plane, _ width: Int, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [UInt32] {
        let (dx, dy) = (x2 - x1, y2 - y1)
        let n = ImageJRules.roundToInt((dx * dx + dy * dy).squareRoot())
        guard n > 0 else { return [] }
        let ip = GeometryProcessor(plane, width: width)
        var (rx, ry) = (x1, y1)
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = ip.interpolatedRGBPixel(x: rx, y: ry) & 0xFF_FFFF
            rx += dx / Double(n)
            ry += dy / Double(n)
        }
        return out
    }
}
