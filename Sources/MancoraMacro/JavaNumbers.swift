// Java's number <-> text conversions, as ImageJ's macro language sees them
// on Java 21:
//
// - `javaString(_:)` is `Double.toString` (the shortest-digits algorithm of
//   JDK 19 and later).
// - `ImageJFormat` is `IJ.d2s` and `ResultsTable.d2s`, which use
//   `java.text.DecimalFormat`. DecimalFormat still takes its digits from the
//   old `FloatingDecimal.dtoa`, so that algorithm is ported here verbatim
//   (`FloatingDecimalDigits`), with `DigitList`'s rounding rules on top.
// - `javaParseDouble(_:)` is `Double.parseDouble`.
// - Java's `(int)` and `(long)` casts, `Math.round`, `Integer.toHexString` etc.

// MARK: - Casts

/// Java's `(int)x`: truncates toward zero, saturates, and maps NaN to 0.
@inline(__always)
func jInt(_ x: Double) -> Int32 {
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    if x.isNaN { return 0 }
    return Int32(x)
}

/// Java's `(int)x` widened to Int, for indexes and counts.
@inline(__always)
func jIntI(_ x: Double) -> Int { Int(jInt(x)) }

/// Java's `(long)x`.
@inline(__always)
func jLong(_ x: Double) -> Int64 {
    if x >= 9223372036854775807.0 { return Int64.max }
    if x <= -9223372036854775808.0 { return Int64.min }
    if x.isNaN { return 0 }
    return Int64(x)
}

/// `(int)x == x`, the test ImageJ uses to decide whether a number prints as an integer.
@inline(__always)
func isJavaInt(_ x: Double) -> Bool { Double(jInt(x)) == x }

/// Java's `Math.round(double)` (round half up, exactly, as in Java 8 and later).
func javaMathRound(_ a: Double) -> Int64 {
    let longBits = Int64(bitPattern: a.bitPattern)
    let biasedExp = (longBits & 0x7ff0_0000_0000_0000) >> 52
    let shift = (52 - 1 + 1023) - biasedExp
    if (shift & -64) == 0 {
        var r = (longBits & 0x000f_ffff_ffff_ffff) | (0x000f_ffff_ffff_ffff + 1)
        if longBits < 0 { r = -r }
        return ((r >> shift) + 1) >> 1
    }
    return jLong(a)
}

// MARK: - Integer text

func javaIntegerToString(_ v: Int32) -> String { String(v) }

/// `Integer.toHexString`: the 32-bit two's complement, unsigned, lowercase.
func javaToHexString(_ v: Int32) -> String { String(UInt32(bitPattern: v), radix: 16) }

/// `Integer.toBinaryString`.
func javaToBinaryString(_ v: Int32) -> String { String(UInt32(bitPattern: v), radix: 2) }

/// `Integer.parseInt(s, radix)`; nil where Java throws NumberFormatException.
func javaParseInt(_ s: String, radix: Int) -> Int32? {
    let units = Array(s.utf16)
    if units.isEmpty { return nil }
    var i = 0
    var negative = false
    let first = units[0]
    if first < 0x30 {  // possible leading "+" or "-"
        if first == 0x2D { negative = true } else if first != 0x2B { return nil }
        if units.count == 1 { return nil }
        i = 1
    }
    let limit: Int64 = negative ? 2147483648 : 2147483647
    var result: Int64 = 0
    while i < units.count {
        guard let d = javaCharacterDigit(units[i], radix: radix) else { return nil }
        result = result * Int64(radix) + Int64(d)
        if result > limit { return nil }
        i += 1
    }
    return Int32(negative ? -result : result)
}

/// `Character.digit(char, radix)` for the BMP: ASCII letters and digits, plus
/// the Unicode decimal digits and fullwidth letters Java also accepts.
func javaCharacterDigit(_ c: UInt16, radix: Int) -> Int? {
    var value: Int
    switch c {
    case 0x30...0x39: value = Int(c) - 0x30
    case 0x41...0x5A: value = Int(c) - 0x41 + 10
    case 0x61...0x7A: value = Int(c) - 0x61 + 10
    case 0xFF21...0xFF3A: value = Int(c) - 0xFF21 + 10
    case 0xFF41...0xFF5A: value = Int(c) - 0xFF41 + 10
    default:
        guard let scalar = Unicode.Scalar(c), scalar.properties.numericType == .decimal,
              let n = scalar.properties.numericValue else { return nil }
        value = Int(n)
    }
    return value < radix ? value : nil
}

// MARK: - Double.parseDouble

