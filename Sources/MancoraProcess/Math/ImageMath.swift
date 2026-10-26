public import MancoraCore

/// Process ▸ Math and Edit ▸ Invert: a port of ImageJ's
/// `ij.plugin.filter.ImageMath` and the `ImageProcessor` arithmetic it calls
/// (`ByteProcessor`/`ColorProcessor` through a 256-entry table,
/// `ShortProcessor.process`, `FloatProcessor.process`).
///
/// Results follow ImageJ's per-type rules: 8-bit and RGB values (each color
/// component) are computed in integers and clamped to 0–255, 16-bit values
/// are clamped to 0–65535 (signed 16-bit data is computed on the signed
/// values), and 32-bit values use `float` arithmetic.
public enum ImageMath {
    /// One command of the Process ▸ Math menu, or Edit ▸ Invert.
    public enum Operation: Sendable, Hashable {
        /// "Add…". Integer types add the value truncated toward zero.
        case add(Double)
        /// "Subtract…", which ImageJ performs as adding `-value`.
        case subtract(Double)
        /// "Multiply…". Integer types round the product (`Math.round`).
        case multiply(Double)
        /// "Divide…": multiplies by `1/value`. Dividing 8-, 16-bit or RGB data
        /// by zero changes nothing; 32-bit data becomes ±infinity or NaN.
        case divide(Double)
        /// "AND…", "OR…", "XOR…" with an integer (ImageJ asks for it in
        /// binary). 32-bit data is left unchanged.
        case and(Int)
        case or(Int)
        case xor(Int)
        /// "Min…": values below `value` become `value`.
        case min(Double)
        /// "Max…": values above `value` become `value`.
        case max(Double)
        /// "Gamma…", for 0.05 ≤ value ≤ 5 (other values change nothing, as
        /// ImageJ refuses them). 16-bit data is scaled within the display range.
        case gamma(Double)
        /// "Set…". On RGB data the value is a packed color (`0xRRGGBB`), as in ImageJ.
        case set(Double)
        /// "Log": 8-bit data scales `ln(v)` by `255/ln(255)`, 16-bit by
        /// `max/ln(max)` of the display range.
        case log
        /// "Exp", the inverse scaling of "Log" for integer types.
        case exp
        /// "Square".
        case square
        /// "Square Root".
        case squareRoot
        /// "Reciprocal" (`1/v`, NaN for 0); 32-bit data only.
        case reciprocal
        /// "Abs"; 32-bit and signed 16-bit data only.
        case abs
        /// "NaN Background": 32-bit values outside `lower...upper` (ImageJ's
        /// threshold) become NaN.
        case nanBackground(lower: Double, upper: Double)
        /// Edit ▸ Invert (`ImageProcessor.invert`): 8-bit and RGB become
        /// `255 - v`; 16-bit `max + min - v` over the pixel range (or
        /// `65535 - v` with full-range inversion); 32-bit `max + min - v`
        /// over the display range.
        case invert
    }

    /// Applies `operation` to one plane.
    ///
    /// - Parameters:
    ///   - displayRange: The processor's min and max, which ImageJ takes from
    ///     the display range: 16-bit gamma, log and exp scale within it, and
    ///     32-bit inversion reflects within it.
    ///   - signed16: The plane holds signed 16-bit data (stored `+32768`).
    ///   - fullRange16BitInversions: ImageJ's "Full range 16-bit inversions"
    ///     conversion option.
    public static func apply(
        _ operation: Operation,
        to plane: Plane,
        displayRange: ClosedRange<Double>,
        signed16: Bool = false,
        fullRange16BitInversions: Bool = false
    ) -> Plane {
        switch plane {
        case .gray8(let p):
            guard let table = byteTable(operation) else { return plane }
            return .gray8(p.map { table[Int($0)] })
        case .rgb8(let p):
            if case .set(let value) = operation {
                // ColorProcessor.set: fill with (int)value as a packed color.
                let color = UInt32(bitPattern: JavaNumerics.int32(value)) | 0xFF00_0000
                return .rgb8(Array(repeating: color, count: p.count))
            }
            guard let table = byteTable(operation) else { return plane }
            return .rgb8(
                p.map { c in
                    0xFF00_0000 | UInt32(table[Int((c >> 16) & 0xFF)]) << 16
                        | UInt32(table[Int((c >> 8) & 0xFF)]) << 8 | UInt32(table[Int(c & 0xFF)])
                })
        case .gray16(let p):
            return .gray16(
                short(operation, p, displayRange: displayRange, signed: signed16, fullRange: fullRange16BitInversions))
        case .gray32Float(let p):
            return .gray32Float(float(operation, p, displayRange: displayRange))
        }
    }

