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
            } else {
                ResultsGrid(table: session.results, decimals: session.settings.decimalPlaces)
            }
            Divider()
            HStack {
                Text("\(session.results.count) rows").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Copy") { copy() }
                    .disabled(session.results.isEmpty)
                Button("Save As…") { save() }
                    .disabled(session.results.isEmpty)
                Button("Clear Results") { session.clearResults() }
                    .disabled(session.results.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 220)
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
            switch table.value(column, row: row) {
            case .number(let v)?: cells.append(format(v, decimals: decimals))
            case .text(let t)?: cells.append(t)
            case nil: cells.append(table.emptyCellsAreNaN ? "NaN" : "0")
            }
        }
        return cells
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

/// The table itself: a fixed header and scrolling rows.
struct ResultsGrid: View {
    let table: ResultsTable
    let decimals: Int

    var body: some View {
        let headings = ResultsText.headings(table)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<table.count, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(ResultsText.cells(table, row: row, decimals: decimals).enumerated()), id: \.offset) {
                                index, cell in
                                Text(cell)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: index == 0 ? 48 : 96, alignment: index == 0 ? .leading : .trailing)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(row % 2 == 0 ? Color.clear : Color.primary.opacity(0.04))
                        .textSelection(.enabled)
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                            Text(heading)
                                .bold()
                                .frame(width: index == 0 ? 48 : 96, alignment: index == 0 ? .leading : .trailing)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(.bar)
                }
            }
        }
    }
}

/// ImageJ's Log window.
struct LogWindow: View {
    let session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.log.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: session.log.count) { proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.log.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { session.clearLog() }
            }
            .padding(8)
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}
