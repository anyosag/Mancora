/// A table of measurements, like ImageJ's `ResultsTable`: named columns of
/// numbers (or text), one row per measurement, with an optional row label.
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

    /// Column headings as ImageJ orders them: the standard ones in their
    /// fixed order, then the others in the order they were first used.
    /// Tables without ImageJ's default headings keep every column in the
    /// order it was first used.
    public var columns: [String] {
        guard hasDefaultHeadings else { return used }
        return used.filter { Self.standardIndex[$0] != nil }.sorted { Self.standardIndex[$0]! < Self.standardIndex[$1]! }
            + used.filter { Self.standardIndex[$0] == nil }
    }
    private var used: [String] = []
    private var cells: [[String: Value]] = []
    /// ImageJ's "Label" column.
    public private(set) var labels: [String?] = []
    /// Whether cells never set read as NaN rather than 0 (Set Measurements ▸ NaN empty cells).
    public var emptyCellsAreNaN = false
    /// Whether the standard measurement headings have their fixed columns,
    /// as in the Results table (`setDefaultHeadings`); a new table of
    /// ImageJ's has none.
    public var hasDefaultHeadings = true
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

    /// An empty table whose columns stay in the order they are first used.
    public static func custom() -> ResultsTable {
        var table = ResultsTable()
        table.hasDefaultHeadings = false
        return table
    }

    public var count: Int { cells.count }
    public var isEmpty: Bool { cells.isEmpty }

    /// Appends an empty row and returns its index (`incrementCounter`).
    @discardableResult
    public mutating func addRow(label: String? = nil) -> Int {
        cells.append([:])
        labels.append(label)
        return cells.count - 1
    }

    public mutating func set(_ column: String, row: Int, _ value: Value) {
        if !used.contains(column) { used.append(column) }
        cells[row][column] = value
        // `(int)value != value && !Double.isNaN(value)`
        if case .number(let n) = value, !n.isNaN, !(n >= -2147483648 && n <= 2147483647 && n == n.rounded(.towardZero)) {
            decimalColumns.insert(column)
        }
    }

    /// `setDecimalPlaces(column, precision)`: shows `column` with decimals from now on.
    public mutating func setDecimal(_ column: String) {
        decimalColumns.insert(column)
    }

    public mutating func set(_ column: String, row: Int, _ number: Double) {
        set(column, row: row, .number(number))
    }

    public mutating func setLabel(_ label: String?, row: Int) {
        labels[row] = label
    }

    public func value(_ column: String, row: Int) -> Value? {
        guard row >= 0, row < cells.count else { return nil }
        return cells[row][column]
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

    /// Clears the Label column (`disableRowLabels`).
    public mutating func removeLabels() {
        labels = Array(repeating: nil, count: labels.count)
    }

    public mutating func reset() {
        used = []
        cells = []
        labels = []
        decimalColumns = []
    }

    /// Renames a column, keeping its place, values and format.
    public mutating func renameColumn(_ old: String, to new: String) {
        guard let i = used.firstIndex(of: old) else { return }
        used[i] = new
        for row in cells.indices {
            if let value = cells[row].removeValue(forKey: old) { cells[row][new] = value }
        }
        if decimalColumns.remove(old) != nil { decimalColumns.insert(new) }
    }

    /// Removes a column and its values.
    public mutating func removeColumn(_ column: String) {
        used.removeAll { $0 == column }
        for row in cells.indices { cells[row][column] = nil }
        decimalColumns.remove(column)
    }

    /// Removes rows `first` through `last` (clamped to the table).
    public mutating func removeRows(_ first: Int, _ last: Int) {
        let lo = max(0, first), hi = min(cells.count - 1, last)
        guard lo <= hi else { return }
        cells.removeSubrange(lo...hi)
        labels.removeSubrange(lo...hi)
    }

    /// Puts the rows in the order `order` lists them (each row once).
    public mutating func reorderRows(_ order: [Int]) {
        cells = order.map { cells[$0] }
        labels = order.map { labels[$0] }
    }
}