/// Java's `Double.parseDouble`: surrounding whitespace (chars <= ' ') is
/// ignored, an optional f/F/d/D suffix is allowed, as are "NaN", "Infinity"
/// and hexadecimal floating-point literals. Returns nil where Java throws.
func javaParseDouble(_ s: String) -> Double? {
    var units = Array(s.utf8)
    // String.trim() removes chars <= ' '; non-ASCII never parses anyway.
    var start = 0, end = units.count
    while start < end && units[start] <= 0x20 { start += 1 }
    while end > start && units[end - 1] <= 0x20 { end -= 1 }
    if start == end { return nil }
    units = Array(units[start..<end])
    var i = 0
    var negative = false
    if units[0] == 0x2B || units[0] == 0x2D {
        negative = units[0] == 0x2D
        i = 1
    }
    let rest = units[i...]
    if rest.elementsEqual("NaN".utf8) { return Double.nan }
    if rest.elementsEqual("Infinity".utf8) { return negative ? -Double.infinity : Double.infinity }
    // Hexadecimal: 0x<hex>[.<hex>]p<exp>[fFdD]
    if rest.count > 2 && rest[i] == 0x30 && (rest[i + 1] == 0x78 || rest[i + 1] == 0x58) {
        var body = Array(units[(i + 2)...])
        if let last = body.last, [0x66, 0x46, 0x64, 0x44].contains(last) { body.removeLast() }
        // Must contain a binary exponent.
        guard let pIndex = body.firstIndex(where: { $0 == 0x70 || $0 == 0x50 }) else { return nil }
        let mantissa = body[..<pIndex], exponent = body[(pIndex + 1)...]
        let hexDigits = mantissa.filter { $0 != 0x2E }
        if hexDigits.isEmpty || mantissa.filter({ $0 == 0x2E }).count > 1 { return nil }
        if !hexDigits.allSatisfy({ isHexDigit($0) }) { return nil }
        var e = Array(exponent)
        if let f = e.first, f == 0x2B || f == 0x2D { e.removeFirst() }
        if e.isEmpty || !e.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return nil }
        let text = (negative ? "-" : "") + "0x" + String(decoding: body, as: UTF8.self)
        return Double(text)
    }
    // Decimal: digits [. digits] [e[+-]digits] [fFdD]
    var j = i
    var sawDigit = false
    while j < units.count && units[j] >= 0x30 && units[j] <= 0x39 { j += 1; sawDigit = true }
    if j < units.count && units[j] == 0x2E {
        j += 1
        while j < units.count && units[j] >= 0x30 && units[j] <= 0x39 { j += 1; sawDigit = true }
    }
    if !sawDigit { return nil }
    let mantissaEnd = j
    if j < units.count && (units[j] == 0x65 || units[j] == 0x45) {
        j += 1
        if j < units.count && (units[j] == 0x2B || units[j] == 0x2D) { j += 1 }
        var expDigits = false
        while j < units.count && units[j] >= 0x30 && units[j] <= 0x39 { j += 1; expDigits = true }
        if !expDigits { return nil }
    }
    let numberEnd = j
    if j < units.count && [0x66, 0x46, 0x64, 0x44].contains(units[j]) { j += 1 }
    if j != units.count { return nil }
    _ = mantissaEnd
    var text = String(decoding: units[0..<numberEnd], as: UTF8.self)
    if text.hasPrefix("+") { text.removeFirst() }
    // Swift's parser rejects a bare trailing or leading "." in some forms; normalise.
    if text.contains(".") {
        text = text.replacingDotForms()
    }
    return Double(text)
}

private func isHexDigit(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}

private extension String {
    /// Turns "1." into "1.0" and ".5" into "0.5" (with an optional sign), which
    /// Java accepts and Swift's `Double(_:)` may not.
    func replacingDotForms() -> String {
        var u = Array(self.utf8)
        var signLen = 0
        if let f = u.first, f == 0x2D { signLen = 1 }
        if u.count > signLen && u[signLen] == 0x2E { u.insert(0x30, at: signLen) }
        if let dot = u.firstIndex(of: 0x2E), dot + 1 == u.count || !(u[dot + 1] >= 0x30 && u[dot + 1] <= 0x39) {
            u.insert(0x30, at: dot + 1)
        }
        return String(decoding: u, as: UTF8.self)
    }
}

/// `Tools.parseDouble(s, defaultValue)`.
@inline(__always)
func toolsParseDouble(_ s: String?, _ defaultValue: Double = .nan) -> Double {
    guard let s else { return defaultValue }
    return javaParseDouble(s) ?? defaultValue
}

// MARK: - Double.toString (JDK 19+)

