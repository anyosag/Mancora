import AppKit
import Charts
import MancoraCommands
import MancoraCore
import MancoraProcess
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Analyze ▸ Plot Profile and Analyze ▸ Histogram: ImageJ draws each in a
// plot window of its own. Here the window draws the data the core computes
// (`CommandContext.plotProfile` and `.histogram`) with Swift Charts.

// MARK: Opening

enum PlotWindows {
    /// Analyze ▸ Plot Profile or Histogram on the image in `viewer`: opens
    /// a plot window, or says why there is none (ImageJ's "Line or
    /// rectangular selection required."). `false` when only ImageJ can plot
    /// it, for the caller to run the command there.
    @MainActor
    static func open(_ command: String, viewer: ViewerModel, openWindow: OpenWindowAction) -> Bool {
        let kind: PlotKind = command == "Histogram" ? .histogram : .profile
        // The Alt key makes a rectangle's profile vertical, as in ImageJ.
        let model = PlotModel(kind: kind, viewer: viewer, altKeyDown: NSEvent.modifierFlags.contains(.option))
        guard let result = model.compute() else {
            viewer.errorMessage = CommandError.noImage(command).description
            return true
        }
        switch result {
        case .success(let content):
            model.show(content)
        case .failure(.notNative):
            return false
        case .failure(let error):
            viewer.errorMessage = PlotModel.message(error)
            return true
        }
        let request = PlotRequest(kind: kind)
        PlotRegistry.shared.models[request.id] = model
        openWindow(id: "plot", value: request)
        AppRecorder.shared.record(command, options: "")
        return true
    }
}

/// What opens a plot window: its kind, and an id that finds its model (a
/// window's value can only be encoded; every command opens a window of its own).
nonisolated struct PlotRequest: Codable, Hashable, Sendable {
    var kind: PlotKind
    var id = UUID()
}

nonisolated enum PlotKind: String, Codable, Sendable {
    case profile
    case histogram
}

/// The models of the plot windows that are open, by the id in their request.
final class PlotRegistry {
    static let shared = PlotRegistry()
    var models: [UUID: PlotModel] = [:]
}

// MARK: Model

/// What a plot window draws.
nonisolated enum PlotContent: Sendable {
    case profile(ProfileData)
    case histogram(HistogramData)
}

/// The data of Analyze ▸ Plot Profile and Histogram for a context's current
/// image; free of the main actor, so live plots can compute off it.
nonisolated enum PlotCalculator {
    static func plot(_ kind: PlotKind, in context: CommandContext, altKeyDown: Bool) -> Result<PlotContent, CommandError> {
        do throws(CommandError) {
            switch kind {
            case .profile: return .success(.profile(try context.plotProfile(altKeyDown: altKeyDown)))
            case .histogram: return .success(.histogram(try context.histogram()))
            }
        } catch {
            return .failure(error)
        }
    }
}

/// One plot window's state: the plot, and how to compute it again from the
/// image window it was made from.
@Observable
final class PlotModel {
    let kind: PlotKind
    /// The Alt key was down when the command ran.
    let altKeyDown: Bool
    /// The image window the plot is made from, which Live follows.
    @ObservationIgnored private(set) weak var viewer: ViewerModel?
    private(set) var content: PlotContent?
    /// Why the plot couldn't be updated; the last plot stays.
    private(set) var problem: String?
    private(set) var imageTitle = ""
    /// Live: the plot follows the image's selection, plane and pixels.
    var isLive = false
    /// Histogram ▸ Log: log-scaled counts drawn behind the histogram.
    var logScale = false
    @ObservationIgnored private var update: Task<Void, Never>?

    init(kind: PlotKind, viewer: ViewerModel, altKeyDown: Bool) {
        self.kind = kind
        self.viewer = viewer
        self.altKeyDown = altKeyDown
        imageTitle = viewer.image?.title ?? ""
    }

