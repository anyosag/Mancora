import AppKit
import MancoraBridge
import SwiftUI
import UniformTypeIdentifiers

@main
struct MancoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var updater = AppUpdater()
    @State private var bridge = AppBridge()
    @State private var updateSites = AppUpdateSites()

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
        // `Mancora --screenshots dir` opens each window in each state, saves a
        // PNG of it in light and dark mode, and exits (see Screenshots.swift).
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            Screenshots.configure(path: args[i + 1])
        }
        // Run from `swift run` there is no app bundle; make it a regular app
        // so it gets a Dock icon, a menu bar and keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mancora", id: "viewer", for: OpenRequest.self) { $request in
            ViewerWindow(request: $request, bridge: bridge)
                .task { if !Screenshots.isActive { updater.checkAtLaunch() } }
                .screenshotDriver(bridge: bridge)
        }
        .commands {
            ImageJMenuCommands(bridge: bridge)
            PluginCommands(bridge: bridge)
            MacroEditorCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.isBusy)
            }
        }
        Window("Recorder", id: "recorder") {
            RecorderView(recorder: AppRecorder.shared)
        }
        .defaultSize(width: 520, height: 280)
        Window("Results", id: "results") {
            ResultsWindow(session: AppSession.shared)
        }
        .defaultSize(width: 640, height: 320)
        Window("Log", id: "log") {
            LogWindow(session: AppSession.shared)
        }
        .defaultSize(width: 480, height: 300)
        WindowGroup("Plot", id: "plot", for: PlotRequest.self) { $request in
            if let request { PlotWindow(request: request) }
        }
        .defaultSize(width: 520, height: 460)
        Window("ROI Manager", id: "roi-manager") {
            RoiManagerView(session: AppSession.shared)
        }
        .defaultSize(width: 340, height: 360)
        WindowGroup("Macro Editor", id: "macro-editor", for: EditorRequest.self) { $request in
            MacroEditorWindow(request: $request, bridge: bridge)
        }
        .defaultSize(width: 640, height: 480)
        Window("Update Sites", id: "update-sites") {
            UpdateSitesView(model: updateSites, bridge: bridge)
        }
        .defaultSize(width: 720, height: 520)
        Settings {
            SettingsView(updater: updater)
        }
    }
}

/// The Plugins menu: ImageJ's (Macros, Shortcuts, Utilities, New, …),
/// Fiji's update sites, the bridge's state, and the commands of installed
/// plugin jars.
struct PluginCommands: Commands {
    let bridge: AppBridge
    @FocusedValue(\.viewer) private var viewer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Plugins") {
            MenuEntries(entries: ImageJMenuCommands.menu("Plugins").entries, perform: perform)
            Divider()
            Button("Manage Update Sites…") { openWindow(id: "update-sites") }
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
                    Button(command.name) { perform(command.name) }
                }
            }
        }
    }

    private func perform(_ name: String) {
        if name == "Run..." {
            AppMenuActions.runMacroFile(viewer: viewer, bridge: bridge, openWindow: openWindow)
        } else {
            AppMenuActions.perform(name, viewer: viewer, bridge: bridge, openWindow: openWindow)
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
