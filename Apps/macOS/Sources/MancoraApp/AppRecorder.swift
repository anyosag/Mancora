import AppKit
import MancoraCommands
import MancoraCore
import Observation
import SwiftUI

/// Plugins ▸ Macros ▸ Record…: while it records, every command, open and
/// save becomes a line of ImageJ macro code, as in ImageJ's Recorder.
@Observable
final class AppRecorder {
    static let shared = AppRecorder()

    var isRecording = false
    private(set) var recorder = MacroRecorder()

    var macro: String { recorder.macro }

    func record(_ command: String, options: String) {
        guard isRecording else { return }
        recorder.record(command, options: MacroOptions(options))
    }

    func recordOpen(_ url: URL, virtual: Bool) {
        guard isRecording else { return }
        let path = MacroRecorder.escape(url.path)
        recorder.recordLine(virtual ? "run(\"TIFF Virtual Stack...\", \"open=[\(path)]\");" : "open(\"\(path)\");")
    }

    func recordSave(_ url: URL) {
        guard isRecording else { return }
        recorder.recordLine("saveAs(\"Tiff\", \"\(MacroRecorder.escape(url.path))\");")
    }

    func recordLine(_ line: String) {
        guard isRecording else { return }
        recorder.recordLine(line)
    }

    /// A selection made with a tool, as ImageJ's Recorder writes it.
    func recordSelection(_ roi: Roi?) {
        guard isRecording else { return }
        guard let roi else {
            recorder.record("Select None", options: MacroOptions(""))
            return
        }
        func ints(_ points: [Roi.FloatPoint]) -> String {
            points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: ",")
        }
        switch roi.shape {
        case .rectangle(let r, let corner):
            guard case .integer(let x, let y, let w, let h) = r else { return }
            recorder.recordLine("makeRectangle(\(x), \(y), \(w), \(h)" + (corner > 0 ? ", \(corner));" : ");"))
        case .oval(let r):
            guard case .integer(let x, let y, let w, let h) = r else { return }
            recorder.recordLine("makeOval(\(x), \(y), \(w), \(h));")
        case .line(let l):
            recorder.recordLine("makeLine(\(Int(l.x1)), \(Int(l.y1)), \(Int(l.x2)), \(Int(l.y2)));")
        case .polygon(let p):
            let points = p.vertices.floatPoints
            switch p.kind {
            case .angle:
                let xs = points.map { String(Int($0.x)) }.joined(separator: ",")
                let ys = points.map { String(Int($0.y)) }.joined(separator: ",")
                recorder.recordLine("makeSelection(\"angle\",newArray(\(xs)),newArray(\(ys)));")
            case .polyline, .freeline: recorder.recordLine("makeLine(\(ints(points)));")
            default: recorder.recordLine("makePolygon(\(ints(points)));")
            }
        case .points(let p):
            let points = p.vertices.floatPoints
            if points.count == 1, let only = points.first {
                recorder.recordLine("makePoint(\(Int(only.x)), \(Int(only.y)));")
            } else {
                let xs = points.map { String(Int($0.x)) }.joined(separator: ",")
                let ys = points.map { String(Int($0.y)) }.joined(separator: ",")
                recorder.recordLine("makeSelection(\"point\",newArray(\(xs)),newArray(\(ys)));")
            }
        case .opaque:
            break
        }
    }

    func clear() { recorder = MacroRecorder() }
}

/// The Recorder window: the macro so far, and what to do with it.
struct RecorderView: View {
    @Bindable var recorder: AppRecorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RecorderText(text: recorder.macro)
            .overlay {
                if recorder.macro.isEmpty {
                    ContentUnavailableView(
                        "Nothing Recorded Yet", systemImage: "record.circle",
                        description: Text("Commands you run appear here as macro code."))
                }
            }
            .frame(minWidth: 420, minHeight: 220)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $recorder.isRecording) {
                        Label("Record", systemImage: recorder.isRecording ? "record.circle.fill" : "record.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .toggleStyle(.button)
                    .tint(.red)
                    .help("Record the commands you run as macro code")
                    Button("Clear", systemImage: "trash") { recorder.clear() }
                        .help("Throw away what has been recorded")
                        .disabled(recorder.macro.isEmpty)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recorder.macro, forType: .string)
                    }
                    .help("Copy the macro to the clipboard")
                    .disabled(recorder.macro.isEmpty)
                    Button("Create Macro", systemImage: "square.and.pencil") { createMacro() }
                        .help("Open the recorded macro in an editor window, to run, change or save")
                        .disabled(recorder.macro.isEmpty)
                }
            }
            .onAppear { recorder.isRecording = true }
    }

    /// Create Macro: the recorded text in a new editor window (ImageJ's Recorder opens its Editor).
    private func createMacro() {
        openWindow(id: "macro-editor", value: EditorRequest(serial: UUID(), text: recorder.macro))
    }
}

/// The recorded macro: monospaced text you can select, in the colors of the macro editor, that
/// follows the newest line.
struct RecorderText: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.shown != text, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.shown = text
        textView.textStorage?.setAttributedString(Self.attributed(text))
        textView.scrollToEndOfDocument(nil)
    }

    final class Coordinator {
        /// The text the view has, so it is replaced only when it changes.
        var shown = ""
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for span in MacroSyntax.spans(in: text, keywords: MacroTextView.keywords, functions: MacroTextView.functions) {
            result.addAttribute(.foregroundColor, value: color(of: span.kind), range: span.range)
        }
        return result
    }

    private static func color(of kind: MacroSyntax.Kind) -> NSColor {
        switch kind {
        case .comment: .systemGreen
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPurple
        case .function: .systemTeal
        }
    }
}
