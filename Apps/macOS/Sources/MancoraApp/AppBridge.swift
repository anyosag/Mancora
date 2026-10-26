import AppKit
import Foundation
import MancoraBridge
import MancoraCore
import MancoraFiji
import MancoraUpdate
import Observation

/// The app's Java bridge: ImageJ and its plugins in a helper process, set up
/// on first use. The engine is Fiji, which Mancora downloads the first time
/// a command needs it (see `FijiSetup`) and keeps up to date. An ImageJ that
/// an earlier Mancora installed keeps working until Fiji is there, and Fiji
/// is used as soon as it is.
///
/// Two helpers can run. The engine runs Mancora's commands with no windows
/// of its own. Fiji's own menu entries (TrackMate, Labkit, the Script
/// Editor) show dialogs and windows for someone to use, so they run in a
/// second helper with a Dock icon and a name of its own: "Fiji".
@Observable
final class AppBridge {
    enum State: Equatable {
        case idle
        case starting
        case ready(imagej: String, java: String)
        case failed(String)
    }

    /// Fiji was asked for and the person said no.
    nonisolated struct Declined: Error, CustomStringConvertible {
        var description: String { "Fiji wasn’t downloaded." }
    }

    /// No engine could be started, and why.
    nonisolated struct Unavailable: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private(set) var state = State.idle
    private(set) var commands: [BridgeCommand] = []
    /// The last start asked for Fiji and was turned down: the command that asked has nothing to run in.
    private(set) var wasDeclined = false
    /// The engine runs in Fiji (not in a plain ImageJ).
    private(set) var usesFiji = false
    /// Fiji's own windows have a helper running, which may hold images for the app to fetch.
    private(set) var hasFijiWindows = false
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var windowsBridge: Bridge?
    /// A start that is under way, and whether it may ask for Fiji.
    @ObservationIgnored private var starting: (task: Task<Void, Never>, prompting: Bool)?
    @ObservationIgnored private var declinedAt: Date?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Commands that come from plugin jars rather than ImageJ itself.
    var pluginCommands: [BridgeCommand] { commands.filter(\.isPlugin) }

    /// What the commands run in, for the menus and the status lines.
    var engineName: String { FijiState.shared.isInstalled ? "Fiji" : "ImageJ" }

    /// Whether there is an engine to start: Fiji, or an ImageJ an earlier Mancora installed.
    static var hasEngine: Bool { FijiManager.shared.isInstalled || BridgeHome.standard().hasImageJ }

    /// The same for views: Fiji as `FijiState` knows it, which they follow.
    var engineIsInstalled: Bool { FijiState.shared.isInstalled || BridgeHome.standard().hasImageJ }

