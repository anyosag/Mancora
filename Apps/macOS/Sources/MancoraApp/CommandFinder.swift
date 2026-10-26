import MancoraBridge
import MancoraCommands
import SwiftUI

/// ImageJ's Command Finder (⌘L): every command, native or in ImageJ,
/// searchable by name; Return runs the selection on the current image.
struct CommandFinder: View {
    @Bindable var model: ViewerModel
    let bridge: AppBridge
    let openNewWindows: ([URL]) -> Void
    @State private var query = ""
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Hashable {
        let name: String
        let source: String
    }

    private var entries: [Entry] {
        let native = CommandRegistry.standard.commands.keys
        var all = Dictionary(uniqueKeysWithValues: native.map { ($0, "Mancora") })
        for command in bridge.commands where all[command.name] == nil {
            all[command.name] = command.isPlugin ? "Plugin" : "ImageJ"
        }
        let words = query.lowercased().split(separator: " ")
        return all.map { Entry(name: $0.key, source: $0.value) }
            .filter { entry in words.allSatisfy { entry.name.lowercased().contains($0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit(runSelection)
            List(entries, id: \.name, selection: $selection) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Text(entry.source).foregroundStyle(.secondary).font(.caption)
                }
                .tag(entry.name)
            }
            .frame(minHeight: 280)
            Divider()
            HStack {
                bridgeStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Run", action: runSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled((selection ?? entries.first?.name) == nil)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .task { await bridge.start() }
    }

    @ViewBuilder private var bridgeStatus: some View {
        switch bridge.state {
        case .idle, .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting ImageJ…").foregroundStyle(.secondary)
            }
        case .ready(let imagej, _):
            Text("ImageJ \(imagej)").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    private func runSelection() {
        guard let name = selection ?? entries.first?.name else { return }
        dismiss()
        Task {
            // As from the menus: a command with a dialog asks for its options first.
            let created = await model.perform(name, bridge: bridge)
            openNewWindows(created)
        }
    }
}
