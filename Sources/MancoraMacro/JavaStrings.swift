// java.lang.String's methods as the macro language uses them: indexes and
// lengths count UTF-16 code units, comparisons are by code unit, and case
// mapping follows Character's one-to-one mapping.

import Foundation

@inline(__always) func utf16String(_ units: some Collection<UInt16>) -> String {
    String(decoding: units, as: UTF16.self)
}

/// `s.substring(begin, end)` (indexes already checked).
func javaSubstring(_ s: String, _ begin: Int, _ end: Int? = nil) -> String {
    let units = Array(s.utf16)
    let e = min(end ?? units.count, units.count)
    let b = max(0, min(begin, e))
    return utf16String(units[b..<e])
}

/// `s.indexOf(t, from)`.
func javaIndexOf(_ s: String, _ t: String, from: Int = 0) -> Int {
    let a = Array(s.utf16), b = Array(t.utf16)
    var start = max(0, from)
    if b.isEmpty { return min(start, a.count) }
    while start + b.count <= a.count {
        if a[start] == b[0] && a[start..<(start + b.count)].elementsEqual(b) { return start }
        start += 1
    }
    return -1
}

/// `s.lastIndexOf(t)`.
func javaLastIndexOf(_ s: String, _ t: String) -> Int {
    let a = Array(s.utf16), b = Array(t.utf16)
    var start = a.count - b.count
    while start >= 0 {
        if a[start..<(start + b.count)].elementsEqual(b) { return start }
        start -= 1
    }
    return -1
}

func javaContains(_ s: String, _ t: String) -> Bool { javaIndexOf(s, t) >= 0 }
func javaStartsWith(_ s: String, _ t: String) -> Bool { s.utf16.starts(with: t.utf16) }
func javaEndsWith(_ s: String, _ t: String) -> Bool { s.utf16.reversed().starts(with: t.utf16.reversed()) }

/// `String.trim()`: removes characters up to U+0020 from both ends.
func javaTrim(_ s: String) -> String {
    let units = Array(s.utf16)
    var b = 0, e = units.count
    while b < e && units[b] <= 32 { b += 1 }
    while e > b && units[e - 1] <= 32 { e -= 1 }
    return b == 0 && e == units.count ? s : utf16String(units[b..<e])
}

func javaToLowerCase(_ s: String) -> String { s.lowercased() }
func javaToUpperCase(_ s: String) -> String { s.uppercased() }

/// `Character.toUpperCase(char)`.
func javaUpper(_ c: UInt16) -> UInt16 { caseMapped(c, upper: true) }
/// `Character.toLowerCase(char)`.
func javaLower(_ c: UInt16) -> UInt16 { caseMapped(c, upper: false) }

private func caseMapped(_ c: UInt16, upper: Bool) -> UInt16 {
    if c < 128 {
        if upper, c >= 97, c <= 122 { return c - 32 }
        if !upper, c >= 65, c <= 90 { return c + 32 }
        return c
    }
    guard let scalar = Unicode.Scalar(c) else { return c }
    let mapped = upper ? scalar.properties.uppercaseMapping : scalar.properties.lowercaseMapping
    let units = Array(mapped.utf16)
    return units.count == 1 ? units[0] : c
}

/// `String.compareToIgnoreCase`.
func javaCompareToIgnoreCase(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1.utf16), b = Array(s2.utf16)
    for i in 0..<min(a.count, b.count) {
        var c1 = a[i], c2 = b[i]
        if c1 != c2 {
            c1 = javaUpper(c1)
            c2 = javaUpper(c2)
            if c1 != c2 {
                c1 = javaLower(c1)
                c2 = javaLower(c2)
                if c1 != c2 { return Int(c1) - Int(c2) }
            }
        }
    }
    return a.count - b.count
}

/// `String.compareTo`: by code unit.
func javaCompare(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1.utf16), b = Array(s2.utf16)
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return Int(a[i]) - Int(b[i]) }
    return a.count - b.count
}

/// `Double.compare`: -0.0 before 0.0, NaN after everything.
func javaDoubleCompare(_ a: Double, _ b: Double) -> Int {
    if a < b { return -1 }
    if a > b { return 1 }
    // doubleToLongBits: NaN is canonical, so it sorts after +Infinity.
    let x = a.isNaN ? 0x7ff8_0000_0000_0000 : Int64(bitPattern: a.bitPattern)
    let y = b.isNaN ? 0x7ff8_0000_0000_0000 : Int64(bitPattern: b.bitPattern)
    return x == y ? 0 : (x < y ? -1 : 1)
}