    /// The helper and command table: inside Mancora.app, or in the source
    /// tree when run with `swift run`.
    static let resources: URL? = {
        if let bundled = Bundle.main.url(forResource: "Bridge", withExtension: nil) { return bundled }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Bridge")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("MancoraBridgeHelper.java").path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    // MARK: Starting

    /// Starts the engine: Fiji if it's installed, else an ImageJ that is. With neither, and
    /// `prompting`, asks for Fiji with a sheet, downloads it, and starts it; the commands waiting
    /// for the bridge go on once it's there (or find `wasDeclined`). Commands that start the
    /// bridge for their own sake (Find Command listing plugins) pass `prompting: false`.
    func start(prompting: Bool = true) async {
        while !isReady {
            if let running = starting {
                await running.task.value
                // That start did not ask for Fiji and this one may: go again.
                if running.prompting || !prompting { return }
                continue
            }
            let task = Task { await self.performStart(prompting: prompting) }
            starting = (task, prompting)
            await task.value
            return
        }
    }

    private func performStart(prompting: Bool) async {
        defer { starting = nil }
        wasDeclined = false
        if isReady { return }
        if !Self.hasEngine {
            guard prompting, !Screenshots.isActive else { return }
            // One answer covers a command's whole run (its dialog, then the command itself): no second sheet within moments.
            if let declinedAt, Date().timeIntervalSince(declinedAt) < 2 {
                wasDeclined = true
                return
            }
            guard await FijiSetup.shared.request(reason: "This command needs Fiji.") == .installed else {
                declinedAt = Date()
                wasDeclined = true
                return
            }
        }
        state = .starting
        do {
            guard let resources = Self.resources else { throw BridgeError.imageJMissing(path: "Resources/Bridge") }
            let configuration = try Bridge.Configuration.standard(resources: resources)
            if configuration.fiji == nil {
                try await configuration.home.installImageJ(
                    client: URLSessionHTTPClient(userAgent: "Mancora/\(MancoraVersion.number)"))
            }
            let started = Bridge(configuration: configuration)
            let hello = try await started.start()
            commands = try await started.commands()
            bridge = started
            usesFiji = configuration.fiji != nil
            state = .ready(imagej: hello.imagej, java: hello.java)
            if usesFiji { Task { await self.refreshMenus(from: started) } }
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Fiji's menus, as this helper has them (a staged update has just gone in): for the menu bar, and the disk.
    private func refreshMenus(from bridge: Bridge) async {
        guard let items = try? await bridge.menus() else { return }
        FijiMenus.shared.update(items.map { FijiMenuEntry($0) })
    }

    /// Stops the helpers and starts the engine again: Fiji has been installed or updated, or its plugins changed.
    func restart() async {
        await stop()
        await start(prompting: false)
    }

    func stop() async {
        let engine = bridge, windows = windowsBridge
        bridge = nil
        windowsBridge = nil
        hasFijiWindows = false
        state = .idle
        await engine?.stop()
        await windows?.stop()
    }

    // MARK: Fiji

    /// Settings' and the welcome window's Download Fiji…: the sheet, then Fiji instead of whatever ran before.
    func downloadFiji() async {
        guard await FijiSetup.shared.request(reason: nil) == .installed else { return }
        await restart()
    }

    /// Settings' Reinstall Fiji…: the installation goes to the Trash and Fiji is downloaded again.
    /// Returns what went wrong, if anything did.
    func reinstallFiji() async -> String? {
        await stop()
        do {
            try FileManager.default.trashItem(at: FijiManager.shared.root, resultingItemURL: nil)
        } catch {
            return "Fiji couldn’t be moved to the Trash: \(error.localizedDescription)"
        }
        FijiMenus.shared.forget()
        await FijiState.shared.refresh()
        await downloadFiji()
        return nil
    }

    // MARK: Commands

    /// The engine, started (and Fiji asked for) if need be.
    private func engine() async throws -> Bridge {
        if !isReady { await start() }
        if let bridge { return bridge }
        if wasDeclined { throw Declined() }
        if case .failed(let message) = state { throw Unavailable(message: message) }
        throw BridgeError.helperExited(status: -1)
    }

    /// Runs an ImageJ command (or macro) on `image`; the bridge restarts the
    /// helper by itself if it has died.
    /// Runs a command with several images open, the last one active.
    func run(_ command: String, options: String = "", images: [Hyperstack]) async throws -> BridgeRunResult {
        try await engine().run(command, options: options, images: images)
    }

    func run(_ command: String, options: String = "", on image: Hyperstack?) async throws -> BridgeRunResult {
        try await engine().run(command, options: options, images: image.map { [$0] } ?? [])
    }

    func runMacro(_ code: String, on image: Hyperstack?) async throws -> BridgeRunResult {
        try await runMacro(code, images: image.map { [$0] } ?? [])
    }

    /// Runs a macro on `images`, the last one current.
    func runMacro(_ code: String, images: [Hyperstack]) async throws -> BridgeRunResult {
        try await engine().runMacro(code, images: images)
    }

    /// The dialogs `command` would show for `image`, to ask for its options natively.
    func describeDialog(_ command: String, images: [Hyperstack]) async throws -> BridgeDialogs {
        try await engine().describeDialog(command, images: images)
    }

    /// Opens a file Mancora can't read in ImageJ (or Bio-Formats, if installed).
    func open(_ path: String) async throws -> BridgeRunResult {
        try await engine().open(path)
    }

    // MARK: Fiji's own windows

    /// The helper Fiji's dialogs and windows run in, made on first use. Fiji is asked for if it
    /// isn't installed (an ImageJ from before Fiji cannot run these entries).
    private func windows() async throws -> Bridge {
        if !FijiManager.shared.isInstalled {
            guard await FijiSetup.shared.request(reason: "This menu item is part of Fiji.") == .installed else { throw Declined() }
            // The engine that was running, if any, was a plain ImageJ.
            if !usesFiji { await stop() }
        }
        if let windowsBridge { return windowsBridge }
        guard let resources = Self.resources else { throw BridgeError.imageJMissing(path: "Resources/Bridge") }
        var configuration = try Bridge.Configuration.standard(resources: resources)
        guard configuration.fiji != nil else { throw Unavailable(message: "Fiji couldn’t be started.") }
        configuration.interactive = true
        configuration.dockName = "Fiji"
        let created = Bridge(configuration: configuration)
        windowsBridge = created
        hasFijiWindows = true
        Task { await self.refreshMenus(from: created) }
        return created
    }

    /// A SciJava command, by identifier or menu path, in Fiji's own dialog or window.
    func runFijiCommand(_ command: String, images: [Hyperstack]) async throws -> BridgeRunResult {
        try await windows().runCommand(command, images: images, interactive: true)
    }

    /// A script in its language, with Fiji asking for its parameters.
    func runFijiScript(_ code: String, language: String, images: [Hyperstack]) async throws -> BridgeRunResult {
        try await windows().runScript(code, language: language, images: images, interactive: true)
    }

    /// The images open in Fiji's windows, as the plugins there have left them.
    func fijiImages() async throws -> BridgeRunResult {
        guard let windowsBridge else { throw Unavailable(message: "Fiji’s windows aren’t open.") }
        return try await windowsBridge.openImages()
    }
}

enum BridgeFileName {
    /// A file name that keeps `title` (ImageJ titles images after their file).
    static func safe(_ title: String) -> String {
        let cleaned = String(title.map { "/:\\".contains($0) ? "_" : $0 })
        let name = cleaned.isEmpty ? "Untitled" : cleaned
        return name.lowercased().hasSuffix(".tif") || name.lowercased().hasSuffix(".tiff") ? name : name + ".tif"
    }
}
