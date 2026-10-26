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

    /// Java's `Double.toString`, which ImageJ uses when it writes numbers
    /// into a TIFF's ImageDescription: `4095.0`, `0.001`, `1.0E-4`, `1.0E7`.
    ///
    /// Both languages print the shortest digits that round-trip. Since
    /// JDK 19 Java prefers the closest two-digit decimal over a one-digit
    /// one, which only differs for a few subnormals (`4.9E-324` here is
    /// `5.0E-324`); both parse back to the same double.
    package static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        let magnitude = value.magnitude
        // Swift prints "123.45", "0.001" or "1.2345e-05"; split out the digits
        // and where the decimal point falls relative to them.
        var text = Substring(magnitude.description)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        let point = text.firstIndex(of: ".") ?? text.endIndex
        var digits = Array(text[..<point]) + Array(text[point...].dropFirst())
        var pointPosition = text.distance(from: text.startIndex, to: point) + exponent
        while digits.first == "0" {
            digits.removeFirst()
            pointPosition -= 1
        }
        while digits.last == "0" { digits.removeLast() }

        var out = value < 0 ? "-" : ""
        if magnitude >= 1e-3, magnitude < 1e7 {
            if pointPosition <= 0 {
                out += "0." + String(repeating: "0", count: -pointPosition) + String(digits)
            } else if pointPosition >= digits.count {
                out += String(digits) + String(repeating: "0", count: pointPosition - digits.count) + ".0"
            } else {
                out += String(digits[..<pointPosition]) + "." + String(digits[pointPosition...])
            }
        } else {
            out += String(digits[0]) + "." + (digits.count > 1 ? String(digits[1...]) : "0")
            out += "E" + String(pointPosition - 1)
        }
        return out
    }
}
