public import MancoraCommands
public import MancoraCore
import Foundation
import MancoraIO

/// What macros run against: ImageJ's open images, results table, Log
/// window, ROI Manager and settings. One session can run many macros, which
/// share its images and results, as macros run one after another in ImageJ.
public final class MacroSession {
    public var context: CommandContext
    public var registry: CommandRegistry
    /// The version `getVersion()` reports and `requires()` checks.
    public var imageJVersion = "1.54p"

    /// The Log window's lines.
    public private(set) var logLines: [String] = []
    /// Called with each line printed, as it is printed (the CLI writes them to stdout).
    public var onLog: (@Sendable (String) -> Void)?
    /// Shows `showMessage` text; returns `false` when the person cancels. Without
    /// a handler, messages go to the log and are never cancelled.
    public var onMessage: ((_ title: String, _ message: String, _ withCancel: Bool) -> Bool)?

    /// Batch mode: on from the start, as for a macro ImageJ runs without its window (`IJ.runMacro` headless).
    public var batchMode = true
    public var lineWidth = 1
    /// `random("seed", n)`'s seed, which ImageJ also uses for its noise filters.
    public var randomSeed = Double.nan
    /// The foreground and background colors (`0xRRGGBB`), kept in the command settings.
    public var foreground: UInt32 {
        get { context.settings.foreground }
        set { context.settings.foreground = newValue }
    }
    public var background: UInt32 {
        get { context.settings.background }
        set { context.settings.background = newValue }
    }
    /// `setColor(value)` and `setColor(r, g, b)`: what drawing and filling use instead of the foreground color.
    var drawingValue: Double? {
        get { context.settings.fillValue }
        set { context.settings.fillValue = newValue }
    }
    var drawingColor: UInt32? {
        get { context.settings.fillColor }
        set { context.settings.fillColor = newValue }
    }
    /// The value each image's processor fills with once a macro used it
    /// (ImageJ's `fillValueSet`), by image ID: Edit ▸ Fill run from a macro uses it.
    var processorFill: [Int: Double] = [:]

    /// `ij.Prefs` keys `call("ij.Prefs.get", ...)` reads.
    public var preferences: [String: String] = [:]
    /// The macro file running, for `getInfo("macro.filepath")` and `getDirectory("macros")`.
    public var macroPath: String?
    /// ImageJ's folder (Mancora's ImageJ home), for `getDirectory("imagej")`.
    public var imageJDirectory: String?
    public var lastDirectory: String?
    public var lastName: String?
    public var defaultDirectory: String?
    public var thresholdMethod = "Default"
    public var thresholdMode = "Red"
    /// Command names and classes, for `List.setCommands`.
    public var commandTable: [String: String] = [:]

    /// The ROI Manager.
    public var roiManager = RoiManagerList()
    /// Image IDs, most recently activated last (ImageJ's `imageActivations`).
    var activations: [Int] = []
    /// Settings `saveSettings()` keeps.
    var savedSettings: CommandSettings?
    /// Interpreters running nested macros (`runMacro`, `eval`).
    var depth = 0

    public init(context: CommandContext = CommandContext(), registry: CommandRegistry = .standard) {
        self.context = context
        self.registry = registry
        for image in context.images { activations.append(image.id) }
    }

    /// Runs `macro` in this session.
    @discardableResult
    public func run(_ macro: String, argument: String? = nil, path: String? = nil) throws(MacroError) -> String? {
        let previousPath = macroPath
        if let path { macroPath = path }
        defer { macroPath = previousPath }
        return try Interpreter(session: self).run(macro, argument: argument)
    }

    // MARK: - The Log window

    /// `IJ.log(s)`: appends a line, or runs a Log command (`\\Clear`, `\\Update:`, `\\Update<n>:`).
    public func log(_ s: String) {
        if s.hasPrefix("\\") {
            if s == "\\Clear" {
                logLines = []
                onLog?(s)
                return
            }
            if s.hasPrefix("\\Update:") {
                let text = String(s.dropFirst(8))
                if logLines.isEmpty { logLines.append(text) } else { logLines[logLines.count - 1] = text }
                onLog?(s)
                return
            }
            if s.hasPrefix("\\Update"), let colon = s.firstIndex(of: ":"),
                let n = Int(s[s.index(s.startIndex, offsetBy: 7)..<colon])
            {
                let text = String(s[s.index(after: colon)...])
                if n >= 0 && n < logLines.count { logLines[n] = text } else { logLines.append(text) }
                onLog?(s)
                return
            }
        }
        logLines.append(s)
        onLog?(s)
    }

    /// `getInfo("log")`: the Log window's text.
    public var logText: String { logLines.map { $0 + "\n" }.joined() }

    func showMessage(title: String, _ message: String, withCancel: Bool = false) -> Bool {
        if let onMessage { return onMessage(title, message, withCancel) }
        log(title == "Message" || title == "Macro" ? message : title + ": " + message)
        return true
    }

    // Dialogs a person would answer; without one, the defaults stand, as with a macro's options.
    func askNumber(_ prompt: String, defaultValue: Double) -> Double? { nil }
    func askYesNo(_ prompt: String) -> Bool { true }
    func askString(_ prompt: String, defaultValue: String) -> String? { nil }

