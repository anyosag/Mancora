/// Java's numeric conversion rules, used where Mancora must reproduce
/// ImageJ bit for bit.
///
/// Java's `(int)` cast of a floating-point value maps NaN to 0 and saturates
/// out-of-range values, where Swift's `Int32(_:)` traps. `(byte)` then keeps
/// the low 8 bits.
package enum JavaNumerics {
    package static func int32(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return .max }
        if value <= Double(Int32.min) { return .min }
        return Int32(value.rounded(.towardZero))
    }

    package static func int32(_ value: Float) -> Int32 {
        int32(Double(value))
    }

    /// Java's `Math.round(double)`: the nearest `long`, with ties rounding
    /// up (`-2.5` gives `-2`). NaN gives 0; out-of-range values saturate.
    ///
    /// Like Java 7 and later, this is the exact `floor(value + 0.5)`, so
    /// `0.49999999999999994` rounds to 0 rather than 1.
    package static func round(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        let floor = value.rounded(.down)
        // value - floor is exact except for values in (-0.5, 0), where it
        // lies in (0.5, 1) and rounding can't take it below 0.5.
        let rounded = value - floor >= 0.5 ? floor + 1 : floor
        if rounded >= 0x1p63 { return .max }
        if rounded < -0x1p63 { return .min }
        return Int64(rounded)
    }

    /// Java's `(int)Math.round(double)`: the `long` result narrowed to its
    /// low 32 bits.
    package static func roundToInt32(_ value: Double) -> Int32 {
        Int32(truncatingIfNeeded: round(value))
    }

    /// Java `(byte)` of a `double`, reinterpreted as unsigned.
    package static func byte(_ value: Double) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(value))
    }

    /// Java `(byte)` of a `float`, reinterpreted as unsigned.
    package static func byte(_ value: Float) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(value))
    }
}
