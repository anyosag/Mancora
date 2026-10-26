// A port of ImageJ 1.54p's ij/macro/Tokenizer.java, with the parts of
// java.io.StreamTokenizer it relies on: the macro language's lexical rules
// are StreamTokenizer's, quirks included (numbers parsed digit by digit,
// the character after a newline in a /* comment never ending it, Latin-1
// letters treated as white space).

/// `java.io.StreamTokenizer` as ImageJ configures it.
struct StreamTokenizer {
    static let TT_EOF = -1
    static let TT_NUMBER = -2
    static let TT_WORD = -3
    private static let NEED_CHAR = Int.max
    private static let SKIP_LF = Int.max - 1

    private static let CT_WHITESPACE: UInt8 = 1, CT_DIGIT: UInt8 = 2, CT_ALPHA: UInt8 = 4, CT_QUOTE: UInt8 = 8,
        CT_COMMENT: UInt8 = 16

    /// The character types after ImageJ's setup: the defaults (letters, digits,
    /// '.', '-', quotes, '/' comments, 0–32 white space), then '-', '/' and
    /// '.' made ordinary, '_' a word character and 128–255 white space.
    private static let ctype: [UInt8] = {
        var ct = [UInt8](repeating: 0, count: 256)
        for c in Int(ch("a"))...Int(ch("z")) { ct[c] |= CT_ALPHA }
        for c in Int(ch("A"))...Int(ch("Z")) { ct[c] |= CT_ALPHA }
        for c in (128 + 32)...255 { ct[c] |= CT_ALPHA }
        for c in 0...32 { ct[c] = CT_WHITESPACE }
        ct[Int(ch("/"))] = CT_COMMENT
        ct[Int(ch("\""))] = CT_QUOTE
        ct[Int(ch("'"))] = CT_QUOTE
        for c in Int(ch("0"))...Int(ch("9")) { ct[c] |= CT_DIGIT }
        ct[Int(ch("."))] |= CT_DIGIT
        ct[Int(ch("-"))] |= CT_DIGIT
        // ImageJ's changes.
        ct[Int(ch("-"))] = 0
        ct[Int(ch("/"))] = 0
        ct[Int(ch("."))] = 0
        ct[Int(ch("_"))] |= CT_ALPHA
        for c in 128...255 { ct[c] = CT_WHITESPACE }
        return ct
    }()

    private let input: [UInt16]
    private var position = 0
    private var peekc = NEED_CHAR
    private var pushedBack = false
    private(set) var lineno = 1
    private(set) var ttype = -4
    private(set) var sval: String?
    private(set) var nval = 0.0

    init(_ text: String) { input = Array(text.utf16) }

    private mutating func read() -> Int {
        guard position < input.count else { return -1 }
        defer { position += 1 }
        return Int(input[position])
    }

    private func type(of c: Int) -> UInt8 { c < 256 ? Self.ctype[c] : Self.CT_ALPHA }

    mutating func pushBack() {
        if ttype != -4 { pushedBack = true }
    }