    // MARK: - Images

    /// Makes `id` the current image.
    func activate(_ id: Int) {
        try? context.select(id: id)
        activations.removeAll { $0 == id }
        activations.append(id)
    }

    /// After a command: newly opened images become current, and when the
    /// current image was closed, the most recently activated one left does.
    func syncCurrent(previous: Int?) {
        let open = Set(context.images.map(\.id))
        activations.removeAll { !open.contains($0) }
        if let current = context.currentID, !activations.contains(current) {
            activations.append(current)
            return
        }
        if let previous, !open.contains(previous), let last = activations.last {
            try? context.select(id: last)
        }
        if let current = context.currentID, current != activations.last {
            activations.removeAll { $0 == current }
            activations.append(current)
        }
    }

    /// Opens an image and makes it current.
    @discardableResult
    public func add(_ image: Hyperstack) -> Int {
        let id = context.add(image)
        activations.append(id)
        return id
    }

    func close(id: Int) {
        let wasCurrent = context.currentID == id
        context.close(id: id)
        activations.removeAll { $0 == id }
        if wasCurrent, let last = activations.last { try? context.select(id: last) }
    }

    public func isCommand(_ name: String) -> Bool {
        registry.isNative(name) || commandTable[name] != nil
    }

    /// `run(command, options)`.
    func runCommand(_ name: String, options: String?) throws(CommandError) {
        let previous = context.currentID
        // Filler in a macro fills with the value the macro left on the processor.
        let (savedValue, savedColor) = (context.settings.fillValue, context.settings.fillColor)
        context.settings.fillValue = previous.flatMap { processorFill[$0] }
        context.settings.fillColor = nil
        defer {
            (context.settings.fillValue, context.settings.fillColor) = (savedValue, savedColor)
            syncCurrent(previous: previous)
        }
        try registry.run(name, options: MacroOptions(options ?? ""), in: &context)
    }

    func deleteRows(_ first: Int, _ last: Int) {
        let rows = context.results.count
        guard rows > 0 else { return }
        let lo = max(0, first), hi = min(rows - 1, last)
        guard lo <= hi else { return }
        var table = ResultsTable()
        table.emptyCellsAreNaN = context.results.emptyCellsAreNaN
        for row in 0..<rows where row < lo || row > hi {
            let r = table.addRow(label: context.results.labels[row])
            for column in context.results.columns {
                if let value = context.results.value(column, row: row) { table.set(column, row: r, value) }
            }
        }
        context.results = table
    }

    /// When a macro ends.
    func finishMacro() {}

    // MARK: - Directories

    /// `getDirectory(name)`, with a trailing separator; `nil` for names Mancora doesn't know.
    func directory(_ nameIn: String) -> String? {
        let name = nameIn.lowercased()
        let fm = FileManager.default
        func slash(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }
        switch name {
        case "home": return slash(fm.homeDirectoryForCurrentUser.path)
        case "temp": return slash(NSTemporaryDirectory())
        case "startup", "imagej": return imageJDirectory.map(slash) ?? slash(fm.currentDirectoryPath)
        case "plugins": return imageJDirectory.map { slash($0) + "plugins/" }
        case "macros": return imageJDirectory.map { slash($0) + "macros/" }
        case "luts": return imageJDirectory.map { slash($0) + "luts/" }
        case "cwd": return slash(fm.currentDirectoryPath)
        // OpenDialog's default directory, as ImageJ gives for both.
        case "current", "default": return defaultDirectory.map(slash) ?? ""
        case "file": return lastDirectory ?? ""
        case "image":
            guard let path = context.current?.image.properties["Mancora.path"] else { return "" }
            return slash((path as NSString).deletingLastPathComponent)
        case "downloads": return slash(fm.homeDirectoryForCurrentUser.path) + "Downloads/"
        default: return nil
        }
    }

    // MARK: - Nested macros

    /// `eval(code)` and `runMacro`: runs `code` with `argument`; an error
    /// aborts only the inner macro, which returns `"[aborted]"`.
    func runMacro(code: String, argument: String?) throws(MacroSignal) -> String? {
        depth += 1
        defer { depth -= 1 }
        if depth > 20 { throw .error(MacroError(message: "Too many nested macros")) }
        do {
            return try Interpreter(session: self).run(code, argument: argument ?? "")
        } catch {
            log("Macro Error: " + error.description)
            return "[aborted]"
        }
    }

    func runMacroFile(_ nameIn: String, argument: String?) throws(MacroSignal) -> String? {
        var path = nameIn
        if !path.hasSuffix(".ijm") && !path.hasSuffix(".txt") && !FileManager.default.fileExists(atPath: path) {
            path += ".ijm"
        }
        if !path.hasPrefix("/"), let macros = directory("macros") { path = macros + path }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw .error(MacroError(message: "Macro or script not found: " + nameIn))
        }
        let previous = macroPath
        macroPath = path
        defer { macroPath = previous }
        return try runMacro(code: String(decoding: data, as: UTF8.self), argument: argument)
    }
}

/// The ROI Manager's list.
public struct RoiManagerList: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var roi: Roi
    }

    public var entries: [Entry] = []
    public var selected: [Int] = []

    public init() {}

    public var count: Int { entries.count }
}
