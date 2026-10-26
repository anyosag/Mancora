#if os(Windows)
import Foundation
import MancoraCore
import MancoraSupport
import MancoraUpdate
import WinSDK

/// Posted to the main window when the background check finds an update.
let updateAvailableMessage: UINT = 0x8001  // WM_APP + 1

/// Set by the background check before it posts `updateAvailableMessage`.
nonisolated(unsafe) var pendingUpdate: AvailableUpdate?

/// Where the viewer keeps its update settings: %LOCALAPPDATA%\Mancora.
enum UpdateSettings {
    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("Mancora")
    }

    private static var lastCheckFile: URL { directory.appendingPathComponent("last-update-check") }
    private static var disabledFile: URL { directory.appendingPathComponent("no-automatic-update-checks") }

    static var checksAutomatically: Bool { !FileManager.default.fileExists(atPath: disabledFile.path) }

    static func setChecksAutomatically(_ on: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if on {
            try? FileManager.default.removeItem(at: disabledFile)
        } else {
            try? Data().write(to: disabledFile)
        }
    }

    static var lastCheck: Date? {
        guard let text = try? String(contentsOf: lastCheckFile, encoding: .utf8), let seconds = Double(text) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    static func recordCheck() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(Date().timeIntervalSince1970).write(to: lastCheckFile, atomically: true, encoding: .utf8)
    }
}

/// Runs async work and waits for it on the calling (UI) thread.
final class Blocking<T: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: T?

    static func wait(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Blocking<T>()
        Task.detached {
            box.result = await work()
            box.done.signal()
        }
        box.done.wait()
        return box.result!
    }
}

func makeChecker() -> UpdateChecker? {
    SemanticVersion(MancoraVersion.number).map {
        UpdateChecker(currentVersion: $0, client: URLSessionHTTPClient(userAgent: "MancoraViewer/\(MancoraVersion.number)"))
    }
}

/// The once-a-day check at launch; it only speaks up when there's an update.
func checkForUpdatesInBackground(window: HWND?) {
    guard UpdateSettings.checksAutomatically, UpdateSchedule().isDue(lastCheck: UpdateSettings.lastCheck),
        let checker = makeChecker()
    else { return }
    let target = UInt(bitPattern: window)
    Task.detached {
        guard let update = try? await checker.availableUpdate() else { return }
        UpdateSettings.recordCheck()
        pendingUpdate = update
        _ = PostMessageW(HWND(bitPattern: target), updateAvailableMessage, 0, 0)
    }
}

/// Help ▸ Check for Updates…
func checkForUpdatesNow() {
    guard let checker = makeChecker() else { return }
    let outcome = Blocking<Result<AvailableUpdate?, UpdateError>>.wait {
        do {
            return .success(try await checker.availableUpdate())
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.invalidResponse("\(error)"))
        }
    }
    switch outcome {
    case .success(let update?):
        UpdateSettings.recordCheck()
        offer(update, checker: checker)
    case .success(nil):
        UpdateSettings.recordCheck()
        showMessage(
            "Mancora \(MancoraVersion.number) is up to date.", title: "Mancora Update", owner: viewer.window,
            isError: false)
    case .failure(let error):
        showMessage("Couldn't check for updates:\n\(error)", title: "Mancora Update", owner: viewer.window, isError: true)
    }
}

/// Asks whether to install `update`; if so downloads it (verified against
/// SHA256SUMS.txt), runs the installer silently and quits. The installer
/// closes the old viewer if needed and starts the new one (`/relaunch=1`).
func offer(_ update: AvailableUpdate, checker: UpdateChecker? = makeChecker()) {
    guard let checker else { return }
    var text = "Mancora \(update.version) is available (you have \(MancoraVersion.number))."
    if let notes = update.release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
        text += "\n\n" + String(notes.prefix(500)) + (notes.count > 500 ? "…" : "")
    }
    text += "\n\nInstall it now? Mancora will restart."
    guard MessageBoxW(viewer.window, text.wide, "Mancora Update".wide, messageBoxYesNo | messageBoxIconInformation)
        == dialogYes
    else { return }

    _ = SetCursor(LoadCursorW(nil, waitCursor))
    let downloaded = Blocking<Result<Data, UpdateError>>.wait {
        do {
            return .success(try await checker.download(update))
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.invalidResponse("\(error)"))
        }
    }
    let data: Data
    switch downloaded {
    case .success(let bytes): data = bytes
    case .failure(let error):
        showMessage("The update couldn't be downloaded:\n\(error)", title: "Mancora Update", owner: viewer.window, isError: true)
        return
    }
    let installer = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(update.installer.name)
    do {
        try data.write(to: installer)
    } catch {
        showMessage("The update couldn't be saved:\n\(error)", title: "Mancora Update", owner: viewer.window, isError: true)
        return
    }
    let arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /relaunch=1"
    let result = ShellExecuteW(nil, "open".wide, installer.path.wide, arguments.wide, nil, SW_SHOWNORMAL)
    // ShellExecute reports success with a value above 32.
    guard Int(bitPattern: result) > 32 else {
        showMessage("The installer couldn't be started.", title: "Mancora Update", owner: viewer.window, isError: true)
        return
    }
    _ = DestroyWindow(viewer.window)
}
#endif
