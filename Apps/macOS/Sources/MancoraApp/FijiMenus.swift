import Foundation
import MancoraBridge
import MancoraCommands
import MancoraFiji
import Observation

// Fiji's menus in the menu bar. ImageJ's own menus come from the table the app
// ships (`imagej-menus.tsv`); Fiji has more in them (Plugins ▸ Tracking ▸ TrackMate,
// File ▸ New ▸ Script…). The bridge lists Fiji's whole menu bar, and what the
// table lacks is merged into it, next to the entries around it in Fiji.
//
// The list is kept on disk beside the installation (`Fiji.menus.json`), so the
// menu bar has Fiji's entries at launch, before any Java runs. It's read again
// whenever the helper starts, which is when an update that was waiting goes in.
// Nothing here uses AppKit or SwiftUI, so the logic can be checked on its own.

/// One entry of Fiji's menus, as the bridge lists it and the disk cache keeps it.
nonisolated struct FijiMenuEntry: Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Hashable, Sendable {
        /// An ImageJ 1.x command or plugin: runs as any ImageJ command does.
        case imagej1
        /// A SciJava command: runs in Fiji, which shows its dialog or window.
        case command
        /// A script in Fiji's `scripts/` or `plugins/` folders.
        case script
        case separator
    }

    let kind: Kind
    /// The menus down to the item, its own label last (`["Plugins", "Tracking", "TrackMate"]`);
    /// a separator's is its menu's.
    let path: [String]
    let command: String?
    /// ImageJ 1.x's class and argument, or `command:<class>` or `script:<path>`.
    let identifier: String?
    /// ImageJ's way of writing it, `Shift+X` (Command on a Mac).
    let shortcut: String?

    init(kind: Kind, path: [String], command: String?, identifier: String? = nil, shortcut: String? = nil) {
        self.kind = kind
        self.path = path
        self.command = command
        self.identifier = identifier
        self.shortcut = shortcut
    }

    init(_ item: BridgeMenuItem) {
        self.init(
            kind: Kind(rawValue: item.kind.rawValue) ?? .command, path: item.path, command: item.command,
            identifier: item.identifier, shortcut: item.shortcut)
    }

    var isSeparator: Bool { kind == .separator }

    /// The menus it is in: `["Plugins", "Tracking"]`. Empty for a command that is in no menu.
    var menuPath: [String] { isSeparator ? path : Array(path.dropLast()) }

    /// What the menu shows.
    var label: String { command ?? path.last ?? "" }

    /// `Plugins > Tracking > TrackMate`: how Fiji names a menu entry, and what Find Command calls it.
    var fullPath: String { path.joined(separator: " > ") }
}

/// A keyboard shortcut of Fiji's, as a Mac writes it: always with Command.
nonisolated struct FijiShortcut: Hashable, Sendable {
    /// Lowercase.
    let key: Character
    let shift: Bool
    let option: Bool
    let control: Bool

    /// As a menu shows it: `⇧⌘X`.
    var text: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + "⌘" + String(key).uppercased()
    }

    /// The same shortcut written the same way, whoever wrote it.
    var signature: String { "\(control ? "c" : "")\(option ? "o" : "")\(shift ? "s" : "")-\(key)" }

    /// ImageJ's `Shift+X` (and `X`), or SciJava's `ctrl shift X`; `nil` for keys a menu can't take
    /// (function keys, say). Control in ImageJ's and SciJava's words is Command on a Mac.
    static func parse(_ text: String) -> FijiShortcut? {
        var spaced = ""
        for character in text {
            switch character {
            case "⇧": spaced += " shift "
            case "⌥": spaced += " alt "
            case "⌘", "⌃": spaced += " ctrl "
            case "+", "-": spaced += " "
            default: spaced.append(character)
            }
        }
        let words = spaced.lowercased().split(separator: " ").map(String.init)
        guard let last = words.last else { return nil }
        var shift = false, option = false
        for word in words.dropLast() {
            switch word {
            case "shift": shift = true
            case "alt", "option", "opt": option = true
            case "ctrl", "control", "cmd", "command", "meta": break
            default: return nil
            }
        }
        guard let key = Self.key(named: last) else { return nil }
        return FijiShortcut(key: key, shift: shift, option: option, control: false)
    }

    private static func key(named word: String) -> Character? {
        if word.count == 1, let character = word.first, character.isLetter || character.isNumber { return character }
        switch word {
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "minus": return "-"
        case "equals": return "="
        case "semicolon": return ";"
        default: return nil
        }
    }
}