extension String {
    /// `replace(CharSequence, CharSequence)`: literal, every occurrence.
    func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        let a = Array(utf16), t = Array(target.utf16), r = Array(replacement.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            if i + t.count <= a.count && a[i] == t[0] && a[i..<(i + t.count)].elementsEqual(t) {
                out.append(contentsOf: r)
                i += t.count
            } else {
                out.append(a[i])
                i += 1
            }
        }
        return utf16String(out)
    }
}

// MARK: - Regular expressions

/// Java's `java.util.regex` through ICU (NSRegularExpression), whose syntax
/// is close to Java's for the patterns macros use.
enum JavaRegex {
    struct Failure: Error, CustomStringConvertible {
        let pattern: String
        var description: String { "java.util.regex.PatternSyntaxException: Invalid pattern \"\(pattern)\"" }
    }

    static func compile(_ pattern: String) throws(Failure) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch { throw Failure(pattern: pattern) }
    }

    /// `s.matches(regex)`: the whole string.
    static func matches(_ s: String, _ pattern: String) throws(Failure) -> Bool {
        let re = try compile("(?:" + pattern + ")\\z")
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        return m.range.location == 0 && m.range.length == ns.length
    }

    /// `s.replaceAll(regex, replacement)`.
    static func replaceAll(_ s: String, _ pattern: String, _ replacement: String) throws(Failure) -> String {
        let re = try compile(pattern)
        let ns = s as NSString
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: javaTemplate(replacement))
    }

    /// `s.split(regex, -1)`: keeps trailing empty strings; a match at the
    /// start that is zero-width gives no leading empty string.
    static func split(_ s: String, _ pattern: String) throws(Failure) -> [String] {
        let re = try compile(pattern)
        let ns = s as NSString
        var parts: [String] = []
        var index = 0
        var matched = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if index == 0 && m.range.location == 0 && m.range.length == 0 { continue }
            matched = true
            parts.append(ns.substring(with: NSRange(location: index, length: m.range.location - index)))
            index = m.range.location + m.range.length
        }
        if !matched { return [s] }
        parts.append(ns.substring(from: index))
        return parts
    }

    /// Java replacement strings use `$n` and `\` escapes, as ICU templates do;
    /// `${name}` isn't supported by ICU.
    private static func javaTemplate(_ r: String) -> String { r }

    /// `str.contains(regex)` as `FolderOpener.containsRegex` uses it: a match anywhere.
    static func find(_ s: String, _ pattern: String, caseSensitive: Bool = true) throws(Failure) -> Bool {
        let re: NSRegularExpression
        do {
            re = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw Failure(pattern: pattern)
        }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

// MARK: - java.util.Formatter (String.format with numbers)

enum JavaFormatter {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// `String.format(format, args)` with Double arguments.
    static func format(_ format: String, _ args: [Double]) throws(Failure) -> String {
        let f = Array(format.utf16)
        var out = ""
        var i = 0
        var argIndex = 0
        var literal: [UInt16] = []
        func flushLiteral() {
            if !literal.isEmpty {
                out += utf16String(literal)
                literal = []
            }
        }
        while i < f.count {
            guard f[i] == 37 else {  // %
                literal.append(f[i])
                i += 1
                continue
            }
            flushLiteral()
            i += 1
            // %[argument_index$][flags][width][.precision]conversion
            var flags: Set<UInt16> = []
            var explicitIndex: Int?
            var j = i
            var number = 0
            var sawDigits = false
            while j < f.count, f[j] >= 48, f[j] <= 57 {
                number = number * 10 + Int(f[j] - 48)
                sawDigits = true
                j += 1
            }
            if sawDigits, j < f.count, f[j] == 36 {  // $
                explicitIndex = number
                i = j + 1
            }
            while i < f.count, [45, 35, 43, 32, 48, 44, 40].contains(f[i]) {  // - # + space 0 , (
                flags.insert(f[i])
                i += 1
            }
            var width: Int?
            while i < f.count, f[i] >= 48, f[i] <= 57 {
                width = (width ?? 0) * 10 + Int(f[i] - 48)
                i += 1
            }
            var precision: Int?
            if i < f.count, f[i] == 46 {
                i += 1
                var p = 0
                var any = false
                while i < f.count, f[i] >= 48, f[i] <= 57 {
                    p = p * 10 + Int(f[i] - 48)
                    any = true
                    i += 1
                }
                guard any else { throw Failure(description: "java.util.IllegalFormatPrecisionException") }
                precision = p
            }
            guard i < f.count else {
                throw Failure(description: "java.util.UnknownFormatConversionException: Conversion = '%'")
            }
            let conversion = f[i]
            i += 1
            let c = Character(Unicode.Scalar(conversion) ?? "?")
            switch c {
            case "%":
                out += pad("%", width, flags)
                continue
            case "n":
                out += "\n"
                continue
            default: break
            }
            let index: Int
            if let explicitIndex { index = explicitIndex - 1 } else {
                index = argIndex
                argIndex += 1
            }
            guard index >= 0, index < args.count else {
                throw Failure(description: "java.util.MissingFormatArgumentException: Format specifier '%\(c)'")
            }
            let value = args[index]
            switch c {
            case "f", "e", "E", "g", "G":
                var s = floating(value, c, precision, flags)
                if flags.contains(48), !flags.contains(45), let width, s.utf16.count < width, value.isFinite {
                    // Zeros go after the sign.
                    let signed = s.hasPrefix("-") || s.hasPrefix("+") || s.hasPrefix(" ")
                    let zeros = String(repeating: "0", count: width - s.utf16.count)
                    s = signed ? String(s.prefix(1)) + zeros + String(s.dropFirst()) : zeros + s
                }
                out += pad(s, width, flags)
            case "s", "S":
                var s = javaString(value)
                if let precision { s = javaSubstring(s, 0, precision) }
                out += pad(c == "S" ? s.uppercased() : s, width, flags)
            case "b", "B":
                out += pad(c == "B" ? "TRUE" : "true", width, flags)
            case "d", "x", "X", "o", "c", "C":
                throw Failure(description: "java.util.IllegalFormatConversionException: \(c) != java.lang.Double")
            default:
                throw Failure(description: "java.util.UnknownFormatConversionException: Conversion = '\(c)'")
            }
        }
        flushLiteral()
        return out
    }

    private static func pad(_ s: String, _ width: Int?, _ flags: Set<UInt16>) -> String {
        guard let width, s.utf16.count < width else { return s }
        let fill = String(repeating: " ", count: width - s.utf16.count)
        return flags.contains(45) ? s + fill : fill + s
    }

    /// `%f`, `%e` and `%g`: FloatingDecimal's digits rounded half-up, as Java's Formatter does.
    private static func floating(_ value: Double, _ c: Character, _ precisionIn: Int?, _ flags: Set<UInt16>)
        -> String
    {
        let negative = value.sign == .minus && !value.isNaN
        var body: String
        if value.isNaN || value.isInfinite {
            body = value.isNaN ? "NaN" : "Infinity"
        } else {
            let magnitude = abs(value)
            switch c {
            case "f":
                body = fixed(magnitude, precisionIn ?? 6)
            case "e", "E":
                body = scientific(magnitude, precisionIn ?? 6)
                if c == "E" { body = body.uppercased() }
            default:
                var precision = precisionIn ?? 6
                if precision == 0 { precision = 1 }
                if magnitude == 0 {
                    body = fixed(0, precision - 1)
                } else {
                    // Round to `precision` significant digits first.
                    var d = digits(magnitude)
                    let exp = applyPrecision(&d.digits, d.decExponent, precision)
                    let rounded = exp - 1  // the exponent of the rounded value
                    if rounded >= -4 && rounded < precision {
                        body = fixed(magnitude, precision - (rounded + 1))
                    } else {
                        body = scientific(magnitude, precision - 1)
                    }
                }
                if c == "G" { body = body.uppercased() }
            }
            if flags.contains(44), c == "f" || c == "g" || c == "G" { body = grouped(body) }
        }
        var sign = ""
        if negative {
            sign = "-"
        } else if flags.contains(43) {
            sign = "+"
        } else if flags.contains(32) {
            sign = " "
        }
        if negative && flags.contains(40) { return "(" + body + ")" }
        return sign + body
    }

    private static func digits(_ v: Double) -> (digits: [UInt8], decExponent: Int) {
        let fd = FloatingDecimalDigits(v)
        return (fd.digits, fd.decExponent)
    }

    /// `FormattedFloatingDecimal.applyPrecision`: keeps `prec` digits, rounding half up.
    private static func applyPrecision(_ digits: inout [UInt8], _ decExp: Int, _ prec: Int) -> Int {
        let n = digits.count
        if prec >= n || prec < 0 { return decExp }
        if prec == 0 {
            if digits[0] >= 0x35 {
                digits = [0x31] + [UInt8](repeating: 0x30, count: n - 1)
                return decExp + 1
            }
            digits = [UInt8](repeating: 0x30, count: n)
            return decExp
        }
        if digits[prec] >= 0x35 {
            var i = prec - 1
            var q = digits[i]
            if q == 0x39 {
                while q == 0x39 && i > 0 {
                    i -= 1
                    q = digits[i]
                }
                if q == 0x39 {
                    digits = [0x31] + [UInt8](repeating: 0x30, count: n - 1)
                    return decExp + 1
                }
            }
            digits[i] = q + 1
            for k in (i + 1)..<n { digits[k] = 0x30 }
        } else {
            for k in prec..<n { digits[k] = 0x30 }
        }
        return decExp
    }

    private static func fixed(_ v: Double, _ precision: Int) -> String {
        if v == 0 { return precision > 0 ? "0." + String(repeating: "0", count: precision) : "0" }
        var (d, decExp) = digits(v)
        let exp = applyPrecision(&d, decExp, decExp + precision)
        // value = 0.d * 10^exp
        var intPart = ""
        var frac = ""
        if exp > 0 {
            for k in 0..<exp { intPart.append(k < d.count ? Character(Unicode.Scalar(d[k])) : "0") }
            for k in exp..<(exp + precision) { frac.append(k < d.count ? Character(Unicode.Scalar(d[k])) : "0") }
        } else {
            intPart = "0"
            for k in 0..<precision {
                let idx = k + exp
                frac.append(idx >= 0 && idx < d.count ? Character(Unicode.Scalar(d[idx])) : "0")
            }
        }
        return precision > 0 ? intPart + "." + frac : intPart
    }

    private static func scientific(_ v: Double, _ precision: Int) -> String {
        var mantissa: String
        var exponent: Int
        if v == 0 {
            mantissa = precision > 0 ? "0." + String(repeating: "0", count: precision) : "0"
            exponent = 0
        } else {
            var (d, decExp) = digits(v)
            let exp = applyPrecision(&d, decExp, precision + 1)
            mantissa = String(Character(Unicode.Scalar(d[0])))
            if precision > 0 {
                mantissa += "."
                for k in 1...precision { mantissa.append(k < d.count ? Character(Unicode.Scalar(d[k])) : "0") }
            }
            exponent = exp - 1
        }
        let e = abs(exponent)
        return mantissa + "e" + (exponent < 0 ? "-" : "+") + (e < 10 ? "0" : "") + String(e)
    }

    private static func grouped(_ body: String) -> String {
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = Array(parts[0])
        guard intPart.allSatisfy(\.isNumber), intPart.count > 3 else { return body }
        var out = ""
        for (k, ch) in intPart.enumerated() {
            if k > 0 && (intPart.count - k) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return parts.count > 1 ? out + "." + parts[1] : out
    }
}

// MARK: - java.util.Random

/// `java.util.Random`: the same sequence for the same seed.
struct JavaRandom {
    private var seed: Int64
    private var nextNextGaussian = 0.0
    private var haveNextNextGaussian = false
    private static let multiplier: Int64 = 0x5_DEEC_E66D
    private static let mask: Int64 = (1 << 48) - 1

    init(seed: Int64) { self.seed = (seed ^ Self.multiplier) & Self.mask }

    init() {
        self.init(seed: Int64.random(in: Int64.min...Int64.max))
    }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* Self.multiplier &+ 0xB) & Self.mask
        return Int32(truncatingIfNeeded: seed >> (48 - bits))
    }

    mutating func nextDouble() -> Double {
        let high = Int64(next(26)) << 27
        let low = Int64(next(27))
        return Double(high + low) * 0x1.0p-53
    }

    mutating func nextGaussian() -> Double {
        if haveNextNextGaussian {
            haveNextNextGaussian = false
            return nextNextGaussian
        }
        var v1 = 0.0, v2 = 0.0, s = 0.0
        repeat {
            v1 = 2 * nextDouble() - 1
            v2 = 2 * nextDouble() - 1
            s = v1 * v1 + v2 * v2
        } while s >= 1 || s == 0
        let multiplier = (-2 * jLog(s) / s).squareRoot()
        nextNextGaussian = v2 * multiplier
        haveNextNextGaussian = true
        return v1 * multiplier
    }
}
