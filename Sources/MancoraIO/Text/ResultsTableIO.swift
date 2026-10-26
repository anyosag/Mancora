#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import MancoraCore

/// Results and other tables as text files, following ImageJ 1.54p's
/// `ResultsTable.saveAs` and `ResultsTable.open`.
///
/// - A path ending in `.csv` (or `.CSV`) means commas; anything else
///   (`.xls`, `.tsv`, `.txt`, no extension) means tabs. Saving to CSV
///   quotes cells that contain a comma or are empty, and turns commas in
///   row labels into semicolons.
/// - The first column is " ", the row numbers, when the table shows them
///   (the Results table does by default); then "Label" when rows have
///   labels; then the columns.
/// - Opening skips a " " column, reads "Label" after it as row labels,
///   numbers as numbers and anything else as text, and names the columns
///   C1, C2, … when every heading is a number (the first line is then data).
public enum ResultsTableIO {
    /// Whether ImageJ treats `path` as CSV.
    public static func isCSV(_ path: String) -> Bool { path.hasSuffix(".csv") || path.hasSuffix(".CSV") }

    /// The title ImageJ shows an opened table under (`Opener.openTable`):
    /// the file name, or "Results" for `Results.*`.
    public static func title(forPath path: String) -> String {
        let name = FileType.fileName(path)
        return name.hasPrefix("Results.") ? "Results" : name
    }

    // MARK: Saving

    /// The file `ResultsTable.saveAs` writes: a heading line (unless the
    /// table has no rows and no columns) and one line per row, each ending
    /// in a newline.
    ///
    /// `format(value, fixed)` gives a number's text as the table shows it.
    /// `fixed` is true for a column ImageJ shows with its set number of
    /// decimal places: one with a fraction in its first 25 rows (a value
    /// that `(int)` changes). Other columns show integers without decimals.
    public static func encode(_ rt: ResultsTable, csv: Bool, rowNumbers: Bool, format: (Double, Bool) -> String) -> String {
        var out = ""
        if !(rt.count == 0 && rt.columns.isEmpty) { out += headingLine(rt, csv: csv, rowNumbers: rowNumbers) + "\n" }
        let fixed = fixedColumns(rt)
        for row in 0..<rt.count {
            out += rowLine(rt, row: row, csv: csv, rowNumbers: rowNumbers, fixed: fixed, format: format) + "\n"
        }
        return out
    }

    /// `ResultsTable.getColumnHeadings()`: " " for row numbers, "Label" when
    /// a row has one, then the columns.
    public static func headingLine(_ rt: ResultsTable, csv: Bool, rowNumbers: Bool) -> String {
        let delimiter = csv ? "," : "\t"
        var heading = rowNumbers ? " " + delimiter : ""
        if rt.labels.contains(where: { $0 != nil }) { heading += "Label" + delimiter }
        return heading + rt.columns.joined(separator: delimiter)
    }

    /// The columns ImageJ shows with a fixed number of decimal places: those
    /// with a fraction in their first 25 rows.
    public static func fixedColumns(_ rt: ResultsTable) -> Set<String> {
        Set(rt.columns.filter { column in
            (0..<min(25, rt.count)).contains { row in
                guard case .number(let v)? = rt.value(column, row: row) else { return false }
                return !v.isNaN && !isJavaInt(v)
            }
        })
    }

    /// `ResultsTable.getRowAsString(row)`, quoting for CSV as `saveAs` does.
    public static func rowLine(
        _ rt: ResultsTable, row: Int, csv: Bool, rowNumbers: Bool, fixed: Set<String>, format: (Double, Bool) -> String
    ) -> String {
        let delimiter = csv ? "," : "\t"
        var line = rowNumbers ? String(row + 1) + delimiter : ""
        if rt.labels.contains(where: { $0 != nil }) {
            if let label = rt.labels[row] { line += csv ? label.replacing(",", with: ";") : label }
            line += delimiter
        }
        line += rt.columns.map { column -> String in
            var value: String
            if case .text(let s)? = rt.value(column, row: row) {
                value = s.replacing("\n", with: "\\n")
            } else {
                value = format(rt.number(column, row: row), fixed.contains(column))
            }
            if csv, value.contains(",") || value.isEmpty { value = "\"" + value + "\"" }
            return value
        }.joined(separator: delimiter)
        return line
    }