/// Decimal digits and exponent: value = 0.d1d2...dn * 10^exponent.
struct DecimalDigits {
    var digits: [UInt8]  // ASCII digits, first one non-zero
    var exponent: Int
}

/// Shortest decimal that rounds to `v` (v finite, > 0), with Java's rule of
/// preferring the closest two-digit decimal when one digit would do.
func shortestDigits(_ v: Double) -> DecimalDigits {
    // Swift's description is shortest round-trip, closest to v.
    var d = parseDescription(v.description)
    if d.digits.count == 1 {
        // Java 19+: when the shortest has one digit, the closest of the one- or
        // two-digit decimals that round to v wins (matters for subnormals).
        let e = d.exponent  // value = 0.d * 10^e
        let scaled = (v * 1e300) / pow10Double(e - 2 + 300)  // v / 10^(e-2), two digits before the point
        let k = scaled.rounded()
        if k >= 10 && k <= 99 {
            let candidate = "\(Int(k))e\(e - 2)"
            if let back = Double(candidate), back == v, Int(k) % 10 != 0 {
                d = DecimalDigits(digits: Array(String(Int(k)).utf8), exponent: e)
            }
        }
    }
    return d
}

private func pow10Double(_ e: Int) -> Double {
    var r = 1.0
    if e >= 0 { for _ in 0..<e { r *= 10 } } else { for _ in 0..<(-e) { r /= 10 } }
    return r
}

/// Parses Swift's `Double.description` ("1.5", "1e-05", "1.2345e+20") into digits.
private func parseDescription(_ s: String) -> DecimalDigits {
    var digits: [UInt8] = []
    var pointPos: Int? = nil
    var exp = 0
    var it = s.utf8.makeIterator()
    var countBeforeE = 0
    while let c = it.next() {
        if c == 0x2D { continue }
        if c == 0x2E { pointPos = countBeforeE; continue }
        if c == 0x65 || c == 0x45 {
            var rest: [UInt8] = []
            while let c2 = it.next() { rest.append(c2) }
            exp = Int(String(decoding: rest, as: UTF8.self).replacingOccurrencesOfPlus()) ?? 0
            break
        }
        digits.append(c)
        countBeforeE += 1
    }
    let intLen = pointPos ?? digits.count
    // Strip leading zeros.
    var lead = 0
    while lead < digits.count - 1 && digits[lead] == 0x30 { lead += 1 }
    var decExp = intLen - lead + exp
    digits.removeFirst(lead)
    while digits.count > 1 && digits.last == 0x30 { digits.removeLast() }
    if digits == [0x30] { decExp = 0 }
    return DecimalDigits(digits: digits, exponent: decExp)
}

private extension String {
    func replacingOccurrencesOfPlus() -> String {
        var s = self
        if s.hasPrefix("+") { s.removeFirst() }
        return s
    }
}

/// Java's `Double.toString(v)` (and `"" + v`).
func javaString(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
    if v == 0 { return v.sign == .minus ? "-0.0" : "0.0" }
    let d = shortestDigits(abs(v))
    var out = v < 0 ? "-" : ""
    let n = d.digits.count
    let e = d.exponent  // value = 0.d * 10^e
    if v.magnitude >= 1e-3 && v.magnitude < 1e7 {
        if e > 0 {
            // Integer part has e digits.
            if n <= e {
                out += String(decoding: d.digits, as: UTF8.self) + String(repeating: "0", count: e - n) + ".0"
            } else {
                out += String(decoding: d.digits[0..<e], as: UTF8.self) + "." + String(decoding: d.digits[e...], as: UTF8.self)
            }
        } else {
            out += "0." + String(repeating: "0", count: -e) + String(decoding: d.digits, as: UTF8.self)
        }
    } else {
        out += String(UnicodeScalar(d.digits[0])) + "."
        out += n > 1 ? String(decoding: d.digits[1...], as: UTF8.self) : "0"
        out += "E" + String(e - 1)
    }
    return out
}

// MARK: - FloatingDecimal.dtoa (the digits DecimalFormat works from)

/// The result of `FloatingDecimal.getBinaryToASCIIConverter(d)`: digits with
/// value 0.d1...dn * 10^decExponent, and whether the last digit was rounded
/// up and whether the digits are exact.
struct FloatingDecimalDigits {
    var digits: [UInt8]
    var decExponent: Int
    var roundedUp: Bool
    var exact: Bool

