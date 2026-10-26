public import MancoraCore

/// The stack-level parts of ImageJ's geometry plugins: `Resizer`'s Z and T
/// scaling, `Binner`'s shrinking, and the canvas `Rotator` enlarges.
public enum StackGeometry {
    /// A processor for plane `index` of `image`, as `ImageStack.getProcessor`
    /// hands it to a plugin: the display range and LUT of `channel` (the
    /// current one), and the signed 16-bit calibration.
    public static func processor(_ image: Hyperstack, plane index: Int, channel: Int) -> GeometryProcessor {
        let display = image.channels[min(max(channel, 0), image.channels.count - 1)]
        let isRGB = image.pixelType == .rgb8
        var p = GeometryProcessor(image.stack[index], width: image.width, displayRange: isRGB ? nil : display.displayRange)
        p.invertedLUT = !isRGB && ImageJRules.isInvertedLUT(display.lut)
        p.signed16 = image.pixelType == .gray16 && ImageJRules.isSigned16(image.calibration)
        return p
    }

    /// The display range a processor shows: as set, or its pixel range
    /// (0–255 for 8-bit and RGB).
    public static func displayRange(of p: GeometryProcessor) -> ClosedRange<Double> {
        let (lo, hi) = p.currentMinMax
        return ImageJRules.closed(lo, hi)
    }

    /// `ImagePlus.isHyperStack` for an image opened from a TIFF: two or more
    /// of channels, slices and frames.
    public static func isHyperStack(_ image: Hyperstack) -> Bool { ImageJRules.isHyperStack(image.dimensions) }

    /// `ImagePlus.isComposite`: more than one channel of grayscale data.
    public static func isComposite(_ image: Hyperstack) -> Bool { ImageJRules.isComposite(image) }

    /// `ImageProcessor.isInvertedLut`: brightness never rises over entries 0–254.
    public static func isInvertedLUT(_ lut: LUT) -> Bool { ImageJRules.isInvertedLUT(lut) }

    /// `Calibration.scaled()`.
    public static func isScaled(_ cal: Calibration) -> Bool {
        cal.pixelWidth != 1 || cal.pixelHeight != 1 || cal.pixelDepth != 1 || cal.unit != "pixel"
    }

    // MARK: Resizer.zScale

    /// `Resizer.zScale`: a new image with `depth` slices (or, with
    /// `scaleTime` or for a hyperstack without slices, `depth` frames),
    /// each row of every x-z (or x-t) plane resized with `method` as
    /// `ImageProcessor.resize(width, depth, averaging)` does. The result
    /// keeps the title, LUTs, display ranges, calibration (voxel depth
    /// scaled), Info and properties; it has no selection or slice labels.
    /// `channel` is the current channel, whose display a single-channel
    /// result takes.
    public static func zScaled(
        _ image: Hyperstack, depth: Int, method: InterpolationMethod, averaging: Bool, scaleTime: Bool = false,
        channel: Int
    ) -> Hyperstack {
        let dims = image.dimensions
        let width = image.width, height = image.height
        let current = processor(image, plane: 0, channel: channel)
        let hyper = isHyperStack(image)
        var newDims: HyperstackDimensions
        // Each output column is one line of planes: (plane indices in, plane indices out).
        var lines: [([Int], [Int])] = []
        if hyper {
            var scaleT = scaleTime
            if dims.slices == 1 && dims.frames > 1 { scaleT = true }
            newDims = HyperstackDimensions(
                channels: dims.channels, slices: scaleT ? dims.slices : depth, frames: scaleT ? depth : dims.frames)
            if scaleT {
                for z in 0..<dims.slices {
                    for c in 0..<dims.channels {
                        lines.append((
                            (0..<dims.frames).map { dims.planeIndex(channel: c, slice: z, frame: $0) },
                            (0..<depth).map { newDims.planeIndex(channel: c, slice: z, frame: $0) }))
                    }
                }
            } else {
                for t in 0..<dims.frames {
                    for c in 0..<dims.channels {
                        lines.append((
                            (0..<dims.slices).map { dims.planeIndex(channel: c, slice: $0, frame: t) },
                            (0..<depth).map { newDims.planeIndex(channel: c, slice: $0, frame: t) }))
                    }
                }
            }
        } else {
            newDims = HyperstackDimensions(slices: depth)
            lines = [(Array(0..<image.stack.count), Array(0..<depth))]
        }
        let planeCount = newDims.planeCount ?? 0
        var out = [Plane](repeating: Plane(zeroed: image.pixelType, count: width * height), count: planeCount)
        let inputs = image.stack.planes
        for (sources, targets) in lines {
            for y in 0..<height {
                let xz = xzPlane(inputs, sources, row: y, width: width, like: current, method: method)
                let resized = xz.resized(width: width, height: targets.count, averaging: averaging)
                for (k, target) in targets.enumerated() {
                    copyRow(from: resized.plane, row: k, to: &out[target], row: y, width: width)
                }
            }
        }
        let stack = ImageJRules.stack(out, width: width, height: height, labels: nil)
        var channels: [ChannelDisplay]
        if isComposite(image) {
            channels = image.channels
        } else {
            let display = image.channels[min(max(channel, 0), image.channels.count - 1)]
            channels = [display]
            if image.pixelType == .rgb8 { channels = [ChannelDisplay(lut: display.lut, displayRange: 0...255)] }
        }
        var cal = image.calibration
        if isScaled(cal) { cal.pixelDepth *= Double(dims.slices) / Double(newDims.slices) }
        do {
            return try Hyperstack(
                title: image.title, stack: stack, dimensions: newDims, calibration: cal, channels: channels,
                compositeMode: image.compositeMode, info: image.info, properties: image.properties)
        } catch {
            preconditionFailure("zScaled built an invalid image: \(error)")
        }
    }

