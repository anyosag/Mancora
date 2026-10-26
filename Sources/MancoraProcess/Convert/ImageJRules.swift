import MancoraCore

/// Rules ImageJ applies in many places: Java's numeric casts, how an
/// `ImageProcessor` stores the range given to `setMinAndMax`, how
/// `Calibration.setImage` reacts to a new pixel type, and how LUTs are
/// classified and applied.
///
/// Operations in this module call these so that every port shares one
/// definition of, say, "the min and max a ShortProcessor holds".
enum ImageJRules {
    // MARK: Java numerics

    /// Java's `Math.round(double)`: the closest `long`, ties toward positive
    /// infinity, NaN to 0, saturating at the `long` range.
    static func round(_ x: Double) -> Int64 {
        guard !x.isNaN else { return 0 }
        let floor = x.rounded(.down)
        let r = x - floor >= 0.5 ? floor + 1 : floor
        if r >= 0x1p63 { return .max }
        if r < -0x1p63 { return .min }
        return Int64(r)
    }

    /// Java's `(int)Math.round(x)`: the `long` narrowed to its low 32 bits.
    static func roundToInt(_ x: Double) -> Int {
        Int(Int32(truncatingIfNeeded: round(x)))
    }

    /// Java's `(int)` of a `double`: truncation, NaN to 0, saturating.
    @inline(__always)
    static func int(_ x: Double) -> Int { Int(JavaNumerics.int32(x)) }

    /// Java's `(int)` of a `float`.
    @inline(__always)
    static func int(_ x: Float) -> Int { Int(JavaNumerics.int32(x)) }

    // MARK: Pixel ranges

    /// `ShortProcessor.findMinAndMax`.
    static func pixelRange(_ pixels: [UInt16]) -> (min: Int, max: Int) {
        guard var lo = pixels.first else { return (0, 0) }
        var hi = lo
        for v in pixels {
            if v < lo { lo = v } else if v > hi { hi = v }
        }
        return (Int(lo), Int(hi))
    }

    /// `FloatProcessor.findMinAndMax`: NaN is skipped but infinities count;
    /// both are NaN when every pixel is NaN.
    static func pixelRange(_ pixels: [Float]) -> (min: Double, max: Double) {
        var i = 0
        while i < pixels.count, pixels[i].isNaN { i += 1 }
        guard i < pixels.count else { return (.nan, .nan) }
        var lo = pixels[i], hi = pixels[i]
        while i < pixels.count {
            let v = pixels[i]
            if v < lo { lo = v } else if v > hi { hi = v }
            i += 1
        }
        return (Double(lo), Double(hi))
    }

    /// The min and max a `ShortProcessor` holds after `setMinAndMax(range)`:
    /// rounded to integers, or the pixel range for `0...0`.
    static func shortMinMax(_ range: ClosedRange<Double>, _ pixels: [UInt16]) -> (min: Int, max: Int) {
        if range.lowerBound == 0, range.upperBound == 0 { return pixelRange(pixels) }
        return (roundToInt(range.lowerBound), roundToInt(range.upperBound))
    }

    /// The min and max a `FloatProcessor` holds after `setMinAndMax(range)`:
    /// rounded to `float`, or the pixel range for `0...0`.
    static func floatMinMax(_ range: ClosedRange<Double>, _ pixels: [Float]) -> (min: Double, max: Double) {
        if range.lowerBound == 0, range.upperBound == 0 { return pixelRange(pixels) }
        return (Double(Float(range.lowerBound)), Double(Float(range.upperBound)))
    }

    /// A display range from an ImageJ min and max. ImageJ keeps NaN when a
    /// float image has no numbers at all; a `ClosedRange` can't, so that
    /// becomes `0...0`.
    static func closed(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
        if lo.isNaN || hi.isNaN { return 0...0 }
        return lo <= hi ? lo...hi : lo...lo
    }

    /// The display range of a single-channel image after `resetDisplayRange`.
    static func resetRange(_ plane: Plane) -> ClosedRange<Double> {
        switch plane {
        case .gray8, .rgb8:
            return 0...255
        case .gray16(let p):
            let r = pixelRange(p)
            return Double(r.min)...Double(r.max)
        case .gray32Float(let p):
            let r = pixelRange(p)
            return closed(r.min, r.max)
        }
    }