/// An entry that Fiji has and the app's own table lacks, as placed in the menus.
nonisolated struct FijiMenuItem: Hashable, Sendable {
    let entry: FijiMenuEntry
    /// The menu it is in, as `ImageJMenu.path` writes it: `Plugins>Tracking`.
    let menuPath: String
    /// Its shortcut, unless something else in the menus has it.
    var shortcut: FijiShortcut?

    var label: String { entry.label }

    /// `Plugins > Tracking > TrackMate`.
    var key: String { entry.fullPath }

    /// `Plugins ▸ Tracking`, as Find Command and the dialogs show a menu.
    var menuTitle: String { menuPath.split(separator: ">").joined(separator: " ▸ ") }
}

/// A script of Fiji's menus, read from its file: what Fiji's script service runs.
nonisolated struct FijiScript: Sendable {
    let code: String
    /// The file's extension (`groovy`, `py`, `ijm`), which names the language to Fiji.
    let language: String

    /// `nil` for an entry that isn't a script, or whose file can't be read (a script that lives inside
    /// a jar): Fiji then runs it from its identifier.
    init?(_ entry: FijiMenuEntry, root: URL = FijiManager.shared.root) {
        guard entry.kind == .script, let identifier = entry.identifier, identifier.hasPrefix("script:") else { return nil }
        let path = String(identifier.dropFirst("script:".count))
        var candidates: [URL] = []
        if path.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: path))
        } else {
            candidates.append(root.appendingPathComponent(path))
            candidates.append(root.appendingPathComponent("scripts").appendingPathComponent(path))
        }
        var found: (code: String, language: String)?
        for url in candidates where !url.pathExtension.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            found = (text, url.pathExtension)
            break
        }
        guard let found else { return nil }
        code = found.code
        language = found.language
    }
}

