import Foundation
import MancoraBridge
import MancoraCommands
import MancoraCore
import Observation

/// What all of Mancora's windows share, as ImageJ's do: the Results table
/// and other tables, the Log, the settings commands keep (Set
/// Measurements, Binary Options, colors…), and the open images, which
/// commands that combine images choose from.
@Observable
final class AppSession {
    static let shared = AppSession()

    var results = ResultsTable()
    var tables: [String: ResultsTable] = [:]
    var log: [String] = []
    var settings = CommandSettings()
    /// The toolbar's tool, the same for every window.
    var tool = CanvasTool.rectangle
    /// Bumped when a command adds results or log lines, so their windows come forward.
    private(set) var resultsAdded = 0
    private(set) var logAdded = 0

    private struct WeakViewer {
        weak var model: ViewerModel?
    }

    @ObservationIgnored private var viewers: [WeakViewer] = []

    func register(_ viewer: ViewerModel) {
        viewers.removeAll { $0.model == nil || $0.model === viewer }
        viewers.append(WeakViewer(model: viewer))
    }

    /// The windows with an image, in the order they were registered.
    var imageViewers: [ViewerModel] { viewers.compactMap(\.model).filter(\.hasImage) }

    /// Commands that use more than the current image.
    static let multiImageCommands: Set<String> = [
        "Image Calculator...", "Merge Channels...", "Concatenate...", "Combine...", "Images to Stack", "Paste Control...",
        "Add Image...", "Colocalization...",
    ]

    /// Takes what a native command left: its results, tables, settings and log.
    func absorb(_ context: CommandContext) {
        if context.results != results, !context.results.isEmpty { resultsAdded += 1 }
        results = context.results
        tables = context.tables
        settings = context.settings
        if !context.log.isEmpty {
            log += context.log
            logAdded += 1
        }
    }

    /// Adds what a command or macro run in ImageJ measured and logged (the
    /// helper starts every request with an empty Results table).
    func absorb(_ result: BridgeRunResult) {
        let lines = result.log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let logged = lines.last == "" ? Array(lines.dropLast()) : lines
        if !logged.isEmpty {
            log += logged
            logAdded += 1
        }
        guard !result.results.isEmpty else { return }
        for row in result.results.rows {
            let index = results.addRow()
            for (column, cell) in zip(result.results.columns, row) {
                switch cell {
                case .number(let v):
                    if column == "Label" { results.setLabel(String(v), row: index) } else { results.set(column, row: index, v) }
                case .text(let t):
                    if column == "Label" { results.setLabel(t, row: index) } else { results.set(column, row: index, .text(t)) }
                case .empty:
                    break
                }
            }
        }
        resultsAdded += 1
    }

    func clearResults() {
        results.reset()
    }

    func clearLog() {
        log = []
    }
}