    /// The display range a single-channel image reports after
    /// `setDisplayRange(range)`, which rounds it the way its processor does.
    static func setRange(_ range: ClosedRange<Double>, on plane: Plane) -> ClosedRange<Double> {
        switch plane {
        case .gray8:
            return closed(Double(roundToInt(range.lowerBound)), Double(roundToInt(range.upperBound)))
        case .gray16(let p):
            let r = shortMinMax(range, p)
            return closed(Double(r.min), Double(r.max))
        case .gray32Float(let p):
            let r = floatMinMax(range, p)
            return closed(r.min, r.max)
        case .rgb8:
            return range
        }
    }

    /// `ImagePlus.getDisplayRangeMin()`/`Max()`: rounded for every type but 32-bit.
    static func reportedRange(_ range: ClosedRange<Double>, type: PixelType) -> (min: Double, max: Double) {
        if type == .gray32Float { return (range.lowerBound, range.upperBound) }
        return (Double(round(range.lowerBound)), Double(round(range.upperBound)))
    }

    // MARK: Calibration

    /// Whether `cal` is ImageJ's signed 16-bit calibration (`-32768 + raw`).
    static func isSigned16(_ cal: Calibration) -> Bool {
        if case .straightLine(let intercept, let slope)? = cal.valueFunction {
            return intercept == -32768 && slope == 1
        }
        return false
    }

    /// `Calibration.setImage`: the value function is dropped when the bit
    /// depth changes or the image becomes 32-bit or RGB (32-bit keeps the
    /// value unit); signed 16-bit data that stays 16-bit keeps it.
    static func calibration(_ cal: Calibration, from old: PixelType, to new: PixelType) -> Calibration {
        if new == .gray16, old == .gray16, isSigned16(cal) { return cal }
        var c = cal
        if new.bitDepth != old.bitDepth || new == .gray32Float || new == .rgb8 {
            c.valueFunction = nil
            if new != .gray32Float { c.valueUnit = "Gray Value" }
        }
        return c
    }

    // MARK: LUTs

    /// `LookUpTable.createGrayscaleColorModel(true)`.
    static let invertedGrays: LUT = LUT.grays.inverted()

    /// `ImageProcessor.isColorLut`: some entry is not gray.
    static func isColorLUT(_ lut: LUT) -> Bool {
        for i in 0..<256 where lut.reds[i] != lut.greens[i] || lut.greens[i] != lut.blues[i] {
            return true
        }
        return false
    }

    /// `ImageProcessor.isPseudoColorLut`: the colors change smoothly (or it
    /// is the 3-3-2 RGB LUT). Thresholds, which also make it true, aren't modeled.
    static func isPseudoColorLUT(_ lut: LUT) -> Bool {
        var r2 = Int(lut.reds[0]), g2 = Int(lut.greens[0]), b2 = Int(lut.blues[0])
        var sum = 0.0, sum2 = 0.0
        for i in 0..<256 {
            let r = Int(lut.reds[i]), g = Int(lut.greens[i]), b = Int(lut.blues[i])
            let dr = r - r2, dg = g - g2, db = b - b2
            sum += Double(dr)
            sum2 += Double(dr * dr)
            sum += Double(dg)
            sum2 += Double(dg * dg)
            sum += Double(db)
            sum2 += Double(db * db)
            r2 = r
            g2 = g
            b2 = b
        }
        var stdDev = (768 * sum2 - sum * sum) / 768.0
        stdDev = stdDev > 0 ? (stdDev / 767.0).squareRoot() : 0
        return stdDev < 20.0 || int(stdDev) == 67
    }

    /// `ImageProcessor.isInvertedLut`: brightness never rises over entries 0–254.
    static func isInvertedLUT(_ lut: LUT) -> Bool {
        for i in 1..<255 {
            let v1 = Int(lut.reds[i - 1]) + Int(lut.greens[i - 1]) + Int(lut.blues[i - 1])
            let v2 = Int(lut.reds[i]) + Int(lut.greens[i]) + Int(lut.blues[i])
            if v1 < v2 { return false }
        }
        return true
    }

    // MARK: Display mapping

