import Foundation
import MancoraBridge
import SwiftUI

/// A command waiting for its options: the dialogs ImageJ would show for it,
/// read through the bridge.
struct PendingDialog: Identifiable {
    let id = UUID()
    let command: String
    let dialogs: BridgeDialogs
    let stackSize: Int
}

/// ImageJ's GenericDialog, shown natively: each field as ImageJ lays it out,
/// starting from ImageJ's defaults or the values last used with this
/// command, and OK runs the command with the options ImageJ's recorder
/// would write.
struct CommandDialogView: View {
    let pending: PendingDialog
    let run: (String) -> Void
    @State private var answers: [String: String]
    @State private var processStack = false
    @Environment(\.dismiss) private var dismiss

    init(pending: PendingDialog, run: @escaping (String) -> Void) {
        self.pending = pending
        self.run = run
        var initial: [String: String] = [:]
        for dialog in pending.dialogs.dialogs {
            for field in dialog.fields {
                if let key = field.key { initial[key] = field.value ?? "" }
            }
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey(pending.command)) as? [String: String] {
            for (key, value) in saved where initial[key] != nil { initial[key] = value }
        }
        _answers = State(initialValue: initial)
    }

    static func defaultsKey(_ command: String) -> String { "dialog." + command }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(Array(pending.dialogs.dialogs.enumerated()), id: \.offset) { _, dialog in
                    Section(pending.dialogs.dialogs.count > 1 ? dialog.title : "") {
                        ForEach(Array(dialog.fields.enumerated()), id: \.offset) { _, field in
                            fieldView(field)
                        }
                    }
                }
                if pending.dialogs.asksForStack {
                    Section {
                        Toggle("Process all \(pending.stackSize) images", isOn: $processStack)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    UserDefaults.standard.set(answers, forKey: Self.defaultsKey(pending.command))
                    let options = pending.dialogs.options(answers, processStack: processStack)
                    dismiss()
                    run(options)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 200)
        .navigationTitle(pending.dialogs.dialogs.first?.title ?? pending.command)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
    }

    @ViewBuilder
    private func fieldView(_ field: BridgeDialogs.Field) -> some View {
        let key = field.key ?? ""
        switch field.kind {
        case .message:
            Text(field.label)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .checkbox:
            Toggle(
                field.label,
                isOn: Binding(get: { answers[key] == "true" }, set: { answers[key] = $0 ? "true" : "false" }))
        case .choice:
            Picker(field.label, selection: text(key)) {
                ForEach(field.items ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .radio:
            Picker(field.label, selection: text(key)) {
                ForEach(field.items ?? [], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.radioGroup)
        case .slider:
            let low = field.minimum ?? 0
            let high = max(field.maximum ?? 100, low + 1)
            LabeledContent(field.label) {
                HStack {
                    Slider(
                        value: Binding(
                            get: { min(max(Double(answers[key] ?? "") ?? low, low), high) },
                            set: { answers[key] = Self.format($0, like: answers[key] ?? "") }),
                        in: low...high)
                    TextField("", text: text(key))
                        .frame(width: 64)
                }
            }
        case .number, .string, .path, .text:
            LabeledContent(field.label) {
                HStack {
                    TextField("", text: text(key))
                    if let units = field.units, !units.isEmpty {
                        Text(units).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A slider's value with as many decimals as the field's text had.
    static func format(_ value: Double, like previous: String) -> String {
        let decimals = previous.split(separator: ".").dropFirst().first?.count ?? 0
        return String(format: "%.\(decimals)f", value)
    }
}
