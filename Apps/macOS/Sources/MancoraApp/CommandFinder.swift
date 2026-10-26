import MancoraBridge
import MancoraCommands
import SwiftUI

/// Where ImageJ's menus keep each command: shown beside a command in Find
/// Command, and under the heading of its dialog.
enum CommandCatalog {
    struct Place {
        /// The menu the command is in, such as "Process ▸ Filters".
        let menu: String
        /// Its keyboard shortcut as a menu shows it, such as "⇧⌘L".
        let shortcut: String?
    }

    /// Every command in ImageJ's menus, by name.
    static let places: [String: Place] = {
        var found: [String: Place] = [:]
        func walk(_ menu: ImageJMenu) {
            let path = menu.path.split(separator: ">").joined(separator: " ▸ ")
            for entry in menu.entries {
                switch entry {
                case .command(let name, let shortcut):
                    if found[name] == nil {
                        found[name] = Place(menu: path, shortcut: shortcutText(name: name, shortcut: shortcut))
                    }
                case .submenu(let child):
                    walk(child)
                case .separator:
                    break
                }
            }
        }
        for menu in ImageJMenuCommands.menus { walk(menu) }
        return found
    }()

    /// The shortcut as the menu bar gives it: the same ones, by `MenuCommandButton.keyEquivalent`'s rules.
    static func shortcutText(name: String, shortcut: Character?) -> String? {
        guard MenuCommandButton.keyEquivalent(name: name, shortcut: shortcut) != nil else { return nil }
        if name.hasSuffix("[+]") { return "⌘+" }
        if name.hasSuffix("[-]") { return "⌘-" }
        guard let shortcut else { return nil }
        return (shortcut.isUppercase ? "⇧⌘" : "⌘") + String(shortcut).uppercased()
    }

    /// A command's name as a heading: "Gaussian Blur..." as "Gaussian Blur".
    static func heading(_ name: String) -> String {
        var text = MenuCommandButton.title(name)
        while text.hasSuffix(".") || text.hasSuffix("…") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// The commands run from Find Command lately, newest first.
enum RecentCommands {
    static let limit = 6
    private static let key = "FindCommand.Recent"

    /// A list to show instead of the stored one, which then stays as it is
    /// (the screenshot run uses this).
    static var preset: [String]?

    static var names: [String] {
        preset ?? UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func note(_ name: String) {
        guard preset == nil else { return }
        var names = self.names.filter { $0 != name }
        names.insert(name, at: 0)
        UserDefaults.standard.set(Array(names.prefix(limit)), forKey: key)
    }
}

/// ImageJ's Command Finder (⌘L): every command, native or in ImageJ,
/// searchable by name, each with its menu and shortcut; Return runs the
/// selection on the current image, ↑ and ↓ move it. With nothing typed yet,
/// the commands run lately come first.
struct CommandFinder: View {
    @Bindable var model: ViewerModel
    let bridge: AppBridge
    let openNewWindows: ([URL]) -> Void
    /// A search to start with (the screenshot run shows one).
    static var presetQuery: String?
    @State private var query = CommandFinder.presetQuery ?? ""
    @State private var selection: String?
    @State private var recent = RecentCommands.names
    @State private var didRun = false
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    fileprivate struct Entry: Hashable {
        let name: String
        let title: String
        /// The menu it is in, if it is in one.
        let menu: String?
        let shortcut: String?
    }

    fileprivate struct ResultGroup {
        let title: String?
        let entries: [Entry]
    }

    /// Every command, by title.
    private var entries: [Entry] {
        var names = Set(CommandRegistry.standard.commands.keys)
        var plugins = Set<String>()
        for command in bridge.commands where !names.contains(command.name) {
            names.insert(command.name)
            if command.isPlugin { plugins.insert(command.name) }
        }
        return names.map { name in
            let place = CommandCatalog.places[name]
            return Entry(
                name: name, title: MenuCommandButton.title(name),
                menu: place?.menu ?? (plugins.contains(name) ? "Plugins" : nil), shortcut: place?.shortcut)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var groups: [ResultGroup] {
        let all = entries
        let words = query.lowercased().split(separator: " ")
        if !words.isEmpty {
            return [ResultGroup(title: nil, entries: all.filter { entry in words.allSatisfy { entry.name.lowercased().contains($0) } })]
        }
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let lately = recent.compactMap { byName[$0] }
        if lately.isEmpty { return [ResultGroup(title: nil, entries: all)] }
        let lateNames = Set(lately.map(\.name))
        return [
            ResultGroup(title: "Recent", entries: lately),
            ResultGroup(title: "All Commands", entries: all.filter { !lateNames.contains($0.name) }),
        ]
    }

    private func effectiveSelection(in rows: [Entry]) -> String? {
        if let selection, rows.contains(where: { $0.name == selection }) { return selection }
        return rows.first?.name
    }

    var body: some View {
        let groups = self.groups
        let rows = groups.flatMap(\.entries)
        let selected = effectiveSelection(in: rows)
        VStack(spacing: 0) {
            searchField
            Divider()
            if rows.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultList(groups, selected: selected)
            }
            Divider()
            footer(canRun: selected != nil)
        }
        .frame(width: 540, height: 460)
        .task { await bridge.start() }
        .task {
            // A sheet takes a moment to become key; focus the field once it has.
            try? await Task.sleep(for: .milliseconds(120))
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search commands", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(runSelection)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    move(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func resultList(_ groups: [ResultGroup], selected: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if let title = group.title {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.entries, id: \.name) { entry in
                            Row(entry: entry, isSelected: entry.name == selected)
                                .id(entry.name)
                                .onTapGesture { run(entry.name) }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) {
                if let selection { proxy.scrollTo(selection) }
            }
            .onChange(of: query) {
                selection = nil
                if let first = self.groups.first?.entries.first { proxy.scrollTo(first.name, anchor: .top) }
            }
        }
    }

    private func footer(canRun: Bool) -> some View {
        HStack {
            bridgeStatus
                .font(.callout)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run", action: runSelection)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One command: its name, the menu it is in and its shortcut.
    fileprivate struct Row: View {
        let entry: Entry
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 10) {
                Text(entry.title)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let menu = entry.menu {
                    Text(menu)
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Text(entry.shortcut ?? "")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
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

    /// ↑ and ↓ move the selection a row; it stops at the ends.
    private func move(_ delta: Int) {
        let rows = groups.flatMap(\.entries)
        guard !rows.isEmpty else { return }
        let current = effectiveSelection(in: rows).flatMap { name in rows.firstIndex(where: { $0.name == name }) } ?? 0
        selection = rows[min(max(current + delta, 0), rows.count - 1)].name
    }

    private func runSelection() {
        guard let name = effectiveSelection(in: groups.flatMap(\.entries)) else { return }
        run(name)
    }

    private func run(_ name: String) {
        // Return reaches both the field and the default button.
        guard !didRun else { return }
        didRun = true
        RecentCommands.note(name)
        dismiss()
        Task {
            // As from the menus: a command with a dialog asks for its options first.
            let created = await model.perform(name, bridge: bridge)
            openNewWindows(created)
        }
    }
}
