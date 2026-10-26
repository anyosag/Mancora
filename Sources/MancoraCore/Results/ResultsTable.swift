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
    public var columns: [String] {
        used.filter { Self.standardIndex[$0] != nil }.sorted { Self.standardIndex[$0]! < Self.standardIndex[$1]! }
            + used.filter { Self.standardIndex[$0] == nil }
    }
    private var used: [String] = []
    private var cells: [[String: Value]] = []
    /// ImageJ's "Label" column.
    public private(set) var labels: [String?] = []
    /// Whether cells never set read as NaN rather than 0 (Set Measurements ▸ NaN empty cells).
    public var emptyCellsAreNaN = false

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
        if !used.contains(column) { used.append(column) }
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
    }
}
