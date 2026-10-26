// A port of ImageJ 1.54p's ij/macro/Interpreter.java: the recursive descent
// parser and interpreter of the macro language. It parses straight from the
// token stream, as ImageJ does, so that its quirks (lookahead deciding
// between string and numeric expressions, && and || evaluating both sides,
// loose semicolons outside loops) carry over.

/// A macro error, as ImageJ's "Macro Error" dialog shows it.
public struct MacroError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// The line it happened on (1-based), or 0 if it isn't known.
    public var lineNumber: Int
    /// The tokens of that line, the current one in angle brackets.
    public var line: String
    /// The lines of the user-defined function calls that led here, innermost first.
    public var calledFrom: [Int]

    public init(message: String, lineNumber: Int = 0, line: String = "", calledFrom: [Int] = []) {
        self.message = message
        self.lineNumber = lineNumber
        self.line = line
        self.calledFrom = calledFrom
    }

    /// The dialog's text.
    public var description: String {
        var text = message + (lineNumber > 0 ? " in line \(lineNumber)" : "")
        for line in calledFrom { text += "\n\t\t(called from line \(line))" }
        if !line.isEmpty { text += "\n \n" + line }
        return text
    }
}

/// How control leaves a statement other than by finishing it (Java's
/// MacroException, ReturnException and RuntimeException(MACRO_CANCELED)).
enum MacroSignal: Error, @unchecked Sendable {
    case breakLoop
    case continueLoop
    case returned(value: Double, str: String?, array: VariableArray?, arraySize: Int)
    case error(MacroError)
    /// `exit()`, or a macro aborted from outside.
    case exit(message: String?)
}

/// Runs macros. Not thread-safe: one interpreter runs one macro at a time.
public final class Interpreter {
    static let STACK_SIZE = 1000
    static let MAX_ARGS = 20

    var pc = -1
    var token = 0
    var tokenAddress = 0
    var tokenValue = 0.0
    var tokenString: String?
    var looseSyntax = true
    var lineNumber = 0
    var checkingType = false
    var prefixValue = 0
    var stack: [Variable] = []
    var topOfStack: Int {
        get { stack.count - 1 }
        set { if newValue + 1 < stack.count { stack.removeLast(stack.count - newValue - 1) } }
    }
    var topOfGlobals = -1
    var startOfLocals = 0
    var done = false
    var pgm = Program()
    var function: Functions!
    var inFunction = false
    var macroName: String?
    /// The table `Table.applyMacro` runs this macro on, row by row: title-less `Table.*` calls use it.
    var applyMacroTable: String?
    var argument: String?
    var returnValue: String?
    var calledMacro = false
    var inPrint = false
    var wasError = false
    var inLoop = false
    var loopDepth = 0
    var evaluating = false
    var errorCount = 0
    var ignoreErrors = false
    var errorMessage: String?
    var evalOutput: String?
    var callStack = [Int](repeating: 0, count: 10)
    var callDepth = 0

    /// What the macro works on: images, results, the log.
    public let session: MacroSession

    public init(session: MacroSession) {
        self.session = session
    }

    // MARK: - Running

    /// Runs `macro`, passing it `argument` (`getArgument()`), and returns
    /// the string it returns, if any.
    @discardableResult
    public func run(_ macro: String, argument: String? = nil) throws(MacroError) -> String? {
        self.argument = argument
        if argument != nil { calledMacro = true }
        let program = Tokenizer.tokenize(macro)
        do {
            if program.hasVars && program.hasFunctions { try saveGlobals2(program) }
            try run(program)
        } catch {
            try finish(error)
        }
        return returnValue
    }

    /// `Interpreter.eval(code)`: runs `code`, returning what it printed last, or the error message.
    func eval(_ code: String) -> String? {
        let program = Tokenizer.tokenize(code)
        evaluating = true
        evalOutput = nil
        ignoreErrors = true
        calledMacro = true
        do {
            if program.hasVars && program.hasFunctions { try saveGlobals2(program) }
            try run(program)
        } catch {
            if case .error(let e) = error { errorMessage = e.message }
        }
        return errorMessage ?? evalOutput
    }

    private func finish(_ signal: MacroSignal) throws(MacroError) {
        switch signal {
        case .error(let error):
            function?.finishUp()
            throw error
        case .exit(let message):
            if let message { _ = session.showMessage(title: "Macro", message) }
        case .breakLoop, .continueLoop, .returned:
            function?.finishUp()
        }
    }

    func run(_ program: Program) throws(MacroSignal) {
        pgm = program
        pc = -1
        callDepth = 0
        pushGlobals()
        if function == nil {
            function = Functions(interp: self)
        }
        done = false
        errorMessage = nil
        try doStatements()
        finishUp()
    }

    func saveGlobals2(_ program: Program) throws(MacroSignal) {
        pgm = program
        pc = -1
        function = Functions(interp: self)
        while !done {
            getToken()
            switch token {
            case VAR: try doVar()
            case MACRO: try skipMacro()
            case FUNCTION: try skipFunction()
            default: break
            }
        }
        pgm.saveGlobals(self)
        pc = -1
        topOfStack = -1
        done = false
    }

    // MARK: - Tokens

    @inline(__always) func code(_ i: Int) -> Int { i >= 0 && i < pgm.code.count ? pgm.code[i] : 0 }

    final func getToken() {
        if done { return }
        pc += 1
        token = code(pc)
        if token <= 127 { return }
        tokenAddress = token >> TOK_SHIFT
        token = token & TOK_MASK
        let sym = pgm.table[tokenAddress]
        tokenString = sym.str
        tokenValue = sym.value
        done = token == EOF
    }

    @inline(__always) final func nextToken() -> Int { code(pc + 1) & TOK_MASK }
    @inline(__always) final func nextNextToken() -> Int { code(pc + 2) & TOK_MASK }

    final func putTokenBack() {
        pc -= 1
        if pc < 0 { pc = -1 }
        if token == EOF { done = false }
    }

    // MARK: - Statements

    func doStatements() throws(MacroSignal) {
        while !done { try doStatement() }
    }