    /// The x-z plane of row `y` through `sources` (one row per plane), as a
    /// processor made by `createProcessor` from `like`.
    static func xzPlane(
        _ planes: [Plane], _ sources: [Int], row y: Int, width: Int, like: GeometryProcessor, method: InterpolationMethod
    ) -> GeometryProcessor {
        let range = (y * width)..<((y + 1) * width)
        let plane: Plane
        switch like.plane {
        case .gray8:
            plane = .gray8(sources.flatMap { i -> ArraySlice<UInt8> in
                guard case .gray8(let p) = planes[i] else { return [] }
                return p[range]
            })
        case .gray16:
            plane = .gray16(sources.flatMap { i -> ArraySlice<UInt16> in
                guard case .gray16(let p) = planes[i] else { return [] }
                return p[range]
            })
        case .gray32Float:
            plane = .gray32Float(sources.flatMap { i -> ArraySlice<Float> in
                guard case .gray32Float(let p) = planes[i] else { return [] }
                return p[range]
            })
        case .rgb8:
            plane = .rgb8(sources.flatMap { i -> ArraySlice<UInt32> in
                guard case .rgb8(let p) = planes[i] else { return [] }
                return p[range]
            })
        }
        var p = like.created(plane, width: width)
        p.interpolation = method
        return p
    }

    static func copyRow(from source: Plane, row k: Int, to target: inout Plane, row y: Int, width: Int) {
        let from = (k * width)..<((k + 1) * width)
        let to = (y * width)..<((y + 1) * width)
        switch (source, target) {
        case (.gray8(let s), .gray8(var t)):
            target = .gray8([])
            t.replaceSubrange(to, with: s[from])
            target = .gray8(t)
        case (.gray16(let s), .gray16(var t)):
            target = .gray8([])
            t.replaceSubrange(to, with: s[from])
            target = .gray16(t)
        case (.gray32Float(let s), .gray32Float(var t)):
            target = .gray8([])
            t.replaceSubrange(to, with: s[from])
            target = .gray32Float(t)
        case (.rgb8(let s), .rgb8(var t)):
            target = .gray8([])
            t.replaceSubrange(to, with: s[from].map { $0 | 0xFF00_0000 })
            target = .rgb8(t)
        default:
            preconditionFailure("planes of different types")
        }
    }

    // MARK: Binner

    /// `Binner`'s methods, in its "Bin Method" order.
    public enum BinMethod: Int, Sendable, Hashable, CaseIterable {
        case average, median, min, max, sum

        /// "Average", "Median", "Min", "Max", "Sum".
        public var name: String { ["Average", "Median", "Min", "Max", "Sum"][rawValue] }

        public init?(name: String) {
            guard let method = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = method
        }
    }