    /// Applies `operation` to every plane of `image`, each with its
    /// channel's display range, and updates the display ranges as ImageJ
    /// does: Min, Max, Abs and NaN Background reset the display range of a
    /// single 16- or 32-bit image to its new pixel range, and inverting a
    /// 16-bit stack resets it to the first plane's range.
    ///
    /// ImageJ runs a stack through one processor whose min and max are the
    /// current channel's display range; Mancora uses each channel's own
    /// range, which is the same for single-channel images.
    public static func apply(
        _ operation: Operation,
        to image: Hyperstack,
        fullRange16BitInversions: Bool = false
    ) -> Hyperstack {
        let type = image.pixelType
        let signed = type == .gray16 && ImageJRules.isSigned16(image.calibration)
        let c = image.dimensions.channels
        let planes = image.stack.planes.enumerated().map { k, plane in
            apply(
                operation, to: plane, displayRange: image.channels[k % c].displayRange, signed16: signed,
                fullRange16BitInversions: fullRange16BitInversions)
        }
        var channels = image.channels
        if planes.count == 1 {
            let reset: Bool
            switch operation {
            case .min, .max: reset = type == .gray16 || type == .gray32Float
            case .abs: reset = type == .gray32Float || signed
            case .nanBackground: reset = type == .gray32Float
            case .invert: reset = type == .gray16 && fullRange16BitInversions
            default: reset = false
            }
            if reset { channels[0].displayRange = ImageJRules.resetRange(planes[0]) }
        } else if operation == .invert, type == .gray16 {
            channels[0].displayRange = ImageJRules.resetRange(planes[0])
        }
        return ImageJRules.image(
            like: image, planes: planes, labels: image.stack.labels, dimensions: image.dimensions,
            channels: channels, calibration: image.calibration)
    }

    // MARK: 8-bit and RGB (ImageProcessor.process)

    /// The 256-entry table `ImageProcessor.process` applies, or `nil` when
    /// ImageJ leaves the data unchanged.
    static func byteTable(_ operation: Operation) -> [UInt8]? {
        // Java int arithmetic, which wraps.
        let scale = 255.0 / LibM.naturalLog(255.0)
        let int = { (x: Double) in JavaNumerics.int32(x) }
        let f: (Int32) -> Int32
        switch operation {
        case .invert: f = { 255 - $0 }
        case .set(let v): f = { _ in int(v) }
        case .add(let v): f = { $0 &+ int(v) }
        case .subtract(let v): f = { $0 &+ int(-v) }
        case .multiply(let v): f = { Int32(truncatingIfNeeded: ImageJRules.round(Double($0) * v)) }
        case .divide(let v):
            if v == 0 { return nil }
            let m = 1.0 / v
            f = { Int32(truncatingIfNeeded: ImageJRules.round(Double($0) * m)) }
        case .and(let v): f = { $0 & Int32(truncatingIfNeeded: v) }
        case .or(let v): f = { $0 | Int32(truncatingIfNeeded: v) }
        case .xor(let v): f = { $0 ^ Int32(truncatingIfNeeded: v) }
        case .gamma(let v):
            guard (0.05...5.0).contains(v) else { return nil }
            f = { int(LibM.exponential(LibM.naturalLog(Double($0) / 255.0) * v) * 255.0) }
        case .log: f = { $0 == 0 ? 0 : int(LibM.naturalLog(Double($0)) * scale) }
        case .exp: f = { int(LibM.exponential(Double($0) / scale)) }
        case .square: f = { $0 * $0 }
        case .squareRoot: f = { int(Double($0).squareRoot()) }
        case .min(let v): f = { Double($0) < v ? int(v) : $0 }
        case .max(let v): f = { Double($0) > v ? int(v) : $0 }
        case .reciprocal, .abs, .nanBackground: return nil
        }
        return (0..<256).map { UInt8(Swift.max(0, Swift.min(f(Int32($0)), 255))) }
    }

    // MARK: 16-bit (ShortProcessor.process)