    /// Saves the table as `ResultsTable.saveAs(path)` does, with commas for
    /// `.csv` and tabs otherwise.
    public static func save(_ rt: ResultsTable, to path: String, rowNumbers: Bool, format: (Double, Bool) -> String = defaultFormat)
        throws(MancoraIOError)
    {
        let text = encode(rt, csv: isCSV(path), rowNumbers: rowNumbers, format: format)
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
    }

    /// Whether Java's `(int)value == value`.
    static func isJavaInt(_ v: Double) -> Bool {
        v.isFinite && v >= -2_147_483_648 && v <= 2_147_483_647 && v == v.rounded(.towardZero)
    }

    /// ImageJ's formats with its default 3 decimal places: integers without
    /// decimals unless the column is `fixed`. (Macros pass ImageJ's exact formatter.)
    public static let defaultFormat: @Sendable (Double, Bool) -> String = { value, fixed in
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if !fixed, isJavaInt(value) { return String(Int(value)) }
        let thousandths = (abs(value) * 1000).rounded()
        guard thousandths < 1e15 else { return "\(value)" }
        let n = Int64(thousandths)
        let fraction = String(n % 1000)
        return (value < 0 ? "-" : "") + String(n / 1000) + "." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }

    // MARK: Opening

    /// Reads a table file as `ResultsTable.open(path)` does. The table shows
    /// row numbers when the path contains "Results". `parse` reads a number
    /// as Java's `Double.parseDouble` does, or returns `nil`.
    public static func read(path: String, parse: (String) -> Double? = defaultParse) throws(MancoraIOError) -> ResultsTable {
        let bytes = try FileLoader.load(path: path, limit: 1 << 30)
        var rt = try decode(String(decoding: bytes, as: UTF8.self), csv: isCSV(path), parse: parse)
        if !rt.isEmpty { rt.showsRowNumbers = path.contains("Results") }
        return rt
    }

    /// The commas inside quotes stand for this character while a CSV file
    /// is split, as in ImageJ.
    static let commaSubstitute: Character = "\u{08B3}"