    /// `Binner.shrink`: each plane reduced by `xShrink` × `yShrink` blocks,
    /// then (for a plain stack, or a hyperstack of channels and one of slices
    /// or frames) groups of `zShrink` planes, combined by `method` (Z uses
    /// the average where the planes used the median). Partial blocks at the
    /// edges are dropped. 8-bit planes shown with an inverted LUT are
    /// inverted around the binning.
    ///
    /// The result keeps the title, LUTs, display ranges (the current
    /// channel's maximum multiplied by the bin volume for a 16- or 32-bit
    /// sum), Info and properties; a scaled calibration is multiplied by the
    /// shrink factors. An RGB sum leaves the current plane (`currentPlane`
    /// of a hyperstack, the first otherwise) mapped through ImageJ's
    /// `setMinAndMax(0, 255·n)`. Shrink factors must be at least 1, and no
    /// larger than the image.
    public static func binned(
        _ image: Hyperstack, xShrink: Int, yShrink: Int, zShrink: Int, method: BinMethod, channel: Int,
        currentPlane: Int = 0
    ) -> Hyperstack {
        let dims = image.dimensions
        let w = image.width / xShrink, h = image.height / yShrink
        let display = image.channels[min(max(channel, 0), image.channels.count - 1)]
        let inverted = image.pixelType == .gray8 && ImageJRules.isInvertedLUT(display.lut)
        let maxValue: Float = image.pixelType == .gray8 ? 255 : image.pixelType == .gray16 ? 65535 : 0
        var planes = (0..<image.stack.count).map { i -> Plane in
            var plane = image.stack[i]
            if inverted { plane = invert8(plane) }
            var shrunk = shrink(plane, width: image.width, xShrink: xShrink, yShrink: yShrink, method: method, maxValue: maxValue)
            if inverted { shrunk = invert8(shrunk) }
            return shrunk
        }
        var newDims = dims
        let zMethod: BinMethod = method == .median ? .average : method
        if zShrink > 1 {
            if isHyperStack(image) {
                if dims.channels > 1 && (dims.slices == 1 || dims.frames == 1) {
                    let depth = dims.slices * dims.frames
                    let depth2 = depth / zShrink
                    var merged = [Plane](repeating: Plane(zeroed: image.pixelType, count: w * h), count: dims.channels * depth2)
                    for c in 0..<dims.channels {
                        let channelPlanes = (0..<depth).map { planes[$0 * dims.channels + c] }
                        let shrunk = shrinkZ(channelPlanes, zShrink: zShrink, method: zMethod, maxValue: maxValue)
                        for (z, plane) in shrunk.enumerated() { merged[z * dims.channels + c] = plane }
                    }
                    planes = merged
                    if dims.slices > 1 { newDims.slices /= zShrink }
                    if dims.frames > 1 { newDims.frames /= zShrink }
                }
            } else {
                planes = shrinkZ(planes, zShrink: zShrink, method: zMethod, maxValue: maxValue)
                // ImagePlus.verifyDimensions: a time series stays one; anything else becomes slices.
                newDims = dims.slices == 1 && dims.frames > 1 && dims.channels == 1
                    ? HyperstackDimensions(frames: planes.count) : HyperstackDimensions(slices: planes.count)
            }
        }
        var labels: [String?]? = nil
        if planes.count == image.stack.count { labels = image.stack.labels }
        var stack = ImageJRules.stack(planes, width: w, height: h, labels: labels)
        var cal = image.calibration
        if isScaled(cal) {
            cal.pixelWidth *= Double(xShrink)
            cal.pixelHeight *= Double(yShrink)
            cal.pixelDepth *= Double(zShrink)
        }
        var channels = image.channels
        if !isComposite(image) {
            channels = [display]
            if image.pixelType == .rgb8 { channels = [ChannelDisplay(lut: display.lut, displayRange: 0...255)] }
        }
        if newDims.channels != channels.count { channels = Hyperstack.defaultChannels(for: stack, dimensions: newDims) }
        let factor = Double(xShrink * yShrink * zShrink)
        if method == .sum, image.pixelType == .gray16 || image.pixelType == .gray32Float, !isComposite(image) {
            // ip.setMinAndMax(ip.getMin(), ip.getMax()*n) on the result's processor. A
            // composite keeps the ranges of its channel LUTs, which are what it saves.
            var p = GeometryProcessor(stack[0], width: w, displayRange: channels[0].displayRange)
            p.setMinAndMax(p.displayMin, p.displayMax * factor)
            channels[0].displayRange = displayRange(of: p)
        }
        if method == .sum, image.pixelType == .rgb8 {
            // ColorProcessor.setMinAndMax(0, 255*n) maps the current plane's pixels through a LUT.
            let current = isHyperStack(image) ? min(max(currentPlane, 0), stack.count - 1) : 0
            if case .rgb8(let p) = stack[current] {
                let hi = 255 * factor
                let lut = (0..<256).map { i in min(max(ImageJRules.int(256.0 * Double(i) / hi), 0), 255) }
                let mapped = p.map { c -> UInt32 in
                    let r = lut[Int((c >> 16) & 0xFF)], g = lut[Int((c >> 8) & 0xFF)], b = lut[Int(c & 0xFF)]
                    return 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                }
                try? stack.setPlane(.rgb8(mapped), at: current)
            }
        }
        do {
            var out = try Hyperstack(
                title: image.title, stack: stack, dimensions: newDims, calibration: cal, channels: channels,
                compositeMode: image.compositeMode, info: image.info, properties: image.properties)
            out.encodedOverlay = image.encodedOverlay
            return out
        } catch {
            preconditionFailure("binned built an invalid image: \(error)")
        }
    }