    /// "Plot of blobs" (ImageJ drops an extension of up to four characters)
    /// or "Histogram of blobs" (`ImagePlus.getShortTitle`).
    var windowTitle: String {
        switch kind {
        case .profile:
            var title = imageTitle
            if let dot = title.lastIndex(of: "."), dot > title.startIndex, title.distance(from: dot, to: title.endIndex) <= 5 {
                title = String(title[..<dot])
            }
            return "Plot of " + title
        case .histogram:
            var title = imageTitle.trimmingCharacters(in: .whitespaces)
            if let dot = title.lastIndex(of: "."), dot > title.startIndex {
                title = String(title[..<dot]).replacingOccurrences(of: " ", with: "")
            } else if let space = title.firstIndex(of: " ") {
                title = String(title[..<space])
            }
            return "Histogram of " + title
        }
    }

    /// What a command would run on: the viewer's image at its plane, with
    /// its threshold, its selection (the one being drawn, if any) and the
    /// session's settings. `nil` when the image is gone.
    func makeContext() -> CommandContext? {
        guard let viewer, let image = viewer.image else { return nil }
        var context = CommandContext()
        context.settings = AppSession.shared.settings
        context.add(image)
        let (c, z, t, levels, draft) = (viewer.channel, viewer.slice, viewer.frame, viewer.threshold, viewer.draft)
        try? context.withCurrent("Plot") { (open: inout OpenImage) in
            open.channel = c
            open.slice = z
            open.frame = t
            open.threshold = levels
            if let draft { open.roi = draft }
        }
        return context
    }

    /// The plot for the image as it is now, on this thread; `nil` without an image.
    func compute() -> Result<PlotContent, CommandError>? {
        guard let context = makeContext() else { return nil }
        return PlotCalculator.plot(kind, in: context, altKeyDown: altKeyDown)
    }

    func show(_ content: PlotContent) {
        self.content = content
        problem = nil
    }

    /// Computes the plot again (off the main thread), for Live.
    func refresh() {
        update?.cancel()
        guard let context = makeContext() else {
            problem = "The image is closed."
            isLive = false
            return
        }
        let kind = self.kind, alt = altKeyDown
        update = Task {
            let result = await Task.detached(priority: .userInitiated) {
                PlotCalculator.plot(kind, in: context, altKeyDown: alt)
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let content): show(content)
            case .failure(let error): problem = Self.message(error)
            }
        }
    }

    /// An error as ImageJ words it for the user.
    static func message(_ error: CommandError) -> String {
        if case .failed(_, let detail) = error { return detail }
        if case .notNative = error { return "Mancora can't plot this yet; ImageJ can (choose the command again)." }
        return "\(error)"
    }

    /// The values the List and Copy buttons give: for a histogram, the list
    /// has its bin number too, which ImageJ's Copy leaves out.
    func table(forList: Bool) -> PlotTable? {
        let settings = AppSession.shared.settings
        switch content {
        case .profile(let data)?: return PlotTable.profile(data, settings: settings)
        case .histogram(let data)?: return PlotTable.histogram(data, settings: settings, forList: forList)
        case nil: return nil
        }
    }
}

// MARK: Window

/// A plot window: its model, or, for one restored from a last launch, a
/// note and nothing else.
struct PlotWindow: View {
    let request: PlotRequest
    @State private var model: PlotModel?
    @Environment(\.dismiss) private var dismiss

    init(request: PlotRequest) {
        self.request = request
        _model = State(initialValue: PlotRegistry.shared.models[request.id])
    }

    var body: some View {
        if let model {
            PlotView(model: model)
                .onDisappear { PlotRegistry.shared.models[request.id] = nil }
        } else {
            ContentUnavailableView(
                "Plot Closed", systemImage: "chart.xyaxis.line",
                description: Text("Choose Analyze ▸ Plot Profile or Histogram again.")
            )
            .frame(minWidth: 320, minHeight: 200)
            .task { dismiss() }
        }
    }
}

/// What a live plot is computed from: when it changes, the plot is stale.
nonisolated struct PlotLiveKey: Equatable {
    var roi: [UInt8]?
    var draft: Roi?
    var channel: Int
    var slice: Int
    var frame: Int
    var threshold: ThresholdLevels?
    /// The rendered plane, which is replaced whenever the image changes.
    var bitmap: ObjectIdentifier?
}

