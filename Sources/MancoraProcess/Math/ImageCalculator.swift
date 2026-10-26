public import MancoraCore

/// Process ▸ Image Calculator: a port of ImageJ's `ij.plugin.ImageCalculator`
/// and the blitters it drives (`ByteBlitter`, `ShortBlitter`, `FloatBlitter`,
/// `ColorBlitter`).
public enum ImageCalculator {
    /// The calculator's operations, in ImageJ's menu order.
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        /// `image1 + image2`, clamped for integer types.
        case add
        /// `image1 - image2`, clamped at 0 for integer types.
        case subtract
        /// `image1 * image2`, clamped (16-bit products overflow Java's `int`
        /// first, as in ImageJ).
        case multiply
        /// `image1 / image2`: integer division, with 255 or 65535 where the
        /// divisor is 0; 32-bit division gives ±infinity or NaN, or the
        /// chosen divide-by-zero value.
        case divide
        case and
        case or
        case xor
        case min
        case max
        /// `(image1 + image2) / 2` (integer division for integer types).
        case average
        /// `|image1 - image2|`.
        case difference
        /// `image2`.
        case copy
        /// `image2`, except where it is 0 ("Transparent-zero").
        case transparentZero
    }

    public enum CalculatorError: Error, Equatable, Sendable {
        /// The images differ in width or height (ImageJ uses the overlap;
        /// Mancora requires equal sizes).
        case sizeMismatch
        /// Both images are stacks, with different numbers of planes.
        case stackSizeMismatch(Int, Int)
    }

    /// Combines two planes of the same type and size as ImageJ's blitters do
    /// (`ip1.copyBits(ip2, 0, 0, mode)` without type conversion).
    public static func combine(
        _ plane1: Plane,
        _ operation: Operation,
        _ plane2: Plane,
        divideByZeroValue: Float = .infinity
    ) -> Plane {
        precondition(plane1.pixelType == plane2.pixelType && plane1.count == plane2.count, "planes must match")
        return Blitter.blit(plane1, plane2, operation, divideByZeroValue: divideByZeroValue)
    }

    /// `image1 operation image2` as a new image ("Create new window").
    ///
    /// `image2` is converted to `image1`'s type first, as `copyBits` does:
    /// to 8-bit through its display range, to 16-bit by clamping, to 32-bit
    /// through its calibration, to RGB through its LUT. Multiplying or
    /// dividing an 8- or 16-bit image by a 32-bit one is computed in
    /// `float` and rounded back. A stack is processed plane by plane, with a
    /// single `image2` applied to every plane.
    ///
    /// - Parameters:
    ///   - float32Result: "32-bit (float) result"; implied when either image
    ///     is signed 16-bit.
    ///   - divideByZeroValue: ImageJ's "Divide by zero value" (Edit ▸
    ///     Options ▸ Misc) for 32-bit division; infinity means IEEE division.
    public static func calculate(
        _ image1: Hyperstack,
        _ operation: Operation,
        _ image2: Hyperstack,
        float32Result: Bool = false,
        divideByZeroValue: Float = .infinity
    ) throws(CalculatorError) -> Hyperstack {
        guard image1.width == image2.width, image1.height == image2.height else { throw .sizeMismatch }
        let n1 = image1.stack.count, n2 = image2.stack.count
        if n1 > 1, n2 > 1, n1 != n2 { throw .stackSizeMismatch(n1, n2) }
        let float = float32Result || ImageJRules.isSigned16(image1.calibration)
            || ImageJRules.isSigned16(image2.calibration)
        let source = Source(image2)
        let title = "Result of " + image1.title
        let lut1 = image1.channels[0].lut

        if n1 == 1 {
            // doOperation
            let t1 = image1.pixelType
            let function1 = image1.calibration.valueFunction
            var dst = float && t1 != .rgb8 ? TypeConverter.toGray32(image1.stack[0], calibration: function1) : image1.stack[0]
            var src = source.plane(0)
            var srcDisplay = source.display
            if float, src.pixelType != .rgb8 {
                src = TypeConverter.toGray32(src, calibration: source.function)
                srcDisplay.displayRange = ImageJRules.resetRange(src)
            }
            let srcFunction = float ? nil : source.function
            var display = ChannelDisplay(lut: lut1, displayRange: image1.channels[0].displayRange)
            let blitted = blit(dst, src, srcDisplay, srcFunction, operation, divideByZeroValue)
            dst = blitted.plane
            if let range = blitted.byteRange { display.displayRange = range }
            if float, source.type == .rgb8 {
                if dst.pixelType == .rgb8 { display.lut = .grays }
                dst = TypeConverter.toGray32(dst)
            }
            if case .rgb8 = dst { display = ChannelDisplay(lut: .grays, displayRange: 0...255) }
            if dst.pixelType != .gray8 { display.displayRange = ImageJRules.resetRange(dst) }
            return ImageJRules.image(
                like: image1, planes: [dst], labels: image1.stack.labels, dimensions: HyperstackDimensions(),
                channels: [display], calibration: ImageJRules.calibration(image1.calibration, from: t1, to: dst.pixelType),
                title: title)
        }

        // doStackOperation on a duplicate of image1.
        let t1 = image1.pixelType
        let function1 = image1.calibration.valueFunction
        var planes = image1.stack.planes
        if float { planes = planes.map { TypeConverter.toGray32($0, calibration: function1) } }
        let type = planes[0].pixelType
        planes = planes.enumerated().map { i, dst in
            blit(dst, source.plane(n2 == 1 ? 0 : i), source.display, source.function, operation, divideByZeroValue).plane
        }
        var channels = image1.channels
        if t1 == .rgb8, type == .gray32Float {
            channels = channels.map { _ in ChannelDisplay(lut: .grays, displayRange: 0...255) }
        }
        // The duplicate keeps image 1's display range (ImageStack.addSlice of
        // cropped processors); other types then reset it to the first plane.
        if !ImageJRules.isComposite(image1), type != .gray8 {
            channels[0].displayRange = ImageJRules.resetRange(planes[0])
        }
        return ImageJRules.image(
            like: image1, planes: planes, labels: image1.stack.labels, dimensions: image1.dimensions,
            channels: channels, calibration: ImageJRules.calibration(image1.calibration, from: t1, to: type),
            title: title)
    }

    /// Image 2 as ImageJ's `img2.getProcessor()` / `img2.getStack()` presents it:
    /// the first channel's LUT and display range and the calibration table.
    struct Source {
        let image: Hyperstack
        let display: ChannelDisplay
        let function: Calibration.ValueFunction?
        var type: PixelType { image.pixelType }

        init(_ image: Hyperstack) {
            self.image = image
            display = image.channels[0]
            function = image.calibration.valueFunction
        }

        func plane(_ i: Int) -> Plane { image.stack[i] }
    }

    /// `ip1.copyBits(ip2, 0, 0, mode)`: converts `src` to `dst`'s type and
    /// blits. `byteRange` is the display range an 8-bit result takes when it
    /// was computed in `float` (`ByteProcessor.setPixels(channel, fp)`).
    static func blit(
        _ dst: Plane,
        _ src: Plane,
        _ srcDisplay: ChannelDisplay,
        _ srcFunction: Calibration.ValueFunction?,
        _ operation: Operation,
        _ divideByZeroValue: Float
    ) -> (plane: Plane, byteRange: ClosedRange<Double>?) {
        let temporaryFloat = src.pixelType == .gray32Float && (operation == .multiply || operation == .divide)
        switch dst {
        case .gray8, .gray16:
            if temporaryFloat {
                let result = Blitter.blit(TypeConverter.toGray32(dst), src, operation, divideByZeroValue: divideByZeroValue)
                guard case .gray32Float(let f) = result else { preconditionFailure() }
                if case .gray8 = dst {
                    let r = ImageJRules.pixelRange(f)
                    let range = ImageJRules.closed(
                        Double(ImageJRules.roundToInt(r.min)), Double(ImageJRules.roundToInt(r.max)))
                    return (.gray8(f.map(TypeConverter.floatToByte)), range)
                }
                return (.gray16(f.map(TypeConverter.floatToShort)), nil)
            }
            let converted = dst.pixelType == .gray8
                ? TypeConverter.toGray8(src, displayRange: srcDisplay.displayRange, scale: true)
                : TypeConverter.toGray16(src, displayRange: srcDisplay.displayRange, scale: false)
            return (Blitter.blit(dst, converted, operation, divideByZeroValue: divideByZeroValue), nil)
        case .gray32Float:
            let converted = TypeConverter.toGray32(src, calibration: srcFunction)
            return (Blitter.blit(dst, converted, operation, divideByZeroValue: divideByZeroValue), nil)
        case .rgb8:
            let converted = TypeConverter.toRGB(src, lut: srcDisplay.lut, displayRange: srcDisplay.displayRange)
            return (Blitter.blit(dst, converted, operation, divideByZeroValue: divideByZeroValue), nil)
        }
    }
}