    /// 8-bit `invert()`: 255 − v.
    static func invert8(_ plane: Plane) -> Plane {
        guard case .gray8(let p) = plane else { return plane }
        return .gray8(p.map { 255 - $0 })
    }

    /// `Binner.shrink(ip, method)` of one plane.
    static func shrink(_ plane: Plane, width: Int, xShrink: Int, yShrink: Int, method: BinMethod, maxValue: Float) -> Plane {
        let height = plane.count / width
        let w = width / xShrink, h = height / yShrink
        func binned(_ values: [Float], _ store: (Float) -> Void) {
            var block = [Float](repeating: 0, count: xShrink * yShrink)
            for y in 0..<h {
                for x in 0..<w {
                    var k = 0
                    for y2 in 0..<yShrink {
                        for x2 in 0..<xShrink {
                            block[k] = values[(y * yShrink + y2) * width + x * xShrink + x2]
                            k += 1
                        }
                    }
                    store(combine(&block, method: method, count: xShrink * yShrink, maxValue: maxValue))
                }
            }
        }
        switch plane {
        case .gray8(let p):
            var out: [UInt8] = []
            out.reserveCapacity(w * h)
            binned(p.map { Float($0) }) { out.append(byteSetf($0)) }
            return .gray8(out)
        case .gray16(let p):
            var out: [UInt16] = []
            out.reserveCapacity(w * h)
            binned(p.map { Float($0) }) { out.append(UInt16(truncatingIfNeeded: JavaNumerics.int32($0 + 0.5))) }
            return .gray16(out)
        case .gray32Float(let p):
            var out: [Float] = []
            out.reserveCapacity(w * h)
            binned(p) { out.append($0) }
            return .gray32Float(out)
        case .rgb8(let p):
            // shrinkRGB: each channel binned as an 8-bit image. ImageJ only clamps sums
            // of 8- and 16-bit images, so an RGB channel's sum wraps around like a byte.
            let channels = [16, 8, 0].map { shift -> [UInt8] in
                var out: [UInt8] = []
                out.reserveCapacity(w * h)
                binned(p.map { Float(($0 >> UInt32(shift)) & 0xFF) }) { out.append(byteSetf($0)) }
                return out
            }
            return .rgb8(GeometryProcessor.merge(channels))
        }
    }

    /// `ByteProcessor.setf`: `(byte)(value + 0.5f)`.
    @inline(__always)
    static func byteSetf(_ value: Float) -> UInt8 { UInt8(truncatingIfNeeded: JavaNumerics.int32(value + 0.5)) }

    /// `getAverage`, `getMedian`, `getMin`, `getMax` and `getSum` over one block.
    static func combine(_ block: inout [Float], method: BinMethod, count n: Int, maxValue: Float) -> Float {
        switch method {
        case .average:
            var sum: Float = 0
            for i in 0..<n { sum += block[i] }
            return sum / Float(n)
        case .median:
            // Binner's own median: the largest values are zeroed in turn.
            let halfsize = n / 2
            for _ in 0...halfsize {
                var max: Float = 0
                var mj = 0
                for j in 0..<n where block[j] > max {
                    max = block[j]
                    mj = j
                }
                block[mj] = 0
            }
            var max = -Float.greatestFiniteMagnitude
            for j in 0..<n where block[j] > max { max = block[j] }
            return max
        case .min:
            var min = Float.greatestFiniteMagnitude
            for i in 0..<n where block[i] < min { min = block[i] }
            return min
        case .max:
            var max = -Float.greatestFiniteMagnitude
            for i in 0..<n where block[i] > max { max = block[i] }
            return max
        case .sum:
            var sum: Float = 0
            for i in 0..<n { sum += block[i] }
            if maxValue > 0 && sum > maxValue { sum = maxValue }
            return sum
        }
    }

