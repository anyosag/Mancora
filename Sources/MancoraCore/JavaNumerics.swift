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

    /// Java `(byte)` of a `double`, reinterpreted as unsigned.
    package static func byte(_ value: Double) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(value))
    }

    /// Java `(byte)` of a `float`, reinterpreted as unsigned.
    package static func byte(_ value: Float) -> UInt8 {
        UInt8(truncatingIfNeeded: int32(value))
    }
}
