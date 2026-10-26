// A port of ImageJ 1.54p's ij/macro/Program.java and Symbol.java.

/// An entry in the symbol table: a keyword, built-in function, word, string
/// constant or number.
struct Symbol: Sendable {
    var type: Int
    var value: Double
    var str: String?

    init(token: Int, str: String?) {
        type = token & 0xffff
        value = 0
        self.str = str
    }

    init(value: Double) {
        type = 0
        self.value = value
        str = nil
    }

    /// `getFunctionType()`: which kind of built-in function the symbol is, or 0.
    var functionType: Int {
        switch type {
        case 300..<1000: PREDEFINED_FUNCTION
        case 1000..<2000: NUMERIC_FUNCTION
        case 2000..<3000: STRING_FUNCTION
        case 3000..<4000: ARRAY_FUNCTION
        case 4000..<5000: VARIABLE_FUNCTION
        default: 0
        }
    }
}

/// A tokenized macro and its symbol table.
final class Program {
    /// Keywords and built-in functions, in ImageJ's order: every program's table starts with them.
    static let systemTable: [Symbol] = {
        var table: [Symbol] = []
        for list in [keywords, functions, numericFunctions, stringFunctions, arrayFunctions, variableFunctions] {
            for (name, id) in list { table.append(Symbol(token: id, str: name)) }
        }
        return table
    }()
    private static let systemWords: [String: Int] = {
        var words: [String: Int] = [:]
        for (i, symbol) in systemTable.enumerated() where words[symbol.str!] == nil { words[symbol.str!] = i }
        return words
    }()

    var table: [Symbol]
    /// The tokens, each with its symbol table address above `TOK_SHIFT`. Java's
    /// array is larger than the program and zero beyond it; the interpreter's
    /// lookahead relies on that, so `finish()` pads it.
    var code: [Int] = []
    var lineNumbers: [Int] = []
    var globals: [Variable]?
    var hasVars = false
    var hasFunctions = false
    var macroCount = 0
    /// The address of the last symbol.
    var stLoc: Int { table.count - 1 }
    /// Words added by this program, for `lookupWord`.
    private var words: [String: Int] = [:]
    /// The index of the last token (EOF).
    private(set) var pc = -1

    init() {
        table = Self.systemTable
    }

    func addSymbol(_ symbol: Symbol) {
        table.append(symbol)
        if symbol.type != STRING_CONSTANT, let str = symbol.str, words[str] == nil, Self.systemWords[str] == nil {
            words[str] = table.count - 1
        }
    }

    func addToken(_ token: Int, lineNumber: Int) {
        pc += 1
        code.append(token)
        lineNumbers.append(lineNumber)
    }

    /// Pads the code with zeros, as Java's oversized array is.
    func finish() {
        code.append(contentsOf: repeatElement(0, count: 16))
        lineNumbers.append(contentsOf: repeatElement(lineNumbers.last ?? 0, count: 16))
    }

    /// The address of the first symbol (other than a string constant) for `word`.
    func lookupWord(_ word: String) -> Int? {
        Self.systemWords[word] ?? words[word]
    }

    func saveGlobals(_ interp: Interpreter) {
        if interp.topOfStack == -1 { return }
        globals = Array(interp.stack[0...interp.topOfStack])
    }

    /// The number of tokens before EOF (Java's `getSize()`).
    var size: Int { pc }

    func decodeToken(_ token: Int) -> String {
        decodeToken(token & TOK_MASK, token >> TOK_SHIFT)
    }

    func decodeToken(_ token: Int, _ address: Int) -> String {
        switch token {
        case WORD, PREDEFINED_FUNCTION, NUMERIC_FUNCTION, STRING_FUNCTION, ARRAY_FUNCTION, VARIABLE_FUNCTION,
            USER_FUNCTION:
            return table[address].str ?? "null"
        case STRING_CONSTANT:
            return "\"" + (table[address].str ?? "null") + "\""
        case NUMBER:
            let v = table[address].value
            return Double(jInt(v)) == v ? ImageJFormat.d2s(v, 0) : javaString(v)
        case EOF:
            return "EOF"
        default:
            if token < 32 {
                switch token {
                case PLUS_PLUS: return "++"
                case MINUS_MINUS: return "--"
                case PLUS_EQUAL: return "+="
                case MINUS_EQUAL: return "-="
                case MUL_EQUAL: return "*="
                case DIV_EQUAL: return "/="
                case LOGICAL_AND: return "&&"
                case LOGICAL_OR: return "||"
                case EQ: return "=="
                case NEQ: return "!="
                case GT: return ">"
                case GTE: return ">="
                case LT: return "<"
                case LTE: return "<="
                default: return ""
                }
            } else if token >= 200 {
                return table[address].str ?? "null"
            } else {
                return String(decoding: [UInt16(token)], as: UTF16.self)
            }
        }
    }

    /// Whether `word` appears in the program.
    func hasWord(_ word: String) -> Bool {
        for token in code {
            if token <= 127 { continue }
            if token == EOF { return false }
            if table[token >> TOK_SHIFT].str == word { return true }
        }
        return false
    }
}