    /// `Binner.shrinkZ`: groups of `zShrink` planes combined voxel by voxel.
    static func shrinkZ(_ planes: [Plane], zShrink: Int, method: BinMethod, maxValue: Float) -> [Plane] {
        guard let first = planes.first else { return planes }
        let d = planes.count, d2 = d / zShrink
        let count = first.count
        var out = Array(planes.prefix(d2))
        var block = [Float](repeating: 0, count: zShrink)
        func combined(_ values: (Int, Int) -> Float, _ store: (Int, Int, Float) -> Void) {
            for i in 0..<count {
                for z2 in 0..<d2 {
                    for k in 0..<zShrink { block[k] = values(z2 * zShrink + k, i) }
                    store(z2, i, combine(&block, method: method, count: zShrink, maxValue: maxValue))
                }
            }
        }
        switch first {
        case .gray8:
            let p = planes.map { plane -> [UInt8] in if case .gray8(let p) = plane { return p } else { return [] } }
            var o = out.map { plane -> [UInt8] in if case .gray8(let p) = plane { return p } else { return [] } }
            combined({ Float(p[$0][$1]) }) { z, i, v in
                // ImageStack.setVoxel: clamped, (byte)(value + 0.5) in double.
                o[z][i] = UInt8(truncatingIfNeeded: JavaNumerics.int32(min(max(Double(v), 0), 255) + 0.5))
            }
            out = o.map { .gray8($0) }
        case .gray16:
            let p = planes.map { plane -> [UInt16] in if case .gray16(let p) = plane { return p } else { return [] } }
            var o = out.map { plane -> [UInt16] in if case .gray16(let p) = plane { return p } else { return [] } }
            combined({ Float(p[$0][$1]) }) { z, i, v in
                o[z][i] = UInt16(truncatingIfNeeded: JavaNumerics.int32(min(max(Double(v), 0), 65535) + 0.5))
            }
            out = o.map { .gray16($0) }
        case .gray32Float:
            let p = planes.map { plane -> [Float] in if case .gray32Float(let p) = plane { return p } else { return [] } }
            var o = out.map { plane -> [Float] in if case .gray32Float(let p) = plane { return p } else { return [] } }
            combined({ p[$0][$1] }) { z, i, v in o[z][i] = v }
            out = o.map { .gray32Float($0) }
        case .rgb8:
            // A ColorProcessor's channels, each binned as bytes.
            let p = planes.map { plane -> [UInt32] in if case .rgb8(let p) = plane { return p } else { return [] } }
            var o = out.map { plane -> [UInt32] in if case .rgb8(let p) = plane { return p } else { return [] } }
            for shift in [16, 8, 0] {
                let s = UInt32(shift)
                combined({ Float((p[$0][$1] >> s) & 0xFF) }) { z, i, v in
                    let byte = UInt32(byteSetf(v))
                    o[z][i] = (o[z][i] & ~(0xFF << s)) | byte << s | 0xFF00_0000
                }
            }
            out = o.map { .rgb8($0) }
        }
        return out
    }

    // MARK: Rotator's enlarged canvas