    final func doStatement() throws(MacroSignal) {
        getToken()
        switch token {
        case VAR:
            try doVar()
        case PREDEFINED_FUNCTION:
            try function.doFunction(pgm.table[tokenAddress].type)
        case USER_FUNCTION:
            _ = try runUserFunction()
        case RETURN:
            try doReturn()
        case BREAK:
            if inLoop { throw .breakLoop }
        case CONTINUE:
            if inLoop { throw .continueLoop }
        case WORD:
            if code(pc + 1) == ch(".") { try doStringFunction() } else { try doAssignment() }
        case IF:
            try doIf()
            return
        case ELSE:
            try error("Else without if")
            return
        case FOR:
            try doFor()
            return
        case WHILE:
            try doWhile()
            return
        case DO:
            try doDo()
            return
        case MACRO:
            try runFirstMacro()
            return
        case FUNCTION:
            try skipFunction()
            return
        case ch(";"):
            return
        case ch("{"):
            putTokenBack()
            try doBlock()
            return
        case NUMBER, NUMERIC_FUNCTION, STRING_FUNCTION, STRING_CONSTANT, VARIABLE_FUNCTION, ch("("):
            putTokenBack()
            inPrint = true
            let s = try getString()
            inPrint = false
            if let s, !s.isEmpty && s != "NaN" && s != "[aborted]" { log(s) }
            return
        case ARRAY_FUNCTION:
            _ = try function.getArrayFunction(pgm.table[tokenAddress].type)
        case EOF:
            break
        default:
            if evaluating && token == PI {
                putTokenBack()
                log(javaString(try getExpression()))
            } else {
                try error("Statement cannot begin with '" + pgm.decodeToken(token, tokenAddress) + "'")
            }
        }
        if !looseSyntax {
            getToken()
            if token != ch(";") && !done { try error("';' expected") }
        }
    }

    private func doStringFunction() throws(MacroSignal) {
        let stringFunction = (code(pc + 2) & 0xff) == STRING_FUNCTION
        putTokenBack()
        var s = stringFunction ? (try getString() ?? "null") : javaString(try getExpression())
        if s.hasSuffix(".0") { s.removeLast(2) }
        session.log(s)
    }

    /// Prints `s`; `IJ.log` ignores a null string.
    func log(_ s: String?) {
        if evaluating {
            evalOutput = s
        } else if let s {
            session.log(s)
        }
    }

    /// ImageJ's: it stops growing (and shrinking) at depth 9.
    private func growCallStack(_ grow: Int) {
        if callDepth < 0 || callDepth > 8 { return }
        if grow == 1 {
            callStack[callDepth] = pgm.lineNumbers[min(max(pc, 0), pgm.lineNumbers.count - 1)]
            callDepth += 1
        }
        if grow == -1 && callDepth > 0 { callDepth -= 1 }
    }

    func runUserFunction() throws(MacroSignal) -> Variable? {
        growCallStack(1)
        let newPC = Int(tokenValue)
        let saveStartOfLocals = startOfLocals
        startOfLocals = topOfStack + 1
        let saveTOS = topOfStack
        let nArgs = try pushArgs()
        let savePC = pc
        var value: Variable?
        pc = newPC
        try setupArgs(nArgs)
        let saveInFunction = inFunction
        inFunction = true
        do {
            try doBlock()
        } catch {
            guard case .returned(let v, let str, let array, let arraySize) = error else { throw error }
            value = Variable(symTabIndex: 0, value: v, str: str, array: array)
            if array != nil && arraySize != 0 { value!.setArraySize(arraySize) }
        }
        inFunction = saveInFunction
        pc = savePC
        trimStack(saveTOS, saveStartOfLocals)
        growCallStack(-1)
        return value
    }

    /// Pushes a function's arguments onto the stack.
    func pushArgs() throws(MacroSignal) -> Int {
        try getLeftParen()
        var args: [Variable] = []
        if nextToken() != ch(")") {
            repeat {
                if args.count == Self.MAX_ARGS { try error("Too many arguments") }
                let next = nextToken()
                let nextPlus = code(pc + 2) & 0xff
                if next == STRING_CONSTANT || next == STRING_FUNCTION {
                    args.append(Variable(symTabIndex: 0, value: 0, str: try getString()))
                } else if next == USER_FUNCTION {
                    let savePC = pc
                    getToken()  // the function
                    let simpleFunctionCall = try isSimpleFunctionCall(assignment: false)
                    pc = savePC
                    if simpleFunctionCall {
                        getToken()
                        guard let v2 = try runUserFunction() else { try fail("No return value") }
                        args.append(v2)
                    } else {
                        args.append(Variable(symTabIndex: 0, value: try getExpression(), str: nil))
                    }
                } else if next == WORD && (nextPlus == ch(",") || nextPlus == ch(")")) {
                    var value = 0.0
                    var array: VariableArray?
                    var arraySize = 0
                    var str: String?
                    getToken()
                    if let v = try lookupVariable() {
                        switch v.kind {
                        case .value: value = v.getValue()
                        case .array:
                            array = v.getArray()
                            arraySize = v.getArraySize()
                        case .string: str = v.getString()
                        }
                    }
                    let arg = Variable(symTabIndex: 0, value: value, str: str, array: array)
                    if array != nil { arg.setArraySize(arraySize) }
                    args.append(arg)
                } else if next == WORD && nextPlus == ch("[") {
                    let savePC = pc
                    getToken()
                    let v = try getArrayElement(try lookupVariable())
                    if let s = v.getString() {
                        args.append(Variable(symTabIndex: 0, value: 0, str: s))
                    } else {
                        pc = savePC
                        args.append(Variable(symTabIndex: 0, value: try getExpression(), str: nil))
                    }
                } else if next == WORD && nextPlus == ch(".") {  // s.length, s.substring() etc.
                    let stringFunction = (code(pc + 3) & 0xff) == STRING_FUNCTION
                    if stringFunction {
                        args.append(Variable(symTabIndex: 0, value: 0, str: try function.getString()))
                    } else {
                        args.append(Variable(symTabIndex: 0, value: try getExpression(), str: nil))
                    }
                } else if nextPlus == ch("+") && next == WORD {
                    let savePC = pc
                    getToken()
                    let v = try lookupVariable()
                    let isString = v?.kind == .string
                    pc = savePC
                    if isString {
                        args.append(Variable(symTabIndex: 0, value: 0, str: try getString()))
                    } else {
                        args.append(Variable(symTabIndex: 0, value: try getExpression(), str: nil))
                    }
                } else if next == ARRAY_FUNCTION {
                    getToken()
                    let array = try function.getArrayFunction(pgm.table[tokenAddress].type)
                    args.append(Variable(symTabIndex: 0, value: 0, str: nil, array: array))
                } else {
                    args.append(Variable(symTabIndex: 0, value: try getExpression(), str: nil))
                }
                getToken()
            } while token == ch(",")
            putTokenBack()
        }
        let nArgs = args.count
        for arg in args.reversed() { try push(arg) }
        try getRightParen()
        return nArgs
    }

