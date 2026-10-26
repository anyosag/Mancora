import AppKit
import MancoraBridge
import UniformTypeIdentifiers
import MancoraCommands
import SwiftUI

/// ImageJ's menu bar: File, Edit, Image, Process, Analyze, Plugins, Window
/// and Help, with ImageJ's items and shortcuts. Commands Mancora has run
/// natively, others in ImageJ through the bridge; either way a command
/// with a dialog asks for its options first. What belongs to the app
/// itself (opening, closing, saving, zooming, windows) is done natively.
struct ImageJMenuCommands: Commands {
    let bridge: AppBridge
    @FocusedValue(\.viewer) private var viewer
    @FocusedValue(\.macroEditor) private var editor
    @Environment(\.openWindow) private var openWindow

    static let menus: [ImageJMenu] = {
        guard let folder = AppBridge.resources,
            let table = try? String(contentsOf: folder.appendingPathComponent("imagej-menus.tsv"), encoding: .utf8)
        else { return [] }
        return ImageJMenu.parse(table)
    }()

    static func menu(_ title: String) -> ImageJMenu {
        menus.first { $0.title == title } ?? ImageJMenu(title: title, path: title)
    }

    /// Items the system menus already have (Edit's Undo, Cut, Copy, Paste; File's Quit).
    static let systemItems: Set<String> = ["Undo", "Cut", "Copy", "Paste", "Quit"]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MenuEntries(entries: Self.menu("File").entries, skipping: Self.systemItems, perform: perform)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            MenuEntries(entries: Self.menu("Edit").entries, skipping: Self.systemItems, perform: perform)
        }
        CommandMenu("Image") { MenuEntries(entries: Self.menu("Image").entries, perform: perform) }
        CommandMenu("Process") { MenuEntries(entries: Self.menu("Process").entries, perform: perform) }
        CommandMenu("Analyze") { MenuEntries(entries: Self.menu("Analyze").entries, perform: perform) }
        CommandGroup(before: .windowArrangement) {
            MenuEntries(entries: Self.menu("Window").entries, perform: perform)
            Divider()
            Button("Results") { openWindow(id: "results") }
            Button("Log") { openWindow(id: "log") }
            Divider()
        }
        CommandGroup(replacing: .help) {
            MenuEntries(entries: Self.menu("Help").entries, perform: perform)
        }
    }

    func perform(_ name: String) {
        // With an editor in front, File ▸ Open, Save and Save As ▸ Text act on its text.
        if let editor, editor.perform(name) { return }
        AppMenuActions.perform(name, viewer: viewer, bridge: bridge, openWindow: openWindow)
    }
}

/// A menu's items; submenus nest.
struct MenuEntries: View {
    let entries: [ImageJMenu.Entry]
    var skipping: Set<String> = []
    let perform: (String) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .command(let name, let shortcut):
                if !skipping.contains(name) {
                    MenuCommandButton(name: name, shortcut: shortcut, perform: perform)
                }
            case .submenu(let menu):
                Menu(menu.title) {
                    MenuEntries(entries: menu.entries, perform: perform)
                }
            }
        }
    }
}

struct MenuCommandButton: View {
    let name: String
    let shortcut: Character?
    let perform: (String) -> Void

    var body: some View {
        let button = Button(Self.title(name)) { perform(name) }
        if let equivalent = Self.keyEquivalent(name: name, shortcut: shortcut) {
            button.keyboardShortcut(equivalent.key, modifiers: equivalent.modifiers)
        } else {
            button
        }
    }

    /// ImageJ shows hotkeys in brackets ("In [+]"); the menu shows them as shortcuts instead.
    static func title(_ name: String) -> String {
        var title = name.trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("]"), let open = title.lastIndex(of: "["), open > title.startIndex {
            title = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return title.replacingOccurrences(of: " [/]", with: "")
    }

    /// ImageJ's Cmd-letter shortcuts (Shift for capitals), except Cmd-H, which hides the app on a Mac.
    static func keyEquivalent(name: String, shortcut: Character?) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        if name.hasSuffix("[+]") { return (KeyEquivalent("+"), .command) }
        if name.hasSuffix("[-]") { return (KeyEquivalent("-"), .command) }
        guard let shortcut, shortcut.isLetter || shortcut.isNumber else { return nil }
        let lower = Character(shortcut.lowercased())
        if lower == "h" { return nil }
        return (KeyEquivalent(lower), shortcut.isUppercase ? [.command, .shift] : .command)
    }
}

/// A command for the next new viewer window to run.
@MainActor
final class CommandQueue {
    static let shared = CommandQueue()
    var next: String?

    func take() -> String? {
        defer { next = nil }
        return next
    }
}

/// What a menu item does in Mancora's app.
enum AppMenuActions {
    /// ImageJ commands that open ImageJ's own windows (Java frames), which
    /// have no place next to Mancora's: these say so instead of opening one.
    static let javaWindows: Set<String> = [
        "Window/Level...", "Color Balance...", "Color Threshold...", "Channels Tool...",
        "Color Picker...", "Line Width...", "Control Panel...", "Monitor Memory...",
        "Startup Macros...", "Macro Tool", "JavaScript", "BeanShell", "Python", "Plugin", "Plugin Filter",
        "Plugin Frame", "Plugin Tool", "Table...", "Main Window [return]", "Put Behind [tab]",
        "Synchronize Windows", "Orthogonal Views",
    ]