    private static let longPow5: [Int64] = {
        var a: [Int64] = [1]
        for _ in 1...26 { a.append(a.last! * 5) }
        return a
    }()
    private static let smallPow5: [Int32] = {
        var a: [Int32] = [1]
        for _ in 1...13 { a.append(a.last! * 5) }
        return a
    }()
    private static let n5Bits: [Int] = [0, 3, 5, 7, 10, 12, 14, 17, 19, 21, 24, 26, 28, 31, 33, 35, 38, 40, 42, 45,
                                        47, 49, 52, 54, 56, 59, 61]
    private static let insignificantDigitsNumber: [Int] = [
        0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7,
        8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 14, 14, 14,
        15, 15, 15, 15, 16, 16, 16, 17, 17, 17, 18, 18, 18, 19,
    ]

    /// `d` must be finite and > 0.
    init(_ d: Double) {
        let dBits = Int64(bitPattern: d.bitPattern)
        var fractBits = dBits & 0x000f_ffff_ffff_ffff
        var binExp = Int((dBits & 0x7ff0_0000_0000_0000) >> 52)
        let nSignificantBits: Int
        if binExp == 0 {
            let leadingZeros = fractBits.leadingZeroBitCount
            let shift = leadingZeros - (63 - 52)
            fractBits <<= Int64(shift)
            binExp = 1 - shift
            nSignificantBits = 64 - leadingZeros
        } else {
            fractBits |= 1 << 52
            nSignificantBits = 53
        }
        binExp -= 1023
        digits = []
        decExponent = 0
        roundedUp = false
        exact = false
        dtoa(binExp: binExp, fractBits: fractBits, nSignificantBits: nSignificantBits)
    }

    private mutating func developLongDigits(_ decExponentIn: Int, _ lvalueIn: Int64, _ insignificantDigits: Int) {
        var decExponent = decExponentIn
        var lvalue = lvalueIn
        if insignificantDigits != 0 {
            let pow10 = Self.longPow5[insignificantDigits] << Int64(insignificantDigits)
            let residue = lvalue % pow10
            lvalue /= pow10
            decExponent += insignificantDigits
            if residue >= (pow10 >> 1) { lvalue += 1 }
        }
        var out: [UInt8] = []
        var c = Int(lvalue % 10)
        lvalue /= 10
        while c == 0 {
            decExponent += 1
            c = Int(lvalue % 10)
            lvalue /= 10
        }
        while lvalue != 0 {
            out.append(UInt8(c + 0x30))
            decExponent += 1
            c = Int(lvalue % 10)
            lvalue /= 10
        }
        out.append(UInt8(c + 0x30))
        digits = out.reversed()
        self.decExponent = decExponent + 1
    }

    private static func estimateDecExp(_ fractBits: Int64, _ binExp: Int) -> Int {
        let d2 = Double(bitPattern: UInt64(bitPattern: 0x3ff0_0000_0000_0000 | (fractBits & 0x000f_ffff_ffff_ffff)))
        let d = (d2 - 1.5) * 0.289529654 + 0.176091259 + Double(binExp) * 0.301029995663981
        let dBits = Int64(bitPattern: d.bitPattern)
        let exponent = Int((dBits & 0x7ff0_0000_0000_0000) >> 52) - 1023
        let isNegative = dBits < 0
        if exponent >= 0 && exponent < 52 {
            let mask = Int64(0x000f_ffff_ffff_ffff) >> Int64(exponent)
            let r = Int(Int32(truncatingIfNeeded: ((dBits & 0x000f_ffff_ffff_ffff) | (1 << 52)) >> Int64(52 - exponent)))
            return isNegative ? (((mask & dBits) == 0) ? -r : -r - 1) : r
        } else if exponent < 0 {
            return ((dBits & ~Int64.min) == 0) ? 0 : (isNegative ? -1 : 0)
        } else {
            return Int(Int32(truncatingIfNeeded: Int64(d)))
        }
    }

    private static func insignificantDigitsForPow2(_ p2: Int) -> Int {
        if p2 > 1 && p2 < insignificantDigitsNumber.count { return insignificantDigitsNumber[p2] }
        return 0
    }