    func setupArgs(_ nArgs: Int) throws(MacroSignal) {
        try getLeftParen()
        var i = topOfStack
        var count = nArgs
        if nextToken() != ch(")") {
            repeat {
                getToken()
                if i >= 0 { stack[i].symTabIndex = tokenAddress }
                i -= 1
                count -= 1
                getToken()
            } while token == ch(",")
            putTokenBack()
        }
        if count != 0 { try error("\(nArgs) argument" + (nArgs == 1 ? "" : "s") + " expected") }
        try getRightParen()
    }

    func doReturn() throws(MacroSignal) {
        var value = 0.0
        var str: String?
        var array: VariableArray?
        var arraySize = 0
        getToken()
        if token == ch("(") {
            let next = code(pc + 1)
            if (next & TOK_MASK) == STRING_CONSTANT || (next & TOK_MASK) == STRING_FUNCTION || isString(pc + 1) {
                try error("String enclosed in parens")
            }
        }
        if token != ch(";") {
            var isString = token == STRING_CONSTANT || token == STRING_FUNCTION
            let isArrayFunction = token == ARRAY_FUNCTION
            if token == WORD {
                let v = lookupLocalVariable(tokenAddress)
                if let v, nextToken() == ch(";") {
                    array = v.getArray()
                    if array != nil { arraySize = v.getArraySize() }
                    isString = v.getString() != nil
                } else if let v, nextToken() == ch("+") {
                    isString = v.kind == .string
                }
            }
            putTokenBack()
            if isString {
                str = try getString()
            } else if isArrayFunction {
                getToken()
                array = try function.getArrayFunction(pgm.table[tokenAddress].type)
            } else if array == nil {
                if (code(pc + 2) & 0xff) == ch("[") && nextToken() == WORD {
                    let savePC = pc
                    getToken()
                    let v = try getArrayElement(try lookupVariable())
                    pc = savePC
                    if v.getString() != nil { str = try getString() } else { value = try getExpression() }
                } else {
                    value = try getExpression()
                }
            }
        }
        if inFunction {
            throw .returned(value: value, str: str, array: array, arraySize: arraySize)
        } else {
            finishUp()
            if value != 0 || array != nil { try error("Macros can only return strings") }
            returnValue = str
            done = true
        }
    }

    func doFor() throws(MacroSignal) {
        let saveLooseSyntax = looseSyntax
        looseSyntax = false
        loopDepth += 1
        inLoop = true
        getToken()
        if token != ch("(") { try error("'(' expected") }
        getToken()  // skip 'var'
        if token != VAR { putTokenBack() }
        repeat {
            if nextToken() != ch(";") { _ = try getAssignmentExpression() }
            getToken()
        } while token == ch(",")
        if token != ch(";") { try error("';' expected") }
        let condPC = pc
        var startPC = 0
        var cond = 1.0
        while true {
            if code(pc + 1) != ch(";") { cond = try getLogicalExpression() }
            if startPC == 0 { try checkBoolean(cond) }
            getToken()
            if token != ch(";") { try error("';' expected") }
            let incPC = pc
            if startPC != 0 {
                pc = startPC
            } else {
                while token != ch(")") {
                    getToken()
                    if token == ch("{") || token == ch(";") || token == ch("(") || done { try error("')' expected") }
                }
            }
            startPC = pc
            if cond == 1 {
                var broke = false
                do {
                    try doStatement()
                } catch {
                    switch error {
                    case .breakLoop:
                        pc = startPC
                        try skipStatement()
                        broke = true
                    case .continueLoop: break
                    default: throw error
                    }
                }
                if broke { break }
            } else {
                try skipStatement()
                break
            }
            pc = incPC  // the increment
            repeat {
                if nextToken() != ch(")") { _ = try getAssignmentExpression() }
                getToken()
            } while token == ch(",")
            pc = condPC
        }
        looseSyntax = saveLooseSyntax
        loopDepth -= 1
        if loopDepth == 0 { inLoop = false }
    }

    func doWhile() throws(MacroSignal) {
        looseSyntax = false
        loopDepth += 1
        inLoop = true
        let savePC = pc
        var isTrue: Bool
        repeat {
            pc = savePC
            isTrue = try getBoolean()
            if isTrue {
                var broke = false
                do {
                    try doStatement()
                } catch {
                    switch error {
                    case .breakLoop:
                        pc = savePC
                        _ = try getBoolean()
                        try skipStatement()
                        broke = true
                    case .continueLoop: break
                    default: throw error
                    }
                }
                if broke { break }
            } else {
                try skipStatement()
            }
        } while isTrue && !done
        loopDepth -= 1
        if loopDepth == 0 { inLoop = false }
    }

    func doDo() throws(MacroSignal) {
        looseSyntax = false
        let savePC = pc
        var isTrue: Bool
        repeat {
            try doStatement()
            getToken()
            if token != WHILE { try error("'while' expected") }
            isTrue = try getBoolean()
            if isTrue { pc = savePC }
        } while isTrue && !done
    }

    final func doBlock() throws(MacroSignal) {
        getToken()
        if token != ch("{") { try error("'{' expected") }
        while !done {
            getToken()
            if token == ch("}") { break }
            putTokenBack()
            try doStatement()
        }
        if token != ch("}") { try error("'}' expected") }
    }

    final func skipStatement() throws(MacroSignal) {
        if done { return }
        getToken()
        switch token {
        case PREDEFINED_FUNCTION, USER_FUNCTION, VAR, WORD, ch("("), PLUS_PLUS, RETURN, ARRAY_FUNCTION,
            NUMERIC_FUNCTION, STRING_FUNCTION, VARIABLE_FUNCTION:
            try skipSimpleStatement()
        case IF:
            try skipParens()
            try skipStatement()
            getToken()
            if token == ELSE { try skipStatement() } else { putTokenBack() }
        case FOR, WHILE:
            try skipParens()
            try skipStatement()
        case DO:
            try skipStatement()
            getToken()  // skip 'while'
            try skipParens()
        case BREAK, CONTINUE, ch(";"):
            break
        case ch("{"):
            putTokenBack()
            try skipBlock()
        default:
            try error("Skipped statement cannot begin with '" + pgm.decodeToken(token, tokenAddress) + "'")
        }
    }

    final func skipBlock() throws(MacroSignal) {
        var count = 0
        repeat {
            getToken()
            if token == ch("{") {
                count += 1
            } else if token == ch("}") {
                count -= 1
            } else if done {
                try error("'}' expected")
                return
            }
        } while count > 0
    }

    final func skipParens() throws(MacroSignal) {
        var count = 0
        repeat {
            getToken()
            if token == ch("(") {
                count += 1
            } else if token == ch(")") {
                count -= 1
            } else if done {
                try error("')' expected")
                return
            }
        } while count > 0
    }

