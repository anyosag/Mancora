/// An ImageJ command's options string, as macros pass it to `run()` and the
/// recorder writes it: `"sigma=2 stack"`, `"projection=[Max Intensity] all"`.
///
/// Lookups follow ImageJ exactly: `ij.Macro.getValue` for values and
/// `GenericDialog.isMatch` for checkboxes, with dialog labels reduced to
/// keys by `Macro.trimKey` (first word, before any colon, lowercased).
public struct MacroOptions: Sendable, Hashable, CustomStringConvertible {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var description: String { text }

    /// `Macro.trimKey`: `"Sigma (Radius):"` → `"sigma"`.
    public static func key(forLabel label: String) -> String {
        var key = Substring(label)
        if let space = key.firstIndex(of: " ") { key = key[..<space] }
        if let colon = key.firstIndex(of: ":") { key = key[..<colon] }
        return key.lowercased()
    }

    /// The value for a dialog field, or `nil` when the options don't set it
    /// (`Macro.getValue`): `key=value`, `key=[value with spaces]` (brackets
    /// nest) or `key='value'`, with `key` not preceded by a letter.
    public func value(forLabel label: String) -> String? {
        let key = Array(Self.key(forLabel: label) + "=")
        var chars = Array(text)
        if chars.last != " " { chars.append(" ") }
        var start = 0
        var found: Int?
        while start + key.count <= chars.count {
            guard let index = Self.find(key, in: chars, from: start) else { return nil }
            if index == 0 || !chars[index - 1].isLetter {
                found = index
                break
            }
            start = index + 1
        }
        guard let at = found else { return nil }
        let rest = chars[(at + key.count)...]
        guard let first = rest.first else { return nil }
        if first == "'" {
            guard let close = rest.dropFirst().firstIndex(of: "'") else { return nil }
            return String(rest[(rest.startIndex + 1)..<close])
        }
        if first == "[" {
            var depth = 1
            for i in (rest.startIndex + 1)..<rest.endIndex {
                if rest[i] == "[" { depth += 1 } else if rest[i] == "]" { depth -= 1 }
                if depth == 0 { return String(rest[(rest.startIndex + 1)..<i]) }
            }
            return nil
        }
        guard let space = rest.firstIndex(of: " ") else { return nil }
        return String(rest[rest.startIndex..<space])
    }

    /// A numeric field: the value parsed as ImageJ's `Tools.parseDouble`
    /// would, or `defaultValue` if absent or not a number.
    public func number(forLabel label: String, default defaultValue: Double) -> Double {
        value(forLabel: label).flatMap { Double(Self.trimmed($0)) } ?? defaultValue
    }

    static func trimmed(_ s: String) -> String {
        String(s.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }

    /// A checkbox: whether its key appears as a word outside `[literals]`
    /// and not as a value (`GenericDialog.isMatch(options, key + " ")`).
    public func flag(forLabel label: String) -> Bool {
        var options = Array(text)
        if options.last != " " { options.append(" ") }
        let word = Array(Self.key(forLabel: label) + " ")
        if options.starts(with: word) { return true }
        let needle = [" "] + word
        var inLiteral = false
        var i = 0
        while i + needle.count <= options.count {
            let c = options[i]
            if inLiteral && c == "]" {
                inLiteral = false
            } else if c == "[" {
                inLiteral = true
            }
            if c == needle[0], !inLiteral, !(i > 1 && options[i - 1] == "="),
                Array(options[i..<(i + needle.count)]) == needle
            {
                return true
            }
            i += 1
        }
        return false
    }

    private static func find(_ needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = start
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

/// Builds an options string the way ImageJ's recorder does as a dialog is
/// read: `key=value` for fields (bracketed when the value has a space) and
/// bare keys for ticked checkboxes, in dialog order.
public struct OptionsRecorder: Sendable {
    public private(set) var parts: [String] = []

    public init() {}

    /// `Recorder.recordOption(key, value)`.
    public mutating func value(_ label: String, _ value: String) {
        let quoted = value.contains(" ") ? "[" + value + "]" : value
        parts.append(MacroOptions.key(forLabel: label) + "=" + quoted)
    }

    /// `Recorder.recordOption(key)` for a ticked checkbox.
    public mutating func flag(_ label: String, _ on: Bool) {
        if on { parts.append(MacroOptions.key(forLabel: label)) }
    }

    public var options: MacroOptions { MacroOptions(parts.joined(separator: " ")) }
}
