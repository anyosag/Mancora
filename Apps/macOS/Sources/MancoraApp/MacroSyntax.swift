import Foundation

/// What the macro editor knows about ImageJ macro text: which parts are
/// comments, strings, numbers, keywords and built-in functions, and where
/// lines are. Offsets count UTF-16 units, as `NSTextView`'s ranges do, and
/// lines end with "\n", as the interpreter counts them for its errors.
enum MacroSyntax {
    enum Kind: Equatable {
        case comment, string, number, keyword, function
    }

    struct Span: Equatable {
        var range: NSRange
        var kind: Kind
    }

    /// The colored parts of `text`, in order. `keywords` and `functions` are
    /// the language's names (`MancoraMacro.vocabulary`).
    static func spans(in text: String, keywords: Set<String>, functions: Set<String>) -> [Span] {
        let u = Array(text.utf16)
        let n = u.count
        var spans: [Span] = []
        // Where the last `Math`, `Array`, `Table`… ended: its member (`Math.sqrt`) is a function too.
        var namespaceEnd = -1
        var i = 0
        func add(_ start: Int, _ end: Int, _ kind: Kind) {
            spans.append(Span(range: NSRange(location: start, length: end - start), kind: kind))
        }
        while i < n {
            let c = u[i]
            if c == slash, i + 1 < n, u[i + 1] == slash {
                // `// …` to the end of the line.
                var j = i + 2
                while j < n, u[j] != newline { j += 1 }
                add(i, j, .comment)
                i = j
            } else if c == slash, i + 1 < n, u[i + 1] == star {
                // `/* … */`, which runs to the end of the text if it isn't closed.
                var j = i + 2
                while j < n, !(u[j] == star && j + 1 < n && u[j + 1] == slash) { j += 1 }
                j = j < n ? j + 2 : n
                add(i, j, .comment)
                i = j
            } else if c == doubleQuote || c == singleQuote {
                // A string ends at its closing quote, or at the end of the line if it isn't closed.
                var j = i + 1
                while j < n, u[j] != c, u[j] != newline {
                    if u[j] == backslash, j + 1 < n, u[j + 1] != newline { j += 1 }
                    j += 1
                }
                if j < n, u[j] == c { j += 1 }
                add(i, j, .string)
                i = j
            } else if isDigit(c) || (c == dot && i + 1 < n && isDigit(u[i + 1])) {
                // 12, 1.5, .5, 1e-3, 0xFF.
                var j = i
                if c == zero, i + 1 < n, u[i + 1] == lowerX || u[i + 1] == upperX {
                    j = i + 2
                    while j < n, isHexDigit(u[j]) { j += 1 }
                } else {
                    while j < n, isDigit(u[j]) { j += 1 }
                    // A dot before a letter is a member (`1.toString`), not a fraction.
                    if j < n, u[j] == dot, j + 1 >= n || !isIdentifierStart(u[j + 1]) {
                        j += 1
                        while j < n, isDigit(u[j]) { j += 1 }
                    }
                    if j < n, u[j] == lowerE || u[j] == upperE {
                        var k = j + 1
                        if k < n, u[k] == plus || u[k] == minus { k += 1 }
                        if k < n, isDigit(u[k]) {
                            while k < n, isDigit(u[k]) { k += 1 }
                            j = k
                        }
                    }
                }
                add(i, j, .number)
                i = j
            } else if isIdentifierStart(c) {
                var j = i + 1
                while j < n, isIdentifierPart(u[j]) { j += 1 }
                let word = String(decoding: u[i..<j], as: UTF16.self)
                if i > 0, u[i - 1] == dot, i - 1 == namespaceEnd {
                    add(i, j, .function)
                } else if keywords.contains(word) {
                    add(i, j, .keyword)
                } else if functions.contains(word) {
                    add(i, j, .function)
                    if c >= upperA && c <= upperZ { namespaceEnd = j }
                }
                i = j
            } else {
                i += 1
            }
        }
        return spans
    }

    /// The 1-based line and column of the UTF-16 `offset`.
    static func position(of offset: Int, in text: String) -> (line: Int, column: Int) {
        let target = max(offset, 0)
        var line = 1
        var lineStart = 0
        var index = 0
        for unit in text.utf16 {
            if index >= target { break }
            index += 1
            if unit == newline {
                line += 1
                lineStart = index
            }
        }
        return (line, index - lineStart + 1)
    }

    /// The range of the line holding the UTF-16 `offset`, without its line end.
    static func lineRange(containing offset: Int, in text: String) -> NSRange {
        let u = Array(text.utf16)
        let at = min(max(offset, 0), u.count)
        var start = at
        while start > 0, u[start - 1] != newline { start -= 1 }
        var end = at
        while end < u.count, u[end] != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The range of line `number` (1-based), without its line end, or nil if the text has fewer lines.
    static func lineRange(ofLine number: Int, in text: String) -> NSRange? {
        guard number >= 1 else { return nil }
        let u = Array(text.utf16)
        var line = 1
        var start = 0
        var index = 0
        while index < u.count, line < number {
            if u[index] == newline {
                line += 1
                start = index + 1
            }
            index += 1
        }
        guard line == number else { return nil }
        var end = start
        while end < u.count, u[end] != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The text of `range` (UTF-16 offsets), or "" if it isn't inside `text`.
    static func substring(of text: String, in range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    // The characters the scanner looks for, as UTF-16 units.
    private static let newline: UInt16 = 10
    private static let doubleQuote: UInt16 = 34
    private static let singleQuote: UInt16 = 39
    private static let star: UInt16 = 42
    private static let plus: UInt16 = 43
    private static let minus: UInt16 = 45
    private static let dot: UInt16 = 46
    private static let slash: UInt16 = 47
    private static let zero: UInt16 = 48
    private static let upperA: UInt16 = 65
    private static let upperE: UInt16 = 69
    private static let upperX: UInt16 = 88
    private static let upperZ: UInt16 = 90
    private static let backslash: UInt16 = 92
    private static let lowerE: UInt16 = 101
    private static let lowerX: UInt16 = 120

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    private static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    }

    /// A letter or underscore; anything beyond ASCII counts, so names with accents stay whole.
    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
}