    final func skipSimpleStatement() throws(MacroSignal) {
        var finished = done
        getToken()
        while !finished && !done {
            if token == ch(";") {
                finished = true
            } else if token == ELSE || (token == PREDEFINED_FUNCTION && code(pc - 1) != ch(".")) {
                try error("';' expected")
            } else {
                getToken()
            }
        }
    }

    func skipFunction() throws(MacroSignal) {
        getToken()  // skip the function's name
        try skipParens()
        try skipBlock()
    }

    func runFirstMacro() throws(MacroSignal) {
        getToken()  // skip the macro's label
        try doBlock()
        done = true
        finishUp()
    }

    func skipMacro() throws(MacroSignal) {
        getToken()  // skip the macro's label
        try skipBlock()
    }

    // MARK: - Assignments

    final func doAssignment() throws(MacroSignal) {
        let next = code(pc + 1) & 0xff
        if next == ch("[") {
            try doArrayElementAssignment()
            return
        }
        let type = try getExpressionType()
        switch type {
        case VariableType.string: try doStringAssignment()
        case VariableType.array: try doArrayAssignment()
        case USER_FUNCTION: try doUserFunctionAssignment()
        case STRING_FUNCTION: try doNumericStringAssignment()
        default:
            putTokenBack()
            let value = try getAssignmentExpression()
            if evaluating { log(javaString(value)) }
        }
    }

    /// Java's `Variable.VALUE`, `ARRAY` and `STRING`, as `getExpressionType` returns them.
    enum VariableType {
        static let value = 0, array = 1, string = 2
    }

    func typeCode(_ v: Variable) -> Int {
        switch v.kind {
        case .value: VariableType.value
        case .array: VariableType.array
        case .string: VariableType.string
        }
    }

    func getExpressionType() throws(MacroSignal) -> Int {
        let rightSideToken = code(pc + 2)
        let tok = rightSideToken & 0xff
        if tok == STRING_CONSTANT { return VariableType.string }
        if tok == STRING_FUNCTION {
            let address = rightSideToken >> TOK_SHIFT
            let type = pgm.table[address].type
            if type == DIALOG {
                let name = pgm.table[code(pc + 4) >> TOK_SHIFT].str
                if name == "getNumber" || name == "getCheckbox" { return STRING_FUNCTION }
            } else if type == FILE {
                let name = pgm.table[code(pc + 4) >> TOK_SHIFT].str
                if ["exists", "isDirectory", "length", "getLength", "rename", "delete"].contains(name) {
                    return STRING_FUNCTION
                }
            } else if type == LIST {
                if pgm.table[code(pc + 4) >> TOK_SHIFT].str == "getValue" { return STRING_FUNCTION }
            } else if numericStringFunction(pc + 2) {
                return VariableType.value
            }
            return VariableType.string
        }
        if tok == ARRAY_FUNCTION { return VariableType.array }
        if tok == USER_FUNCTION { return USER_FUNCTION }
        if tok == VARIABLE_FUNCTION {
            if isString(pc + 2) { return VariableType.string }
            let name = pgm.table[code(pc + 4) >> TOK_SHIFT].str
            if name == "getColumn" || name == "toArray" { return VariableType.array }
        }
        if tok != WORD { return VariableType.value }
        guard let v = lookupVariable(rightSideToken >> TOK_SHIFT) else { return VariableType.value }
        switch v.kind {
        case .value: return VariableType.value
        case .string: return isString(pc + 2) ? VariableType.string : VariableType.value
        case .array: break
        }
        if code(pc + 3) == ch(".") { return VariableType.value }
        if code(pc + 3) != ch("[") { return VariableType.array }
        let savePC = pc
        getToken()  // "="
        getToken()  // the variable
        checkingType = true
        let index = try getIndex()
        checkingType = false
        pc = savePC - 1
        getToken()
        guard let array = v.getArray(), index >= 0, index < array.count else { return VariableType.value }
        return typeCode(array[index])
    }

    /// String functions such as `Dialog.getNumber()` that return a number.
    final func doNumericStringAssignment() throws(MacroSignal) {
        putTokenBack()
        getToken()
        let v: Variable
        if let local = lookupLocalVariable(tokenAddress) { v = local } else { v = try push(tokenAddress, 0, nil) }
        getToken()
        if token != ch("=") { try error("'=' expected") }
        v.setValue(try getExpression())
    }

    final func doArrayElementAssignment() throws(MacroSignal) {
        guard let v = lookupLocalVariable(tokenAddress) else { try fail("Undefined identifier") }
        if code(pc + 5) == ch(";") && (code(pc + 4) == PLUS_PLUS || code(pc + 4) == MINUS_MINUS) {
            putTokenBack()
            _ = try getFactor()
            return
        }
        let index = try getIndex()
        let expressionType = try getExpressionType()
        if expressionType == VariableType.array { try error("Arrays of arrays not supported") }
        getToken()
        let op = token
        if !(op == ch("=") || op == PLUS_EQUAL || op == MINUS_EQUAL || op == MUL_EQUAL || op == DIV_EQUAL) {
            try error("'=', '+=', '-=', '*=' or '/=' expected")
            return
        }
        if op != ch("=") && (expressionType == VariableType.string || expressionType == VariableType.array) {
            try error("'=' expected")
            return
        }
        guard var array = v.getArray() else { try fail("Array expected") }
        if index < 0 { try fail("Negative index") }
        if index >= array.count {  // expand the array
            if !function.expandableArrays { try fail("Index (\(index)) out of range") }
            let strings = array.count > 0 && array[0].getString() != nil
            var elements: [Variable] = []
            for i in 0..<(index + array.count / 2 + 1) {
                if i < array.count {
                    elements.append(array[i])
                } else {
                    let element = Variable(Double.nan)
                    if strings { element.setString("undefined") }
                    elements.append(element)
                }
            }
            v.setArray(VariableArray(elements))
            v.setArraySize(index + 1)
            array = v.getArray()!
        }
        let size = v.getArraySize()
        if index + 1 > size { v.setArraySize(index + 1) }
        switch expressionType {
        case VariableType.string:
            array[index].setString(try getString())
        case VariableType.array:
            getToken()
            if token == ARRAY_FUNCTION {
                array[index].setArray(try function.getArrayFunction(pgm.table[tokenAddress].type))
            }
        case USER_FUNCTION:
            let savePC = pc
            getToken()  // the function
            let simpleFunctionCall = try isSimpleFunctionCall(assignment: true)
            pc = savePC
            if simpleFunctionCall {
                getToken()
                guard let v2 = try runUserFunction() else { try fail("No return value") }
                if done { return }
                if v2.kind == .value {
                    array[index].setValue(v2.getValue())
                } else {
                    array[index].setString(v2.getString())
                }
            } else {
                array[index].setValue(try getExpression())
            }
        default:
            let element = array[index]
            switch op {
            case ch("="): element.setValue(try getExpression())
            case PLUS_EQUAL: element.setValue(element.getValue() + (try getExpression()))
            case MINUS_EQUAL: element.setValue(element.getValue() - (try getExpression()))
            case MUL_EQUAL: element.setValue(element.getValue() * (try getExpression()))
            case DIV_EQUAL: element.setValue(element.getValue() / (try getExpression()))
            default: break
            }
        }
    }

