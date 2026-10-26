import AppKit
import MancoraCommands
import MancoraCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Record", isOn: $recorder.isRecording)
                    .toggleStyle(.button)
                Spacer()
                Button("Clear") { recorder.clear() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recorder.macro, forType: .string)
                }
                Button("Create…") { save() }
            }
            ScrollView {
                Text(recorder.macro.isEmpty ? "Commands you run appear here as macro code." : recorder.macro)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(recorder.macro.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 220)
        .onAppear { recorder.isRecording = true }
    }

    /// Saves the macro as an `.ijm` file, which Plugins ▸ Macros ▸ Run… runs.
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ijm") ?? .plainText]
        panel.nameFieldStringValue = "Macro.ijm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? recorder.macro.write(to: url, atomically: true, encoding: .utf8)
    }
}
