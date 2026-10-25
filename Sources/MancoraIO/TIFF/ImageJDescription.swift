public import MancoraCore

/// The `key=value` metadata ImageJ writes into a TIFF's ImageDescription,
/// e.g. `ImageJ=1.54p\nimages=24\nchannels=2\nslices=3\nframes=4\n…`.
///
/// It's parsed as a Java properties file, as ImageJ does, so escapes such as
/// `µm` (µm) decode correctly.
public struct ImageJDescription: Sendable, Equatable {
    public let properties: [String: String]

    /// Parses `text`, or returns `nil` if it wasn't written by ImageJ.
    public init?(_ text: String) {
        guard text.hasPrefix("ImageJ") else { return nil }
        properties = Self.parseProperties(text)
    }

    public var version: String? { properties["ImageJ"] }
    public var images: Int? { int("images") }
    public var channels: Int? { int("channels") }
    public var slices: Int? { int("slices") }
    public var frames: Int? { int("frames") }
    public var isHyperstack: Bool { properties["hyperstack"] == "true" }
    public var unit: String? { properties["unit"] }
    public var spacing: Double? { double("spacing") }
    public var frameInterval: Double? { double("finterval") }
    public var timeUnit: String? { properties["tunit"] }
    public var xOrigin: Double? { double("xorigin") }
    public var yOrigin: Double? { double("yorigin") }
    public var zOrigin: Double? { double("zorigin") }
    public var invertY: Bool { properties["inverty"] == "true" }
    public var loop: Bool { properties["loop"] == "true" }

    /// The saved display range, unless both ends are 0 (ImageJ's "unset").
    public var displayRange: ClosedRange<Double>? {
        guard let lo = double("min"), let hi = double("max"), !(lo == 0 && hi == 0), lo <= hi else { return nil }
        return lo...hi
    }

    public var compositeMode: CompositeMode? {
        switch properties["mode"] {
        case "composite": .composite
        case "color": .color
        case "gray", "grayscale": .grayscale
        default: nil
        }
    }

    private func int(_ key: String) -> Int? {
        guard let v = double(key), v.isFinite, abs(v) < Double(Int32.max) else { return nil }
        return Int(v)
    }

    private func double(_ key: String) -> Double? {
        properties[key].flatMap { Double($0.trimmingWhitespace()) }
    }

    /// A subset of `java.util.Properties.load`: `key=value`, `key:value` and
    /// `key value` lines; `#`/`!` comments; `\uXXXX`, `\t`, `\n`, `\r`, `\f`
    /// and `\\` escapes; trailing-backslash line continuations.
    static func parseProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var logical: [Character] = []
        var lines: [[Character]] = []
        let chars = Array(text)
        var i = 0
        // Join continuation lines first.
        while i <= chars.count {
            let atEnd = i == chars.count
            let c: Character = atEnd ? "\n" : chars[i]
            if c == "\n" || c == "\r" || c == "\r\n" {
                var backslashes = 0
                var k = logical.count - 1
                while k >= 0, logical[k] == "\\" {
                    backslashes += 1
                    k -= 1
                }
                if backslashes % 2 == 1, !atEnd {
                    logical.removeLast()
                    i += 1
                    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
                    continue
                }
                lines.append(logical)
                logical = []
            } else {
                logical.append(c)
            }
            i += 1
        }

        for line in lines {
            var s = line[...]
            while let f = s.first, f == " " || f == "\t" || f == "\u{0C}" { s.removeFirst() }
            guard let first = s.first, first != "#", first != "!" else { continue }
            var key: [Character] = []
            var j = s.startIndex
            var escaped = false
            while j < s.endIndex {
                let c = s[j]
                if escaped {
                    key.append("\\")
                    key.append(c)
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "=" || c == ":" || c == " " || c == "\t" {
                    break
                } else {
                    key.append(c)
                }
                j = s.index(after: j)
            }
            // Skip the separator and surrounding whitespace.
            while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
            if j < s.endIndex, s[j] == "=" || s[j] == ":" { j = s.index(after: j) }
            while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
            result[unescape(key[...])] = unescape(s[j...])
        }
        return result
    }

    private static func unescape(_ s: ArraySlice<Character>) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            i += 1
            guard c == "\\", i < s.endIndex else {
                out.append(c)
                continue
            }
            let e = s[i]
            i += 1
            switch e {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "f": out.append("\u{0C}")
            case "u":
                let hex = String(s[i..<min(i + 4, s.endIndex)])
                if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(scalar)
                    i += 4
                } else {
                    out.append("u")
                }
            default: out.append(e)
            }
        }
        return out
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }
}