    final func doUserFunctionAssignment() throws(MacroSignal) {
        putTokenBack()
        let savePC = pc
        getToken()  // the variable
        getToken()  // '='
        getToken()  // the function
        let simpleAssignment = try isSimpleFunctionCall(assignment: true)
        pc = savePC
        if !simpleAssignment {
            _ = try getAssignmentExpression()
        } else {
            getToken()
            let v1: Variable
            if let local = lookupLocalVariable(tokenAddress) { v1 = local } else { v1 = try push(tokenAddress, 0, nil) }
            getToken()
            if token != ch("=") { try error("'=' expected") }
            getToken()  // the function
            guard let v2 = try runUserFunction() else { try fail("No return value") }
            if done { return }
            switch v2.kind {
            case .value: v1.setValue(v2.getValue())
            case .array:
                v1.setArray(v2.getArray())
                v1.setArraySize(v2.getArraySize())
            case .string: v1.setString(v2.getString())
            }
        }
    }

    func isSimpleFunctionCall(assignment: Bool) throws(MacroSignal) -> Bool {
        var count = 0
        repeat {
            getToken()
            if token == ch("(") {
                count += 1
            } else if token == ch(")") {
                count -= 1
            } else if done {
                try error("')' expected")
            }
        } while count > 0
        getToken()
        return assignment ? token == ch(";") : (token == ch(",") || token == ch(")"))
    }

    final func doStringAssignment() throws(MacroSignal) {
        var v = lookupLocalVariable(tokenAddress)
        if v == nil {
            if nextToken() == ch("=") { v = try push(tokenAddress, 0, nil) } else { try fail("Undefined identifier") }
        }
        getToken()
        if token == ch("=") {
            v!.setString(try getString())
        } else if token == PLUS_EQUAL {
            v!.setString((v!.getString() ?? "null") + (try getString() ?? "null"))
        } else {
            try error("'=' or '+=' expected")
        }
    }

    final func doArrayAssignment() throws(MacroSignal) {
        var v = lookupLocalVariable(tokenAddress)
        if v == nil {
            if nextToken() == ch("=") { v = try push(tokenAddress, 0, nil) } else { try fail("Undefined identifier") }
        }
        getToken()
        if token != ch("=") {
            try error("'=' expected")
            return
        }
        getToken()
        if token == ARRAY_FUNCTION {
            v!.setArray(try function.getArrayFunction(pgm.table[tokenAddress].type))
        } else if token == WORD {
            guard let v2 = try lookupVariable() else { return }
            v!.setArray(v2.getArray())
            v!.setArraySize(v2.getArraySize())
        } else if token == VARIABLE_FUNCTION {
            let v2 = try function.getVariableFunction(pgm.table[tokenAddress].type)
            guard let array = v2.getArray() else { try fail("Array expected") }
            v!.setArray(array)
        } else {
            try error("Array expected")
        }
    }

    final func doIf() throws(MacroSignal) {
        looseSyntax = false
        let b = try getBoolean()
        if b { try doStatement() } else { try skipStatement() }
        var next = nextToken()
        if next == ch(";") {
            getToken()
            next = nextToken()
        }
        if next == ELSE {
            getToken()
            if b { try skipStatement() } else { try doStatement() }
        }
    }

    // MARK: - Expressions

    final func getBoolean() throws(MacroSignal) -> Bool {
        try getLeftParen()
        let value = try getLogicalExpression()
        try checkBoolean(value)
        try getRightParen()
        return value != 0
    }

    final func getLogicalExpression() throws(MacroSignal) -> Double {
        let v1 = try getBooleanExpression()
        let next = nextToken()
        if !(next == LOGICAL_AND || next == LOGICAL_OR) { return v1 }
        try checkBoolean(v1)
        getToken()
        let op = token
        let v2 = try getLogicalExpression()
        try checkBoolean(v2)
        if op == LOGICAL_AND { return Double(jInt(v1) & jInt(v2)) }
        if op == LOGICAL_OR { return Double(jInt(v1) | jInt(v2)) }
        return v1
    }

    final func getBooleanExpression() throws(MacroSignal) -> Double {
        var v1 = 0.0
        var s1: String?
        let next = code(pc + 1)
        let tok = next & TOK_MASK
        if tok == STRING_CONSTANT || tok == STRING_FUNCTION || isString(pc + 1) {
            if numericStringFunction(pc + 1) { v1 = try getExpression() } else { s1 = try getString() }
        } else {
            v1 = try getExpression()
        }
        let next2 = nextToken()
        if next2 >= EQ && next2 <= LTE {
            getToken()
            let op = token
            if let s1 { return compareStrings(s1, try getString() ?? "null", op) }
            let v2 = try getExpression()
            switch op {
            case EQ: v1 = v1 == v2 ? 1 : 0
            case NEQ: v1 = v1 != v2 ? 1 : 0
            case GT: v1 = v1 > v2 ? 1 : 0
            case GTE: v1 = v1 >= v2 ? 1 : 0
            case LT: v1 = v1 < v2 ? 1 : 0
            case LTE: v1 = v1 <= v2 ? 1 : 0
            default: break
            }
        } else if let s1 {
            if s1 == "true" {
                v1 = 1
            } else if s1 == "false" {
                v1 = 0
            } else {
                v1 = toolsParseDouble(s1, .nan)
            }
        }
        return v1
    }

    private func numericStringFunction(_ loc: Int) -> Bool {
        if (code(loc) & TOK_MASK) != STRING_FUNCTION { return false }
        let type = pgm.table[code(loc) >> TOK_SHIFT].type
        if [VARIABLE_FUNCTION, DIALOG, FILE, STRING, EXT, LIST, IJ_CALL].contains(type) { return false }
        if code(loc + 1) == ch(".") && (code(loc + 2) & 0xff) != STRING_FUNCTION { return true }
        if code(loc + 1) == ch("(") && code(loc + 2) == ch(")") && code(loc + 3) == ch(".")
            && (code(loc + 4) & 0xff) != STRING_FUNCTION
        {
            return true
        }
        return false
    }

