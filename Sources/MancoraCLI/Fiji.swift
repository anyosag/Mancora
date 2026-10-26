import Foundation
import MancoraCore
import MancoraFiji

let fijiUsage = """
    usage: mancora fiji status                 where Fiji is, its version, and its updates
           mancora fiji install                download the latest Fiji (Java included) for the Java bridge
           mancora fiji update [--check]       apply what Fiji's update sites changed (--check: only list it)
           mancora fiji auto-update on|off     check Fiji's update sites once a day and apply their updates
    Fiji lives in MANCORA_FIJI_HOME, or by default \(FijiManager.defaultRoot().path).
    Once installed, `mancora bridge` runs ImageJ inside it (ImageJ2, SciJava commands and scripts).
    """

func fijiCommand(_ args: [String]) async {
    let fiji = FijiManager.shared
    do {
        switch (args.first, args.count) {
        case ("status", 1):
            let settings = await fiji.settings
            if let version = await fiji.status.version {
                print("\(version) in \(fiji.root.path)")
            } else {
                print("Fiji isn't installed (it would go in \(fiji.root.path)); run `mancora fiji install`.")
            }
            print("automatic updates: \(settings.autoUpdate ? "on" : "off")")
            print("last checked: \(settings.lastCheck.map(describeDate) ?? "never")")
            if let updated = settings.lastUpdate { print("last updated: \(describeDate(updated))") }
            if let error = settings.lastError { print("last automatic update failed: \(error)") }
            let staged = await fiji.stagedChanges
            if !staged.isEmpty {
                print("staged for the next start (\(staged.count) change(s)):")
                for change in staged { print("  \(change)") }
            }
        case ("install", 1):
            if fiji.isInstalled {
                print("\(await fiji.status.version.map { "\($0)" } ?? "Fiji") is installed in \(fiji.root.path)")
                return
            }
            guard let name = fiji.distribution.archiveName else {
                fail("mancora: Fiji publishes no download for this platform (\(fiji.distribution.platform))")
            }
            print("Downloading \(fiji.distribution.archiveURL?.absoluteString ?? name)")
            let meter = ProgressMeter()
            try await fiji.install { progress in meter.show(progress) }
            meter.finish()
            print("Installed \(await fiji.status.version.map { "\($0)" } ?? "Fiji") in \(fiji.root.path)")
        case ("update", 1), ("update", 2):
            let checkOnly = args.count == 2
            guard !checkOnly || args[1] == "--check" else { fail(fijiUsage) }
            let check = try await fiji.checkForUpdates()
            for warning in check.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
            for conflict in check.conflicts { FileHandle.standardError.write(Data("conflict: \(conflict)\n".utf8)) }
            if check.isUpToDate {
                print("Fiji is up to date.")
                return
            }
            for change in check.changes { print(change) }
            if checkOnly { return }
            switch try await fiji.applyUpdates(progress: { print($0.detail ?? $0.phase.rawValue) }) {
            case .upToDate: print("Fiji is up to date.")
            case .applied(let changes): print("Done: \(changes.count) file(s) changed in \(fiji.root.path)")
            case .staged(let changes):
                print("\(changes.count) change(s) staged: a Java helper is running; they go in before the next one starts.")
            }
        case ("auto-update", 2) where ["on", "off"].contains(args[1]):
            try await fiji.setAutoUpdate(args[1] == "on")
            print("Automatic Fiji updates are \(args[1]).")
        default:
            fail(fijiUsage)
        }
    } catch {
        fail("mancora: \(error)")
    }
}

func describeDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

/// A one-line download meter on standard error.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var lastPhase: FijiProgress.Phase?

    func show(_ progress: FijiProgress) {
        lock.lock()
        defer { lock.unlock() }
        if progress.phase != lastPhase, lastPhase != nil { FileHandle.standardError.write(Data("\n".utf8)) }
        lastPhase = progress.phase
        if let fraction = progress.fractionCompleted, let total = progress.totalBytes {
            let percent = Int(fraction * 100)
            guard percent != lastPercent else { return }
            lastPercent = percent
            let line = "\r\(progress.phase.rawValue) \(percent)% of \(total / 1_000_000) MB"
            FileHandle.standardError.write(Data(line.utf8))
        } else if let detail = progress.detail {
            FileHandle.standardError.write(Data(detail.utf8))
        }
    }

    func finish() {
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
