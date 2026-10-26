import AppKit
import Foundation
import MancoraCore
import MancoraSupport
import MancoraUpdate
import Observation

/// Checks GitHub for a newer Mancora, and installs it in place: the DMG is
/// downloaded and verified against the release's SHA256SUMS.txt, mounted,
/// its app's signature checked, and swapped in for this bundle; then
/// Mancora relaunches.
@Observable
final class AppUpdater {
    nonisolated static let bundleIdentifier = "io.github.anyosag.mancora"
    private static let automaticKey = "AutomaticallyChecksForUpdates"
    private static let lastCheckKey = "LastUpdateCheck"

    private(set) var isBusy = false
    private(set) var automaticallyChecks: Bool

    @ObservationIgnored private var checkedThisLaunch = false

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    func setAutomaticallyChecks(_ on: Bool) {
        automaticallyChecks = on
        UserDefaults.standard.set(on, forKey: Self.automaticKey)
    }

    /// The once-a-day background check; quiet unless there's an update.
    func checkAtLaunch() {
        guard !checkedThisLaunch, automaticallyChecks else { return }
        checkedThisLaunch = true
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard UpdateSchedule().isDue(lastCheck: last) else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy, let current = SemanticVersion(MancoraVersion.number) else { return }
        isBusy = true
        defer { isBusy = false }
        let checker = UpdateChecker(currentVersion: current)
        do {
            let update = try await checker.availableUpdate()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let update {
                await offer(update, checker: checker)
            } else if userInitiated {
                Self.inform("Mancora \(current) is up to date.", "It's the newest version available.")
            }
        } catch {
            if userInitiated { Self.inform("Couldn't check for updates", "\(error)") }
        }
    }

    private func offer(_ update: AvailableUpdate, checker: UpdateChecker) async {
        let app = Bundle.main.bundleURL
        let inPlace = Self.canReplace(app)
        let alert = NSAlert()
        alert.messageText = "Mancora \(update.version) is available"
        var text = "You have \(MancoraVersion.number)."
        if let notes = update.release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\n\n" + String(notes.prefix(600)) + (notes.count > 600 ? "…" : "")
        }
        if !inPlace { text += "\n\nMancora can't replace itself where it is, so the disk image will open instead." }
        alert.informativeText = text
        alert.addButton(withTitle: inPlace ? "Install and Relaunch" : "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(update, checker: checker, app: inPlace ? app : nil)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(update.release.pageURL)
        default:
            break
        }
    }

    private func install(_ update: AvailableUpdate, checker: UpdateChecker, app: URL?) async {
        do {
            let data = try await checker.download(update)
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent(update.installer.name)
            try data.write(to: dmg)
            guard let app else {
                NSWorkspace.shared.open(dmg)
                return
            }
            let version = try await Task.detached(priority: .userInitiated) {
                try Self.install(dmg: dmg, over: app)
            }.value
            try? FileManager.default.removeItem(at: dmg)
            relaunch(app, version: version)
        } catch {
            Self.inform("The update couldn't be installed", "\(error)")
        }
    }

    private func relaunch(_ app: URL, version: String) {
        let alert = NSAlert()
        alert.messageText = "Mancora \(version) is installed"
        alert.informativeText = "Relaunch now to start using it."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    private static func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Whether this is a real app bundle in a folder we may write to.
    nonisolated static func canReplace(_ app: URL) -> Bool {
        app.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    // MARK: Installing

    nonisolated enum InstallError: Error, CustomStringConvertible {
        case toolFailed(String, Int32, String)
        case noApp
        case wrongApp(String?)

        var description: String {
            switch self {
            case .toolFailed(let tool, let status, let output): "\(tool) failed (\(status)): \(output)"
            case .noApp: "The disk image doesn't contain Mancora.app."
            case .wrongApp(let id): "The disk image's app isn't Mancora (\(id ?? "no bundle identifier"))."
            }
        }
    }

    /// Installs the Mancora.app in `dmg` over `app` and returns its version.
    ///
    /// The new app is copied next to the old one first and the two are then
    /// swapped by renaming, so a failure part-way leaves the old app intact.
    nonisolated static func install(dmg: URL, over app: URL) throws -> String {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("mancora-update-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let newApp = mount.appendingPathComponent("Mancora.app")
        guard fm.fileExists(atPath: newApp.path) else { throw InstallError.noApp }
        let bundle = Bundle(url: newApp)
        guard bundle?.bundleIdentifier == bundleIdentifier else { throw InstallError.wrongApp(bundle?.bundleIdentifier) }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        let folder = app.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".Mancora-\(UUID().uuidString).app")
        let retired = folder.appendingPathComponent(".Mancora-old-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        do {
            if fm.fileExists(atPath: app.path) { try fm.moveItem(at: app, to: retired) }
            do {
                try fm.moveItem(at: staged, to: app)
            } catch {
                if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: app) }
                throw error
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: retired)
        return version
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.toolFailed(
                (tool as NSString).lastPathComponent, process.terminationStatus,
                String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