    func isString(_ pcLoc: Int) -> Bool {
        let tok = code(pcLoc)
        if (tok & 0xff) == VARIABLE_FUNCTION {
            let type = pgm.table[tok >> TOK_SHIFT].type
            if let name = pgm.table[code(pcLoc + 2) >> TOK_SHIFT].str, Functions.isStringFunction(name, type) {
                return true
            }
        }
        if (tok & TOK_MASK) != WORD { return false }
        guard let v = lookupVariable(tok >> TOK_SHIFT) else { return false }
        if code(pcLoc + 1) == ch("[") {
            if let array = v.getArray(), array.count > 0 { return array[0].kind == .string }
        }
        if v.kind == .string && (code(pcLoc + 1) & 0xff) == ch(".") && (code(pcLoc + 2) & 0xff) != STRING_FUNCTION {
            return false
        }
        return v.kind == .string
    }

    func compareStrings(_ s1: String, _ s2: String, _ op: Int) -> Double {
        let result = javaCompareToIgnoreCase(s1, s2)
        switch op {
        case EQ: return result == 0 ? 1 : 0
        case NEQ: return result != 0 ? 1 : 0
        case GT: return result > 0 ? 1 : 0
        case GTE: return result >= 0 ? 1 : 0
        case LT: return result < 0 ? 1 : 0
        case LTE: return result <= 0 ? 1 : 0
        default: return 0
        }
    }

    final func getAssignmentExpression() throws(MacroSignal) -> Double {
        let tokPlus2 = code(pc + 2)
        if (code(pc + 1) & 0xff) == WORD
            && (tokPlus2 == ch("=") || tokPlus2 == PLUS_EQUAL || tokPlus2 == MINUS_EQUAL || tokPlus2 == MUL_EQUAL
                || tokPlus2 == DIV_EQUAL)
        {
            getToken()
            var v = lookupLocalVariable(tokenAddress)
            let saveAddress = tokenAddress
            getToken()
            var value = 0.0
            if token == ch("=") {
                value = try getAssignmentExpression()
            } else {
                value = v?.getValue() ?? 0
                switch token {
                case PLUS_EQUAL: value += try getAssignmentExpression()
                case MINUS_EQUAL: value -= try getAssignmentExpression()
                case MUL_EQUAL: value *= try getAssignmentExpression()
                case DIV_EQUAL: value /= try getAssignmentExpression()
                default: break
                }
            }
            if v == nil { v = try push(saveAddress, 0, nil) }
            v!.setValue(value)
            return value
        }
        return try getLogicalExpression()
    }

    final func checkBoolean(_ value: Double) throws(MacroSignal) {
        if !(value == 0 || value == 1) { try error("Boolean expression expected: " + javaString(value)) }
    }

    func doVar() throws(MacroSignal) {
        getToken()
        while token == WORD {
            if nextToken() == ch("=") {
                try doAssignment()
            } else if lookupVariable(tokenAddress) == nil {
                try push(tokenAddress, 0, nil)
            }
            getToken()
            if token == ch(",") {
                getToken()
            } else {
                putTokenBack()
                break
            }
        }
    }

    final func getLeftParen() throws(MacroSignal) {
        getToken()
        if token != ch("(") { try error("'(' expected") }
    }

    final func getRightParen() throws(MacroSignal) {
        getToken()
        if token != ch(")") { try error("')' expected") }
    }

    final func getParens() throws(MacroSignal) {
        if nextToken() == ch("(") {
            try getLeftParen()
            try getRightParen()
        }
    }

    final func getComma() throws(MacroSignal) {
        getToken()
        if token != ch(",") {
            if looseSyntax { putTokenBack() } else { try error("',' expected") }
        }
    }

    /// `error(message)`: aborts the macro, unless errors are ignored (eval)
    /// or the macro has already run to its end, where ImageJ carries on.
    func error(_ message: String) throws(MacroSignal) {
        errorMessage = message
        if ignoreErrors { return }
        errorCount += 1
        let showMessage = !done
        token = EOF
        tokenString = ""
        wasError = true
        if showMessage {
            let line = getErrorLine()
            done = true
            let shown = line.utf16.count > 120 ? javaSubstring(line, 0, 119) + "..." : line
            throw .error(
                MacroError(message: message, lineNumber: lineNumber, line: shown, calledFrom: callStack[0..<callDepth].reversed()))
        }
        done = true
        if errorCount > 10 { throw .error(MacroError(message: message, lineNumber: lineNumber)) }
    }

    /// An error after which ImageJ would fail with an exception (it carries on
    /// with a null); here the macro always stops.
    func fail(_ message: String) throws(MacroSignal) -> Never {
        try error(message)
        throw .error(MacroError(message: message, lineNumber: lineNumber))
    }

    func getErrorLine() -> String {
        let savePC = pc
        lineNumber = pgm.lineNumbers[min(max(pc, 0), pgm.lineNumbers.count - 1)]
        while pc >= 0 && lineNumber == pgm.lineNumbers[pc] { pc -= 1 }
        if lineNumber <= 1 { pc = -1 }
        var line = ""
        getToken()
        while !done && pc < pgm.lineNumbers.count && lineNumber == pgm.lineNumbers[pc] {
            var str = pgm.decodeToken(token, tokenAddress)
            if pc == savePC { str = "<" + str + ">" }
            line += str + " "
            getToken()
        }
        return line
    }

    /// A string expression; `nil` when it is a single call of a string
    /// function that returns nothing (`File.makeDirectory(...)`), as Java's null.
    final func getString() throws(MacroSignal) -> String? {
        var str = try getStringTerm()
        while true {
            getToken()
            if token == ch("+") {
                let term = try getStringTerm()
                str = (str ?? "null") + (term ?? "null")
            } else {
                putTokenBack()
                break
            }
        }
        return str
    }

    final func getStringTerm() throws(MacroSignal) -> String? {
        getToken()
        switch token {
        case STRING_CONSTANT:
            return tokenString ?? "null"
        case STRING_FUNCTION:
            return try function.getStringFunction(pgm.table[tokenAddress].type)
        case VARIABLE_FUNCTION:
            if !isString(pc) {
                putTokenBack()
                return toString(try getStringExpression())
            }
            let v = try function.getVariableFunction(pgm.table[tokenAddress].type)
            return v.getString() ?? Self.numberString(v.getValue())
        case USER_FUNCTION:
            guard let v = try runUserFunction() else { try fail("No return value") }
            return v.getString() ?? Self.numberString(v.getValue())
        case WORD:
            if let str = try lookupStringVariable() { return str }
            fallthrough
        default:
            putTokenBack()
            return toString(try getStringExpression())
        }
    }

    /// A function's numeric result in a string: an integer, or Java's `""+value`.
    static func numberString(_ value: Double) -> String {
        Double(jInt(value)) == value ? ImageJFormat.d2s(value, 0) : javaString(value)
    }