    static func short(
        _ operation: Operation,
        _ pixels: [UInt16],
        displayRange: ClosedRange<Double>,
        signed: Bool,
        fullRange: Bool
    ) -> [UInt16] {
        var minMax = ImageJRules.shortMinMax(displayRange, pixels)
        if case .invert = operation {
            // ShortProcessor.invert: the pixel range, or 0–65535.
            minMax = fullRange ? (0, 65535) : ImageJRules.pixelRange(pixels)
        }
        let range = Double(minMax.max) - Double(minMax.min)
        let offset: Int32 = signed ? 32768 : 0
        let min2 = Int32(truncatingIfNeeded: minMax.min) &- offset
        let max2 = Int32(truncatingIfNeeded: minMax.max) &- offset

        let f: (Int32) -> Int32
        switch operation {
        case .invert: f = { max2 &- ($0 &- min2) }
        case .set(let v):
            let i = JavaNumerics.int32(v)
            f = { _ in i }
        case .add(let v):
            let i = JavaNumerics.int32(v)
            f = { $0 &+ i }
        case .subtract(let v):
            let i = JavaNumerics.int32(-v)
            f = { $0 &+ i }
        case .multiply(let v): f = { Int32(truncatingIfNeeded: ImageJRules.round(Double($0) * v)) }
        case .divide(let v):
            if v == 0 { return pixels }
            let m = 1.0 / v
            f = { Int32(truncatingIfNeeded: ImageJRules.round(Double($0) * m)) }
        case .and(let v):
            let i = Int32(truncatingIfNeeded: v)
            f = { $0 & i }
        case .or(let v):
            let i = Int32(truncatingIfNeeded: v)
            f = { $0 | i }
        case .xor(let v):
            let i = Int32(truncatingIfNeeded: v)
            f = { $0 ^ i }
        case .gamma(let v):
            guard (0.05...5.0).contains(v) else { return pixels }
            f = { v1 in
                if range <= 0 || v1 == min2 { return v1 }
                let x = LibM.exponential(v * LibM.naturalLog(Double(v1 &- min2) / range)) * range + Double(min2)
                return JavaNumerics.int32(x)
            }
        case .log:
            let factor = Double(max2) / LibM.naturalLog(Double(max2))
            f = { $0 <= 0 ? 0 : JavaNumerics.int32(LibM.naturalLog(Double($0)) * factor) }
        case .exp:
            let factor = LibM.naturalLog(Double(max2)) / Double(max2)
            f = { JavaNumerics.int32(LibM.exponential(Double($0) * factor)) }
        case .square: f = { JavaNumerics.int32(Double($0) * Double($0)) }
        case .squareRoot: f = { JavaNumerics.int32(Double($0).squareRoot()) }
        case .abs:
            guard signed else { return pixels }
            f = { $0 < 0 ? 0 &- $0 : $0 }
        case .min(let v):
            let i = JavaNumerics.int32(v)
            f = { Double($0) < v ? i : $0 }
        case .max(let v):
            let i = JavaNumerics.int32(v)
            f = { Double($0) > v ? i : $0 }
        case .reciprocal, .nanBackground:
            return pixels
        }
        return pixels.map { raw in
            let v2 = f(Int32(raw) &- offset) &+ offset
            return UInt16(Swift.max(0, Swift.min(v2, 65535)))
        }
    }

    // MARK: 32-bit (FloatProcessor.process, ImageMath)

    static func float(_ operation: Operation, _ pixels: [Float], displayRange: ClosedRange<Double>) -> [Float] {
        switch operation {
        case .invert:
            let (lo, hi) = ImageJRules.floatMinMax(displayRange, pixels)
            let min2 = Float(lo), max2 = Float(hi)
            return pixels.map { max2 - ($0 - min2) }
        case .set(let v):
            return Array(repeating: Float(v), count: pixels.count)
        case .add(let v):
            let c = Float(v)
            return pixels.map { $0 + c }
        case .subtract(let v):
            let c = Float(-v)
            return pixels.map { $0 + c }
        case .multiply(let v):
            let c = Float(v)
            return pixels.map { $0 * c }
        case .divide(let v):
            let c = Float(1.0 / v)
            return pixels.map { $0 * c }
        case .and, .or, .xor:
            return pixels
        case .gamma(let v):
            guard (0.05...5.0).contains(v) else { return pixels }
            let c = Double(Float(v))
            return pixels.map { $0 <= 0 ? 0 : Float(LibM.exponential(c * LibM.naturalLog(Double($0)))) }
        case .log:
            return pixels.map { Float(LibM.naturalLog(Double($0))) }
        case .exp:
            return pixels.map { Float(LibM.exponential(Double($0))) }
        case .square:
            return pixels.map { $0 * $0 }
        case .squareRoot:
            return pixels.map { $0 <= 0 ? 0 : Float(Double($0).squareRoot()) }
        case .abs:
            return pixels.map { $0.magnitude }
        case .min(let v):
            let c = Float(v)
            return pixels.map { Double($0) < v ? c : $0 }
        case .max(let v):
            let c = Float(v)
            return pixels.map { Double($0) > v ? c : $0 }
        case .reciprocal:
            return pixels.map { $0 == 0 ? .nan : 1 / $0 }
        case .nanBackground(let lower, let upper):
            return pixels.map { Double($0) < lower || Double($0) > upper ? .nan : $0 }
        }
    }
}