    static let links: [String: String] = [
        "ImageJ Website...": "https://imagej.net/ij/",
        "Dev. Resources...": "https://imagej.net/ij/developer/index.html",
        "Macro Functions...": "https://imagej.net/ij/developer/macro/functions.html",
        "Release Notes...": "https://imagej.net/ij/notes.html",
        "About ImageJ...": "https://imagej.net/ij/",
    ]

    @MainActor
    static func perform(_ name: String, viewer: ViewerModel?, bridge: AppBridge, openWindow: OpenWindowAction) {
        let open = { (urls: [URL]) in for url in urls { openWindow(id: "viewer", value: OpenRequest(url: url)) } }
        switch name {
        case "Open...":
            openFile(virtual: false, viewer: viewer, openWindow: openWindow)
        case "TIFF Virtual Stack...":
            openFile(virtual: true, viewer: viewer, openWindow: openWindow)
        case "Close":
            NSApp.keyWindow?.performClose(nil)
        case "Close All":
            for window in NSApp.windows where window.isVisible && window.title != "Recorder" { window.performClose(nil) }
        case "Save":
            viewer?.saveInPlace()
        case "Tiff...":
            viewer?.presentSavePanel()
        case "ZIP...":
            viewer?.presentSavePanel(as: .zip, extension: "zip")
        case "PNG...":
            viewer?.presentSavePanel(as: .png, extension: "png")
        case "Gif...":
            viewer?.presentSavePanel(as: .gif, extension: "gif")
        case "Revert":
            viewer?.revert()
        case "In [+]":
            viewer?.zoom(by: 2)
        case "Out [-]":
            viewer?.zoom(by: 0.5)
        case "Original Scale", "View 100%":
            viewer?.zoom = .scale(1)
        case "Scale to Fit":
            viewer?.zoom = .fit
        case "Show All", "Cascade", "Tile":
            NSApp.arrangeInFront(nil)
        case "Repeat Command":
            guard let viewer, let last = viewer.lastCommand else { return }
            Task { open(await viewer.runRecorded(last.name, options: last.options, bridge: bridge)) }
        case "Record...":
            openWindow(id: "recorder")
        // The editor: Plugins ▸ New ▸ Macro and File ▸ New ▸ Text Window are empty ones, and
        // Plugins ▸ Macros ▸ Edit… and File ▸ Import ▸ Text File… ask for a file.
        case "Macro":
            openWindow(id: "macro-editor", value: EditorRequest(serial: UUID()))
        case "Text Window", "Text Window...":
            openWindow(id: "macro-editor", value: EditorRequest(isText: true, serial: UUID()))
        case "Edit...", "Text File... ":
            if let url = MacroEditorModel.chooseFile() {
                openWindow(id: "macro-editor", value: EditorRequest(url: url))
            }
        case "Find Commands...", "Commands...":
            viewer?.showsCommandFinder = true
        case "Brightness/Contrast...", "Show Info...":
            viewer?.showsInspector = true
        case "Threshold...":
            viewer?.showsInspector = true
            viewer?.showsThreshold = true
        case "Update...":
            openWindow(id: "update-sites")
        case "ROI Manager...":
            openWindow(id: "roi-manager")
        case "Add to Manager":
            do throws(AppSession.ManagerError) {
                try AppSession.shared.addToManager(from: viewer)
                openWindow(id: "roi-manager")
            } catch {
                viewer?.errorMessage = error.text
            }
        default:
            if let link = links[name], let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else if javaWindows.contains(name) {
                let alert = NSAlert()
                alert.messageText = "\(MenuCommandButton.title(name)) isn't available in Mancora yet."
                alert.runModal()
            } else if let viewer {
                Task { open(await viewer.perform(name, bridge: bridge)) }
            } else {
                // No image window: a new one runs it (and shows what it makes).
                CommandQueue.shared.next = name
                openWindow(id: "viewer")
            }
        }
    }

    /// Plugins ▸ Macros ▸ Run…: natively when Mancora has what the macro uses.
    @MainActor
    static func runMacroFile(viewer: ViewerModel?, bridge: AppBridge, openWindow: OpenWindowAction) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ijm") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
            let code = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let target = viewer ?? ViewerModel()
        Task {
            for created in await target.runMacro(code, bridge: bridge) {
                openWindow(id: "viewer", value: OpenRequest(url: created))
            }
        }
    }

    @MainActor
    static func openFile(virtual: Bool, viewer: ViewerModel?, openWindow: OpenWindowAction) {
        let panelOwner = viewer ?? ViewerModel()
        guard let url = panelOwner.presentOpenPanel(virtual: virtual) else { return }
        let request = OpenRequest(url: url, virtual: virtual)
        AppRecorder.shared.recordOpen(url, virtual: virtual)
        if let viewer, !viewer.hasImage {
            viewer.open(request)
        } else {
            openWindow(id: "viewer", value: request)
        }
    }
}
