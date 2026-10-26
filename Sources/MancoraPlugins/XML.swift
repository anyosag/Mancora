/// The XML Fiji's update sites are written in, read and written as the
/// updater's Java XML stack does it.
///
/// Reading reports what a namespace-aware, non-validating SAX parser
/// (Xerces, as in the JDK) reports to the updater's handler: start and end
/// tags with their attributes, and character data, without the whitespace
/// an internal DTD makes ignorable (whitespace between elements whose
/// declared content is only other elements). The updater's db.xml.gz
/// files carry such a DTD, and the updater keeps every character it is
/// given, so this decides what a description reads.
public enum XML {
    public enum Event: Equatable, Sendable {
        case start(name: String, attributes: [(name: String, value: String)])
        case end(name: String)
        case text(String)

        public static func == (a: Event, b: Event) -> Bool {
            switch (a, b) {
            case let (.start(n1, a1), .start(n2, a2)):
                n1 == n2 && a1.count == a2.count && zip(a1, a2).allSatisfy { $0.name == $1.name && $0.value == $1.value }
            case let (.end(n1), .end(n2)): n1 == n2
            case let (.text(t1), .text(t2)): t1 == t2
            default: false
            }
        }
    }

    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public let line: Int
        public var description: String { "XML error on line \(line): \(message)" }
    }

    /// The events in a document, in order. Adjacent character data is
    /// reported as one `.text`.
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> [Event] {
        var parser = Parser(decode(bytes))
        return try parser.document()
    }

    /// UTF-8 (with or without a byte order mark), or Latin-1 when the
    /// declaration says so; line ends normalized to \n as XML requires.
    static func decode(_ bytes: [UInt8]) -> [Unicode.Scalar] {
        var body = bytes[...]
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        let head = String(decoding: body.prefix(100), as: UTF8.self).lowercased()
        let latin1 = head.hasPrefix("<?xml") && (head.contains("iso-8859-1") || head.contains("latin1"))
        let scalars: [Unicode.Scalar] =
            latin1 ? body.map { Unicode.Scalar($0) } : Array(String(decoding: body, as: UTF8.self).unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\r" {
                out.append("\n")
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var p = 0
        var events: [Event] = []
        /// Elements the DTD declares with element content (`(a, b*)`, no #PCDATA).
        var elementOnly: Set<String> = []
        var entities: [String: String] = [:]
        var open: [String] = []
        var pendingText = ""

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        var line: Int { s[..<min(p, s.count)].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } }

        func fail(_ message: String) -> ParseError { ParseError(message: message, line: line) }

        func peek(_ literal: String) -> Bool {
            var i = p
            for c in literal.unicodeScalars {
                guard i < s.count, s[i] == c else { return false }
                i += 1
            }
            return true
        }

        mutating func expect(_ literal: String) throws(ParseError) {
            guard peek(literal) else { throw fail("expected \"\(literal)\"") }
            p += literal.unicodeScalars.count
        }

        static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }

        mutating func skipSpace() {
            while p < s.count, Self.isSpace(s[p]) { p += 1 }
        }

        static func isNameChar(_ c: Unicode.Scalar) -> Bool {
            switch c {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ":", "-", ".": true
            default: c.value >= 0xB7
            }
        }

        mutating func name() throws(ParseError) -> String {
            let start = p
            while p < s.count, Self.isNameChar(s[p]) { p += 1 }
            guard p > start else { throw fail("expected a name") }
            var out = ""
            out.unicodeScalars.append(contentsOf: s[start..<p])
            return out
        }

        /// The text up to `terminator`, which is consumed.
        mutating func until(_ terminator: String) throws(ParseError) -> String {
            let start = p
            while p < s.count, !peek(terminator) { p += 1 }
            guard p < s.count else { throw fail("unterminated construct, expected \"\(terminator)\"") }
            var out = ""
            out.unicodeScalars.append(contentsOf: s[start..<p])
            p += terminator.unicodeScalars.count
            return out
        }

        mutating func document() throws(ParseError) -> [Event] {
            if peek("<?xml") {
                p += 5
                _ = try until("?>")
            }
            try misc()
            if peek("<!DOCTYPE") {
                try doctype()
                try misc()
            }
            guard peek("<") else { throw fail("no root element") }
            try element()
            try misc()
            guard p >= s.count else { throw fail("content is not allowed after the root element") }
            return events
        }

        /// Comments, processing instructions and whitespace outside the root.
        mutating func misc() throws(ParseError) {
            while true {
                skipSpace()
                if peek("<!--") {
                    try comment()
                } else if peek("<?") {
                    try processingInstruction()
                } else {
                    return
                }
            }
        }

        mutating func comment() throws(ParseError) {
            p += 4
            let body = try until("-->")
            if body.contains("--") || body.hasSuffix("-") { throw fail("\"--\" is not permitted within comments") }
        }

        mutating func processingInstruction() throws(ParseError) {
            p += 2
            let target = try name()
            if target.lowercased() == "xml" { throw fail("an XML declaration must come first") }
            _ = try until("?>")
        }

        /// `<!DOCTYPE name [internal subset]>`: element declarations decide
        /// which whitespace is ignorable; general entities are kept.
        mutating func doctype() throws(ParseError) {
            p += 9
            skipSpace()
            _ = try name()
            skipSpace()
            if peek("SYSTEM") || peek("PUBLIC") {
                throw fail("external DTDs are not supported")
            }
            if peek("[") {
                p += 1
                while true {
                    skipSpace()
                    if peek("]") {
                        p += 1
                        break
                    } else if peek("<!--") {
                        try comment()
                    } else if peek("<?") {
                        try processingInstruction()
                    } else if peek("<!ELEMENT") {
                        p += 9
                        skipSpace()
                        let element = try name()
                        let spec = try declarationBody()
                        let content = spec.trimmingSpaces()
                        if content.hasPrefix("(") && !content.contains("#PCDATA") { elementOnly.insert(element) }
                    } else if peek("<!ENTITY") {
                        p += 8
                        skipSpace()
                        let parameter = peek("%")
                        if parameter {
                            p += 1
                            skipSpace()
                        }
                        let entity = try name()
                        skipSpace()
                        let quote = p < s.count ? s[p] : " "
                        guard quote == "\"" || quote == "'" else { throw fail("only internal entities are supported") }
                        p += 1
                        let value = try until(String(quote))
                        _ = try declarationBody()
                        if !parameter { entities[entity] = value }
                    } else if peek("<!") {
                        p += 2
                        _ = try declarationBody()
                    } else {
                        throw fail("unexpected content in the DTD")
                    }
                }
                skipSpace()
            }
            try expect(">")
        }

        /// The rest of a markup declaration, up to its `>` (quoted strings may hold `>`).
        mutating func declarationBody() throws(ParseError) -> String {
            var out = ""
            while p < s.count {
                let c = s[p]
                if c == ">" {
                    p += 1
                    return out
                }
                if c == "\"" || c == "'" {
                    p += 1
                    out += "\"" + (try until(String(c))) + "\""
                    continue
                }
                out.unicodeScalars.append(c)
                p += 1
            }
            throw fail("unterminated declaration")
        }

        mutating func element() throws(ParseError) {
            try expect("<")
            let qName = try name()
            var attributes: [(name: String, value: String)] = []
            while true {
                let hadSpace = p < s.count && Self.isSpace(s[p])
                skipSpace()
                if peek("/>") || peek(">") { break }
                guard hadSpace else { throw fail("attributes must be separated by whitespace") }
                let attribute = try name()
                skipSpace()
                try expect("=")
                skipSpace()
                let value = try attributeValue()
                if attributes.contains(where: { $0.name == attribute }) {
                    throw fail("attribute \"\(attribute)\" was already specified for element \"\(qName)\"")
                }
                attributes.append((attribute, value))
            }
            let local = Self.localName(qName)
            // As SAX reports them with namespace-prefixes off: no xmlns declarations.
            let reported = attributes.filter { $0.name != "xmlns" && !$0.name.hasPrefix("xmlns:") }
            flushText()
            events.append(.start(name: local, attributes: reported.map { (Self.localName($0.name), $0.value) }))
            if peek("/>") {
                p += 2
                events.append(.end(name: local))
                return
            }
            p += 1
            open.append(qName)
            try content(ofElement: qName)
            open.removeLast()
            flushText()
            events.append(.end(name: local))
        }

        static func localName(_ qName: String) -> String {
            guard let colon = qName.lastIndex(of: ":") else { return qName }
            return String(qName[qName.index(after: colon)...])
        }

        mutating func attributeValue() throws(ParseError) -> String {
            guard p < s.count, s[p] == "\"" || s[p] == "'" else { throw fail("attribute values must be quoted") }
            let quote = s[p]
            p += 1
            var value = ""
            while true {
                guard p < s.count else { throw fail("unterminated attribute value") }
                let c = s[p]
                if c == quote {
                    p += 1
                    return value
                }
                if c == "<" { throw fail("attribute values must not contain '<'") }
                if c == "&" {
                    value += try reference(inAttribute: true).text
                    continue
                }
                // Attribute-value normalization: literal whitespace becomes a space.
                value.unicodeScalars.append(c == "\n" || c == "\t" ? " " : c)
                p += 1
            }
        }

        /// A character or entity reference at `&`.
        mutating func reference(inAttribute: Bool) throws(ParseError) -> (text: String, isCharacter: Bool) {
            p += 1
            if peek("#") {
                p += 1
                let hex = peek("x")
                if hex { p += 1 }
                let digits = try until(";")
                guard let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value),
                    Self.isXMLChar(scalar)
                else { throw fail("character reference \"&#\(hex ? "x" : "")\(digits)\" is an invalid XML character") }
                return (String(Character(scalar)), true)
            }
            let entity = try name()
            try expect(";")
            switch entity {
            case "lt": return ("<", false)
            case "gt": return (">", false)
            case "amp": return ("&", false)
            case "apos": return ("'", false)
            case "quot": return ("\"", false)
            default:
                guard let value = entities[entity] else {
                    throw fail("the entity \"\(entity)\" was referenced, but not declared")
                }
                return (inAttribute ? value.replacingSpaces() : value, false)
            }
        }

        static func isXMLChar(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
            default: false
            }
        }

        /// Character data: in an element the DTD says holds only elements, a
        /// run of whitespace between markup is ignorable and not reported.
        mutating func addText(_ text: String, ignorableIfSpace: Bool) {
            if ignorableIfSpace, let current = open.last, elementOnly.contains(current),
                text.unicodeScalars.allSatisfy(Self.isSpace)
            {
                return
            }
            pendingText += text
        }

        mutating func flushText() {
            if !pendingText.isEmpty { events.append(.text(pendingText)) }
            pendingText = ""
        }

        mutating func content(ofElement current: String) throws(ParseError) {
            var run = ""
            func flushRun(_ parser: inout Parser) {
                if !run.isEmpty { parser.addText(run, ignorableIfSpace: true) }
                run = ""
            }
            while true {
                guard p < s.count else { throw fail("element \"\(current)\" is not closed") }
                let c = s[p]
                if c == "<" {
                    flushRun(&self)
                    if peek("</") {
                        p += 2
                        let closing = try name()
                        guard closing == current else {
                            throw fail("element \"\(current)\" must be closed by \"</\(current)>\", not \"</\(closing)>\"")
                        }
                        skipSpace()
                        try expect(">")
                        return
                    } else if peek("<!--") {
                        try comment()
                    } else if peek("<![CDATA[") {
                        p += 9
                        addText(try until("]]>"), ignorableIfSpace: false)
                    } else if peek("<?") {
                        try processingInstruction()
                    } else {
                        try element()
                    }
                } else if c == "&" {
                    flushRun(&self)
                    let (text, isCharacter) = try reference(inAttribute: false)
                    addText(text, ignorableIfSpace: isCharacter)
                } else {
                    if c == "]", peek("]]>") { throw fail("\"]]>\" must not appear in content") }
                    guard Self.isXMLChar(c) else { throw fail("an invalid XML character (U+\(String(c.value, radix: 16))) is in the content") }
                    run.unicodeScalars.append(c)
                    p += 1
                }
            }
        }
    }
}