struct PlotView: View {
    @Bindable var model: PlotModel
    @State private var showsList = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                chart
                if case .histogram(let data)? = model.content {
                    HistogramStatsView(data: data)
                }
                if model.content != nil, let problem = model.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttons
                .padding(8)
        }
        .frame(minWidth: 420, minHeight: 320)
        .navigationTitle(model.windowTitle)
        .sheet(isPresented: $showsList) {
            PlotValuesSheet(model: model)
        }
        .alert(
            "Mancora",
            isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: model.isLive) { if model.isLive { model.refresh() } }
        .onChange(of: liveKey) { if model.isLive { model.refresh() } }
    }

    @ViewBuilder
    private var chart: some View {
        switch model.content {
        case .profile(let data)?:
            ProfileChartView(data: data)
        case .histogram(let data)?:
            HistogramChartView(data: data, logScale: model.logScale)
        case nil:
            ContentUnavailableView(
                "No Plot", systemImage: "chart.xyaxis.line", description: Text(model.problem ?? ""))
        }
    }

    private var buttons: some View {
        HStack {
            Button("List") { showsList = true }
            Button("Copy") { copy() }
            if model.kind == .profile {
                Button("Save…") { save() }
            } else {
                Toggle("Log", isOn: $model.logScale).toggleStyle(.button)
            }
            Toggle("Live", isOn: $model.isLive).toggleStyle(.button)
            Spacer()
        }
        .disabled(model.content == nil)
    }

    /// Read while Live, so the window follows the image window's selection
    /// (also the one being drawn), plane, threshold and pixels.
    private var liveKey: PlotLiveKey? {
        guard model.isLive, let viewer = model.viewer else { return nil }
        return PlotLiveKey(
            roi: viewer.image?.encodedROI, draft: viewer.draft, channel: viewer.channel, slice: viewer.slice,
            frame: viewer.frame, threshold: viewer.threshold, bitmap: viewer.rendered.map { ObjectIdentifier($0) })
    }

    /// Copy: ImageJ copies a profile as tab-separated X and Y (here with
    /// their headings) and a histogram as its values and counts.
    private func copy() {
        guard let table = model.table(forList: false) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.text(separator: "\t", header: model.kind == .profile), forType: .string)
    }

    /// Save…: the profile's values as a CSV file.
    private func save() {
        guard let table = model.table(forList: false) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Values.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try table.text(separator: ",", header: true).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorText = "\(error)"
        }
    }
}

/// The List button: the plot's values in a table, which Copy takes with its headings.
struct PlotValuesSheet: View {
    let model: PlotModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let table = model.table(forList: true)
        VStack(spacing: 0) {
            if let table {
                PlotTableGrid(table: table)
            }
            Divider()
            HStack {
                Button("Copy") {
                    guard let table else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.text(separator: "\t", header: true), forType: .string)
                }
                .disabled(table == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
        .frame(width: 380, height: 440)
    }
}

/// A fixed header and scrolling rows of preformatted cells.
struct PlotTableGrid: View {
    let table: PlotTable

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<table.rowCount, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<table.columns.count, id: \.self) { column in
                                Text(table.columns[column][row])
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.horizontal, 6)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(row % 2 == 0 ? Color.clear : Color.primary.opacity(0.04))
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(0..<table.columns.count, id: \.self) { column in
                            Text(table.headings[column])
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(.bar)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
    }
}

// MARK: Charts

struct ProfilePoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

/// Plot Profile's plot: the values along the selection against the distance.
struct ProfileChartView: View {
    let data: ProfileData

    var body: some View {
        let points = Self.points(data)
        Chart(points) { point in
            LineMark(x: .value("X", point.x), y: .value("Y", point.y))
        }
        .chartXAxisLabel { Text(verbatim: data.xLabel) }
        .chartYAxisLabel { Text(verbatim: data.yLabel) }
        .chartYScale(domain: Self.domain(of: points.map(\.y)))
        .frame(minHeight: 200)
    }

