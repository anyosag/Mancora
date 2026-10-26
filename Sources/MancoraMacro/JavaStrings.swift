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
        /// The exception as `"" + e` shows it.
        let description: String

        init(pattern: String) {
            description = "java.util.regex.PatternSyntaxException: Invalid pattern \"\(pattern)\""
        }

        init(_ exception: String, _ message: String) {
            description = "java.lang." + exception + ": " + message
        }
    }

    static func compile(_ pattern: String) throws(Failure) -> NSRegularExpression {
        // Java's empty pattern matches everywhere; ICU rejects it.
        do { return try NSRegularExpression(pattern: pattern.isEmpty ? "(?:)" : pattern) } catch {
            throw Failure(pattern: pattern)
        }
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

    /// `s.replaceAll(regex, replacement)`, expanding the replacement as
    /// `Matcher.appendReplacement` does (ICU's templates differ: a lone `$`
    /// or a missing group is literal there, an exception in Java).
    static func replaceAll(_ s: String, _ pattern: String, _ replacement: String) throws(Failure) -> String {
        let re = try compile(pattern)
        let text = Array(s.utf16)
        let matches = re.matches(in: s, range: NSRange(location: 0, length: text.count))
        if matches.isEmpty { return s }
        let r = Array(replacement.utf16)
        let names = namedGroups(pattern)
        var out: [UInt16] = []
        var tail = 0
        func group(_ m: NSTextCheckingResult, _ n: Int) {
            let range = m.range(at: n)
            if range.location != NSNotFound { out += text[range.location..<(range.location + range.length)] }
        }
        for m in matches {
            out += text[tail..<m.range.location]
            var cursor = 0
            while cursor < r.count {
                var c = r[cursor]
                if c == 92 {  // backslash
                    cursor += 1
                    if cursor == r.count { throw Failure("IllegalArgumentException", "character to be escaped is missing") }
                    out.append(r[cursor])
                    cursor += 1
                } else if c == 36 {  // $
                    cursor += 1
                    if cursor == r.count {
                        throw Failure("IllegalArgumentException", "Illegal group reference: group index is missing")
                    }
                    c = r[cursor]
                    var refNum: Int
                    if c == 123 {  // {name}
                        cursor += 1
                        var name: [UInt16] = []
                        while cursor < r.count, isASCIIAlphanumeric(r[cursor]) {
                            name.append(r[cursor])
                            cursor += 1
                        }
                        let gname = utf16String(name)
                        if name.isEmpty {
                            throw Failure("IllegalArgumentException", "named capturing group has 0 length name")
                        }
                        if cursor == r.count || r[cursor] != 125 {
                            throw Failure("IllegalArgumentException", "named capturing group is missing trailing '}'")
                        }
                        if name[0] >= 48 && name[0] <= 57 {
                            throw Failure(
                                "IllegalArgumentException", "capturing group name {\(gname)} starts with digit character")
                        }
                        guard let n = names[gname] else {
                            throw Failure("IllegalArgumentException", "No group with name {\(gname)}")
                        }
                        refNum = n
                        cursor += 1
                    } else {
                        // The first digit is always a group; more digits while the number is a group.
                        guard c >= 48 && c <= 57 else { throw Failure("IllegalArgumentException", "Illegal group reference") }
                        refNum = Int(c - 48)
                        cursor += 1
                        while cursor < r.count, r[cursor] >= 48, r[cursor] <= 57 {
                            let newRefNum = refNum * 10 + Int(r[cursor] - 48)
                            if re.numberOfCaptureGroups < newRefNum { break }
                            refNum = newRefNum
                            cursor += 1
                        }
                    }
                    if refNum > re.numberOfCaptureGroups {
                        throw Failure("IndexOutOfBoundsException", "No group \(refNum)")
                    }
                    group(m, refNum)
                } else {
                    out.append(c)
                    cursor += 1
                }
            }
            tail = m.range.location + m.range.length
        }
        out += text[tail...]
        return utf16String(out)
    }

    private static func isASCIIAlphanumeric(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    /// The named groups of `pattern` (`(?<name>...)`), numbered as capturing groups are.
    private static func namedGroups(_ pattern: String) -> [String: Int] {
        let p = Array(pattern.utf16)
        var names: [String: Int] = [:]
        var count = 0
        var i = 0
        var inClass = 0
        while i < p.count {
            let c = p[i]
            if c == 92 {  // \Q...\E quotes; any other escape is two characters
                if i + 1 < p.count && p[i + 1] == 81 {
                    i += 2
                    while i + 1 < p.count && !(p[i] == 92 && p[i + 1] == 69) { i += 1 }
                }
                i += 2
                continue
            }
            if c == 91 {
                inClass += 1
            } else if c == 93 && inClass > 0 {
                inClass -= 1
            } else if c == 40 && inClass == 0 {
                if i + 1 < p.count && p[i + 1] == 63 {  // (?
                    if i + 2 < p.count && p[i + 2] == 60 && i + 3 < p.count && p[i + 3] != 61 && p[i + 3] != 33 {
                        count += 1
                        var j = i + 3
                        var name: [UInt16] = []
                        while j < p.count && p[j] != 62 {
                            name.append(p[j])
                            j += 1
                        }
                        names[utf16String(name)] = count
                    }
                } else {
                    count += 1
                }
            }
            i += 1
        }
        return names
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

    /// One `%[argument_index$][flags][width][.precision]conversion`.
    private struct Specifier {
        var index: Int?  // explicit argument index (1-based)
        var flags: Set<UInt16> = []
        var width: Int?
        var precision: Int?
        var dateTime = false
        /// The conversion as written (`E` for `%E`).
        var conversion: UInt16 = 0

        var c: Character { Character(Unicode.Scalar(conversion) ?? "?") }
        var lower: Character { Character(Unicode.Scalar(javaLower(conversion)) ?? "?") }
        var upper: Bool { conversion >= 65 && conversion <= 90 }

        /// `FormatSpecifier.toString()`, as exceptions show it.
        var description: String {
            var s = "%" + Self.flagString(flags)
            if let index, index > 0 { s += "\(index)$" }
            if let width { s += "\(width)" }
            if let precision { s += ".\(precision)" }
            if dateTime { s += upper ? "T" : "t" }
            return s + String(c)
        }

        static let flagOrder: [UInt16] = [45, 35, 43, 32, 48, 44, 40, 60]  // - # + space 0 , ( <

        static func flagString(_ flags: Set<UInt16>) -> String {
            utf16String(flagOrder.filter { flags.contains($0) })
        }
    }

    private static func failure(_ exception: String, _ message: String) -> Failure {
        Failure(description: "java.util." + exception + ": " + message)
    }

    /// The specifier after a `%` at `i`, as Formatter's parser reads it, or nil where it fails.
    private static func parseSpecifier(_ f: [UInt16], _ i: inout Int) throws(Failure) -> Specifier? {
        func isDigit(_ k: Int) -> Bool { k < f.count && f[k] >= 48 && f[k] <= 57 }
        var spec = Specifier()
        var j = i
        var number = 0
        while isDigit(j) {
            number = number * 10 + Int(f[j] - 48)
            j += 1
        }
        if j > i && j < f.count && f[j] == 36 {  // $
            spec.index = number
            j += 1
        } else {
            j = i
        }
        while j < f.count, Specifier.flagOrder.contains(f[j]) {
            if spec.flags.contains(f[j]) {
                throw failure("DuplicateFormatFlagsException", "Flags = '\(utf16String([f[j]]))'")
            }
            spec.flags.insert(f[j])
            j += 1
        }
        if isDigit(j) {
            var w = 0
            while isDigit(j) {
                w = w * 10 + Int(f[j] - 48)
                j += 1
            }
            spec.width = w
        }
        if j < f.count && f[j] == 46 {  // .
            j += 1
            guard isDigit(j) else { return nil }
            var p = 0
            while isDigit(j) {
                p = p * 10 + Int(f[j] - 48)
                j += 1
            }
            spec.precision = p
        }
        if j < f.count && (f[j] == 116 || f[j] == 84) {  // t T
            spec.dateTime = true
            spec.conversion = f[j]
            j += 1
            guard j < f.count, isLetter(f[j]) else { return nil }
            let dc = f[j]
            if !"HIklMSLNpzZsQBbhAaCYyjmdeRTrDFc".utf16.contains(dc) {
                throw failure("UnknownFormatConversionException", "Conversion = 't\(utf16String([dc]))'")
            }
            spec.conversion = dc
            i = j + 1
            return spec
        }
        guard j < f.count, isLetter(f[j]) || f[j] == 37 else { return nil }
        spec.conversion = f[j]
        i = j + 1
        return spec
    }

    private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    /// The checks `FormatSpecifier`'s constructor makes, before anything is printed.
    private static func check(_ spec: Specifier) throws(Failure) {
        let f = spec.flags
        func mismatch(_ bad: [UInt16]) throws(Failure) {
            for flag in bad where f.contains(flag) {
                throw failure(
                    "FormatFlagsConversionMismatchException", "Conversion = \(spec.lower), Flags = \(utf16String([flag]))")
            }
        }
        func needsWidth(_ flagsNeedingIt: [UInt16]) throws(Failure) {
            if spec.width == nil && flagsNeedingIt.contains(where: f.contains) {
                throw failure("MissingFormatWidthException", spec.description)
            }
        }
        func checkNumeric() throws(Failure) {
            try needsWidth([45, 48])
            if (f.contains(43) && f.contains(32)) || (f.contains(45) && f.contains(48)) {
                throw failure("IllegalFormatFlagsException", "Flags = '\(Specifier.flagString(f))'")
            }
        }
        if let index = spec.index, index == 0 {
            throw failure("IllegalFormatArgumentIndexException", "Illegal format argument index = 0")
        }
        if spec.dateTime {
            if let p = spec.precision { throw failure("IllegalFormatPrecisionException", "\(p)") }
            try mismatch([35, 43, 32, 48, 44, 40])
            try needsWidth([45])
            return
        }
        switch spec.lower {
        case "b", "h", "s":
            if spec.lower != "s" { try mismatch([35]) }
            try needsWidth([45])
            try mismatch([43, 32, 48, 44, 40])
        case "c":
            if let p = spec.precision { throw failure("IllegalFormatPrecisionException", "\(p)") }
            try mismatch([35, 43, 32, 48, 44, 40])
            try needsWidth([45])
        case "d", "o", "x":
            try checkNumeric()
            if let p = spec.precision { throw failure("IllegalFormatPrecisionException", "\(p)") }
            try mismatch(spec.lower == "d" ? [35] : [44])
        case "e", "f", "g", "a":
            try checkNumeric()
            switch spec.lower {
            case "a": try mismatch([40, 44])
            case "e": try mismatch([44])
            case "g": try mismatch([35])
            default: break
            }
        case "%":
            if let p = spec.precision { throw failure("IllegalFormatPrecisionException", "\(p)") }
            if !f.subtracting([45]).isEmpty {
                throw failure("IllegalFormatFlagsException", "Flags = '\(Specifier.flagString(f))'")
            }
            try needsWidth([45])
        case "n":
            if let p = spec.precision { throw failure("IllegalFormatPrecisionException", "\(p)") }
            if let w = spec.width { throw failure("IllegalFormatWidthException", "\(w)") }
            if !f.isEmpty { throw failure("IllegalFormatFlagsException", "Flags = '\(Specifier.flagString(f))'") }
        default:
            throw failure("UnknownFormatConversionException", "Conversion = '\(spec.c)'")
        }
    }

    /// `String.format(format, args)` with Double arguments: the whole format
    /// is parsed and checked first, then the arguments are formatted in turn.
    static func format(_ format: String, _ args: [Double]) throws(Failure) -> String {
        let f = Array(format.utf16)
        enum Part {
            case text([UInt16])
            case specifier(Specifier)
        }
        var parts: [Part] = []
        var literal: [UInt16] = []
        var i = 0
        while i < f.count {
            guard f[i] == 37 else {  // %
                literal.append(f[i])
                i += 1
                continue
            }
            if !literal.isEmpty {
                parts.append(.text(literal))
                literal = []
            }
            i += 1
            guard i < f.count else { throw failure("UnknownFormatConversionException", "Conversion = '%'") }
            let first = f[i]
            guard let spec = try parseSpecifier(f, &i) else {
                throw failure("UnknownFormatConversionException", "Conversion = '\(utf16String([first]))'")
            }
            try check(spec)
            parts.append(.specifier(spec))
        }
        if !literal.isEmpty { parts.append(.text(literal)) }

        var out = ""
        var ordinary = -1
        var last = -1
        for part in parts {
            guard case .specifier(let spec) = part else {
                if case .text(let t) = part { out += utf16String(t) }
                continue
            }
            switch spec.lower {
            case "%":
                out += pad("%", spec.width, spec.flags)
                continue
            case "n":
                out += "\n"
                continue
            default: break
            }
            let index: Int
            if spec.flags.contains(60) {  // <
                index = last
            } else if let explicit = spec.index {
                index = explicit - 1
            } else {
                ordinary += 1
                index = ordinary
            }
            last = index
            guard index >= 0, index < args.count else {
                throw failure("MissingFormatArgumentException", "Format specifier '\(spec.description)'")
            }
            out += try formatted(args[index], spec)
        }
        return out
    }

    private static func formatted(_ value: Double, _ spec: Specifier) throws(Failure) -> String {
        if spec.dateTime {
            throw failure("IllegalFormatConversionException", "\(spec.c) != java.lang.Double")
        }
        let flags = spec.flags
        func general(_ s: String) -> String {
            var s = s
            if let precision = spec.precision { s = javaSubstring(s, 0, precision) }
            return pad(spec.upper ? javaToUpperCase(s) : s, spec.width, flags)
        }
        switch spec.lower {
        case "f", "e", "g", "a":
            var s = floating(value, spec)
            if flags.contains(48), let width = spec.width, s.utf16.count < width, value.isFinite {
                // Zeros go after the sign or the opening parenthesis.
                let signed = s.hasPrefix("-") || s.hasPrefix("+") || s.hasPrefix(" ") || s.hasPrefix("(")
                let zeros = String(repeating: "0", count: width - s.utf16.count)
                if spec.lower == "a" {
                    let prefix = s.hasPrefix("-") || s.hasPrefix("+") || s.hasPrefix(" ") ? 3 : 2
                    s = String(s.prefix(prefix)) + zeros + String(s.dropFirst(prefix))
                } else {
                    s = signed ? String(s.prefix(1)) + zeros + String(s.dropFirst()) : zeros + s
                }
            }
            return pad(s, spec.width, flags)
        case "s":
            if flags.contains(35) {  // a Double isn't Formattable
                throw failure("FormatFlagsConversionMismatchException", "Conversion = s, Flags = #")
            }
            return general(javaString(value))
        case "b":
            return general("true")
        case "h":
            let bits = value.isNaN ? UInt64(0x7ff8_0000_0000_0000) : value.bitPattern
            return general(String(UInt32(truncatingIfNeeded: bits ^ (bits >> 32)), radix: 16))
        default:
            throw failure("IllegalFormatConversionException", "\(spec.lower) != java.lang.Double")
        }
    }

    private static func pad(_ s: String, _ width: Int?, _ flags: Set<UInt16>) -> String {
        guard let width, s.utf16.count < width else { return s }
        let fill = String(repeating: " ", count: width - s.utf16.count)
        return flags.contains(45) ? s + fill : fill + s
    }

    /// `%f`, `%e`, `%g` and `%a`: FloatingDecimal's digits rounded half-up, as Java's Formatter does.
    private static func floating(_ value: Double, _ spec: Specifier) -> String {
        let flags = spec.flags
        if value.isNaN { return spec.upper ? "NAN" : "NaN" }
        let negative = value.sign == .minus
        var body: String
        if value.isInfinite {
            body = spec.upper ? "INFINITY" : "Infinity"
        } else {
            let magnitude = abs(value)
            switch spec.lower {
            case "f":
                let precision = spec.precision ?? 6
                body = fixed(magnitude, precision)
                if precision == 0 && flags.contains(35) { body += "." }
            case "e":
                let precision = spec.precision ?? 6
                body = scientific(magnitude, precision)
                if precision == 0 && flags.contains(35), let e = body.firstIndex(of: "e") { body.insert(".", at: e) }
            case "a":
                body = hexDouble(magnitude, spec.precision)
            default:
                var precision = spec.precision ?? 6
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
            }
            if spec.upper { body = body.uppercased() }
            if flags.contains(44), spec.lower == "f" || spec.lower == "g" { body = grouped(body) }
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

    /// `%a` of a positive finite value: `Double.toHexString`, or rounded
    /// half-even to `precision` hex digits (subnormals normalized).
    private static func hexDouble(_ v: Double, _ precisionIn: Int?) -> String {
        var prec = precisionIn ?? 0
        if precisionIn == 0 { prec = 1 }
        func toHexString(_ d: Double) -> (mantissa: String, exponent: Int) {
            if d == 0 { return ("0.0", 0) }
            let subnormal = d < Double.leastNormalMagnitude
            var signif = String(d.significandBitPattern, radix: 16)
            signif = String(repeating: "0", count: 13 - signif.count) + signif
            while signif.count > 1 && signif.hasSuffix("0") { signif.removeLast() }
            return ((subnormal ? "0." : "1.") + signif, subnormal ? -1022 : Int(d.exponent))
        }
        var mantissa: String
        var exponent: Int
        if v == 0 || prec == 0 || prec >= 13 {
            (mantissa, exponent) = toHexString(v)
        } else {
            var d = v
            let subnormal = d < Double.leastNormalMagnitude
            if subnormal { d *= 0x1p54 }
            let shift = 52 - prec * 4
            let bits = d.bitPattern & 0x7fff_ffff_ffff_ffff
            var newSignif = bits >> UInt64(shift)
            let roundingBits = bits & ~(~UInt64(0) << UInt64(shift))
            let leastZero = newSignif & 1 == 0
            let round = (UInt64(1) << UInt64(shift - 1)) & roundingBits != 0
            let sticky = shift > 1 && (~(UInt64(1) << UInt64(shift - 1)) & roundingBits) != 0
            if (leastZero && round && sticky) || (!leastZero && round) { newSignif += 1 }
            let result = Double(bitPattern: newSignif << UInt64(shift))
            if result.isInfinite {
                (mantissa, exponent) = ("1.0", 1024)
            } else {
                (mantissa, exponent) = toHexString(result)
                if subnormal { exponent -= 54 }
            }
        }
        if prec != 0, let dot = mantissa.firstIndex(of: ".") {
            let digits = mantissa.distance(from: mantissa.index(after: dot), to: mantissa.endIndex)
            if digits < prec { mantissa += String(repeating: "0", count: prec - digits) }
        }
        return "0x" + mantissa + "p" + String(exponent)
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