    @discardableResult
    mutating func nextToken() -> Int {
        if pushedBack {
            pushedBack = false
            return ttype
        }
        sval = nil
        var c = peekc
        if c < 0 { c = Self.NEED_CHAR }
        if c == Self.SKIP_LF {
            c = read()
            if c < 0 { ttype = Self.TT_EOF; return ttype }
            if c == 10 { c = Self.NEED_CHAR }
        }
        if c == Self.NEED_CHAR {
            c = read()
            if c < 0 { ttype = Self.TT_EOF; return ttype }
        }
        ttype = c
        peekc = Self.NEED_CHAR

        var ctype = type(of: c)
        while ctype & Self.CT_WHITESPACE != 0 {
            if c == 13 {
                lineno += 1
                c = read()
                if c == 10 { c = read() }
            } else {
                if c == 10 { lineno += 1 }
                c = read()
            }
            if c < 0 { ttype = Self.TT_EOF; return ttype }
            ctype = type(of: c)
        }

        if ctype & Self.CT_DIGIT != 0 {
            var v = 0.0
            var decexp = 0
            var seendot = 0
            while true {
                if c == 46 && seendot == 0 {
                    seendot = 1
                } else if c >= 48 && c <= 57 {
                    v = v * 10 + Double(c - 48)
                    decexp += seendot
                } else {
                    break
                }
                c = read()
            }
            peekc = c
            if decexp != 0 {
                var denom = 10.0
                decexp -= 1
                while decexp > 0 {
                    denom *= 10
                    decexp -= 1
                }
                v = v / denom
            }
            nval = v
            ttype = Self.TT_NUMBER
            return ttype
        }

        if ctype & Self.CT_ALPHA != 0 {
            var buf: [UInt16] = []
            repeat {
                buf.append(UInt16(truncatingIfNeeded: c))
                c = read()
                ctype = c < 0 ? Self.CT_WHITESPACE : type(of: c)
            } while ctype & (Self.CT_ALPHA | Self.CT_DIGIT) != 0
            peekc = c
            sval = String(decoding: buf, as: UTF16.self)
            ttype = Self.TT_WORD
            return ttype
        }

        if ctype & Self.CT_QUOTE != 0 {
            ttype = c
            var buf: [UInt16] = []
            var d = read()
            while d >= 0 && d != ttype && d != 10 && d != 13 {
                if d == 92 {  // backslash
                    c = read()
                    let first = c
                    if c >= 48 && c <= 55 {
                        c = c - 48
                        var c2 = read()
                        if c2 >= 48 && c2 <= 55 {
                            c = (c << 3) + (c2 - 48)
                            c2 = read()
                            if c2 >= 48 && c2 <= 55 && first <= 51 {
                                c = (c << 3) + (c2 - 48)
                                d = read()
                            } else {
                                d = c2
                            }
                        } else {
                            d = c2
                        }
                    } else {
                        switch c {
                        case 97: c = 0x7  // a
                        case 98: c = 8  // b
                        case 102: c = 0xC  // f
                        case 110: c = 10  // n
                        case 114: c = 13  // r
                        case 116: c = 9  // t
                        case 118: c = 0xB  // v
                        default: break
                        }
                        d = read()
                    }
                } else {
                    c = d
                    d = read()
                }
                buf.append(UInt16(truncatingIfNeeded: c))
            }
            peekc = d == ttype ? Self.NEED_CHAR : d
            sval = String(decoding: buf, as: UTF16.self)
            return ttype
        }

        if c == 47 {  // '/', with slash-slash and slash-star comments on
            c = read()
            if c == 42 {
                var prevc = 0
                while true {
                    c = read()
                    if c == 47 && prevc == 42 { break }
                    if c == 13 {
                        lineno += 1
                        c = read()
                        if c == 10 { c = read() }
                    } else if c == 10 {
                        lineno += 1
                        c = read()
                    }
                    if c < 0 { ttype = Self.TT_EOF; return ttype }
                    prevc = c
                }
                return nextToken()
            } else if c == 47 {
                repeat { c = read() } while c != 10 && c != 13 && c >= 0
                peekc = c
                return nextToken()
            } else {
                peekc = c
                ttype = 47
                return ttype
            }
        }

        if ctype & Self.CT_COMMENT != 0 {
            repeat { c = read() } while c != 10 && c != 13 && c >= 0
            peekc = c
            return nextToken()
        }
        ttype = c
        return ttype
    }
}

/// Converts macro source into a ``Program``: ImageJ's `Tokenizer`.
struct Tokenizer {
    private var st = StreamTokenizer("")
    private var token = 0
    private var tokenString: String?
    private var tokenValue = 0.0
    private var pgm = Program()
    private var lineNumber = 0

    static func tokenize(_ source: String) -> Program {
        var tokenizer = Tokenizer()
        return tokenizer.tokenize(source)
    }