    /// The samples to draw: those outside the image are NaN, which the line skips.
    static func points(_ data: ProfileData) -> [ProfilePoint] {
        var points: [ProfilePoint] = []
        for i in 0..<min(data.xValues.count, data.yValues.count) where data.yValues[i].isFinite {
            points.append(ProfilePoint(id: i, x: data.xValues[i], y: data.yValues[i]))
        }
        return points
    }

    /// The values' range with a margin, as ImageJ's plots autoscale.
    static func domain(of values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if high - low < 1e-12 { return (low - 1)...(high + 1) }
        let margin = (high - low) * 0.05
        return (low - margin)...(high + margin)
    }
}

struct HistogramBar: Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let count: Double

    /// One bar per bin, from its calibrated start to the next one's (the
    /// last as wide as the one before it).
    static func bars(_ data: HistogramData) -> [HistogramBar] {
        let n = min(data.counts.count, data.binStarts.count)
        let last = n > 1 ? data.binStarts[n - 1] - data.binStarts[n - 2] : abs(data.binWidth)
        return (0..<n).map { i in
            HistogramBar(
                id: i, start: data.binStarts[i], end: i + 1 < n ? data.binStarts[i + 1] : data.binStarts[i] + last,
                count: Double(data.counts[i]))
        }
    }

    /// The count on a log scale that spans the plot's height, as ImageJ
    /// draws it (`log(count) / log(maximum)` of the height).
    func logCount(top: Double) -> Double {
        guard count > 0 else { return 0 }
        return top > 1 ? log(count) / log(top) * top : count
    }
}

/// Histogram's plot: a bar for each bin; with Log, the log-scaled counts in gray behind them.
struct HistogramChartView: View {
    let data: HistogramData
    let logScale: Bool

    var body: some View {
        let bars = HistogramBar.bars(data)
        let top = Double(max(data.counts.max() ?? 0, 1))
        let edges = bars.flatMap { [$0.start, $0.end] }
        Chart {
            if logScale {
                ForEach(bars) { bar in
                    RectangleMark(
                        xStart: .value("Bin start", bar.start), xEnd: .value("Bin end", bar.end),
                        yStart: .value("Zero", 0.0), yEnd: .value("Log count", bar.logCount(top: top))
                    )
                    .foregroundStyle(Color.gray.opacity(0.35))
                }
            }
            ForEach(bars) { bar in
                RectangleMark(
                    xStart: .value("Bin start", bar.start), xEnd: .value("Bin end", bar.end),
                    yStart: .value("Zero", 0.0), yEnd: .value("Count", bar.count)
                )
                .foregroundStyle(Color.primary.opacity(0.7))
            }
        }
        .chartXScale(domain: (edges.min() ?? 0)...(edges.max() ?? 1))
        .chartYScale(domain: 0...top)
        .frame(minHeight: 200)
    }
}

/// The statistics under ImageJ's histogram: N, Mean, StdDev, Min, Max and
/// Mode (with its count, and "*" when several bins share it), and the bins
/// when they aren't one value wide.
struct HistogramStatsView: View {
    let data: HistogramData

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.lines(data), id: \.self) { line in
                Text(line)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func lines(_ data: HistogramData) -> [String] {
        let n = IJFormat.plotNumber
        var modeCount = " (\(data.modeCount))" + (data.isMultimodal ? "*" : "")
        if modeCount.count > 12 { modeCount = "" }
        var lines = [
            "N: \(data.count)  Mean: \(n(data.mean))  StdDev: \(n(data.stdDev))",
            "Min: \(n(data.min))  Max: \(n(data.max))  Mode: \(n(data.mode))\(modeCount)",
        ]
        if data.showsBins { lines.append("Bins: \(n(Double(data.bins)))  Bin Width: \(n(abs(data.binWidth)))") }
        return lines
    }
}

// MARK: Plot values

/// A plot's values as ImageJ lists and copies them: columns of numbers,
/// already formatted, each with the decimals of its own.
struct PlotTable {
    var headings: [String]
    var columns: [[String]]

    var rowCount: Int { columns.map(\.count).min() ?? 0 }

