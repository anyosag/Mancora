import AppKit
import MancoraCore
import SwiftUI
import UniformTypeIdentifiers

/// ImageJ's Results window: every measurement so far, with the row number
/// and label, numbers shown with Set Measurements' decimal places.
struct ResultsWindow: View {
    let session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            if session.results.isEmpty {
                ContentUnavailableView("No Results", systemImage: "tablecells", description: Text("Analyze ▸ Measure adds a row."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultsTableView(table: session.results, decimals: session.settings.decimalPlaces)
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 220)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                    .help("Copy the table to the clipboard")
                    .disabled(session.results.isEmpty)
                Button("Save As…", systemImage: "square.and.arrow.down") { save() }
                    .help("Save the table as a CSV file")
                    .disabled(session.results.isEmpty)
                Button("Clear Results", systemImage: "trash") { session.clearResults() }
                    .help("Remove every row from the table")
                    .disabled(session.results.isEmpty)
            }
        }
    }

    /// The row count, small, under the table.
    private var footer: some View {
        HStack {
            Text(session.results.count == 1 ? "1 row" : "\(session.results.count) rows")
            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            ResultsText.text(session.results, decimals: session.settings.decimalPlaces, separator: "\t"), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ResultsText.text(session.results, decimals: session.settings.decimalPlaces, separator: ",")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A table's cells as ImageJ's TextPanel shows them.
enum ResultsText {
    static func headings(_ table: ResultsTable) -> [String] {
        let hasLabels = table.labels.contains { $0 != nil }
        return [" "] + (hasLabels ? ["Label"] : []) + table.columns
    }

    static func cells(_ table: ResultsTable, row: Int, decimals: Int) -> [String] {
        let hasLabels = table.labels.contains { $0 != nil }
        var cells = ["\(row + 1)"]
        if hasLabels { cells.append(table.labels[row] ?? "") }
        for column in table.columns {
            cells.append(cell(table, row: row, column: column, decimals: decimals))
        }
        return cells
    }

    /// One measurement column's cell.
    static func cell(_ table: ResultsTable, row: Int, column: String, decimals: Int) -> String {
        switch table.value(column, row: row) {
        case .number(let v)?: return format(v, decimals: decimals)
        case .text(let t)?: return t
        case nil: return table.emptyCellsAreNaN ? "NaN" : "0"
        }
    }

    /// Whole numbers without decimals, as ImageJ's auto format shows them.
    static func format(_ v: Double, decimals: Int) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
        if v == v.rounded(), abs(v) < 1e9 { return String(Int64(v)) }
        return String(format: "%.\(decimals)f", v)
    }

    static func text(_ table: ResultsTable, decimals: Int, separator: String) -> String {
        var lines = [headings(table).joined(separator: separator)]
        for row in 0..<table.count {
            let cells = cells(table, row: row, decimals: decimals)
            lines.append(separator == "," ? cells.map(quoted).joined(separator: ",") : cells.joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoted(_ cell: String) -> String {
        cell.contains(",") || cell.contains("\"") ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
    }
}

// MARK: The table

/// The table itself, in an `NSTableView` (which fills its window with
/// ruled rows, scrolls both ways and keeps its header in view): a table's
/// columns are whatever was measured, which SwiftUI's `Table` on macOS 14.0
/// can't take. The cells are the strings of `ResultsText`: numbers right
/// aligned in digits of one width, the row numbers small and gray.
struct ResultsTableView: NSViewRepresentable {
    let table: ResultsTable
    let decimals: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = ResultsNSTableView()
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView
        context.coordinator.update(table: table, decimals: decimals)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(table: table, decimals: decimals)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Kind: Equatable {
            case rowNumber
            case label
            case value(String)
        }

        /// The table's columns, as the window shows them.
        struct Layout: Equatable {
            var titles: [String] = []
            var kinds: [Kind] = []
            var rightAligned: [Bool] = []
        }

        weak var tableView: ResultsNSTableView?
        private var table = ResultsTable()
        private var decimals = 3
        private var layout = Layout()

        private static let cellID = NSUserInterfaceItemIdentifier("ResultsCell")
        private static let fillerID = NSUserInterfaceItemIdentifier("filler")
        private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        private static let textFont = NSFont.systemFont(ofSize: 12)
        private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

        // MARK: Updating

        func update(table: ResultsTable, decimals: Int) {
            guard let tableView else { return }
            let isNew = tableView.tableColumns.isEmpty
            guard isNew || table != self.table || decimals != self.decimals else { return }
            let grew = table.count > self.table.count
            self.table = table
            self.decimals = decimals
            let layout = Self.layout(for: table)
            if isNew || layout != self.layout {
                self.layout = layout
                rebuildColumns(in: tableView)
            }
            tableView.reloadData()
            fitColumns(in: tableView)
            // New rows are added at the bottom, which ImageJ scrolls to.
            if grew, table.count > 0 { tableView.scrollRowToVisible(table.count - 1) }
        }

        private static func layout(for table: ResultsTable) -> Layout {
            var layout = Layout(titles: ["#"], kinds: [.rowNumber], rightAligned: [true])
            if table.labels.contains(where: { $0 != nil }) {
                layout.titles.append("Label")
                layout.kinds.append(.label)
                layout.rightAligned.append(false)
            }
            for name in table.columns {
                layout.titles.append(name)
                layout.kinds.append(.value(name))
                layout.rightAligned.append(isNumeric(table, column: name))
            }
            return layout
        }

        /// A column of numbers is right aligned; one with any text in it is left aligned.
        private static func isNumeric(_ table: ResultsTable, column: String) -> Bool {
            for row in 0..<table.count {
                if case .text? = table.value(column, row: row) { return false }
            }
            return true
        }

        private func rebuildColumns(in tableView: NSTableView) {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            for (i, title) in layout.titles.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                column.title = title
                column.headerCell.alignment = layout.rightAligned[i] ? .right : .left
                column.resizingMask = .userResizingMask
                column.minWidth = 30
                column.width = 30
                tableView.addTableColumn(column)
            }
            // The last column takes the width the others leave, so the rows run the window's full width.
            let filler = NSTableColumn(identifier: Self.fillerID)
            filler.title = ""
            filler.resizingMask = .autoresizingMask
            filler.minWidth = 0
            filler.width = 1
            tableView.addTableColumn(filler)
        }

        /// Each column at least as wide as its heading and its widest cells (of the rows sampled).
        private func fitColumns(in tableView: NSTableView) {
            let count = table.count
            let step = max(1, count / 300)
            var sample = Array(stride(from: 0, to: count, by: step))
            if let last = sample.last, last != count - 1, count > 0 { sample.append(count - 1) }
            for column in tableView.tableColumns {
                guard let index = Self.index(of: column), index < layout.kinds.count else { continue }
                let kind = layout.kinds[index]
                let font = Self.font(for: kind)
                var width = Self.width(of: layout.titles[index], font: Self.headerFont) + 28
                for row in sample {
                    width = max(width, Self.width(of: text(row: row, kind: kind), font: font) + 16)
                }
                if case .rowNumber = kind {
                    width = max(width, 36)
                } else {
                    width = max(width, 72)
                }
                column.minWidth = width.rounded(.up)
            }
        }

        private static func width(of text: String, font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        private static func index(of column: NSTableColumn) -> Int? {
            let raw = column.identifier.rawValue
            guard raw.hasPrefix("c") else { return nil }
            return Int(raw.dropFirst())
        }

        private static func font(for kind: Kind) -> NSFont {
            if case .label = kind { return textFont }
            return numberFont
        }

        private func text(row: Int, kind: Kind) -> String {
            switch kind {
            case .rowNumber: return String(row + 1)
            case .label: return row < table.labels.count ? (table.labels[row] ?? "") : ""
            case .value(let name): return ResultsText.cell(table, row: row, column: name, decimals: decimals)
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            table.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Self.index(of: tableColumn), index < layout.kinds.count, row < table.count
            else { return nil }
            let kind = layout.kinds[index]
            let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView) ?? makeCell()
            guard let field = cell.textField else { return cell }
            field.stringValue = text(row: row, kind: kind)
            field.font = Self.font(for: kind)
            field.alignment = layout.rightAligned[index] ? .right : .left
            if case .rowNumber = kind {
                field.textColor = .secondaryLabelColor
            } else {
                field.textColor = .labelColor
            }
            return cell
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = Self.cellID
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Copy

        /// ⌘C: the selected rows as tab-separated text, or the whole table (with its headings) when none is selected.
        func copyRows() {
            guard let tableView else { return }
            let selected = tableView.selectedRowIndexes
            let text: String
            if selected.isEmpty {
                text = ResultsText.text(table, decimals: decimals, separator: "\t")
            } else {
                var lines: [String] = []
                for row in selected where row < table.count {
                    lines.append(ResultsText.cells(table, row: row, decimals: decimals).joined(separator: "\t"))
                }
                text = lines.joined(separator: "\n") + "\n"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// The table view, which copies its rows on ⌘C.
final class ResultsNSTableView: NSTableView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "c", window?.firstResponder === self,
            let coordinator = delegate as? ResultsTableView.Coordinator
        {
            coordinator.copyRows()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Log

/// ImageJ's Log window.
struct LogWindow: View {
    let session: AppSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.log.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if session.log.isEmpty {
                    ContentUnavailableView(
                        "The Log Is Empty", systemImage: "text.alignleft",
                        description: Text("What macros and commands log appears here."))
                }
            }
            .onChange(of: session.log.count) { proxy.scrollTo("end") }
        }
        .frame(minWidth: 360, minHeight: 200)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.log.joined(separator: "\n"), forType: .string)
                }
                .help("Copy the log to the clipboard")
                .disabled(session.log.isEmpty)
                Button("Clear", systemImage: "trash") { session.clearLog() }
                    .help("Clear the log")
                    .disabled(session.log.isEmpty)
            }
        }
    }
}