    mutating func tokenize(_ sourceIn: String) -> Program {
        var source = sourceIn
        if source.contains("/*") && source.contains("*/") { source = Self.addSpacesToEmptyLines(source) }
        st = StreamTokenizer(source)
        pgm = Program()
        repeat {
            getToken()
            addToken()
        } while token != EOF
        if pgm.hasFunctions { addUserFunctions() }
        pgm.finish()
        return pgm
    }

    private mutating func getToken() {
        token = st.nextToken()
        lineNumber = st.lineno
        var ret: String?
        switch st.ttype {
        case StreamTokenizer.TT_EOF:
            ret = "EOF"
            token = EOF
        case StreamTokenizer.TT_WORD:
            ret = st.sval
            token = WORD
        case StreamTokenizer.TT_NUMBER:
            ret = javaString(st.nval)
            tokenValue = st.nval
            if tokenValue == 0.0 {
                tokenValue = getHexConstant()
            } else if tryScientificNotation() {
                ret = (ret ?? "") + (st.sval ?? "null")
            }
            token = NUMBER
        case 34, 39:  // '"', '\''
            ret = st.sval ?? "null"
            token = STRING_CONSTANT
        case 43:  // +
            let next = st.nextToken()
            if next == 43 { token = PLUS_PLUS } else if next == 61 { token = PLUS_EQUAL } else { st.pushBack() }
        case 45:  // -
            let next = st.nextToken()
            if next == 45 { token = MINUS_MINUS } else if next == 61 { token = MINUS_EQUAL } else { st.pushBack() }
        case 42:  // *
            if st.nextToken() == 61 { token = MUL_EQUAL } else { st.pushBack() }
        case 47:  // /
            if st.nextToken() == 61 { token = DIV_EQUAL } else { st.pushBack() }
        case 61:  // =
            if st.nextToken() == 61 { token = EQ } else { st.pushBack() }
        case 33:  // !
            if st.nextToken() == 61 { token = NEQ } else { st.pushBack() }
        case 62:  // >
            let next = st.nextToken()
            if next == 61 {
                token = GTE
            } else if next == 62 {
                token = SHIFT_RIGHT
            } else {
                st.pushBack()
                token = GT
            }
        case 60:  // <
            let next = st.nextToken()
            if next == 61 {
                token = LTE
            } else if next == 60 {
                token = SHIFT_LEFT
            } else {
                st.pushBack()
                token = LT
            }
        case 38:  // &
            if st.nextToken() == 38 { token = LOGICAL_AND } else { st.pushBack() }
        case 124:  // |
            if st.nextToken() == 124 { token = LOGICAL_OR } else { st.pushBack() }
        default:
            break
        }
        tokenString = ret
    }

    private mutating func addToken() {
        var tok = token
        switch token {
        case WORD:
            let word = tokenString ?? ""
            if let loc = pgm.lookupWord(word) {
                let symbol = pgm.table[loc]
                let type = symbol.functionType
                if type == 0 {
                    tok = symbol.type
                    switch tok {
                    case FUNCTION: pgm.hasFunctions = true
                    case VAR: pgm.hasVars = true
                    case MACRO: pgm.macroCount += 1
                    default: break
                    }
                } else {
                    tok = type
                }
                tok += loc << TOK_SHIFT
            } else {
                pgm.addSymbol(Symbol(token: token, str: word))
                tok += pgm.stLoc << TOK_SHIFT
            }
        case STRING_CONSTANT:
            pgm.addSymbol(Symbol(token: token, str: tokenString))
            tok += pgm.stLoc << TOK_SHIFT
        case NUMBER:
            pgm.addSymbol(Symbol(value: tokenValue))
            tok += pgm.stLoc << TOK_SHIFT
        default:
            break
        }
        pgm.addToken(tok, lineNumber: lineNumber)
    }