/// The per-type pixel loops of `ByteBlitter`, `ShortBlitter`, `FloatBlitter`
/// and `ColorBlitter.copyBits` for two planes of the same type.
enum Blitter {
    static func blit(
        _ dst: Plane,
        _ src: Plane,
        _ operation: ImageCalculator.Operation,
        divideByZeroValue: Float
    ) -> Plane {
        switch (dst, src) {
        case (.gray8(let d), .gray8(let s)):
            return .gray8(zip(d, s).map { UInt8(byte(Int($0), Int($1), operation)) })
        case (.gray16(let d), .gray16(let s)):
            return .gray16(zip(d, s).map { UInt16(truncatingIfNeeded: short(Int32($0), Int32($1), operation)) })
        case (.gray32Float(let d), .gray32Float(let s)):
            let useValue = !divideByZeroValue.isInfinite
            return .gray32Float(zip(d, s).map { float($0, $1, operation, useValue ? divideByZeroValue : nil) })
        case (.rgb8(let d), .rgb8(let s)):
            return .rgb8(zip(d, s).map { color($0, $1, operation) })
        default:
            preconditionFailure("blit needs planes of one type")
        }
    }

    /// `ByteBlitter`: `d` is the destination pixel, `s` the source pixel.
    @inline(__always)
    static func byte(_ d: Int, _ s: Int, _ op: ImageCalculator.Operation) -> Int {
        switch op {
        case .copy: return s
        case .transparentZero: return s == 0 ? d : s
        case .add: return Swift.min(s + d, 255)
        case .average: return (s + d) / 2
        case .subtract: return Swift.max(d - s, 0)
        case .difference: return Swift.abs(d - s)
        case .multiply: return Swift.min(s * d, 255)
        case .divide: return s == 0 ? 255 : d / s
        case .and: return s & d
        case .or: return s | d
        case .xor: return s ^ d
        case .min: return Swift.min(s, d)
        case .max: return Swift.max(s, d)
        }
    }