    /// How numbers become strings in string expressions: integers without
    /// decimals, others with 4 decimal places, or up to 9 significant digits.
    func toString(_ x: Double) -> String {
        if Double(jInt(x)) == x { return ImageJFormat.d2s(x, 0) }
        if evaluating { return javaString(x) }
        var str = ImageJFormat.d2s(x, significantDigits: 4, maxDigits: 9)
        while str.hasSuffix("0") && str.contains(".") && !str.contains("E") { str.removeLast() }
        if str.hasSuffix(".") { str.removeLast() }
        return str
    }

    final func getExpression() throws(MacroSignal) -> Double {
        var value = try getTerm()
        while true {
            let next = nextToken()
            if next == ch("+") {
                getToken()
                value += try getTerm()
            } else if next == ch("-") {
                getToken()
                value -= try getTerm()
            } else {
                break
            }
        }
        return value
    }

    final func getTerm() throws(MacroSignal) -> Double {
        var value = try getFactor()
        while true {
            switch nextToken() {
            case ch("*"):
                getToken()
                value *= try getFactor()
            case ch("/"):
                getToken()
                value /= try getFactor()
            case ch("%"):
                getToken()
                value = value.truncatingRemainder(dividingBy: try getFactor())
            case ch("&"):
                getToken()
                value = Double(jInt(value) & jInt(try getFactor()))
            case ch("|"):
                getToken()
                value = Double(jInt(value) | jInt(try getFactor()))
            case ch("^"):
                getToken()
                value = Double(jInt(value) ^ jInt(try getFactor()))
            case SHIFT_RIGHT:
                getToken()
                value = Double(jInt(value) >> (jInt(try getFactor()) & 31))
            case SHIFT_LEFT:
                getToken()
                value = Double(jInt(value) << (jInt(try getFactor()) & 31))
            default:
                return value
            }
        }
    }

    final func getFactor() throws(MacroSignal) -> Double {
        var value = 0.0
        getToken()
        switch token {
        case NUMBER:
            value = tokenValue
        case STRING_CONSTANT:
            value = toolsParseDouble(tokenString, .nan)
        case NUMERIC_FUNCTION:
            value = try function.getFunctionValue(pgm.table[tokenAddress].type)
        case STRING_FUNCTION:
            let str = try function.getStringFunction(pgm.table[tokenAddress].type)
            if nextToken() == ch(".") {
                getToken()  // '.'
                getToken()  // the numeric function
                value = try getNumericStringFunction(str ?? "null")
            } else {
                value = toolsParseDouble(str)
            }
            if str == "NaN" {
                value = .nan
            } else if value.isNaN {
                try error("Numeric value expected")
            }
        case VARIABLE_FUNCTION:
            let v = try function.getVariableFunction(pgm.table[tokenAddress].type)
            if v.getString() != nil { try error("Numeric return value expected") } else { value = v.getValue() }
        case USER_FUNCTION:
            guard let v = try runUserFunction() else { try fail("No return value") }
            if done {
                value = 0
            } else if v.getString() != nil {
                try error("Numeric return value expected")
            } else {
                value = v.getValue()
            }
        case TRUE: value = 1
        case FALSE: value = 0
        case PI: value = Double.pi
        case NaN: value = .nan
        case WORD:
            guard var v = try lookupVariable() else { return 0 }
            var next = nextToken()
            if next == ch("[") {
                v = try getArrayElement(v)
                value = v.getValue()
                next = nextToken()
                if next == ch(".") {
                    value = try runNumericFunction(v)
                    next = nextToken()
                }
            } else if next == ch(".") {
                value = try runNumericFunction(v)
                next = nextToken()
            } else {
                if v.getArray() != nil {
                    getToken()
                    try error("'[' or '.' expected")
                }
                if prefixValue != 0 && !checkingType {
                    v.setValue(v.getValue() + Double(prefixValue))
                    prefixValue = 0
                }
                value = v.getValue()
            }
            if !(next == PLUS_PLUS || next == MINUS_MINUS) { break }
            getToken()
            if token == PLUS_PLUS {
                v.setValue(v.getValue() + (checkingType ? 0 : 1))
            } else {
                v.setValue(v.getValue() - (checkingType ? 0 : 1))
            }
        case ch("("):
            value = try getLogicalExpression()
            try getRightParen()
        case PLUS_PLUS:
            prefixValue = 1
            value = try getFactor()
        case MINUS_MINUS:
            prefixValue = -1
            value = try getFactor()
        case ch("!"):
            value = try getFactor()
            if value == 0 || value == 1 { value = value == 0 ? 1 : 0 } else { try error("Boolean expected") }
        case ch("-"):
            value = -(try getFactor())
        case ch("~"):
            value = Double(~jInt(try getFactor()))
        default:
            try error("Number or numeric function expected")
        }
        return value
    }

    private func getNumericStringFunction(_ str: String) throws(MacroSignal) -> Double {
        var value = Double.nan
        if token == WORD {
            if tokenString == "length" {
                try getParens()
                value = Double(str.utf16.count)
            } else if tokenString == "contains" {
                value = javaContains(str, try function.getStringArg()) ? 1 : 0
            } else if tokenString == "charAt" {
                value = Double(try javaCharAt(str, jIntI(try function.getArg())))
            }
        } else if token == NUMERIC_FUNCTION {
            switch pgm.table[tokenAddress].type {
            case INDEX_OF: value = Double(try function.indexOf(str))
            case LAST_INDEX_OF: value = Double(javaLastIndexOf(str, try function.getStringArg()))
            case STARTS_WITH: value = javaStartsWith(str, try function.getStringArg()) ? 1 : 0
            case ENDS_WITH: value = javaEndsWith(str, try function.getStringArg()) ? 1 : 0
            case MATCHES: value = try function.matches(str)
            default: break
            }
        } else {
            try error("Numeric function expected")
        }
        return value
    }

    /// `str.charAt(index)`, or an error where Java throws.
    func javaCharAt(_ str: String, _ index: Int) throws(MacroSignal) -> UInt16 {
        let units = Array(str.utf16)
        guard index >= 0, index < units.count else { try fail("Index (\(index)) out of 0-\(units.count - 1) range") }
        return units[index]
    }

    final func getArrayElement(_ v: Variable?) throws(MacroSignal) -> Variable {
        let index = try getIndex()
        guard let array = v?.getArray() else { try fail("Array expected") }
        if index < 0 || index >= array.count {
            if array.count == 0 { try fail("Empty array") }
            try fail("Index (\(index)) out of 0-\(array.count - 1) range")
        }
        return array[index]
    }

