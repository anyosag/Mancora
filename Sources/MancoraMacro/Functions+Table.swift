// Results tables: getResult, setResult and the other results functions,
// Table.*, Array.show and opening and saving tables, ported from ImageJ
// 1.54p's Functions.java and ResultsTable.java.
//
// ImageJ finds the table a call without a title means by its windows: the
// front table window, else the one the macro last used, else Results.
// Mancora keeps the same order of table windows (MacroSession.tableWindows
// and frontTable). Results is the system table; Mancora treats it as the
// window ImageJ shows it in on the desktop.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO

/// How a table numbers and saves its rows (ResultsTable's `baseRowNumber`
/// and `saveColumnHeaders`); whether it shows row numbers is the table's
/// ``ResultsTable/showsRowNumbers``.
struct TableDisplay {
    var baseRowNumber = 1
    var saveHeaders = true
}

extension MacroSession {
    /// Forgets the windows of closed tables and adds those commands made
    /// (Analyze Particles' Summary), which come to the front.
    func syncTableWindows() {
        tableWindows.removeAll { context.tables[$0] == nil }
        if let front = frontTable, context.tables[front] == nil { frontTable = nil }
        for title in context.tables.keys.sorted() where !tableWindows.contains(title) {
            tableWindows.append(title)
            frontTable = title
        }
    }

    /// `ResultsTable.show(title)`: opens the table's window, or brings it to the front.
    func showTable(_ title: String) {
        guard title != "Results" else { return }
        if !tableWindows.contains(title) { tableWindows.append(title) }
        frontTable = title
    }

    /// How `title` numbers and saves its rows.
    func display(_ title: String) -> TableDisplay {
        tableDisplay[title] ?? TableDisplay()
    }
}

extension Functions {
    // MARK: - Finding tables

    /// The table `title` names: "Results" is the system results table.
    func table(_ title: String) -> ResultsTable {
        title == "Results" ? session.context.results : session.context.tables[title] ?? .custom()
    }

    func store(_ title: String, _ rt: ResultsTable) {
        if title == "Results" { session.context.results = rt } else { session.context.tables[title] = rt }
    }

    /// Whether `title` shows row numbers: Results always does.
    func rowNumbers(_ title: String) -> Bool {
        title == "Results" || table(title).showsRowNumbers == true
    }

    /// The decimal places a table shows fractions with: Set Measurements'
    /// for Results, at least 3 for others.
    func precision(_ title: String) -> Int {
        let places = session.context.settings.decimalPlaces
        return title == "Results" ? places : max(3, places)
    }

    /// `getRT(title)`: the table `title` names, or without one the table
    /// `Table.applyMacro` works on, the front table window, the table last
    /// used, else Results; `nil` when there's no such table.
    func findTable(_ title: String?) -> String? {
        if title == nil, let t = interp.applyMacroTable { return t }
        session.syncTableWindows()
        guard let title else {
            if let front = session.frontTable {
                currentTable = front
                return front
            }
            if let current = currentTable, session.context.tables[current] != nil { return current }
            // No Results window: the first table window.
            if let first = session.tableWindows.first { currentTable = first }
            return session.tableWindows.first
        }
        if title == "Results" || session.context.tables[title] != nil { return title }
        return nil
    }

    /// `getResultsTable(title)`: as ``findTable(_:)``, else Results, failing when there's no such table.
    func resultsTable(_ title: String?) throws(MacroSignal) -> String {
        if let found = findTable(title) { return found }
        if title == nil { return "Results" }
        try interp.fail("\"\(title ?? "Results")\" table not found")
    }

    /// `getResultsTable(true)`: Results, unless it's empty and a table window is in front.
    func measurementsTable() throws(MacroSignal) -> String {
        if session.context.results.count > 0 { return "Results" }
        session.syncTableWindows()
        if let front = session.frontTable, table(front).count > 0 { return front }
        try interp.fail("No results found")
    }

