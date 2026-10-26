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

    /// Column headings in the order columns were first used.
    public private(set) var columns: [String] = []
    private var cells: [[String: Value]] = []
    /// ImageJ's "Label" column.
    public private(set) var labels: [String?] = []

    public init() {}

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
        if !columns.contains(column) { columns.append(column) }
        cells[row][column] = value
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

    /// ImageJ's `getValue(column, row)`: NaN for missing cells or text.
    public func number(_ column: String, row: Int) -> Double {
        value(column, row: row)?.number ?? .nan
    }

    public mutating func reset() {
        columns = []
        cells = []
        labels = []
    }
}