    private mutating func getHexConstant() -> Double {
        token = st.nextToken()
        guard st.ttype == StreamTokenizer.TT_WORD, let sval = st.sval, sval.hasPrefix("x") else {
            st.pushBack()
            return 0
        }
        // Long.parseLong(s, 16)
        let digits = String(sval.dropFirst())
        guard let n = javaParseLong(digits, radix: 16) else {
            st.pushBack()
            return 0
        }
        return Double(n)
    }

    private mutating func tryScientificNotation() -> Bool {
        let sval = javaString(tokenValue)
        st.nextToken()
        guard st.ttype == StreamTokenizer.TT_WORD, var sval2 = st.sval, sval2.hasPrefix("e") || sval2.hasPrefix("E")
        else {
            st.pushBack()
            return false
        }
        // From here on, Java's catch(Exception) returns false without pushing back.
        if sval2.lowercased() == "e" {
            let next = st.nextToken()
            if next == 45 {
                sval2 += "-"
            } else if next != 43 {
                return false
            }
            if st.nextToken() != StreamTokenizer.TT_NUMBER { return false }
            sval2 += javaString(st.nval)
        }
        if sval2.hasSuffix(".0") { sval2.removeLast(2) }
        guard let value = javaParseDouble(sval + sval2) else { return false }
        tokenValue = value
        return true
    }

    /// Adds user-defined functions to the symbol table.
    private mutating func addUserFunctions() {
        let code = pgm.code
        var i = 0
        while i < code.count {
            token = code[i] & TOK_MASK
            if token == FUNCTION {
                let nextToken = code[i + 1] & TOK_MASK
                if nextToken == WORD || (nextToken >= PREDEFINED_FUNCTION && nextToken <= ARRAY_FUNCTION) {
                    let address = code[i + 1] >> TOK_SHIFT
                    var address2 = address
                    if nextToken != WORD {  // overrides a built-in function
                        pgm.addSymbol(Symbol(token: WORD, str: pgm.table[address].str))
                        address2 = pgm.stLoc
                        pgm.code[i + 1] = WORD + (address2 << TOK_SHIFT)
                    }
                    pgm.table[address2].type = USER_FUNCTION
                    pgm.table[address2].value = Double(i + 1)  // the function's address
                    var j = 0
                    while j < pgm.code.count {
                        let t = pgm.code[j] & TOK_MASK
                        if (t == WORD || (t >= PREDEFINED_FUNCTION && t <= ARRAY_FUNCTION))
                            && (pgm.code[j] >> TOK_SHIFT) == address && (j == 0 || (pgm.code[j - 1] & 0xfff) != FUNCTION)
                        {
                            pgm.code[j] = USER_FUNCTION + (address2 << TOK_SHIFT)
                        } else if t == EOF {
                            break
                        }
                        j += 1
                    }
                }
            } else if token == EOF {
                break
            }
            i += 1
        }
    }

    private static func addSpacesToEmptyLines(_ source: String) -> String {
        let units = Array(source.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count + 16)
        for j in 0..<(units.count - 1) {
            out.append(units[j])
            if units[j] == 10 && units[j + 1] == 10 { out.append(32) }
        }
        out.append(units[units.count - 1])
        return String(decoding: out, as: UTF16.self)
    }
}

/// `Long.parseLong(s, radix)`, or `nil` where Java throws.
func javaParseLong(_ s: String, radix: Int) -> Int64? {
    let units = Array(s.utf16)
    guard !units.isEmpty else { return nil }
    var i = 0
    var negative = false
    if units[0] == 45 || units[0] == 43 {
        negative = units[0] == 45
        i = 1
        if units.count == 1 { return nil }
    }
    var result: Int64 = 0
    while i < units.count {
        guard let digit = javaCharacterDigit(units[i], radix: radix) else { return nil }
        let (m, o1) = result.multipliedReportingOverflow(by: Int64(radix))
        if o1 { return nil }
        let (r, o2) = negative ? m.subtractingReportingOverflow(Int64(digit)) : m.addingReportingOverflow(Int64(digit))
        if o2 { return nil }
        result = r
        i += 1
    }
    return result
}