    /// The size `Rotator` enlarges a `width × height` image to before
    /// rotating it `angle` degrees: the image-sized rectangle rotated about
    /// its center (`RoiRotator`, float vertices), its float bounds rounded,
    /// and never smaller than the image.
    public static func rotatedCanvasSize(width: Int, height: Int, angle: Double) -> (width: Int, height: Int) {
        let xcenter = Double(width) / 2.0, ycenter = Double(height) / 2.0
        let theta = -angle * Double.pi / 180.0
        let corners: [(Float, Float)] = [(0, 0), (Float(width), 0), (Float(width), Float(height)), (0, Float(height))]
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = Float.leastNonzeroMagnitude, maxY = Float.leastNonzeroMagnitude
        for (px, py) in corners {
            let dx = Double(px) - xcenter
            let dy = ycenter - Double(py)
            let radius = (dx * dx + dy * dy).squareRoot()
            let a = GeometryMath.arcTangent(dy, dx)
            let x = Float(xcenter + radius * GeometryMath.cosine(a + theta))
            let y = Float(ycenter - radius * GeometryMath.sine(a + theta))
            minX = Swift.min(minX, x)
            maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y)
            maxY = Swift.max(maxY, y)
        }
        var w = ImageJRules.roundToInt(Double(maxX - minX))
        var h = ImageJRules.roundToInt(Double(maxY - minY))
        if w < width { w = width }
        if h < height { h = height }
        return (w, h)
    }

    /// The value `setColor(color)` gives a new processor made from `like`
    /// (`setGlobalBackgroundColor`, as Canvas Size fills): the closest LUT
    /// entry for 8-bit, that entry within the display range for 16- and
    /// 32-bit (0 for black when the range starts above 0), the color for RGB.
    public static func colorValue(_ rgb: UInt32, like p: GeometryProcessor, lut: LUT) -> Double {
        let best = GeometryProcessor.bestIndex(rgb, lut)
        let (lo, hi) = p.currentMinMax
        let isBlack = rgb & 0xFF_FFFF == 0
        switch p.plane {
        case .gray8: return Double(best)
        case .gray16:
            if best > 0 && lo == 0 && hi == 0 { return Double(best) }
            if best == 0 && lo > 0 && isBlack { return p.signed16 ? 32768 : 0 }
            return Double(ImageJRules.int(lo + (hi - lo) * (Double(best) / 255.0)))
        case .gray32Float:
            if best > 0 && lo == 0 && hi == 0 { return Double(best) }
            if best == 0 && lo > 0 && isBlack { return 0 }
            return Double(Float(lo + (hi - lo) * (Double(best) / 255.0)))
        case .rgb8: return Double(Int32(bitPattern: 0xFF00_0000 | (rgb & 0xFF_FFFF)))
        }
    }

    /// `CanvasResizer.expandImage`/`expandStack`: every plane placed at
    /// (`xOffset`, `yOffset`) on a `width × height` canvas filled with `fill`
    /// (stored as `ip.fill()` stores the processor's fill value).
    public static func expandedCanvas(
        _ image: Hyperstack, width: Int, height: Int, xOffset: Int, yOffset: Int, fill: Double
    ) -> Hyperstack {
        let w0 = image.width, h0 = image.height
        let planes = (0..<image.stack.count).map { i -> Plane in
            var canvas = GeometryProcessor(Plane(zeroed: image.pixelType, count: width * height), width: width)
            for y in 0..<height {
                for x in 0..<width { canvas.putFill(x, y, fill) }
            }
            let old = image.stack[i]
            for y in 0..<h0 {
                let ty = y + yOffset
                guard ty >= 0, ty < height else { continue }
                for x in 0..<w0 {
                    let tx = x + xOffset
                    guard tx >= 0, tx < width else { continue }
                    canvas.putRaw(tx, ty, old, y * w0 + x)
                }
            }
            return canvas.plane
        }
        let stack = ImageJRules.stack(planes, width: width, height: height, labels: image.stack.labels)
        do {
            var out = try Hyperstack(
                title: image.title, stack: stack, dimensions: image.dimensions, calibration: image.calibration,
                channels: image.channels, compositeMode: image.compositeMode, info: image.info,
                properties: image.properties)
            out.encodedOverlay = image.encodedOverlay
            return out
        } catch {
            preconditionFailure("expandedCanvas built an invalid image: \(error)")
        }
    }
}

extension GeometryProcessor {
    /// How `fill()` stores a fill value: `(int)` for 8- and 16-bit (already
    /// in range), `float` for 32-bit, the packed color for RGB.
    mutating func putFill(_ x: Int, _ y: Int, _ value: Double) {
        switch plane {
        case .gray8, .gray16: putPixel(x, y, ImageJRules.int(value))
        case .gray32Float: putPixel(x, y, Int(Int32(bitPattern: Float(value).bitPattern)))
        case .rgb8: putPixel(x, y, Int(JavaNumerics.int32(value)) | Int(Int32(bitPattern: 0xFF00_0000)))
        }
    }

    /// Copies pixel `i` of `source` (same type) to (x, y).
    mutating func putRaw(_ x: Int, _ y: Int, _ source: Plane, _ i: Int) {
        let j = y * width + x
        switch (plane, source) {
        case (.gray8(var p), .gray8(let s)):
            plane = .gray8([])
            p[j] = s[i]
            plane = .gray8(p)
        case (.gray16(var p), .gray16(let s)):
            plane = .gray8([])
            p[j] = s[i]
            plane = .gray16(p)
        case (.gray32Float(var p), .gray32Float(let s)):
            plane = .gray8([])
            p[j] = s[i]
            plane = .gray32Float(p)
        case (.rgb8(var p), .rgb8(let s)):
            plane = .gray8([])
            p[j] = s[i]
            plane = .rgb8(p)
        default:
            break
        }
    }
}