    final func runNumericFunction(_ v: Variable) throws(MacroSignal) -> Double {
        getToken()  // '.'
        getToken()
        if token == WORD && v.getArray() != nil && tokenString == "length" { return Double(v.getArraySize()) }
        guard let str = v.getString() else { try fail("Array or string expected") }
        return try getNumericStringFunction(str)
    }

    final func getStringExpression() throws(MacroSignal) -> Double {
        var value = try getTerm()
        while true {
            getToken()
            if token == ch("+") {
                getToken()
                if token == STRING_CONSTANT || token == STRING_FUNCTION {
                    putTokenBack()
                    putTokenBack()
                    break
                }
                if token == WORD, let v = lookupVariable(tokenAddress), v.getString() != nil {
                    putTokenBack()
                    putTokenBack()
                    break
                }
                putTokenBack()
                value += try getTerm()
            } else if token == ch("-") {
                value -= try getTerm()
            } else {
                putTokenBack()
                break
            }
        }
        return value
    }

    // MARK: - The stack

    /// Searches the local and global sections of the stack.
    final func lookupLocalVariable(_ symTabAddress: Int) -> Variable? {
        if topOfStack >= startOfLocals {
            for i in stride(from: topOfStack, through: startOfLocals, by: -1) where stack[i].symTabIndex == symTabAddress {
                return stack[i]
            }
        }
        if topOfGlobals >= 0 {
            for i in stride(from: min(topOfGlobals, topOfStack), through: 0, by: -1)
            where stack[i].symTabIndex == symTabAddress {
                return stack[i]
            }
        }
        return nil
    }

    /// Searches the whole stack.
    final func lookupVariable(_ symTabAddress: Int) -> Variable? {
        for v in stack.reversed() where v.symTabIndex == symTabAddress { return v }
        return nil
    }

    @discardableResult
    func push(_ variable: Variable) throws(MacroSignal) -> Variable {
        if topOfStack >= Self.STACK_SIZE - 2 { try fail("Stack overflow") }
        stack.append(variable)
        return variable
    }

    @discardableResult
    func push(_ symTabLoc: Int, _ value: Double, _ str: String?) throws(MacroSignal) -> Variable {
        try push(Variable(symTabIndex: symTabLoc, value: value, str: str))
    }

    func pushGlobals() {
        guard let globals = pgm.globals else { return }
        stack.append(contentsOf: globals)
        topOfGlobals = topOfStack
    }

    func trimStack(_ previousTOS: Int, _ previousStartOfLocals: Int) {
        topOfStack = previousTOS
        startOfLocals = previousStartOfLocals
    }

    /// Searches the stack for the variable of the current token; aborts the macro if there's none.
    final func lookupVariable() throws(MacroSignal) -> Variable? {
        if let v = lookupVariable(tokenAddress) { return v }
        try undefined()
        return nil
    }

    final func lookupStringVariable() throws(MacroSignal) -> String? {
        guard let v = lookupVariable(tokenAddress) else {
            try undefined()
            return ""
        }
        var str: String?
        let next = nextToken()
        if next == ch("[") {
            let savePC = pc
            let index = try getIndex()
            guard let array = v.getArray() else { try fail("Array expected") }
            if index < 0 || index >= array.count { try fail("Index (\(index)) out of 0-\(array.count - 1) range") }
            str = array[index].getString()
            let next2 = nextToken()
            if let s = str {
                if next2 == ch(".") { str = try runStringFunction(s) }
            } else if next2 == ch(")") || next2 == ch(";") {
                str = toString(array[index].getValue())
            } else {
                pc = savePC - 1
                getToken()
            }
        } else if next == ch(".") {
            if let s = v.getString() { str = try runStringFunction(s) }
        } else {
            if v.getArray() != nil {
                getToken()
                try error("'[' or '.' expected")
            }
            str = v.getString()
        }
        return str
    }

    private func runStringFunction(_ strIn: String) throws(MacroSignal) -> String {
        getToken()  // '.'
        getToken()
        var str: String? = strIn
        if token == WORD {
            if tokenString == "length" {
                try getParens()
                str = String(strIn.utf16.count)
            } else if tokenString == "contains" {
                str = String(javaContains(strIn, try function.getStringArg()))
            } else if tokenString == "replaceAll" {
                str = try function.replace(strIn)
            } else {
                str = nil
            }
        } else if token == NUMERIC_FUNCTION {
            switch pgm.table[tokenAddress].type {
            case INDEX_OF: str = String(try function.indexOf(strIn))
            case LAST_INDEX_OF: str = String(javaLastIndexOf(strIn, try function.getStringArg()))
            case STARTS_WITH: str = String(javaStartsWith(strIn, try function.getStringArg()))
            case ENDS_WITH: str = String(javaEndsWith(strIn, try function.getStringArg()))
            case MATCHES: str = javaString(try function.matches(strIn))  // ""+double
            default: str = nil
            }
        } else if token == STRING_FUNCTION {
            switch pgm.table[tokenAddress].type {
            case SUBSTRING: str = try function.substring(strIn)
            case TO_LOWER_CASE:
                try getParens()
                str = javaToLowerCase(strIn)
            case TO_UPPER_CASE:
                try getParens()
                str = javaToUpperCase(strIn)
            case REPLACE: str = try function.replace(strIn)
            case TRIM:
                try getParens()
                str = javaTrim(strIn)
            case CHARAT:
                let index = jIntI(try function.getArg())
                try function.checkIndex(index, 0, strIn.utf16.count - 1)
                str = String(decoding: [try javaCharAt(strIn, index)], as: UTF16.self)
            default: str = nil
            }
        } else {
            str = nil
        }
        guard let str else { try fail("String function expected") }
        return str
    }

    func getIndex() throws(MacroSignal) -> Int {
        getToken()
        if token != ch("[") { try error("'['expected") }
        let index = jIntI(try getExpression())
        getToken()
        if token != ch("]") { try error("']' expected") }
        return index
    }

    func undefined() throws(MacroSignal) {
        if nextToken() == ch("(") { try fail("Undefined identifier") }
        if pgm.size == 1 {
            // A one-word macro is a command name with underscores for spaces.
            let cmd = pgm.decodeToken(pgm.code[0]).replacingAll("_", with: " ")
            if session.isCommand(cmd) {
                try function.runCommand(cmd, options: nil)
                return
            }
        }
        try fail("Undefined variable")
    }

    func finishUp() {
        function?.finishUp()
    }

    // MARK: - Variables from outside

    /// The values of the macro's variables, by name (globals and locals as they stand).
    public func variable(named name: String) -> Variable? {
        for v in stack.reversed() where pgm.table[v.symTabIndex].str == name { return v }
        return nil
    }
}
