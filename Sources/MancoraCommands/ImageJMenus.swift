/// ImageJ's menu bar (File, Edit, Image, Process, Analyze, Plugins, Window,
/// Help), read from `Resources/Bridge/imagej-menus.tsv`, which
/// `Tools/menus/generate.py` writes from ImageJ's `IJ_Props.txt` the way
/// `ij.Menus` builds its menus.
public struct ImageJMenu: Sendable, Hashable, Identifiable {
    public enum Entry: Sendable, Hashable {
        /// A command, by its ImageJ name, and its shortcut: a lowercase
        /// letter or a digit means Cmd (Ctrl on Windows), uppercase adds Shift.
        case command(String, shortcut: Character?)
        case separator
        case submenu(ImageJMenu)
    }

    public let title: String
    /// `Image>Adjust`, for example.
    public let path: String
    public var entries: [Entry]

    public var id: String { path }

    /// Every command in this menu and its submenus.
    public var commands: [String] {
        entries.flatMap { entry -> [String] in
            switch entry {
            case .command(let name, _): [name]
            case .separator: []
            case .submenu(let menu): menu.commands
            }
        }
    }

    public init(title: String, path: String, entries: [Entry] = []) {
        self.title = title
        self.path = path
        self.entries = entries
    }

    /// The top-level menus, in order, from the table's lines.
    public static func parse(_ table: String) -> [ImageJMenu] {
        var order: [String] = []
        var rows: [String: [(command: String, shortcut: String)]] = [:]
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let path = fields[0]
            if rows[path] == nil {
                order.append(path)
                rows[path] = []
            }
            rows[path]!.append((fields[1], fields.count > 2 ? fields[2] : ""))
        }
        func build(_ path: String) -> ImageJMenu {
            let title = path.split(separator: ">").last.map(String.init) ?? path
            var menu = ImageJMenu(title: title, path: path)
            for row in rows[path] ?? [] {
                if row.command == "-" {
                    menu.entries.append(.separator)
                } else if row.command.hasPrefix(">") {
                    let child = path + ">" + row.command.dropFirst()
                    menu.entries.append(.submenu(build(child)))
                } else {
                    menu.entries.append(.command(row.command, shortcut: row.shortcut.first))
                }
            }
            return menu
        }
        return order.filter { !$0.contains(">") }.map(build)
    }
}
