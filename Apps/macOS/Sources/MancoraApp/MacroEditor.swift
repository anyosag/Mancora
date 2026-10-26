import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What a macro editor window should show: a file, or an empty macro or text window.
struct EditorRequest: Codable, Hashable {
    var url: URL?
    /// File ▸ New ▸ Text Window: plain text (`Untitled.txt`) rather than a macro (`Macro.ijm`).
    var isText = false
    /// Tells empty editors apart: SwiftUI brings the window of an equal value forward instead of opening another.
    var serial: UUID?
    /// The Recorder's Create Macro: a new, unsaved macro that starts with this text.
    var text: String?
}

/// State of one editor window, as ImageJ's Editor has it: the text (kept by
/// its `NSTextView`), the file it came from, whether it has changed, the
/// caret's position, and what the last run said. Run runs the selection
/// if there is one, and Evaluate Line the line the caret is on.
@Observable
final class MacroEditorModel {
    private(set) var fileURL: URL?
    /// Unsaved changes (ImageJ's `Editor.changes`): set when the text is edited, cleared when it's opened or saved.
    private(set) var isChanged = false
    private(set) var isRunning = false
    /// The caret's line and column, both counted from 1.
    private(set) var line = 1
    private(set) var column = 1
    /// Some text is selected, so Run runs just that.
    private(set) var hasSelection = false
    /// The last run's error, as ImageJ's "Macro Error" dialog words it.
    private(set) var message: String?
    /// File ▸ New ▸ Text Window: plain text rather than a macro.
    var isText = false

    @ObservationIgnored weak var textView: MacroTextView?
    @ObservationIgnored var bridge: AppBridge?
    /// Opens a new image window for a file a macro made.
    @ObservationIgnored var openImage: ((URL) -> Void)?
    /// Opens another editor window.
    @ObservationIgnored var openEditor: ((URL) -> Void)?
    /// The text before the window has its text view (and after it, until it's replaced).
    @ObservationIgnored private var pendingText = ""
    /// The text is a new macro's, which isn't saved anywhere yet.
    @ObservationIgnored private var startsChanged = false

    var title: String { fileURL?.lastPathComponent ?? (isText ? "Untitled.txt" : "Macro.ijm") }

