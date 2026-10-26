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

/// ImageJ's GenericDialog, shown natively: the command's name as a heading,
/// then each field as ImageJ lays it out, starting from ImageJ's defaults or
/// the values last used with this command, and OK runs the command with the
/// options ImageJ's recorder would write.
struct CommandDialogView: View {
    let pending: PendingDialog
    let run: (String) -> Void
    /// For a command with a Preview checkbox: called with the options as they
    /// stand while Preview is on, and with `nil` when it is turned off or the
    /// dialog is cancelled. Without one, the checkbox only keeps its state.
    let preview: ((String?) -> Void)?
    @State private var answers: [String: String]
    @State private var processStack = false
    @State private var previewing = false
    @Environment(\.dismiss) private var dismiss

    /// The width of the units column when a dialog has units, so the fields line up.
    private static let unitsWidth: CGFloat = 64

    init(pending: PendingDialog, run: @escaping (String) -> Void, preview: ((String?) -> Void)? = nil) {
        self.pending = pending
        self.run = run
        self.preview = preview
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

    /// The options OK would run the command with.
    private var options: String {
        pending.dialogs.options(answers, processStack: processStack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Form {
                ForEach(Array(pending.dialogs.dialogs.enumerated()), id: \.offset) { _, dialog in
                    Section(pending.dialogs.dialogs.count > 1 ? dialog.title : "") {
                        ForEach(Array(dialog.fields.enumerated()), id: \.offset) { _, field in
                            fieldView(field, reserveUnits: dialog.fields.contains { !($0.units ?? "").isEmpty })
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
            footer
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 240)
        .navigationTitle(CommandCatalog.heading(pending.command))
        .onChange(of: previewing) { notifyPreview() }
        .onChange(of: answers) { if previewing { notifyPreview() } }
        .onChange(of: processStack) { if previewing { notifyPreview() } }
    }

    /// The command's name, and the menu it is in.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CommandCatalog.heading(pending.command))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let menu = CommandCatalog.places[pending.command]?.menu {
                Text(menu)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            if pending.dialogs.supportsPreview {
                Toggle("Preview", isOn: $previewing)
                    .toggleStyle(.checkbox)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                if previewing { preview?(nil) }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("OK") {
                UserDefaults.standard.set(answers, forKey: Self.defaultsKey(pending.command))
                let chosen = options
                dismiss()
                run(chosen)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func notifyPreview() {
        preview?(previewing ? options : nil)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
    }

    @ViewBuilder
    private func fieldView(_ field: BridgeDialogs.Field, reserveUnits: Bool) -> some View {
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
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { min(max(Double(answers[key] ?? "") ?? low, low), high) },
                            set: { answers[key] = Self.format($0, like: answers[key] ?? "") }),
                        in: low...high
                    ) {
                        Text(field.label)
                    }
                    .labelsHidden()
                    .frame(minWidth: 120)
                    TextField(field.label, text: text(key))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(width: 72)
                    unitsView(field.units, reserve: reserveUnits)
                }
            }
        case .number:
            LabeledContent(field.label) {
                HStack(spacing: 6) {
                    TextField(field.label, text: text(key))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(width: 96)
                    unitsView(field.units, reserve: reserveUnits)
                }
            }
        case .string, .path, .text:
            LabeledContent(field.label) {
                HStack(spacing: 6) {
                    TextField(field.label, text: text(key))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                    unitsView(field.units, reserve: reserveUnits)
                }
            }
        }
    }

    /// A field's units in secondary text. When any field of the dialog has units they get a
    /// column of their own, so the fields above and below one without still line up.
    @ViewBuilder
    private func unitsView(_ units: String?, reserve: Bool) -> some View {
        if let units, !units.isEmpty {
            Text(units)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: reserve ? Self.unitsWidth : nil, alignment: .leading)
        } else if reserve {
            Color.clear.frame(width: Self.unitsWidth, height: 1)
        }
    }

    /// A slider's value with as many decimals as the field's text had.
    static func format(_ value: Double, like previous: String) -> String {
        let decimals = previous.split(separator: ".").dropFirst().first?.count ?? 0
        return String(format: "%.\(decimals)f", value)
    }
}