    private mutating func dtoa(binExp: Int, fractBits fractBitsIn: Int64, nSignificantBits: Int) {
        var fractBits = fractBitsIn
        let tailZeros = fractBits.trailingZeroBitCount
        let nFractBits = 53 - tailZeros
        roundedUp = false
        exact = false
        let nTinyBits = max(0, nFractBits - binExp - 1)
        if binExp <= 62 && binExp >= -21 {
            if nTinyBits < Self.longPow5.count && (nFractBits + Self.n5Bits[nTinyBits]) < 64 {
                if nTinyBits == 0 {
                    let insignificant = binExp > nSignificantBits
                        ? Self.insignificantDigitsForPow2(binExp - nSignificantBits - 1) : 0
                    if binExp >= 52 {
                        fractBits <<= Int64(binExp - 52)
                    } else {
                        fractBits = Int64(bitPattern: UInt64(bitPattern: fractBits) >> UInt64(52 - binExp))
                    }
                    developLongDigits(0, fractBits, insignificant)
                    return
                }
            }
        }
        var decExp = Self.estimateDecExp(fractBits, binExp)
        let B5 = max(0, -decExp)
        var B2 = B5 + nTinyBits + binExp
        let S5 = max(0, decExp)
        var S2 = S5 + nTinyBits
        let M5 = B5
        var M2 = B2 - nSignificantBits

        fractBits = Int64(bitPattern: UInt64(bitPattern: fractBits) >> UInt64(tailZeros))
        B2 -= nFractBits - 1
        let common2factor = min(B2, S2)
        B2 -= common2factor
        S2 -= common2factor
        M2 -= common2factor
        if nFractBits == 1 { M2 -= 1 }
        if M2 < 0 {
            B2 -= M2
            S2 -= M2
            M2 = 0
        }
        var out: [UInt8] = []
        var low = false, high = false
        var lowDigitDifference: Int64 = 0
        var q: Int

        let Bbits = nFractBits + B2 + ((B5 < Self.n5Bits.count) ? Self.n5Bits[B5] : (B5 * 3))
        let tenSbits = S2 + 1 + (((S5 + 1) < Self.n5Bits.count) ? Self.n5Bits[S5 + 1] : ((S5 + 1) * 3))
        if Bbits < 64 && tenSbits < 64 {
            if Bbits < 32 && tenSbits < 32 {
                var b: Int32 = (Int32(truncatingIfNeeded: fractBits) &* Self.smallPow5[B5]) << Int32(B2)
                let s: Int32 = Self.smallPow5[S5] << Int32(S2)
                var m: Int32 = Self.smallPow5[M5] << Int32(M2)
                let tens: Int32 = s &* 10
                q = Int(b / s)
                b = 10 &* (b % s)
                m = m &* 10
                low = b < m
                high = b &+ m > tens
                if q == 0 && !high {
                    decExp -= 1
                } else {
                    out.append(UInt8(0x30 + q))
                }
                if decExp < -3 || decExp >= 8 { high = false; low = false }
                while !low && !high {
                    q = Int(b / s)
                    b = 10 &* (b % s)
                    m = m &* 10
                    if m > 0 {
                        low = b < m
                        high = b &+ m > tens
                    } else {
                        low = true
                        high = true
                    }
                    out.append(UInt8(0x30 + q))
                }
                lowDigitDifference = Int64((b << 1) &- tens)
                exact = b == 0
            } else {
                var b: Int64 = (fractBits &* Self.longPow5[B5]) << Int64(B2)
                let s: Int64 = Self.longPow5[S5] << Int64(S2)
                var m: Int64 = Self.longPow5[M5] << Int64(M2)
                let tens: Int64 = s &* 10
                q = Int(b / s)
                b = 10 &* (b % s)
                m = m &* 10
                low = b < m
                high = b &+ m > tens
                if q == 0 && !high {
                    decExp -= 1
                } else {
                    out.append(UInt8(0x30 + q))
                }
                if decExp < -3 || decExp >= 8 { high = false; low = false }
                while !low && !high {
                    q = Int(b / s)
                    b = 10 &* (b % s)
                    m = m &* 10
                    if m > 0 {
                        low = b < m
                        high = b &+ m > tens
                    } else {
                        low = true
                        high = true
                    }
                    out.append(UInt8(0x30 + q))
                }
                lowDigitDifference = (b << 1) &- tens
                exact = b == 0
            }
        } else {
            // Big-integer arithmetic. FDBigInteger normalizes S by a shift, which
            // scales every quantity alike and so changes no comparison; it is omitted.
            let Sval = BigUInt.pow52(S5, S2)
            var Bval = BigUInt.mulPow52(UInt64(fractBits), B5, B2)
            var Mval = BigUInt.pow52(M5 + 1, M2 + 1)
            let tenSval = BigUInt.pow52(S5 + 1, S2 + 1)
            q = Bval.quoRemIteration(Sval)
            low = Bval < Mval
            high = BigUInt.compare(tenSval, Bval.adding(Mval)) <= 0
            if q == 0 && !high {
                decExp -= 1
            } else {
                out.append(UInt8(0x30 + q))
            }
            if decExp < -3 || decExp >= 8 { high = false; low = false }
            while !low && !high {
                q = Bval.quoRemIteration(Sval)
                Mval.multiplyBy10()
                low = Bval < Mval
                high = BigUInt.compare(tenSval, Bval.adding(Mval)) <= 0
                out.append(UInt8(0x30 + q))
            }
            if high && low {
                Bval.shiftLeft(1)
                lowDigitDifference = Int64(BigUInt.compare(Bval, tenSval))
            } else {
                lowDigitDifference = 0
            }
            exact = Bval.isZero
        }
        digits = out
        decExponent = decExp + 1
        if high {
            if low {
                if lowDigitDifference == 0 {
                    if (digits[digits.count - 1] & 1) != 0 { roundup() }
                } else if lowDigitDifference > 0 {
                    roundup()
                }
            } else {
                roundup()
            }
        }
    }

