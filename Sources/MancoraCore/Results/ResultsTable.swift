/// A table of measurements, like ImageJ's `ResultsTable`: named columns of
/// numbers (or text), one row per measurement, with an optional row label.
///
/// Columns sit in numbered slots, as in ImageJ: a column added by name goes
/// to the slot already holding that heading (looking only as far as the
/// first slot without one) or the first free slot; Analyze ▸ Measure's
/// standard columns go to their fixed slots (``setStandard(_:row:_:)``),
/// whose headings ``setDefaultHeadings()`` fills in.
public struct ResultsTable: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case number(Double)
        case text(String)

        public var number: Double? {
            if case .number(let n) = self { return n }
            return nil
        }
    }

    /// ImageJ's standard measurement headings, in its fixed column order.
    public static let standardHeadings = [
        "Area", "Mean", "StdDev", "Mode", "Min", "Max", "X", "Y", "XM", "YM", "Perim.", "BX", "BY", "Width",
        "Height", "Major", "Minor", "Angle", "Circ.", "Feret", "IntDen", "Median", "Skew", "Kurt", "%Area",
        "RawIntDen", "Ch", "Slice", "Frame", "FeretX", "FeretY", "FeretAngle", "MinFeret", "AR", "Round",
        "Solidity", "MinThr", "MaxThr",
    ]
    private static let standardIndex = Dictionary(
        uniqueKeysWithValues: standardHeadings.enumerated().map { ($1, $0) })

    /// Each slot's heading (ImageJ's `headings`), `nil` while free.
    private var headings: [String?] = []
    /// Whether each slot holds a column (ImageJ's `columns[i] != null`).
    private var present: [Bool] = []
    /// Columns set by name, which Set Measurements leaves alone (ImageJ's `keep`).
    private var kept: [Bool] = []
    /// Rows by slot. Deleted rows' numbers stay behind for the rows added
    /// next, as in ImageJ's column arrays (`deleteRow` only moves values up).
    private var cells: [[Int: Value]] = []
    private var rowLabels: [String?] = []
    private var rows = 0
    /// The highest slot that has held a column since the table was reset
    /// (ImageJ's `getLastColumn()`), or -1.
    public private(set) var lastColumn = -1
    /// ImageJ's "Label" column.
    public var labels: [String?] { Array(rowLabels.prefix(rows)) }
    /// Whether cells never set read as NaN rather than 0 (Set Measurements ▸ NaN empty cells).
    public var emptyCellsAreNaN = false
    /// Columns shown with the table's decimal places, integers included:
    /// those that have held a value that isn't an int, and the shape
    /// descriptors (ImageJ's `decimalPlaces[column]` other than AUTO_FORMAT).
    public private(set) var decimalColumns: Set<String> = []
    /// ImageJ's `showRowNumbers` once something has set it (opening a file,
    /// `Table.showRowNumbers`), or `nil` for the default of the window the
    /// table is shown in: row numbers in "Results", none elsewhere. Saved
    /// tables start with a " " column of row numbers when this is on.
    public var showsRowNumbers: Bool?

    public init() {}

    public var count: Int { rows }
    public var isEmpty: Bool { rows == 0 }

    /// The columns' headings, slot by slot (ImageJ's `getHeadings()` without "Label").
    public var columns: [String] {
        present.indices.filter { present[$0] }.map { headings[$0] ?? "C\($0 + 1)" }
    }

    /// The heading of the last standard slot (ImageJ's
    /// `getColumnHeading(LAST_HEADING)`): "MaxThr" once the default
    /// headings are set.
    public var lastHeading: String? {
        let last = Self.standardHeadings.count - 1
        return last < headings.count ? headings[last] : nil
    }

    /// Whether the default headings are set (``lastHeading`` starts with "M").
    public var hasDefaultHeadings: Bool { lastHeading?.first == "M" }

    /// `setDefaultHeadings()`: the standard slots get their headings.
    public mutating func setDefaultHeadings() {
        grow(to: Self.standardHeadings.count)
        for (i, heading) in Self.standardHeadings.enumerated() { headings[i] = heading }
    }

    /// Appends an empty row and returns its index (`incrementCounter`).
    @discardableResult
    public mutating func addRow(label: String? = nil) -> Int {
        if rows < cells.count {
            // incrementCounter: the row's old numbers and label are still there.
            if let label { rowLabels[rows] = label }
        } else {
            cells.append([:])
            rowLabels.append(label)
        }
        rows += 1
        return rows - 1
    }

    /// `columnExists(getColumnIndex(heading))`: whether the column ImageJ
    /// finds by that heading holds values.
    public func columnExists(_ column: String) -> Bool {
        slot(of: column).map { present[$0] } ?? false
    }

    /// `getColumnIndex(heading)`: the first slot with the heading, looking
    /// no further than the first slot without one.
    private func slot(of column: String) -> Int? {
        for (i, heading) in headings.enumerated() {
            guard let heading else { return nil }
            if heading == column { return i }
        }
        return nil
    }

    private mutating func grow(to n: Int) {
        while headings.count < n {
            headings.append(nil)
            present.append(false)
            kept.append(false)
        }
    }

    /// `getFreeColumn(heading)`: the first slot without a heading.
    private mutating func freeSlot(_ column: String) -> Int {
        let i = headings.firstIndex(where: { $0 == nil }) ?? headings.count
        grow(to: i + 1)
        headings[i] = column
        return i
    }

    /// Sets a cell of slot `i`, creating the column.
    private mutating func set(slot i: Int, row: Int, _ value: Value) {
        present[i] = true
        lastColumn = max(lastColumn, i)
        cells[row][i] = value
        // `(int)value != value && !Double.isNaN(value)`
        if case .number(let n) = value, !n.isNaN, !(n >= -2147483648 && n <= 2147483647 && n == n.rounded(.towardZero)) {
            decimalColumns.insert(headings[i] ?? "C\(i + 1)")
        }
    }

    /// `setValue(column, row, value)` / `addValue(column, value)`: the
    /// column's slot, or a free one for a new column.
    public mutating func set(_ column: String, row: Int, _ value: Value) {
        let i = slot(of: column) ?? freeSlot(column)
        kept[i] = true
        set(slot: i, row: row, value)
    }

    public mutating func set(_ column: String, row: Int, _ number: Double) {
        set(column, row: row, .number(number))
    }

    /// `addValue(int column, value)` for one of the ``standardHeadings``:
    /// its fixed slot, headed "C<n>" if the default headings aren't set.
    public mutating func setStandard(_ column: String, row: Int, _ value: Double) {
        guard let i = Self.standardIndex[column] else {
            set(column, row: row, .number(value))
            return
        }
        grow(to: i + 1)
        if headings[i] == nil { headings[i] = "C\(i + 1)" }
        set(slot: i, row: row, .number(value))
    }

    /// `setDecimalPlaces(column, precision)`: shows `column` with decimals from now on.
    public mutating func setDecimal(_ column: String) {
        decimalColumns.insert(column)
    }

    public mutating func setLabel(_ label: String?, row: Int) {
        rowLabels[row] = label
    }

    /// The cell of the first column with that heading.
    public func value(_ column: String, row: Int) -> Value? {
        guard row >= 0, row < rows,
            let i = present.indices.first(where: { present[$0] && headings[$0] == column })
        else { return nil }
        return cells[row][i]
    }

    /// ImageJ's `getValue(column, row)`: NaN for text, and 0 (or NaN, with
    /// ``emptyCellsAreNaN``) for a cell never set.
    public func number(_ column: String, row: Int) -> Double {
        switch value(column, row: row) {
        case .number(let n)?: n
        case .text?: .nan
        case nil: emptyCellsAreNaN ? .nan : 0
        }
    }

    /// The heading and set-by-name flag of each column, slot by slot.
    public var columnSlots: [(slot: Int, heading: String, kept: Bool)] {
        present.indices.filter { present[$0] }.map { ($0, headings[$0] ?? "C\($0 + 1)", kept[$0]) }
    }

    /// Creates an empty column at `slot` with `heading` unless it has one
    /// (`ResultsTable.update`).
    public mutating func addColumn(_ heading: String, slot i: Int) {
        grow(to: i + 1)
        guard !present[i] else { return }
        present[i] = true
        headings[i] = heading
        lastColumn = max(lastColumn, i)
    }

    /// Removes the column at `slot`, keeping its heading (`columns[i] = null`).
    public mutating func removeColumn(slot i: Int) {
        guard i < present.count else { return }
        present[i] = false
        for r in cells.indices { cells[r][i] = nil }
    }

    /// Clears the Label column (`disableRowLabels`).
    public mutating func removeLabels() {
        rowLabels = Array(repeating: nil, count: rowLabels.count)
    }

    /// `deleteRow(row)`: the rows below move up; the columns stay.
    public mutating func removeRow(_ row: Int) {
        guard row >= 0, row < rows else { return }
        rowLabels[row] = nil
        for i in row..<(rows - 1) {
            rowLabels[i] = rowLabels[i + 1]
            cells[i] = cells[i + 1]
        }
        // Text isn't left behind (ImageJ's string columns shrink).
        cells[rows - 1] = cells[rows - 1].filter { $0.value.number != nil }
        rows -= 1
    }

    /// Deletes the last `n` rows.
    public mutating func removeLastRows(_ n: Int) {
        for _ in 0..<min(max(n, 0), rows) { removeRow(rows - 1) }
    }

    /// `deleteRows(first, last)`.
    public mutating func removeRows(_ range: ClosedRange<Int>) {
        let first = max(range.lowerBound, 0)
        guard range.upperBound >= first else { return }
        for _ in first...range.upperBound { removeRow(first) }
    }

    /// `reset()`: no rows, columns or headings.
    public mutating func reset() {
        lastColumn = -1
        headings = []
        present = []
        kept = []
        cells = []
        rowLabels = []
        rows = 0
        decimalColumns = []
    }
}