    /// ", title)": the optional last argument naming the table, and the closing parenthesis.
    private func titleArgument() throws(MacroSignal) -> String? {
        var title: String?
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            title = try getString()
        }
        try interp.getRightParen()
        return title
    }

    /// "(title)": an optional argument list holding just the title.
    private func titleOnlyArgument() throws(MacroSignal) -> String? {
        var title: String?
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if interp.nextToken() != ch(")") { title = try getString() }
            try interp.getRightParen()
        }
        return title
    }

    // MARK: - Results functions

    /// `getResult(column, row, title)`, and `Table.get` with its table.
    func getResult(_ preset: String? = nil) throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        let column = try getString()
        var row = -1
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            row = jIntI(try interp.getExpression())
        }
        var key = preset
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            key = try resultsTable(try getString())
        }
        if key == nil { key = try measurementsTable() }
        try interp.getRightParen()
        let rt = table(key ?? "Results")
        let counter = rt.count
        if row == -1 { row = counter - 1 }
        if row < 0 || row >= counter { try interp.fail("Row (\(row)) out of range") }
        guard rt.columns.contains(column) else { return .nan }
        switch rt.value(column, row: row) {
        case .text(let s)?: return s == "NaN" ? .nan : toolsParseDouble(s)
        default: return rt.number(column, row: row)
        }
    }

    /// `getResultString(column, row, title)`, and `Table.getString` with its table.
    func getResultString(_ preset: String? = nil) throws(MacroSignal) -> String {
        try interp.getLeftParen()
        let column = try getString()
        var row = -1
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            row = jIntI(try interp.getExpression())
        }
        var key = preset
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            key = try resultsTable(try getString())
        }
        try interp.getRightParen()
        if key == nil { key = try measurementsTable() }
        let title = key ?? "Results"
        let rt = table(title)
        if row == -1 { row = rt.count - 1 }
        if row < 0 || row >= rt.count { try interp.fail("Row (\(row)) out of range") }
        if rt.columns.contains(column) { return Self.cellText(rt, column, row, precision: precision(title)) }
        if column == "Label" { return rt.labels[row] ?? "null" }
        return "null"
    }

    /// A cell as `ResultsTable.getStringValue` gives it.
    static func cellText(_ rt: ResultsTable, _ column: String, _ row: Int, precision: Int) -> String {
        switch rt.value(column, row: row) {
        case .text(let s)?: return s.replacingAll("\n", with: "\\n")
        default: return ResultsFormatter.cell(rt.number(column, row: row), column: column, of: rt, decimalPlaces: precision)
        }
    }

    func getResultLabel() throws(MacroSignal) -> String {
        let row = jIntI(try getArg())
        let rt = table(try measurementsTable())
        if row < 0 || row >= rt.count { try interp.fail("Row (\(row)) out of range") }
        if let label = rt.labels[row] { return label }
        if case .text(let s)? = rt.value("Label", row: row) { return s }
        return ""
    }

    /// `setResult(column, row, value, title)`, and `Table.set` with its table.
    func setResult(_ preset: String? = nil) throws(MacroSignal) {
        try interp.getLeftParen()
        let column = try getString()
        try interp.getComma()
        let row = jIntI(try interp.getExpression())
        try interp.getComma()
        var value = 0.0
        var stringValue: String?
        let isLabel = column == "Label"
        if isStringArg() || isLabel { stringValue = try getString() } else { value = try interp.getExpression() }
        var key = preset
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            key = try resultsTable(try getString())
        }
        try interp.getRightParen()
        let title = key ?? "Results"
        var rt = table(title)
        if row < 0 || row > rt.count { try interp.fail("Row (\(row)) out of range") }
        if row == rt.count { rt.addRow() }
        if let stringValue {
            if isLabel { rt.setLabel(stringValue, row: row) } else { rt.set(column, row: row, .text(stringValue)) }
        } else {
            rt.set(column, row: row, value)
        }
        store(title, rt)
    }

    /// `IJ.renameResults`: `renameResults(new)` renames Results.
    func renameResults() throws(MacroSignal) {
        let arg1 = try getFirstString()
        var arg2: String?
        if interp.nextToken() == ch(")") { try interp.getRightParen() } else { arg2 = try getLastString() }
        let (from, to) = arg2.map { (arg1, $0) } ?? ("Results", arg1)
        guard from == "Results" || session.context.tables[from] != nil else {
            try interp.fail("\"\(from)\" table not found")
        }
        let rt = table(from)
        if from == "Results" { session.context.results = ResultsTable() } else { session.context.tables[from] = nil }
        store(to, rt)
        session.tableDisplay[to] = session.tableDisplay.removeValue(forKey: from)
        if let i = session.tableWindows.firstIndex(of: from) {
            session.tableWindows[i] = to
        } else if to != "Results" {
            session.tableWindows.append(to)
        }
        if session.frontTable == from { session.frontTable = to == "Results" ? nil : to }
        if currentTable == from { currentTable = to }
        session.tableWindows.removeAll { $0 == "Results" }
    }

    // MARK: - Table.*

    func doTable() throws(MacroSignal) -> Variable? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == NUMERIC_FUNCTION || interp.token == PREDEFINED_FUNCTION
            || interp.token == STRING_FUNCTION)
        {
            try interp.error("Function name expected: ")
        }
        let name = interp.tokenString ?? ""
        switch name {
        case "create", "reset":
            try resetTable(try titleOnlyArgument())
        case "size":
            return Variable(Double(table(try resultsTable(try titleOnlyArgument())).count))
        case "get":
            return Variable(try getResult(findTable(nil)))
        case "getString":
            return Variable(try getResultString(findTable(nil)))
        case "set":
            try setResult(findTable(nil))
        case "getColumn":
            return try getTableColumn()
        case "setColumn":
            try setTableColumn()
        case "columnExists":
            let column = try getFirstString()
            let rt = table(try resultsTable(try titleArgument()))
            return Variable(rt.columns.contains(column) ? 1 : 0)
        case "update":
            session.showTable(try resultsTable(try titleOnlyArgument()))
        case "applyMacro":
            try applyMacroToTable()
        case "deleteRows":
            let first = jIntI(try getFirstArg())
            let last = jIntI(try getNextArg())
            let title = try resultsTable(try titleArgument())
            var rt = table(title)
            rt.removeRows(first, last)
            store(title, rt)
            session.showTable(title)
        case "deleteColumn":
            let column = try getFirstString()
            let title = try resultsTable(try titleArgument())
            var rt = table(title)
            guard rt.columns.contains(column) else { try interp.fail("\"\(column)\" column not found") }
            rt.removeColumn(column)
            store(title, rt)
        case "renameColumn":
            let old = try getFirstString()
            let new = try getNextString()
            let title = try resultsTable(try titleArgument())
            var rt = table(title)
            guard rt.columns.contains(old) else { try interp.fail("\"\(old)\" column not found") }
            if rt.columns.contains(new) { try interp.fail("\"\(new)\" column exists") }
            rt.renameColumn(old, to: new)
            store(title, rt)
        case "save":
            let path = try getFirstString()
            let title = try resultsTable(try titleArgument())
            try saveTable(title, to: path)
        case "open":
            let path = try getFirstString()
            let title = try titleArgument() ?? Self.javaFileName(path)
            try openTable(path, as: title)
        case "title":
            return Variable(try resultsTable(try titleOnlyArgument()))
        case "headings":
            let title = try resultsTable(try titleOnlyArgument())
            return Variable(ResultsTableIO.headingLine(table(title), csv: false, rowNumbers: rowNumbers(title)))
        case "allHeadings":
            try interp.getParens()
            return Variable(ResultsTable.standardHeadings.joined(separator: "\t"))
        case "showRowNumbers", "showRowIndexes":
            let show = jInt(try getFirstArg()) != 0
            let title = try resultsTable(try titleArgument())
            let indexes = name == "showRowIndexes"
            // The Results table always has row numbers.
            if indexes || show || title != "Results" {
                var rt = table(title)
                rt.showsRowNumbers = show || title == "Results"
                store(title, rt)
                session.tableDisplay[title, default: TableDisplay()].baseRowNumber = indexes && show ? 0 : 1
            }
        case "hideRowNumbers":
            let title = try resultsTable(try titleOnlyArgument())
            if title != "Results" {
                var rt = table(title)
                rt.showsRowNumbers = false
                store(title, rt)
                session.tableDisplay[title, default: TableDisplay()].baseRowNumber = 1
            }
        case _ where name.hasPrefix("saveColumnHeader"):
            let save = jInt(try getFirstArg()) != 0
            let title = try resultsTable(try titleArgument())
            var display = session.display(title)
            display.saveHeaders = save
            session.tableDisplay[title] = display
        case "sort":
            let column = try getFirstString()
            let title = try resultsTable(try titleArgument())
            var rt = table(title)
            guard rt.columns.contains(column) else { try interp.fail("Column not found") }
            rt.reorderRows(Self.sortOrder(rt, column))
            store(title, rt)
            session.showTable(title)
        case "rename":
            try renameResults()
        case _ where name.hasPrefix("showArray"):
            try showArray()
        case "getSelectionStart", "getSelectionEnd":
            // Nothing is ever selected in a table here.
            _ = try resultsTable(try titleOnlyArgument())
            return Variable(-1)
        case "setSelection":
            try interp.getLeftParen()
            _ = try interp.getExpression()
            try interp.getComma()
            _ = try interp.getExpression()
            _ = try resultsTable(try titleArgument())
        case "setLocAndSize", "setLocationAndSize":
            _ = try getFirstArg()
            _ = try getNextArg()
            _ = try getNextArg()
            _ = try interp.getExpression()
            _ = try titleArgument()
        case "showHistogramTable", "list":
            try interp.fail("No histogram window")
        default:
            try interp.error("Unrecognized function name")
        }
        return nil
    }

    /// `Table.create(title)` and `Table.reset(title)`: an empty table, which comes to the front.
    private func resetTable(_ title: String?) throws(MacroSignal) {
        if title == "Results" {
            session.context.results.reset()
            return
        }
        if let existing = findTable(title) {
            var rt = table(existing)
            rt.reset()
            store(existing, rt)
            session.showTable(existing)
            return
        }
        // Table.create() with no tables open makes a new Results table.
        let newTitle = title ?? "Results"
        store(newTitle, newTitle == "Results" ? ResultsTable() : .custom())
        session.tableDisplay[newTitle] = nil
        session.showTable(newTitle)
    }

    private func getTableColumn() throws(MacroSignal) -> Variable {
        let column = try getFirstString()
        let rt = table(try resultsTable(try titleArgument()))
        if column == "Label" && rt.labels.contains(where: { $0 != nil }) {
            return Variable(VariableArray(rt.labels.map { Variable($0 ?? "") }))
        }
        guard rt.columns.contains(column) else { try interp.fail("\"\(column)\" column not found") }
        return Variable(VariableArray((0..<rt.count).map { row -> Variable in
            if case .text(let s)? = rt.value(column, row: row) { return Variable(s) }
            return Variable(rt.number(column, row: row))
        }))
    }

    /// `Table.setColumn(column, array, title)`: shorter arrays blank the
    /// column's other cells; longer ones blank the other columns' new rows.
    private func setTableColumn() throws(MacroSignal) {
        let column = try getFirstString()
        var values: [Variable] = []
        if interp.nextToken() != ch(")") {
            try interp.getComma()
            values = try getArray().elements
        }
        let title = try resultsTable(try titleArgument())
        var rt = table(title)
        let initialSize = rt.count
        let others = rt.columns.filter { $0 != column }
        for (row, v) in values.enumerated() {
            if row == rt.count { rt.addRow() }
            if let s = v.getString() { rt.set(column, row: row, .text(s)) } else { rt.set(column, row: row, v.getValue()) }
        }
        if values.count < rt.count {
            for row in values.count..<rt.count { rt.set(column, row: row, .text("")) }
        }
        if values.isEmpty && rt.count == 0 && !rt.columns.contains(column) {
            rt.set(column, row: 0, .text(""))
            rt.removeRows(0, 0)
        }
        if initialSize > 0 && rt.count > initialSize {
            for other in others {
                for row in initialSize..<rt.count { rt.set(other, row: row, .text("")) }
            }
        }
        store(title, rt)
        session.showTable(title)
    }

    /// `ResultsTable.sort`: ascending, text before numbers, keeping ties in order.
    static func sortOrder(_ rt: ResultsTable, _ column: String) -> [Int] {
        func text(_ row: Int) -> String? {
            if case .text(let s)? = rt.value(column, row: row), s != "NaN" { return s }
            return nil
        }
        return stableSorted(Array(0..<rt.count)) { a, b in
            switch (text(a), text(b)) {
            case (let s?, let t?): return javaCompare(s, t)
            case (_?, nil): return -1
            case (nil, _?): return 1
            case (nil, nil):
                let x = rt.number(column, row: a), y = rt.number(column, row: b)
                return x < y ? -1 : x > y ? 1 : 0
            }
        }
    }

    /// `ResultsTable.saveAs(path)` of the table `title`, its numbers as
    /// `getResultString` shows them: comma-separated for ".csv", else tab-separated.
    func saveTable(_ title: String, to path: String) throws(MacroSignal) {
        if path.isEmpty { try unsupported("Table.save with a save dialog") }
        let rt = table(title)
        let display = session.display(title)
        try saveTable(
            rt, to: path, rowNumbers: rowNumbers(title), firstRowNumber: display.baseRowNumber,
            columnHeadings: display.saveHeaders, fixed: rt.decimalColumns, places: precision(title))
    }

    /// `Table.open`: `ResultsTable.open(path)` shown as `title`.
    func openTable(_ path: String, as title: String) throws(MacroSignal) {
        if path.isEmpty { try unsupported("Table.open with a file dialog") }
        guard FileManager.default.fileExists(atPath: path) else { try interp.fail("Error opening " + path) }
        let rt: ResultsTable
        do {
            rt = try ResultsTableIO.read(path: path, parse: { javaParseDouble($0) })
        } catch .invalidFormat(let message) {
            try interp.fail(message)
        } catch {
            try interp.fail("\(error)")
        }
        showOpenedTable(rt, as: title)
    }

    /// `ResultsTable.show(title)` of a table read from a file: it comes to the front.
    func showOpenedTable(_ rt: ResultsTable, as title: String) {
        store(title, rt)
        session.tableDisplay[title] = nil
        session.showTable(title)
    }

    // MARK: - Array.show

    /// `Array.show(title, a, b, ...)`: the arrays as the columns of a table;
    /// "(row numbers)" or "(indexes)" in the title add a column of them.
    func showArray() throws(MacroSignal) {
        var maxLength = 0
        var title = "Arrays"
        var arrays: [[Variable]] = []
        var names: [String] = []
        try interp.getLeftParen()
        repeat {
            if isStringArg() && !isArrayArg() {
                title = try getString()
            } else {
                names.append(pgm.table[interp.code(interp.pc + 1) >> TOK_SHIFT].str ?? "")
                let a = try getArray().elements
                arrays.append(a)
                maxLength = max(maxLength, a.count)
            }
            interp.getToken()
        } while interp.token == ch(",")
        if interp.token != ch(")") { try interp.error("')' expected") }
        if arrays.count == 1 {
            if title == "Arrays" { title = names[0] }
            names[0] = "Value"
        }
        var rt = ResultsTable.custom()
        var rowNumbers = false
        let paren = javaIndexOf(title, "(")
        if paren >= 0 {
            let options = javaSubstring(title, paren)
            title = javaTrim(javaSubstring(title, 0, paren))
            rowNumbers = javaContains(options, "row") || javaContains(options, "1")
            if !rowNumbers && javaContains(options, "index") {
                for i in 0..<maxLength {
                    if i == rt.count { rt.addRow() }
                    rt.set("Index", row: i, .text(String(i)))
                }
            }
        }
        for (a, heading) in zip(arrays, names) {
            for i in 0..<maxLength {
                if i == rt.count { rt.addRow() }
                if i >= a.count {
                    rt.set(heading, row: i, .text(""))
                } else if let s = a[i].getString() {
                    rt.set(heading, row: i, .text(s))
                } else {
                    rt.set(heading, row: i, a[i].getValue())
                }
            }
        }
        if rowNumbers { rt.showsRowNumbers = true }
        store(title, rt)
        session.tableDisplay[title] = nil
        session.showTable(title)
    }

    // MARK: - Table.applyMacro

    /// `Table.applyMacro(code, title)`: runs `code` once per row, with each
    /// column a variable (named as `getHeadingsAsVariableNames` makes them)
    /// and `row` the row index. Columns the code changes are written back;
    /// new variables starting with a capital letter become new columns.
    private func applyMacroToTable() throws(MacroSignal) {
        var macro = try getFirstString()
        var title = try titleArgument()
        if macro == "Results" {
            macro = title ?? "null"
            title = "Results"
        }
        let key = try resultsTable(title)
        var rt = table(key)
        let hasLabels = rt.labels.contains { $0 != nil }
        let headings = (hasLabels ? ["Label"] : []) + rt.columns
        let names = Self.variableNames(headings)
        let isLabel = headings.indices.map { hasLabels && $0 == 0 }
        // A first run with row 0's values (made positive), as ImageJ does, to find the variables.
        var code = "var "
        for (i, name) in names.enumerated() {
            code += name + "="
            if isLabel[i] {
                code += "\"" + (rt.labels.first.flatMap { $0 } ?? "") + "\""
            } else {
                code += javaString(abs(rt.count > 0 ? rt.number(headings[i], row: 0) : 0))
            }
            code += ","
        }
        code += "row;\nfunction dummy() {}\n" + macro + ";\n"
        let start = 9 + 4 * names.count
        let inner = Interpreter(session: session)
        inner.applyMacroTable = key
        let program = Tokenizer.tokenize(code)
        do {
            try inner.saveGlobals2(program)
            try inner.run(program)
        } catch {
            if case .error(let e) = error { throw .error(e) }
        }
        var inUse = [Bool](repeating: false, count: names.count)
        var newColumns: [String] = []
        for v in inner.stack {
            guard let variable = program.table[v.symTabIndex].str else { continue }
            if let i = names.firstIndex(of: variable) {
                inUse[i] = javaContains(macro, variable)
            } else if let c = variable.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(c),
                !newColumns.contains(variable)
            {
                newColumns.append(variable)
            }
        }
        for row in 0..<rt.count {
            for (i, name) in names.enumerated() where inUse[i] {
                if isLabel[i] {
                    inner.firstVariable(name)?.setString(rt.labels[row])
                } else {
                    inner.setFirstVariable(name, rt.number(headings[i], row: row))
                }
            }
            inner.setFirstVariable("row", Double(row))
            store(key, rt)
            try inner.run(from: start)
            rt = table(key)
            for (i, name) in names.enumerated() where inUse[i] {
                if isLabel[i] {
                    rt.setLabel(inner.variableAsString(named: name), row: row)
                } else {
                    rt.set(headings[i], row: row, inner.firstVariable(name)?.getValue() ?? .nan)
                }
            }
            for column in newColumns { rt.set(column, row: row, inner.firstVariable(column)?.getValue() ?? .nan) }
        }
        store(key, rt)
        session.showTable(key)
    }

    /// `getHeadingsAsVariableNames`: headings made into unique variable names.
    static func variableNames(_ headings: [String]) -> [String] {
        var names: [String] = []
        for heading in headings {
            var name = heading
            if let c = name.unicodeScalars.first, ("0"..."9").contains(c) { name = "_" + name }
            name = String(name.unicodeScalars.map { c -> Character in
                c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_") ? Character(c) : "_"
            })
            var postfix = 0
            while names.contains(name) {
                if postfix > 0 { name = javaSubstring(name, 0, javaLastIndexOf(name, "_")) }
                name += "_\(postfix)"
                postfix += 1
            }
            names.append(name)
        }
        return names
    }
}

extension Interpreter {
    /// `run(location)`: runs the program again from a token, with the globals kept.
    func run(from location: Int) throws(MacroSignal) {
        topOfStack = topOfGlobals
        done = false
        pc = location - 1
        try doStatements()
    }

    /// `getVariable(name)` and `setVariable(name, value)`: the outermost variable called `name`.
    func firstVariable(_ name: String) -> Variable? {
        stack.first { pgm.table[$0.symTabIndex].str == name }
    }

    func setFirstVariable(_ name: String, _ value: Double) {
        firstVariable(name)?.setValue(value)
    }
}