    private mutating func roundup() {
        var i = digits.count - 1
        var q = digits[i]
        if q == 0x39 {
            while q == 0x39 && i > 0 {
                digits[i] = 0x30
                i -= 1
                q = digits[i]
            }
            if q == 0x39 {
                decExponent += 1
                digits[0] = 0x31
                return
            }
        }
        digits[i] = q + 1
        roundedUp = true
    }
}

/// A minimal unsigned big integer (32-bit limbs, least significant first),
/// enough for the hard case of `dtoa`.
struct BigUInt {
    var limbs: [UInt32]

    init(_ v: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32)]
        normalize()
    }

    var isZero: Bool { limbs.isEmpty }

    mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    mutating func multiply(by m: UInt32) {
        var carry: UInt64 = 0
        for i in 0..<limbs.count {
            let p = UInt64(limbs[i]) * UInt64(m) + carry
            limbs[i] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        if carry != 0 { limbs.append(UInt32(carry)) }
    }

    mutating func multiplyBy10() { multiply(by: 10) }

    mutating func shiftLeft(_ bits: Int) {
        if bits <= 0 || isZero { return }
        let words = bits / 32, rem = bits % 32
        if rem != 0 {
            var carry: UInt32 = 0
            for i in 0..<limbs.count {
                let v = limbs[i]
                limbs[i] = (v << UInt32(rem)) | carry
                carry = v >> UInt32(32 - rem)
            }
            if carry != 0 { limbs.append(carry) }
        }
        if words > 0 { limbs.insert(contentsOf: repeatElement(0, count: words), at: 0) }
    }

    static func pow52(_ p5: Int, _ p2: Int) -> BigUInt { mulPow52(1, p5, p2) }

    static func mulPow52(_ value: UInt64, _ p5: Int, _ p2: Int) -> BigUInt {
        var r = BigUInt(value)
        var n = p5
        while n >= 13 { r.multiply(by: 1_220_703_125); n -= 13 }
        var tail: UInt32 = 1
        for _ in 0..<n { tail *= 5 }
        if tail != 1 { r.multiply(by: tail) }
        r.shiftLeft(p2)
        return r
    }

    func adding(_ other: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        result.reserveCapacity(max(limbs.count, other.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<max(limbs.count, other.limbs.count) {
            let a = i < limbs.count ? UInt64(limbs[i]) : 0
            let b = i < other.limbs.count ? UInt64(other.limbs[i]) : 0
            let s = a + b + carry
            result.append(UInt32(truncatingIfNeeded: s))
            carry = s >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        var r = BigUInt(0)
        r.limbs = result
        r.normalize()
        return r
    }

    mutating func subtract(_ other: BigUInt) {
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            var d = Int64(limbs[i]) - borrow - (i < other.limbs.count ? Int64(other.limbs[i]) : 0)
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            limbs[i] = UInt32(d)
        }
        normalize()
    }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        var i = a.limbs.count - 1
        while i >= 0 {
            if a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a, b) < 0 }

    /// q = self / s (q < 10), then self = 10 * (self % s).
    mutating func quoRemIteration(_ s: BigUInt) -> Int {
        var q = 0
        while BigUInt.compare(self, s) >= 0 {
            subtract(s)
            q += 1
        }
        multiplyBy10()
        return q
    }
}

// MARK: - DecimalFormat

enum JavaRoundingMode { case halfEven, halfUp }

/// Port of `java.text.DigitList` for doubles.
struct DigitList {
    var digits: [UInt8] = []
    var count = 0
    var decimalAt = 0
    var isNegative = false

    var isZero: Bool {
        for i in 0..<count where digits[i] != 0x30 { return false }
        return true
    }

    /// `set(isNegative, source, maximumDigits, fixedPoint)`; source >= 0, finite.
    init(negative: Bool, source: Double, maximumDigits: Int, fixedPoint: Bool, mode: JavaRoundingMode) {
        isNegative = negative
        var roundedUp = false
        var exact = false
        if source == 0 {
            digits = []
            count = 0
            decimalAt = 0
        } else {
            let fd = FloatingDecimalDigits(source)
            digits = fd.digits
            count = digits.count
            decimalAt = fd.decExponent
            roundedUp = fd.roundedUp
            exact = fd.exact
        }
        if fixedPoint {
            if -decimalAt > maximumDigits {
                count = 0
                return
            } else if -decimalAt == maximumDigits {
                if shouldRoundUp(0, roundedUp, exact, mode) {
                    count = 1
                    decimalAt += 1
                    if digits.isEmpty { digits = [0x31] } else { digits[0] = 0x31 }
                } else {
                    count = 0
                }
                return
            }
        }
        while count > 1 && digits[count - 1] == 0x30 { count -= 1 }
        round(fixedPoint ? (maximumDigits + decimalAt) : maximumDigits, roundedUp, exact, mode)
    }

    private mutating func round(_ maximumDigitsIn: Int, _ alreadyRounded: Bool, _ exact: Bool, _ mode: JavaRoundingMode) {
        var maximumDigits = maximumDigitsIn
        if maximumDigits >= 0 && maximumDigits < count {
            if shouldRoundUp(maximumDigits, alreadyRounded, exact, mode) {
                while true {
                    maximumDigits -= 1
                    if maximumDigits < 0 {
                        digits[0] = 0x31
                        decimalAt += 1
                        maximumDigits = 0
                        break
                    }
                    digits[maximumDigits] += 1
                    if digits[maximumDigits] <= 0x39 { break }
                }
                maximumDigits += 1
            }
            count = maximumDigits
            while count > 1 && digits[count - 1] == 0x30 { count -= 1 }
        }
    }

    private func shouldRoundUp(_ maximumDigits: Int, _ alreadyRounded: Bool, _ exact: Bool, _ mode: JavaRoundingMode) -> Bool {
        guard maximumDigits < count else { return false }
        switch mode {
        case .halfUp:
            if digits[maximumDigits] > 0x35 { return true }
            if digits[maximumDigits] == 0x35 {
                if maximumDigits != count - 1 { return true }
                return exact ? true : !alreadyRounded
            }
            return false
        case .halfEven:
            if digits[maximumDigits] > 0x35 { return true }
            if digits[maximumDigits] == 0x35 {
                if maximumDigits == count - 1 {
                    if alreadyRounded { return false }
                    if !exact { return true }
                    return maximumDigits > 0 && (digits[maximumDigits - 1] % 2 != 0)
                } else {
                    for i in (maximumDigits + 1)..<count where digits[i] != 0x30 { return true }
                }
            }
            return false
        }
    }
}

/// `new DecimalFormat("0.000…")` with `fractionDigits` zeros (no grouping).
func decimalFormatFixed(_ number: Double, fractionDigits: Int, mode: JavaRoundingMode) -> String {
    if number.isNaN { return "NaN" }
    let negative = number < 0 || (number == 0 && number.sign == .minus)
    if number.isInfinite { return negative ? "-∞" : "∞" }
    var dl = DigitList(negative: negative, source: abs(number), maximumDigits: fractionDigits, fixedPoint: true, mode: mode)
    if dl.isZero { dl.decimalAt = 0 }
    var out: [UInt8] = []
    out.reserveCapacity(dl.count + fractionDigits + 4)
    if negative { out.append(0x2D) }
    var count = 1
    var digitIndex = 0
    if dl.decimalAt > 0 && count < dl.decimalAt { count = dl.decimalAt }
    var i = count - 1
    while i >= 0 {
        if i < dl.decimalAt && digitIndex < dl.count {
            out.append(dl.digits[digitIndex]); digitIndex += 1
        } else {
            out.append(0x30)
        }
        i -= 1
    }
    if fractionDigits > 0 {
        out.append(0x2E)
        for j in 0..<fractionDigits {
            if -1 - j > (dl.decimalAt - 1) {
                out.append(0x30)
                continue
            }
            if digitIndex < dl.count {
                out.append(dl.digits[digitIndex]); digitIndex += 1
            } else {
                out.append(0x30)
            }
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// `new DecimalFormat("0.000E0")` with `fractionDigits` zeros after the point.
func decimalFormatScientific(_ number: Double, fractionDigits: Int) -> String {
    if number.isNaN { return "NaN" }
    let negative = number < 0 || (number == 0 && number.sign == .minus)
    if number.isInfinite { return negative ? "-∞" : "∞" }
    var dl = DigitList(negative: negative, source: abs(number), maximumDigits: 1 + fractionDigits, fixedPoint: false,
                       mode: .halfEven)
    let zero = dl.isZero
    if zero { dl.decimalAt = 0 }
    var out = negative ? "-" : ""
    var exponent = dl.decimalAt - 1
    let integerDigits = zero ? 1 : dl.decimalAt - exponent
    var minimumDigits = 1 + fractionDigits
    if minimumDigits < integerDigits { minimumDigits = integerDigits }
    let totalDigits = max(dl.count, minimumDigits)
    var bytes: [UInt8] = []
    for i in 0..<totalDigits {
        if i == integerDigits { bytes.append(0x2E) }
        bytes.append(i < dl.count ? dl.digits[i] : 0x30)
    }
    out += String(decoding: bytes, as: UTF8.self)
    out += "E"
    if zero { exponent = 0 }
    if exponent < 0 {
        out += "-"
        exponent = -exponent
    }
    out += String(exponent)
    return out
}

// MARK: - ImageJ's formatting helpers

enum ImageJFormat {
    static let floatMax = Double(Float.greatestFiniteMagnitude)

    /// `IJ.d2s(n, decimalPlaces)`.
    static func d2s(_ n: Double, _ decimalPlacesIn: Int) -> String {
        if n.isNaN || n.isInfinite { return javaString(n) }
        if n == floatMax { return "3.4e38" }
        var decimalPlaces = decimalPlacesIn
        if decimalPlaces < 0 {
            decimalPlaces = -decimalPlaces
            if decimalPlaces > 9 { decimalPlaces = 9 }
            return decimalFormatScientific(n, fractionDigits: decimalPlaces)
        }
        if decimalPlaces > 9 { decimalPlaces = 9 }
        return decimalFormatFixed(n, fractionDigits: decimalPlaces, mode: decimalPlaces == 0 ? .halfUp : .halfEven)
    }

    /// `IJ.d2s(x, significantDigits, maxDigits)`.
    static func d2s(_ x: Double, significantDigits: Int, maxDigits: Int) -> String {
        let log10v = javaLog10(abs(x))
        let roundErrorAtMax = 0.223 * javaPow(10, Double(-maxDigits))
        let magnitude = jIntI((log10v + roundErrorAtMax).rounded(.up))
        var decimals = x == 0 ? 0 : maxDigits - magnitude
        if decimals < 0 || magnitude < significantDigits + 1 - maxDigits {
            return d2s(x, -significantDigits)
        } else {
            if decimals > significantDigits {
                decimals = max(significantDigits, decimals - maxDigits + significantDigits)
            }
            return d2s(x, decimals)
        }
    }

    /// `ResultsTable.d2s(n, decimalPlaces)`.
    static func resultsTableD2S(_ n: Double, _ decimalPlacesIn: Int) -> String {
        if n.isNaN || n.isInfinite { return javaString(n) }
        if n == floatMax { return "3.4e38" }
        var decimalPlaces = decimalPlacesIn
        let np = abs(n)
        if (np != 0 && np < 1.0 / javaPow(10, Double(decimalPlaces))) || np > 999999999999 || decimalPlaces < 0 {
            if decimalPlaces < 0 {
                decimalPlaces = -decimalPlaces
                if decimalPlaces > 9 { decimalPlaces = 9 }
            } else {
                decimalPlaces = 3
            }
            return decimalFormatScientific(n, fractionDigits: decimalPlaces)
        }
        if decimalPlaces < 0 { decimalPlaces = 0 }
        if decimalPlaces > 9 { decimalPlaces = 9 }
        return decimalFormatFixed(n, fractionDigits: decimalPlaces, mode: decimalPlaces == 0 ? .halfUp : .halfEven)
    }

    /// `IJ.pad(int, digits)`.
    static func pad(_ n: Int32, _ digits: Int) -> String {
        var s = String(n)
        while s.utf16.count < digits { s = "0" + s }
        return s
    }

    /// `IJ.pad(String, digits)`.
    static func pad(_ s: String, _ digits: Int) -> String {
        var str = s
        while str.utf16.count < digits { str = "0" + str }
        return str
    }
}

// MARK: - java.lang.Math functions that differ from C's in edge cases

@inline(__always)
func javaPow(_ a: Double, _ b: Double) -> Double {
    // Java: pow(x, NaN) is NaN even for x == 1, and pow(±1, ±Inf) is NaN.
    if b.isNaN { return .nan }
    if b.isInfinite && abs(a) == 1 { return .nan }
    return Foundation_pow(a, b)
}

@inline(__always)
func javaLog10(_ a: Double) -> Double { Foundation_log10(a) }
