import AppKit
import MancoraCommands
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