    public static func decode(_ fileText: String, csv: Bool, parse: (String) -> Double? = defaultParse) throws(MancoraIOError)
        -> ResultsTable
    {
        // IJ.openAsString: every line, whatever ended it, followed by "\n".
        var text = javaLines(fileText).map { $0 + "\n" }.joined()
        if text.isEmpty { return ResultsTable() }
        let separator: Character = csv ? "," : "\t"
        var commasReplaced = false
        if csv, text.contains("\"") {
            var inQuotes = false
            text = String(text.map { c -> Character in
                if c == "\"" { inQuotes.toggle() }
                return inQuotes && c == "," ? commaSubstitute : c
            })
            commasReplaced = true
        }
        func number(_ s: String) -> Double? { parse(s) }
        let lines = javaSplit(text, "\n")
        guard !lines.isEmpty, !(lines.count == 1 && lines[0].isEmpty) else {
            throw .invalidFormat("Table is empty or invalid")
        }
        var headings = javaSplit(lines[0], separator)
        guard !headings.isEmpty else { throw .invalidFormat("This is not a tab or comma delimited text file.") }
        if headings[0].hasPrefix("\u{FEFF}") { headings[0].removeFirst() }
        let allNumeric = headings.allSatisfy { $0 == "NaN" || (number($0).map { !$0.isNaN } ?? false) }
        if allNumeric { headings = (1...headings.count).map { "C\($0)" } }
        var firstColumn = headings[0] == " " ? 1 : 0
        headings = headings.map { h in
            var h = javaTrim(h)
            if commasReplaced, h.count >= 2, h.hasPrefix("\""), h.hasSuffix("\"") { h = String(h.dropFirst().dropLast()) }
            return h
        }
        let firstRow = allNumeric ? 0 : 1
        let labels = firstColumn == 1 && headings.count > 1 && headings[1] == "Label"
        // getTableType looks at the second line whatever the first row is.
        var type = 0
        if lines.count >= 2 {
            let items = javaSplit(lines[1], separator)
            var count = 0, index = 0
            for (i, item) in items.enumerated() where item != "NaN" && (number(item).map(\.isNaN) ?? true) {
                count += 1
                index = i
            }
            type = count == 0 ? 0 : count == 1 && index == 1 ? 1 : count == 1 && index == 0 ? 2 : 3
        }
        let labelsIndex = type == 2 ? 0 : 1
        if lines[0].hasPrefix("\t") {
            headings.insert(" ", at: 0)
            firstColumn = 1
        }
        var rt = ResultsTable()
        guard firstRow < lines.count else { return rt }
        for line in lines[firstRow...] {
            let row = rt.addRow()
            let items = javaSplit(line, separator)
            for j in firstColumn..<headings.count {
                if j == labelsIndex && labels {
                    rt.setLabel(labelsIndex < items.count ? items[labelsIndex] : "", row: row)
                    continue
                }
                guard j < items.count else {
                    rt.set(headings[j], row: row, .number(.nan))
                    continue
                }
                if let value = number(items[j]) {
                    rt.set(headings[j], row: row, .number(value))
                } else {
                    var item = items[j]
                    if commasReplaced {
                        item = item.replacing(String(commaSubstitute), with: ",")
                        if item.count >= 2, item.hasPrefix("\""), item.hasSuffix("\"") { item = String(item.dropFirst().dropLast()) }
                    }
                    rt.set(headings[j], row: row, .text(item))
                }
            }
        }
        return rt
    }

    /// Java's `Double.parseDouble`, or `nil` where it throws: surrounding
    /// characters up to space trimmed, an optional sign, "NaN",
    /// "Infinity", or decimal digits with an optional exponent and an
    /// optional `f`/`d` suffix.
    public static let defaultParse: @Sendable (String) -> Double? = { s in
        var t = Substring(javaTrim(s))
        if let last = t.last, "fFdD".contains(last), t.count > 1 { t = t.dropLast() }
        var body = t
        var sign = ""
        if let first = body.first, first == "+" || first == "-" {
            if first == "-" { sign = "-" }
            body = body.dropFirst()
        }
        if body == "NaN" { return .nan }
        if body == "Infinity" { return sign == "-" ? -.infinity : .infinity }
        let allowed = Set("0123456789.eE+-")
        guard let first = body.first, first.isNumber || first == ".", body.allSatisfy({ allowed.contains($0) }),
            body.contains(where: \.isNumber)
        else { return nil }
        return Double(sign + body)
    }

    /// `String.trim()`: drops leading and trailing characters at or below U+0020.
    static func javaTrim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let start = scalars.firstIndex(where: { $0.value > 0x20 }) else { return "" }
        let end = scalars.lastIndex(where: { $0.value > 0x20 })!
        return String(scalars[start...end])
    }

    /// `String.split` with a one-character pattern: trailing empty strings removed.
    static func javaSplit(_ s: String, _ separator: Character) -> [String] {
        var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }

    /// The lines `BufferedReader.readLine` returns: ended by "\n", "\r" or "\r\n".
    static func javaLines(_ s: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousCR = false
        for c in s.unicodeScalars {
            if c == "\n" {
                if !previousCR { lines.append(current) }
                current = ""
                previousCR = false
            } else if c == "\r" {
                lines.append(current)
                current = ""
                previousCR = true
            } else {
                current.unicodeScalars.append(c)
                previousCR = false
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
