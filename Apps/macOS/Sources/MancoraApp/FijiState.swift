import Foundation
import MancoraFiji
import Observation

// What the app knows about Fiji: whether it is installed, being downloaded or
// updated, its version and settings. `FijiManager` is an actor, so views read
// this instead: one observable copy of its status, kept up to date from the
// manager's own stream of changes. Nothing here uses AppKit or SwiftUI.

/// Words for Fiji's states.
nonisolated enum FijiText {
    /// `412 of 703 MB`, as the Finder counts megabytes; just `412 MB` while the size is unknown.
    static func megabytes(done: Int64, of total: Int64?) -> String {
        let finished = Int((Double(done) / 1_000_000).rounded())
        guard let total, total > 0 else { return "\(finished) MB" }
        return "\(finished) of \(Int((Double(total) / 1_000_000).rounded())) MB"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func phase(_ phase: FijiProgress.Phase) -> String {
        switch phase {
        case .downloading: "Downloading Fiji"
        case .unpacking: "Unpacking Fiji"
        case .checking: "Checking for updates"
        case .updating: "Updating Fiji"
        case .applying: "Applying updates"
        }
    }

    /// `Downloading Fiji… 42%`.
    static func progress(_ progress: FijiProgress) -> String {
        var text = phase(progress.phase) + "…"
        if progress.phase == .downloading, let fraction = progress.fractionCompleted { text += " " + percent(fraction) }
        return text
    }

    /// Fiji's release the way people say it: `2.18` for `2.18.0`, `2.18.1` for `2.18.1-SNAPSHOT`.
    static func release(_ version: FijiVersion) -> String? {
        guard var text = version.fiji, !text.isEmpty else { return nil }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        if text.hasSuffix(".0"), text.split(separator: ".").count > 2 { text = String(text.dropLast(2)) }
        return text
    }

    /// `Fiji 2.18`.
    static func name(_ version: FijiVersion) -> String {
        release(version).map { "Fiji \($0)" } ?? "Fiji"
    }

    /// A failure in a sentence.
    static func describe(_ error: any Error) -> String {
        if error is FijiError { return "\(error)" }
        return error.localizedDescription
    }
}

/// Fiji, as the windows show it. Start it once at launch (`begin()`).
@Observable
final class FijiState {
    static let shared = FijiState()

    /// What came of Settings' Check for Updates Now.
    enum CheckResult: Equatable {
        case upToDate
        /// Updates are there and wait for a decision (automatic updates are off).
        case available(Int)
        case updated(Int)
        /// Ready, and installed the next time Fiji starts.
        case staged(Int)
        case failed(String)
    }

    private(set) var status: FijiStatus
    private(set) var settings = FijiSettings()
    /// An update waits to be installed when Fiji next starts.
    private(set) var hasStagedUpdate = false
    private(set) var stagedChanges: [String] = []
    private(set) var isChecking = false
    private(set) var checkResult: CheckResult?
    /// Where the installation is (or will be).
    private(set) var location = FijiManager.shared.root
    /// A made-up state is shown (the screenshot run's), which the manager's changes do not touch.
    private(set) var isPreview = false
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {
        let installation = FijiManager.shared.installation
        status = installation.isComplete ? .installed(installation.version) : .notInstalled
    }

    var isInstalled: Bool { status.isInstalled }

    var version: FijiVersion? { status.version }

    /// Follows the manager: its status as it changes, and its settings, from now on.
    func begin() {
        guard watcher == nil else { return }
        watcher = Task {
            await FijiManager.shared.refreshStatus()
            await reload()
            for await update in await FijiManager.shared.statusUpdates() where !isPreview {
                status = update
                await reload()
            }
        }
    }

    /// Reads the settings and the staged update again.
    func reload() async {
        guard !isPreview else { return }
        let manager = FijiManager.shared
        settings = await manager.settings
        hasStagedUpdate = await manager.hasStagedUpdate
        stagedChanges = await manager.stagedChanges
    }

    /// Reads the folder on disk again, as after Fiji was moved away or installed by another Mancora.
    func refresh() async {
        guard !isPreview else { return }
        await FijiManager.shared.refreshStatus()
        status = FijiManager.shared.isInstalled ? .installed(FijiManager.shared.installation.version) : .notInstalled
        await reload()
    }

    /// Shows a made-up Fiji (the screenshot run's): the pictures then do not depend on the computer.
    func showPreview(status: FijiStatus, settings: FijiSettings, staged: [String] = [], location: URL) {
        isPreview = true
        self.status = status
        self.settings = settings
        hasStagedUpdate = !staged.isEmpty
        stagedChanges = staged
        self.location = location
        checkResult = nil
    }

    func endPreview() async {
        isPreview = false
        location = FijiManager.shared.root
        await refresh()
    }

    func setAutoUpdate(_ on: Bool) {
        settings.autoUpdate = on
        Task {
            try? await FijiManager.shared.setAutoUpdate(on)
            await reload()
        }
    }

    /// Settings' Check for Updates Now: looks, and installs what it finds unless automatic updates are off.
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        checkResult = nil
        defer { isChecking = false }
        do {
            let check = try await FijiManager.shared.checkForUpdates()
            if !check.warnings.isEmpty {
                checkResult = .failed(FijiError.sitesUnreadable(check.warnings).description)
            } else if !check.conflicts.isEmpty {
                checkResult = .failed(FijiError.conflicts(check.conflicts).description)
            } else if check.isUpToDate {
                checkResult = .upToDate
            } else if settings.autoUpdate {
                checkResult = try await apply()
            } else {
                checkResult = .available(check.changes.count)
            }
        } catch {
            checkResult = .failed(FijiText.describe(error))
        }
        await reload()
    }

    /// Installs what the last check found.
    func installUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            checkResult = try await apply()
        } catch {
            checkResult = .failed(FijiText.describe(error))
        }
        await reload()
    }

    private func apply() async throws -> CheckResult {
        switch try await FijiManager.shared.applyUpdates() {
        case .upToDate: .upToDate
        case .applied(let changes): .updated(changes.count)
        case .staged(let changes): .staged(changes.count)
        }
    }
}