extension String {
    fileprivate func trimmingSpaces() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !XML.Parser.isSpace($0) }),
            let last = scalars.lastIndex(where: { !XML.Parser.isSpace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    fileprivate func replacingSpaces() -> String {
        String(String.UnicodeScalarView(unicodeScalars.map { $0 == "\n" || $0 == "\t" ? " " : $0 }))
    }
}

/// Writes XML as the JDK's `TransformerHandler` serializes SAX events with
/// `indent=yes` and an indent of 4, which is how the updater writes its
/// db.xml.gz: elements each on their own line, text inline, empty
/// elements as `<name/>`.
public struct XMLWriter {
    public private(set) var bytes: [UInt8] = Array(#"<?xml version="1.0" encoding="UTF-8"?>"#.utf8)
    private var depth = 0
    private var startTagOpen = false
    /// Per open element: whether it has child elements (its end tag goes on its own line).
    private var hasChildElements: [Bool] = []
    private var hasText: [Bool] = []
    private var first = true

    public init() {}

    public mutating func raw(_ text: String) { bytes += Array(text.utf8) }

    public mutating func start(_ name: String, _ attributes: [(String, String)] = []) {
        closeStartTag()
        if !hasChildElements.isEmpty { hasChildElements[hasChildElements.count - 1] = true }
        let afterText = hasText.last ?? false
        if !first && !afterText {
            bytes.append(0x0A)
            bytes += Array(repeating: 0x20, count: 4 * depth)
        }
        first = false
        bytes += Array("<\(name)".utf8)
        for (key, value) in attributes {
            bytes += Array(" \(key)=\"".utf8)
            Self.escapeAttribute(value, into: &bytes)
            bytes.append(0x22)
        }
        startTagOpen = true
        depth += 1
        hasChildElements.append(false)
        hasText.append(false)
    }

    public mutating func text(_ text: String) {
        guard !text.isEmpty else { return }
        closeStartTag()
        hasText[hasText.count - 1] = true
        Self.escapeText(text, into: &bytes)
    }

    public mutating func end(_ name: String) {
        depth -= 1
        let children = hasChildElements.removeLast()
        let text = hasText.removeLast()
        if startTagOpen {
            bytes += Array("/>".utf8)
            startTagOpen = false
            return
        }
        if children && !text {
            bytes.append(0x0A)
            bytes += Array(repeating: 0x20, count: 4 * depth)
        }
        bytes += Array("</\(name)>".utf8)
    }

    /// A simple element: `<name attributes>text</name>`, or `<name attributes/>`.
    public mutating func element(_ name: String, _ attributes: [(String, String)] = [], text: String? = nil) {
        start(name, attributes)
        if let text { self.text(text) }
        end(name)
    }

    public mutating func endDocument() { bytes.append(0x0A) }

    private mutating func closeStartTag() {
        if startTagOpen {
            bytes.append(0x3E)
            startTagOpen = false
        }
    }

    static func escapeAttribute(_ s: String, into out: inout [UInt8]) {
        for c in s.unicodeScalars {
            switch c {
            case "&": out += Array("&amp;".utf8)
            case "<": out += Array("&lt;".utf8)
            case ">": out += Array("&gt;".utf8)
            case "\"": out += Array("&quot;".utf8)
            case "\n": out += Array("&#10;".utf8)
            case "\t": out += Array("&#9;".utf8)
            case "\r": out += Array("&#13;".utf8)
            default:
                if c.value < 0x20 || c.value > 0xFFFF {
                    out += Array("&#\(c.value);".utf8)
                } else {
                    out += Array(String(Character(c)).utf8)
                }
            }
        }
    }

    static func escapeText(_ s: String, into out: inout [UInt8]) {
        for c in s.unicodeScalars {
            switch c {
            case "&": out += Array("&amp;".utf8)
            case "<": out += Array("&lt;".utf8)
            case ">": out += Array("&gt;".utf8)
            case "\r": out += Array("&#13;".utf8)
            case "\n", "\t": out.append(UInt8(c.value))
            default:
                if c.value < 0x20 || (0x7F...0x9F).contains(c.value) || c.value > 0xFFFF {
                    out += Array("&#\(c.value);".utf8)
                } else {
                    out += Array(String(Character(c)).utf8)
                }
            }
        }
    }
}