    /// The first line of `message`; the status bar has room for no more.
    var messageSummary: String? {
        message?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    // MARK: Files

    /// The Open panel for macros and text files (File ▸ Open, Plugins ▸ Macros ▸ Edit…).
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ijm") ?? .plainText, .text, .sourceCode]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Reads `url` into the editor. Line ends become "\n", as the interpreter counts lines by them.
    func load(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            fileURL = url
            pendingText = text
            textView?.show(text)
            isChanged = false
            message = nil
        } catch {
            message = "Can't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// The Recorder's Create Macro: this window starts as a new macro with `text`, which is unsaved.
    func start(with text: String) {
        guard fileURL == nil, !startsChanged else { return }
        pendingText = text
        startsChanged = true
        textView?.show(text)
        isChanged = true
    }

    /// File ▸ Open in an editor: the file fills this window if it's empty and unchanged, else it gets its own.
    func open() {
        guard let url = Self.chooseFile() else { return }
        if fileURL == nil, !isChanged, textView?.string.isEmpty ?? true {
            load(url)
        } else {
            openEditor?(url)
        }
    }

    /// File ▸ Save: to the file the text came from, or as a new one.
    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    /// File ▸ Save As ▸ Text…: macros as `.ijm` files unless the name says otherwise.
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        let macro = UTType(filenameExtension: "ijm") ?? .plainText
        panel.allowedContentTypes = isText ? [.plainText, macro] : [macro, .plainText]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.nameFieldStringValue = title
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        guard let text = textView?.string else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        fileURL = url
        isChanged = false
        return true
    }

    /// The File menu's items act on the editor when it is the front window, as the Editor's own File menu does.
    func perform(_ menuItem: String) -> Bool {
        switch menuItem {
        case "Open...": open()
        case "Save": save()
        case "Text...": saveAs()
        default: return false
        }
        return true
    }

    /// ImageJ's "Save changes to “title”?" when an editor with changes closes.
    func mayClose() -> Bool {
        guard isChanged else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(title)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private struct WeakEditor {
        weak var model: MacroEditorModel?
    }

    private static var editors: [WeakEditor] = []

    /// Quitting with changed editors asks once, as it does for changed images.
    static func mayQuit() -> Bool {
        let changed = editors.compactMap(\.model).filter(\.isChanged)
        guard !changed.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText =
            changed.count == 1 ? "“\(changed[0].title)” has unsaved changes." : "\(changed.count) macros have unsaved changes."
        alert.informativeText = "Quit anyway? The changes will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: The text view

    /// The window's text view is ready: it shows the text loaded so far.
    func attach(_ textView: MacroTextView) {
        self.textView = textView
        textView.show(pendingText)
        isChanged = startsChanged
        selectionDidChange(in: textView)
        Self.editors.removeAll { $0.model == nil || $0.model === self }
        Self.editors.append(WeakEditor(model: self))
    }

    func textDidChange() {
        isChanged = true
    }

    func selectionDidChange(in textView: MacroTextView) {
        let selection = textView.selectedRange()
        let position = MacroSyntax.position(of: selection.location, in: textView.string)
        line = position.line
        column = position.column
        hasSelection = selection.length > 0
    }

    // MARK: Running

    /// Macro ▸ Run Macro (⌘R): the whole text, or the selection if there is one (Run Selection).
    func run() {
        guard let textView else { return }
        let text = textView.string
        let selection = textView.selectedRange()
        if selection.length > 0 {
            let first = MacroSyntax.position(of: selection.location, in: text).line
            execute(MacroSyntax.substring(of: text, in: selection), firstLine: first)
        } else {
            execute(text, firstLine: 1)
        }
    }

    /// Macro ▸ Evaluate Line (⌘Y in ImageJ): the line the caret is on.
    func evaluateLine() {
        guard let textView else { return }
        let text = textView.string
        let caret = textView.selectedRange().location
        let range = MacroSyntax.lineRange(containing: caret, in: text)
        execute(
            MacroSyntax.substring(of: text, in: range), firstLine: MacroSyntax.position(of: caret, in: text).line)
    }

    /// Runs `code` on the front image (or none), as Plugins ▸ Macros ▸ Run… does. `firstLine` is the
    /// line of the text it starts on, which turns an error's line back into the editor's.
    private func execute(_ code: String, firstLine: Int) {
        guard let bridge, !isRunning else { return }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        message = nil
        textView?.markError(line: nil)
        let target = AppSession.shared.currentViewer ?? ViewerModel()
        Task {
            let created = await target.runMacro(
                code, bridge: bridge,
                onError: { [weak self] text, line in
                    self?.show(error: text, line: line.map { $0 + firstLine - 1 })
                })
            self.isRunning = false
            for url in created { self.openImage?(url) }
        }
    }

    /// ImageJ shows a macro error and puts the caret on its line.
    private func show(error text: String, line errorLine: Int?) {
        message = text
        if let errorLine { textView?.show(errorAtLine: errorLine) }
    }
}

/// An editor window: ImageJ's Editor, for macros and plain text.
struct MacroEditorWindow: View {
    @Binding var request: EditorRequest?
    let bridge: AppBridge
    @State private var model = MacroEditorModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            MacroTextEditor(model: model)
            Divider()
            HStack(spacing: 8) {
                if let summary = model.messageSummary {
                    Text(summary)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(model.message ?? summary)
                } else if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(model.line):\(model.column)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .frame(minWidth: 400, minHeight: 240)
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup {
                Button("Open…", systemImage: "folder") { model.open() }
                    .help("Open a macro or text file")
                Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                    .help("Save")
                Button(model.hasSelection ? "Run Selection" : "Run Macro", systemImage: "play.fill") { model.run() }
                    .disabled(model.isRunning)
                    .help(model.hasSelection ? "Run the selected code (⌘R)" : "Run the macro (⌘R)")
                Button("Evaluate Line", systemImage: "arrow.turn.down.right") { model.evaluateLine() }
                    .disabled(model.isRunning)
                    .help("Run the line the caret is on (⌘Y)")
            }
        }
        .focusedSceneValue(\.macroEditor, model)
        .background(EditorWindowTracking(model: model))
        .task(id: request) {
            let openWindow = openWindow
            model.bridge = bridge
            model.openImage = { url in openWindow(id: "viewer", value: OpenRequest(url: url)) }
            model.openEditor = { url in openWindow(id: "macro-editor", value: EditorRequest(url: url)) }
            if let request {
                model.isText = request.isText
                if let url = request.url, model.fileURL != url {
                    model.load(url)
                } else if request.url == nil, let text = request.text {
                    model.start(with: text)
                }
            }
        }
    }
}

/// The Macro menu: the front editor window's Run, Evaluate Line, Open and Save.
/// ⌘Y, ImageJ's key for Evaluate Line, belongs to Edit ▸ Selection ▸ Properties
/// in the menu bar, so the editor's text view takes it instead (⌘Return is the menu's).
struct MacroEditorCommands: Commands {
    @FocusedValue(\.macroEditor) private var editor

    var body: some Commands {
        CommandMenu("Macro") {
            Button(editor?.hasSelection == true ? "Run Selection" : "Run Macro") { editor?.run() }
                .keyboardShortcut("r")
                .disabled(editor == nil || editor?.isRunning == true)
            Button("Evaluate Line") { editor?.evaluateLine() }
                .keyboardShortcut(.return)
                .disabled(editor == nil || editor?.isRunning == true)
            Divider()
            Button("Open…") { editor?.open() }
                .disabled(editor == nil)
            Button("Save") { editor?.save() }
                .disabled(editor == nil)
            Button("Save As…") { editor?.saveAs() }
                .disabled(editor == nil)
        }
    }
}

nonisolated struct MacroEditorFocusKey: FocusedValueKey {
    typealias Value = MacroEditorModel
}

extension FocusedValues {
    /// The editor in the key window, for menu commands.
    var macroEditor: MacroEditorModel? {
        get { self[MacroEditorFocusKey.self] }
        set { self[MacroEditorFocusKey.self] = newValue }
    }
}

/// Unsaved changes in an editor, as ImageJ shows them: the window's close
/// button is marked, its title bar has the file, and closing asks first.
struct EditorWindowTracking: NSViewRepresentable {
    let model: MacroEditorModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let changed = model.isChanged
        let url = model.fileURL
        let model = model
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isDocumentEdited = changed
            window.representedURL = url
            if !(window.delegate is EditorCloseQuestion) {
                let question = EditorCloseQuestion(original: window.delegate, model: model)
                coordinator.question = question  // the window keeps its delegate weakly
                window.delegate = question
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var question: EditorCloseQuestion?
    }
}

/// The window's delegate while it shows an editor: it asks before closing
/// changed text, and passes everything else to SwiftUI's own delegate.
final class EditorCloseQuestion: NSObject, NSWindowDelegate {
    // Read from the Objective-C runtime's forwarding, on the main thread.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    weak var model: MacroEditorModel?

    init(original: (any NSWindowDelegate)?, model: MacroEditorModel) {
        self.original = original
        self.model = model
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let model, !model.mayClose() { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}