    /// `ByteProcessor.setMinAndMax`'s LUT remap: the LUT entry each 8-bit
    /// value shows. A range with `max < min` leaves the LUT unchanged.
    static func byteRemap(_ range: ClosedRange<Double>) -> [UInt8] {
        let min = range.lowerBound, max = range.upperBound
        let minInt = roundToInt(min)
        return (0..<256).map { i in
            if Double(i) < min { return 0 }
            if Double(i) > max { return 255 }
            let index = int(256.0 * Double(i - minInt) / (max - min))
            return UInt8(Swift.max(0, Swift.min(index, 255)))
        }
    }

    /// LUT indices for a grayscale plane shown with `range`: the remap of
    /// `ByteProcessor.setMinAndMax` for 8-bit, `create8BitImage` of
    /// `ShortProcessor` and `FloatProcessor` otherwise (which is also
    /// `TypeConverter`'s scaled conversion to 8-bit).
    static func lutIndices(_ plane: Plane, _ range: ClosedRange<Double>) -> [UInt8] {
        switch plane {
        case .gray8(let p):
            let table = byteRemap(range)
            return p.map { table[Int($0)] }
        case .gray16(let p):
            let (min2, max2) = shortMinMax(range, p)
            let scale = 256.0 / Double(max2 - min2 + 1)
            return p.map { v in
                var value = Int(v) - min2
                if value < 0 { value = 0 }
                value = int(Double(value) * scale + 0.5)
                if value > 255 { value = 255 }
                return UInt8(truncatingIfNeeded: value)
            }
        case .gray32Float(let p):
            let (min2, max2) = floatMinMax(range, p)
            let scale = 255.0 / (max2 - min2)
            return p.map { v in
                var value = Double(v) - min2
                if value < 0 { value = 0 }
                var index = int(value * scale + 0.5)
                if index > 255 { index = 255 }
                return UInt8(truncatingIfNeeded: index)
            }
        case .rgb8:
            preconditionFailure("RGB planes have no LUT indices")
        }
    }

    /// A grayscale plane drawn through `lut` with `range`, as
    /// `ImageProcessor.createImage` draws it; RGB planes pass through.
    static func render(_ plane: Plane, lut: LUT, range: ClosedRange<Double>) -> [UInt32] {
        if case .rgb8(let p) = plane { return p.map { $0 | 0xFF00_0000 } }
        var palette = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { palette[i] = lut.argb(i) }
        return lutIndices(plane, range).map { palette[Int($0)] }
    }

    // MARK: Assembly

    static func stack(_ planes: [Plane], width: Int, height: Int, labels: [String?]?) -> ImageStack {
        do {
            return try ImageStack(width: width, height: height, planes: planes, labels: labels)
        } catch {
            preconditionFailure("MancoraProcess built an invalid stack: \(error)")
        }
    }

    /// A new image with `image`'s title, Info, properties, selection and
    /// overlay, and the given pixels and display settings.
    static func image(
        like image: Hyperstack,
        planes: [Plane],
        labels: [String?]?,
        dimensions: HyperstackDimensions,
        channels: [ChannelDisplay],
        calibration: Calibration,
        compositeMode: CompositeMode? = nil,
        title: String? = nil
    ) -> Hyperstack {
        let stack = stack(planes, width: image.width, height: image.height, labels: labels)
        do {
            var out = try Hyperstack(
                title: title ?? image.title,
                stack: stack,
                dimensions: dimensions,
                calibration: calibration,
                channels: channels,
                compositeMode: compositeMode ?? image.compositeMode,
                info: image.info,
                properties: image.properties
            )
            out.encodedROI = image.encodedROI
            out.encodedOverlay = image.encodedOverlay
            return out
        } catch {
            preconditionFailure("MancoraProcess built an invalid image: \(error)")
        }
    }

    /// Whether ImageJ treats `image` as a `CompositeImage`: more than one
    /// channel of grayscale data.
    static func isComposite(_ image: Hyperstack) -> Bool {
        image.dimensions.channels > 1 && image.pixelType != .rgb8
    }

    /// `ImagePlus.isHyperStack`: more than one dimension besides x and y.
    static func isHyperStack(_ dims: HyperstackDimensions) -> Bool {
        [dims.channels, dims.slices, dims.frames].filter { $0 > 1 }.count >= 2
    }
}
