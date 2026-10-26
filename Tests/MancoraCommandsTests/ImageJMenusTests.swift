import Foundation
import Testing

@testable import MancoraCommands

@Suite("ImageJ's menus")
struct ImageJMenusTests {
    static let root: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        return parts.joined(separator: "/")
    }()

    static func resource(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: root + "/Resources/Bridge/" + name), encoding: .utf8)
    }

    @Test func menusFollowImageJsMenuBar() throws {
        let menus = ImageJMenu.parse(try Self.resource("imagej-menus.tsv"))
        #expect(menus.map(\.title) == ["File", "Edit", "Image", "Process", "Analyze", "Plugins", "Window", "Help"])
        let image = try #require(menus.first { $0.title == "Image" })
        guard case .submenu(let type) = image.entries.first else {
            Issue.record("Image>Type comes first")
            return
        }
        #expect(type.path == "Image>Type")
        #expect(type.commands.prefix(3) == ["8-bit", "16-bit", "32-bit"])
        #expect(image.entries.contains(.command("Crop", shortcut: "X")))
        let file = try #require(menus.first)
        guard case .submenu(let new) = file.entries.first else { return }
        #expect(new.entries.first == .command("Image...", shortcut: "n"))
    }

    /// Every menu item is a command ImageJ 1.54p knows, by its exact name
    /// (Repeat Command is ImageJ's own, not a plugin).
    @Test func everyItemIsAnImageJCommand() throws {
        let menus = ImageJMenu.parse(try Self.resource("imagej-menus.tsv"))
        let table = Set(
            try Self.resource("imagej-commands.tsv").split(separator: "\n").filter { !$0.hasPrefix("#") }
                .map { String($0.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]) })
        let commands = menus.flatMap(\.commands)
        #expect(commands.count > 400)
        #expect(commands.filter { !table.contains($0) && $0 != "Repeat Command" } == [])
    }
}