    func text(separator: String, header: Bool) -> String {
        func line(_ cells: [String]) -> String {
            (separator == "," ? cells.map(ResultsText.quoted) : cells).joined(separator: separator)
        }
        var lines = header ? [line(headings)] : []
        for row in 0..<rowCount { lines.append(line(columns.map { $0[row] })) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Plot Profile's X and Y (`PlotWindow.copyToClipboard`).
    static func profile(_ data: ProfileData, settings: CommandSettings) -> PlotTable {
        let scientific = settings.measurements.contains(.scientificNotation)
        let xDigits = IJFormat.precision(data.xValues, decimalPlaces: settings.decimalPlaces, scientific: scientific)
        let yDigits = IJFormat.precision(data.yValues, decimalPlaces: settings.decimalPlaces, scientific: scientific)
        return PlotTable(
            headings: ["X", "Y"],
            columns: [data.xValues.map { IJFormat.d2s($0, xDigits) }, data.yValues.map { IJFormat.d2s($0, yDigits) }])
    }

    /// Histogram's value (or bin start) and count (`HistogramWindow.getResultsTable`
    /// and `copyToClipboard`): the values have decimals when the bins aren't
    /// one value wide or the values are calibrated.
    static func histogram(_ data: HistogramData, settings: CommandSettings, forList: Bool) -> PlotTable {
        let whole = data.binWidth == 1 && data.binStarts.allSatisfy { $0 == $0.rounded() }
        let digits = whole ? 0 : settings.decimalPlaces
        var headings = [data.binWidth == 1 ? "value" : "bin start", "count"]
        var columns = [data.binStarts.map { IJFormat.cell($0, digits) }, data.counts.map { String($0) }]
        if forList && data.binWidth != 1 {
            headings.insert("index", at: 0)
            columns.insert(data.counts.indices.map { String($0) }, at: 0)
        }
        return PlotTable(headings: headings, columns: columns)
    }
}

// MARK: Number formatting

/// ImageJ's number formatting: `IJ.d2s`, `ResultsTable.d2s` and the
/// decimals `Plot.getPrecision` picks for a column.
nonisolated enum IJFormat {
    static let floatMax = Double(Float.greatestFiniteMagnitude)

    /// `IJ.d2s(n, decimalPlaces)`: that many decimals (at most 9), or with a
    /// negative count scientific notation (`1.235E-5`) with that many.
    static func d2s(_ n: Double, _ decimalPlaces: Int) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
        if n == floatMax { return "3.4e38" }
        if decimalPlaces < 0 { return scientific(n, min(-decimalPlaces, 9)) }
        let places = min(decimalPlaces, 9)
        // The no-decimals format rounds halves away from zero; the others to even.
        return String(format: "%.\(places)f", places == 0 ? n.rounded(.toNearestOrAwayFromZero) : n)
    }

    /// `IJ.d2s(x, significantDigits, maxDigits)`: at least `significantDigits`
    /// decimals, fewer when the number would need more than `maxDigits`
    /// digits, and scientific notation when it needs more still.
    static func d2s(_ x: Double, significantDigits: Int, maxDigits: Int) -> String {
        guard x.isFinite else { return d2s(x, 0) }
        // ceil(log10(0)) is Integer.MIN_VALUE in Java.
        let magnitude = x == 0 ? Int(Int32.min) : Int((log10(abs(x)) + 0.223 * pow(10, Double(-maxDigits))).rounded(.up))
        var decimals = x == 0 ? 0 : maxDigits - magnitude
        if decimals < 0 || magnitude < significantDigits + 1 - maxDigits {
            return d2s(x, -significantDigits)
        }
        if decimals > significantDigits { decimals = max(significantDigits, decimals - maxDigits + significantDigits) }
        return d2s(x, decimals)
    }

    /// `HistogramPlot.d2s`: whole numbers without decimals, others as `d2s(x, 3, 8)`.
    static func plotNumber(_ d: Double) -> String {
        if d == d.rounded(.towardZero), abs(d) <= Double(Int32.max) { return d2s(d, 0) }
        return d2s(d, significantDigits: 3, maxDigits: 8)
    }

    /// `ResultsTable.d2s(n, decimalPlaces)`: scientific notation for numbers
    /// too small for the decimals, or larger than 999999999999.
    static func cell(_ n: Double, _ decimalPlaces: Int) -> String {
        if n.isNaN || n.isInfinite { return d2s(n, 0) }
        if n == floatMax { return "3.4e38" }
        let np = abs(n)
        if (np != 0 && np < 1.0 / pow(10, Double(decimalPlaces))) || np > 999_999_999_999 || decimalPlaces < 0 {
            return scientific(n, decimalPlaces < 0 ? min(-decimalPlaces, 9) : 3)
        }
        return d2s(n, decimalPlaces)
    }

    /// Java's `DecimalFormat("0.000E0")`: `1.235E-5`, `1.000E9`.
    private static func scientific(_ n: Double, _ decimals: Int) -> String {
        let text = String(format: "%.\(decimals)e", n)
        let parts = text.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        return "\(parts[0])E\(exponent)"
    }

    /// `Plot.getPrecision`: the decimals a column of plot values is written
    /// with: none for whole numbers, else enough to tell them apart (at
    /// least the Set Measurements decimal places); negative is scientific
    /// notation, which Set Measurements can ask for.
    static func precision(_ values: [Double], decimalPlaces: Int, scientific: Bool) -> Int {
        if scientific { return -max(decimalPlaces, 4) }
        var allInteger = true
        var low = floatMax, high = -floatMax
        for v in values where v.isFinite && !(v == v.rounded(.towardZero) && abs(v) <= Double(Int32.max)) {
            allInteger = false
            low = min(low, v)
            high = max(high, v)
        }
        if allInteger { return 0 }
        let minFloatPrecision = 1e-5
        var places: Int
        if high - low > 0 {
            places = digits(low, high, minFloatPrecision * (high - low), maxDigits: 15, suggested: 0)
        } else {
            places = digits(high, minFloatPrecision * abs(high), maxDigits: 15, suggested: 0)
        }
        if decimalPlaces > abs(places) { places = decimalPlaces * (places < 0 ? -1 : 1) }
        return places
    }

    /// `Plot.getDigits(n, resolution, maxDigits, suggestedDigits)`.
    private static func digits(_ n: Double, _ resolution: Double, maxDigits: Int, suggested: Int) -> Int {
        if n == n.rounded() && abs(n) < pow(10, Double(maxDigits - 1)) - 1 { return suggested }
        return digits2(n, resolution, maxDigits: maxDigits, suggested: suggested)
    }

    /// `Plot.getDigits(n1, n2, resolution, maxDigits, suggestedDigits)`.
    private static func digits(_ n1: Double, _ n2: Double, _ resolution: Double, maxDigits: Int, suggested: Int) -> Int {
        if n1 == 0 && n2 == 0 { return suggested }
        return digits2(max(abs(n1), abs(n2)), resolution, maxDigits: maxDigits, suggested: suggested)
    }

    private static func digits2(_ n: Double, _ resolution: Double, maxDigits: Int, suggested: Int) -> Int {
        guard n.isFinite, n != 0 else { return 0 }
        let log10OfN = floorInt(log10(abs(n)) + 1e-7)
        var places = resolution != 0 ? -floorInt(log10(abs(resolution)) + 1e-7) : max(0, -log10OfN + maxDigits - 2)
        let sciDigits = -max(log10OfN + places, 1)
        if (places < -2 && log10OfN >= maxDigits) || suggested < 0 {
            places = sciDigits
        } else if places < 0 {
            places = 0
        } else if places > maxDigits - 1 && log10OfN < -2 {
            places = sciDigits
        }
        return places < 0 ? min(sciDigits, suggested) : max(places, suggested)
    }

    /// `(int)Math.floor(x)`, for finite `x` that may be extreme.
    private static func floorInt(_ x: Double) -> Int {
        x.isFinite ? Int(min(max(x.rounded(.down), -1e9), 1e9)) : 0
    }
}