    /// `ShortBlitter`, in Java `int` arithmetic.
    @inline(__always)
    static func short(_ d: Int32, _ s: Int32, _ op: ImageCalculator.Operation) -> Int32 {
        func clamp(_ v: Int32) -> Int32 { Swift.max(0, Swift.min(v, 65535)) }
        switch op {
        case .copy: return s
        case .transparentZero: return s == 0 ? d : s
        case .add: return clamp(s &+ d)
        case .average: return (s + d) / 2
        case .difference:
            let v = d - s
            return Swift.min(v < 0 ? -v : v, 65535)
        case .subtract: return clamp(d - s)
        case .multiply: return clamp(s &* d)
        case .divide: return s == 0 ? 65535 : d / s
        case .and: return s & d & 0xFFFF
        case .or: return s | d
        case .xor: return s ^ d
        case .min: return Swift.min(s, d)
        case .max: return Swift.max(s, d)
        }
    }

    /// `FloatBlitter`.
    @inline(__always)
    static func float(_ d: Float, _ s: Float, _ op: ImageCalculator.Operation, _ divideByZero: Float?) -> Float {
        switch op {
        case .copy: return s
        case .transparentZero: return s == 0 ? d : s
        case .add: return s + d
        case .average: return (s + d) / 2
        case .difference:
            let v = d - s
            return v < 0 ? -v : v
        case .subtract: return d - s
        case .multiply: return s * d
        case .divide:
            if let divideByZero, s == 0 { return divideByZero }
            return d / s
        case .and: return Float(JavaNumerics.int32(s) & JavaNumerics.int32(d))
        case .or: return Float(JavaNumerics.int32(s) | JavaNumerics.int32(d))
        case .xor: return Float(JavaNumerics.int32(s) ^ JavaNumerics.int32(d))
        case .min: return s < d ? s : d
        case .max: return s > d ? s : d
        }
    }

    /// `ColorBlitter`, per color component.
    @inline(__always)
    static func color(_ d: UInt32, _ s: UInt32, _ op: ImageCalculator.Operation) -> UInt32 {
        switch op {
        case .copy: return s | 0xFF00_0000
        case .transparentZero: return (s & 0xFF_FFFF) == 0 ? d : s | 0xFF00_0000
        default: break
        }
        func component(_ shift: UInt32) -> UInt32 {
            let c1 = Int((s >> shift) & 0xFF), c2 = Int((d >> shift) & 0xFF)
            let v: Int
            switch op {
            case .add: v = Swift.min(c1 + c2, 255)
            case .average: v = (c1 + c2) / 2
            case .subtract: v = Swift.max(c2 - c1, 0)
            case .difference: v = Swift.abs(c2 - c1)
            case .multiply: v = Swift.min(c1 * c2, 255)
            case .divide: v = c1 == 0 ? 255 : c2 / c1
            case .and: v = c1 & c2
            case .or: v = c1 | c2
            case .xor: v = c1 ^ c2
            case .min: v = Swift.min(c1, c2)
            case .max: v = Swift.max(c1, c2)
            case .copy, .transparentZero: v = c1
            }
            return UInt32(v) << shift
        }
        return 0xFF00_0000 | component(16) | component(8) | component(0)
    }
}
