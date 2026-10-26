import AppKit
import MancoraBridge
import SwiftUI
import UniformTypeIdentifiers

@main
struct MancoraApp: App {
    @State private var updater = AppUpdater()
    @State private var bridge = AppBridge()

    init() {
        let args = CommandLine.arguments
        // `Mancora --smoke-test image.tif` checks that the packaged app
        // launches and can decode, render and save an image, then exits.
        if let i = args.firstIndex(of: "--smoke-test"), i + 1 < args.count {
            exit(ViewerModel.smokeTest(path: args[i + 1]) ? 0 : 1)
        }
        // `Mancora --install-test update.dmg target/Mancora.app` installs the
        // app in the disk image over `target` the way an update does.
        if let i = args.firstIndex(of: "--install-test"), i + 2 < args.count {
            do {
                let version = try AppUpdater.install(
                    dmg: URL(fileURLWithPath: args[i + 1]), over: URL(fileURLWithPath: args[i + 2]))
                print("installed Mancora \(version)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
                exit(1)
            }
        }
        // Run from `swift run` there is no app bundle; make it a regular app
        // so it gets a Dock icon, a menu bar and keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mancora", id: "viewer", for: OpenRequest.self) { $request in
            ViewerWindow(request: $request, bridge: bridge)
                .task { updater.checkAtLaunch() }
        }
        .commands {
            ViewerCommands()
            PluginCommands(bridge: bridge)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.isBusy)
            }
        }
        Settings {
            SettingsView(updater: updater)
        }
    }
}

/// File and View menu items for the key window's viewer.
struct ViewerCommands: Commands {
    @FocusedValue(\.viewer) private var viewer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") { open(virtual: false) }
                .keyboardShortcut("o")
            Button("Open as Virtual Stack…") { open(virtual: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save As TIFF…") { viewer?.presentSavePanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!(viewer?.hasImage ?? false))
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { zoom(by: 2) }
                .keyboardShortcut("+")
                .disabled(!(viewer?.hasImage ?? false))
            Button("Zoom Out") { zoom(by: 0.5) }
                .keyboardShortcut("-")
                .disabled(!(viewer?.hasImage ?? false))
            Button("Actual Size") { viewer?.zoom = .scale(1) }
                .keyboardShortcut("0")
                .disabled(!(viewer?.hasImage ?? false))
            Button("Zoom to Fit") { viewer?.zoom = .fit }
                .keyboardShortcut("9")
                .disabled(!(viewer?.hasImage ?? false))
            Divider()
        }
    }

    /// Opens into the key window if it's empty, otherwise into a new one.
    private func open(virtual: Bool) {
        let panelOwner = viewer ?? ViewerModel()
        guard let url = panelOwner.presentOpenPanel(virtual: virtual) else { return }
        let request = OpenRequest(url: url, virtual: virtual)
        if let viewer, !viewer.hasImage {
            viewer.open(request)
        } else {
            openWindow(id: "viewer", value: request)
        }
    }

    private func zoom(by factor: Double) {
        guard let viewer else { return }
        let current: Double
        switch viewer.zoom {
        case .scale(let s): current = s
        case .fit: current = 1
        }
        viewer.zoom = .scale(min(max(current * factor, 1.0 / 32), 64))
    }
}

/// The Plugins menu: Find Command, macros, ImageJ through the bridge, and
/// the commands of installed plugin jars.
struct PluginCommands: Commands {
    let bridge: AppBridge
    @FocusedValue(\.viewer) private var viewer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Plugins") {
            Button("Find Command…") { viewer?.showsCommandFinder = true }
                .keyboardShortcut("l")
            Button("Run Macro File…") { runMacroFile() }
            Divider()
            switch bridge.state {
            case .idle, .failed:
                Button("Start ImageJ") { Task { await bridge.start() } }
            case .starting:
                Text("Starting ImageJ…")
            case .ready(let imagej, let java):
                Text("ImageJ \(imagej) · Java \(java)")
            }
            if !bridge.pluginCommands.isEmpty {
                Divider()
                ForEach(bridge.pluginCommands, id: \.name) { command in
                    Button(command.name) { run(command.name) }
                }
            }
        }
    }

    private func run(_ name: String) {
        guard let viewer else { return }
        Task {
            for url in await viewer.runCommand(name, bridge: bridge) {
                openWindow(id: "viewer", value: OpenRequest(url: url))
            }
        }
    }

    private func runMacroFile() {
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
}

struct SettingsView: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Form {
            Toggle(
                "Check for updates automatically",
                isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) })
            )
            Text("Mancora looks for a newer release on GitHub at most once a day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