/// Merging Fiji's menus into ImageJ's.
nonisolated enum FijiMenuMerge {
    /// Where a menu's entry is looked up: its menu's path and its name.
    static func key(menuPath: String, name: String) -> String {
        menuPath + "\u{1F}" + name.trimmingCharacters(in: .whitespaces)
    }

    /// `base` with the entries of `fiji` it lacks added. Entries both have stay as `base` has
    /// them (and run as they do today); each new one is put after the entry before it in Fiji, with
    /// the separators Fiji puts around it. New submenus come with everything in them.
    static func merge(base: [ImageJMenu], fiji: [FijiMenuEntry]) -> (menus: [ImageJMenu], added: [FijiMenuItem]) {
        let roots = tree(of: fiji)
        var added: [FijiMenuItem] = []
        var menus: [ImageJMenu] = []
        for menu in base {
            guard let node = roots[menu.title] else {
                menus.append(menu)
                continue
            }
            var merged = menu
            merged.entries = entries(base: menu.entries, path: menu.path, children: node.children, added: &added)
            menus.append(merged)
        }
        return (menus, added)
    }

    /// The shortcuts of `menus`, as `FijiShortcut/signature` writes them, and those a Mac keeps
    /// for itself (hide, quit, close, minimize).
    static func shortcutsUsed(by menus: [ImageJMenu]) -> Set<String> {
        var used: Set<String> = ["-h", "-q", "-w", "-m"]
        func collect(_ entries: [ImageJMenu.Entry]) {
            for entry in entries {
                switch entry {
                case .command(_, let shortcut):
                    if let shortcut, shortcut.isLetter || shortcut.isNumber {
                        used.insert((shortcut.isUppercase ? "s" : "") + "-" + shortcut.lowercased())
                    }
                case .submenu(let menu): collect(menu.entries)
                case .separator: break
                }
            }
        }
        for menu in menus { collect(menu.entries) }
        return used
    }

    // MARK: Fiji's menus as a tree

    private nonisolated final class Node {
        nonisolated enum Child {
            case item(FijiMenuEntry)
            case separator
            case menu(Node)
        }

        let title: String
        var children: [Child] = []
        var submenus: [String: Node] = [:]

        init(title: String) { self.title = title }

        /// The submenu down `path` from this one, made (in order) if it isn't there yet.
        func menu(_ path: ArraySlice<String>) -> Node {
            guard let first = path.first else { return self }
            if let existing = submenus[first] { return existing.menu(path.dropFirst()) }
            let node = Node(title: first)
            submenus[first] = node
            children.append(.menu(node))
            return node.menu(path.dropFirst())
        }
    }

    /// The top-level menus by title. Entries in no menu are left out.
    private static func tree(of entries: [FijiMenuEntry]) -> [String: Node] {
        var roots: [String: Node] = [:]
        for entry in entries {
            let path = entry.menuPath
            guard let top = path.first else { continue }
            let root: Node
            if let existing = roots[top] {
                root = existing
            } else {
                root = Node(title: top)
                roots[top] = root
            }
            root.menu(path.dropFirst()).children.append(entry.isSeparator ? .separator : .item(entry))
        }
        return roots
    }

    private static func isSeparator(_ entry: ImageJMenu.Entry) -> Bool {
        if case .separator = entry { return true }
        return false
    }

    private static func isCommand(_ entry: ImageJMenu.Entry, named name: String) -> Bool {
        if case .command(let candidate, _) = entry { return candidate.trimmingCharacters(in: .whitespaces) == name }
        return false
    }

    private static func isSubmenu(_ entry: ImageJMenu.Entry, titled title: String) -> Bool {
        if case .submenu(let menu) = entry { return menu.title.trimmingCharacters(in: .whitespaces) == title }
        return false
    }

    /// One menu's entries with Fiji's `children` merged in.
    private static func entries(
        base: [ImageJMenu.Entry], path: String, children: [Node.Child], added: inout [FijiMenuItem]
    ) -> [ImageJMenu.Entry] {
        var out = base
        // The last entry of `out` that Fiji's order has reached: new entries go after it.
        var cursor = -1
        // Fiji has a separator that `out` hasn't reached, and whether the entry before it is new.
        var pendingSeparator = false
        var afterNew = false

        // A new entry goes in after the cursor, with the separator Fiji has before it.
        func insert(_ entry: ImageJMenu.Entry) {
            if pendingSeparator, cursor >= 0, !isSeparator(out[cursor]) {
                out.insert(.separator, at: cursor + 1)
                cursor += 1
            }
            out.insert(entry, at: cursor + 1)
            cursor += 1
            pendingSeparator = false
            afterNew = true
        }

        // An entry `out` already had: Fiji's order has reached it, and a separator between it and new entries stays.
        func reach(_ index: Int) {
            var index = index
            if pendingSeparator, afterNew, index == cursor + 1 {
                out.insert(.separator, at: index)
                index += 1
            }
            cursor = index
            pendingSeparator = false
            afterNew = false
        }

        for child in children {
            switch child {
            case .separator:
                if cursor + 1 < out.count, isSeparator(out[cursor + 1]) {
                    cursor += 1
                    pendingSeparator = false
                } else {
                    pendingSeparator = true
                }
            case .item(let entry):
                let name = entry.label.trimmingCharacters(in: .whitespaces)
                if let index = out.firstIndex(where: { isCommand($0, named: name) }) {
                    reach(index)
                } else {
                    insert(.command(entry.label, shortcut: nil))
                    added.append(FijiMenuItem(entry: entry, menuPath: path, shortcut: nil))
                }
            case .menu(let node):
                let title = node.title.trimmingCharacters(in: .whitespaces)
                if let index = out.firstIndex(where: { isSubmenu($0, titled: title) }), case .submenu(var submenu) = out[index] {
                    submenu.entries = entries(base: submenu.entries, path: submenu.path, children: node.children, added: &added)
                    out[index] = .submenu(submenu)
                    reach(index)
                } else {
                    var fresh = ImageJMenu(title: node.title, path: path + ">" + node.title)
                    fresh.entries = entries(base: [], path: fresh.path, children: node.children, added: &added)
                    if !fresh.entries.isEmpty { insert(.submenu(fresh)) }
                }
            }
        }
        return out
    }
}

// MARK: The cache

/// Fiji's menu list as kept on disk, and what it was made for: the Fiji it came from (its versions,
/// as `FijiVersion` writes them), and when that Fiji's update sites last changed it.
nonisolated struct FijiMenuCache: Codable, Sendable {
    var version: String
    var changed: Int
    var entries: [FijiMenuEntry]
}

nonisolated enum FijiMenuStore {
    /// `Fiji.menus.json`, beside the installation's `Fiji.json`.
    static func file(root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".menus.json")
    }

    /// What a list is kept for: the installation's versions, and when its update sites last changed
    /// it (the updater rewrites `db.xml.gz` whenever it installs or removes anything).
    static func key(for installation: FijiInstallation) -> (version: String, changed: Int) {
        let database = installation.root.appendingPathComponent("db.xml.gz")
        let attributes = try? FileManager.default.attributesOfItem(atPath: database.path)
        let changed = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (installation.version.description, Int(changed))
    }

    static func read(root: URL) -> FijiMenuCache? {
        guard let data = try? Data(contentsOf: file(root: root)) else { return nil }
        return try? JSONDecoder().decode(FijiMenuCache.self, from: data)
    }

    static func write(_ cache: FijiMenuCache, root: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file(root: root), options: .atomic)
    }

    static func remove(root: URL) {
        try? FileManager.default.removeItem(at: file(root: root))
    }
}

// MARK: The menus the app shows

/// ImageJ's menus with Fiji's merged in, for the menu bar, Find Command and the welcome window's
/// sample list. Without Fiji they are the app's own table.
@Observable
final class FijiMenus {
    static let shared = FijiMenus()

    private(set) var menus: [ImageJMenu]
    /// What Fiji has and the table lacks, in menu order.
    private(set) var items: [FijiMenuItem] = []
    /// The list the menus were made from.
    private(set) var entries: [FijiMenuEntry] = []
    @ObservationIgnored private var lookup: [String: FijiMenuItem] = [:]
    @ObservationIgnored private var byKey: [String: FijiMenuItem] = [:]

    init() {
        menus = ImageJMenuCommands.baseMenus
        // The list from the last time Fiji ran, if it is for this version of Fiji. Plugins added or
        // removed by an update site since (the cache's `changed` is older) stay as they were
        // until a helper starts and says: the menu bar should not lose TrackMate before that.
        guard !Screenshots.isActive, FijiManager.shared.isInstalled,
            let cache = FijiMenuStore.read(root: FijiManager.shared.root),
            cache.version == FijiMenuStore.key(for: FijiManager.shared.installation).version
        else { return }
        entries = cache.entries
        rebuild()
    }

    /// A Fiji-only entry of the menu at `path` (`ImageJMenu.path`).
    func item(path: String, name: String) -> FijiMenuItem? {
        lookup[FijiMenuMerge.key(menuPath: path, name: name)]
    }

    /// A Fiji-only entry by its `Plugins > Tracking > TrackMate` path.
    func item(forKey key: String) -> FijiMenuItem? { byKey[key] }

    /// Fiji's list, as the helper has just given it: used from now on, and kept for the next launch.
    func update(_ list: [FijiMenuEntry]) {
        guard !list.isEmpty else { return }
        if list != entries {
            entries = list
            rebuild()
        }
        guard !Screenshots.isActive else { return }
        let manager = FijiManager.shared
        let key = FijiMenuStore.key(for: manager.installation)
        FijiMenuStore.write(FijiMenuCache(version: key.version, changed: key.changed, entries: list), root: manager.root)
    }

    /// Fiji is gone (reinstalling): the app's own table again.
    func forget() {
        FijiMenuStore.remove(root: FijiManager.shared.root)
        entries = []
        rebuild()
    }

    private func rebuild() {
        let base = ImageJMenuCommands.baseMenus
        let merged = FijiMenuMerge.merge(base: base, fiji: entries)
        var used = FijiMenuMerge.shortcutsUsed(by: base)
        var placed: [FijiMenuItem] = []
        for var item in merged.added {
            if let text = item.entry.shortcut, let shortcut = FijiShortcut.parse(text), !used.contains(shortcut.signature) {
                used.insert(shortcut.signature)
                item.shortcut = shortcut
            }
            placed.append(item)
        }
        menus = merged.menus
        items = placed
        lookup = Dictionary(placed.map { (FijiMenuMerge.key(menuPath: $0.menuPath, name: $0.label), $0) }, uniquingKeysWith: { first, _ in first })
        byKey = Dictionary(placed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        CommandCatalog.invalidate()
    }
}
