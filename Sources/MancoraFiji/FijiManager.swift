#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public import Foundation
public import MancoraPlugins
public import MancoraUpdate
import MancoraSupport

/// How far an install or update has come.
public struct FijiProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Comparable {
        case downloading, unpacking, checking, updating, applying

        public static func < (a: Phase, b: Phase) -> Bool {
            let order: [Phase] = [.downloading, .unpacking, .checking, .updating, .applying]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    public var phase: Phase
    /// Bytes downloaded so far, while downloading.
    public var completedBytes: Int64
    /// The download's size, once the server has said.
    public var totalBytes: Int64?
    /// What's happening, e.g. "Downloading jars/imagej-2.18.0.jar".
    public var detail: String?

    public init(phase: Phase, completedBytes: Int64 = 0, totalBytes: Int64? = nil, detail: String? = nil) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.detail = detail
    }

    /// 0...1, when the total is known.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public enum FijiStatus: Sendable, Equatable {
    case notInstalled
    case installing(FijiProgress)
    case installed(FijiVersion)
    /// Checking the update sites or applying their updates; Fiji stays usable meanwhile.
    case updating(FijiVersion, FijiProgress)

    public var version: FijiVersion? {
        switch self {
        case .installed(let version), .updating(let version, _): version
        case .notInstalled, .installing: nil
        }
    }

    public var isInstalled: Bool { version != nil }
}

/// What Fiji's update sites would change.
public struct FijiUpdateCheck: Sendable {
    public let date: Date
    /// Files to install, update or remove.
    public let changes: [PluginManager.Change]
    /// Sites that couldn't be read; updates aren't applied while any can't.
    public let warnings: [String]
    /// What needs a decision, and stops an update.
    public let conflicts: [String]

    public var isUpToDate: Bool { changes.isEmpty }
}

public enum FijiUpdateOutcome: Sendable, Equatable {
    case upToDate
    /// Applied now (no helper was running); the changes, as `install jars/x.jar (Fiji-Latest)`.
    case applied([String])
    /// Ready, and applied before the next helper starts (one was running).
    case staged([String])
}

/// What's kept between runs, beside the installation (`Fiji.json`).
public struct FijiSettings: Codable, Sendable, Equatable {
    /// Check the update sites once a day and apply their updates.
    public var autoUpdate = true
    public var lastCheck: Date?
    public var lastUpdate: Date?
    /// Why the last automatic update failed, until one succeeds.
    public var lastError: String?
    /// The archive Fiji was installed from, and its SHA-256.
    public var installedFrom: String?
    public var installedAt: Date?

    public init() {}
}

/// A helper's hold on the installation: while any is held, updates are
/// staged rather than applied. Release it when the helper exits.
public final class FijiLease: Sendable {
    public let installation: FijiInstallation
    private let lock: FileLock

    init(installation: FijiInstallation, lock: FileLock) {
        self.installation = installation
        self.lock = lock
    }

    public func release() { lock.release() }
}

/// Installs Fiji on first use and keeps it up to date.
///
/// Beside the installation (`<root>`, by default ``defaultRoot(environment:)``):
///
///     <root>.json           settings (``FijiSettings``)
///     <root>.lock           held shared by every running helper, exclusively to change <root>
///     <root>.updating.lock  held while installing or preparing an update
///     <root>.next/          an update prepared while a helper ran, swapped in before the next starts
///
/// Nothing ever changes `<root>` in place. An install unpacks into a
/// staging folder and renames it into place; an update builds a copy of
/// `<root>` (hard links, so it costs no space but the new files), applies
/// the update sites' changes to the copy with ``PluginManager`` (each
/// download checked against the site's checksum), and swaps the copy in by
/// renaming. If Mancora stops between the two renames, the next start finds
/// `<root>` missing and finishes the swap (or undoes it).
public actor FijiManager {
    public nonisolated let root: URL
    public nonisolated let distribution: FijiDistribution
    public nonisolated let schedule: UpdateSchedule
    private let client: any HTTPClient
    private let downloader: any FijiDownloading

    public private(set) var status: FijiStatus
    public private(set) var settings: FijiSettings
    /// The last check's result, in this process.
    public private(set) var lastCheckResult: FijiUpdateCheck?
    private var observers: [UUID: AsyncStream<FijiStatus>.Continuation] = [:]
    private var automaticUpdates: Task<Void, Never>?

    /// The installation everyone shares, at ``defaultRoot(environment:)``.
    public static let shared = FijiManager()

    public init(
        root: URL = FijiManager.defaultRoot(),
        distribution: FijiDistribution = FijiDistribution(),
        schedule: UpdateSchedule = UpdateSchedule(),
        client: (any HTTPClient)? = nil,
        downloader: (any FijiDownloading)? = nil
    ) {
        let root = root.standardizedFileURL
        self.root = root
        self.distribution = distribution
        self.schedule = schedule
        self.client = client ?? URLSessionHTTPClient(userAgent: "Mancora")
        self.downloader = downloader ?? URLSessionFijiDownloader(userAgent: "Mancora")
        let files = Files(root: root)
        // Finish a swap an earlier run was in the middle of.
        if let lock = try? FileLock.acquire(files.lock, .exclusive, wait: false) {
            files.recover()
            lock.release()
        }
        settings = files.readSettings()
        let installation = FijiInstallation(root: root)
        status = installation.isComplete ? .installed(installation.version) : .notInstalled
    }

    /// `~/Library/Application Support/Mancora/Fiji` on macOS,
    /// `$XDG_DATA_HOME/mancora/Fiji` (`~/.local/share/mancora/Fiji`) on Linux,
    /// `%LOCALAPPDATA%\Mancora\Fiji` on Windows, or `MANCORA_FIJI_HOME`.
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["MANCORA_FIJI_HOME"], !override.isEmpty { return URL(fileURLWithPath: override) }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSTemporaryDirectory()
        #if os(macOS)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Mancora/Fiji")
        #elseif os(Windows)
        return URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? home).appendingPathComponent("Mancora")
            .appendingPathComponent("Fiji")
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home + "/.local/share")
        return URL(fileURLWithPath: data).appendingPathComponent("mancora").appendingPathComponent("Fiji")
        #endif
    }

    public nonisolated var installation: FijiInstallation { FijiInstallation(root: root) }

    /// Whether a complete Fiji is installed (read from disk, so another process's install counts).
    public nonisolated var isInstalled: Bool { installation.isComplete }

    private nonisolated var files: Files { Files(root: root) }

    // MARK: Status

    /// The status now, then every change.
    public func statusUpdates() -> AsyncStream<FijiStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FijiStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(status)
        observers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func setStatus(_ new: FijiStatus) {
        guard new != status else { return }
        status = new
        for observer in observers.values { observer.yield(new) }
    }

    /// Reads the status from disk again, as another Mancora may have installed or updated Fiji.
    public func refreshStatus() {
        settings = files.readSettings()
        settle()
    }

    /// The status the folder on disk gives.
    private func settle() {
        let installation = installation
        setStatus(installation.isComplete ? .installed(installation.version) : .notInstalled)
    }

    /// Progress reported from a download's thread: dropped if it arrives after a later phase's.
    private func note(_ progress: FijiProgress) {
        switch status {
        case .installing(let current) where progress.phase > current.phase || (progress.phase == current.phase && progress.completedBytes >= current.completedBytes):
            setStatus(.installing(progress))
        case .updating(let version, let current) where progress.phase >= current.phase:
            setStatus(.updating(version, progress))
        default: break
        }
    }

    // MARK: Settings

    public var autoUpdate: Bool { settings.autoUpdate }

    /// Turns automatic updates on or off, for every Mancora on this computer.
    public func setAutoUpdate(_ on: Bool) throws {
        settings = files.readSettings()
        settings.autoUpdate = on
        try files.write(settings)
    }

    private func updateSettings(_ change: (inout FijiSettings) -> Void) {
        settings = files.readSettings()
        change(&settings)
        try? files.write(settings)
    }

    // MARK: Installing

    /// Downloads the latest Fiji for this platform, Java bundled (see
    /// ``FijiDistribution``), checks it against its published SHA-256,
    /// unpacks it into a staging folder and renames that into place.
    /// Does nothing if Fiji is installed. Cancel the task to stop it;
    /// nothing is left behind.
    public func install(progress: @escaping @Sendable (FijiProgress) -> Void = { _ in }) async throws {
        if installation.isComplete {
            settle()
            return
        }
        guard let name = distribution.archiveName, let archiveURL = distribution.archiveURL,
            let checksumURL = distribution.checksumURL
        else { throw FijiError.unsupportedPlatform(distribution.platform) }
        guard let updating = try FileLock.acquire(files.updating, .exclusive, wait: false) else { throw FijiError.busy }
        defer { updating.release() }
        let fm = FileManager.default
        try fm.createDirectory(at: files.parent, withIntermediateDirectories: true)
        files.removeLeftovers()
        defer { settle() }

        let start = FijiProgress(phase: .downloading)
        setStatus(.installing(start))
        progress(start)
        let checksumData = checksumURL.isFileURL ? try Data(contentsOf: checksumURL) : try await client.data(from: checksumURL)
        let checksumText = String(decoding: checksumData, as: UTF8.self)
        guard let expected = FijiDistribution.parseChecksum(checksumText) else {
            throw FijiError.badChecksumFile("\(checksumURL.absoluteString): \(checksumText.prefix(100))")
        }
        let archive = files.temporary("download").appendingPathExtension("zip")
        defer { try? fm.removeItem(at: archive) }
        let digest = try await downloader.download(archiveURL, to: archive) { done, total in
            let p = FijiProgress(phase: .downloading, completedBytes: done, totalBytes: total)
            progress(p)
            Task { await self.note(p) }
        }
        let actual = hexString(digest)
        guard actual == expected else { throw FijiError.checksumMismatch(file: name, expected: expected, actual: actual) }

        let unpacking = FijiProgress(phase: .unpacking, detail: "Unpacking \(name)")
        setStatus(.installing(unpacking))
        progress(unpacking)
        let staging = files.temporary("install")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await FijiArchive.extract(archive, into: staging)
        try Task.checkCancellation()
        let unpacked = try Files.unpackedRoot(in: staging)
        guard FijiInstallation(root: unpacked, platform: distribution.platform).isComplete else {
            throw FijiError.incomplete("\(name) holds no Fiji with ImageJ, ImageJ2's legacy layer and Java for \(distribution.platform)")
        }

        guard let live = try FileLock.acquire(files.lock, .exclusive, wait: true) else { throw FijiError.busy }
        defer { live.release() }
        if fm.fileExists(atPath: root.path) {
            // Something incomplete is in the way (a complete Fiji returned above).
            let old = files.temporary("old")
            try fm.moveItem(at: root, to: old)
            try? fm.removeItem(at: old)
        }
        try fm.moveItem(at: unpacked, to: root)
        updateSettings {
            $0.installedFrom = "\(archiveURL.absoluteString) (SHA-256 \(actual))"
            $0.installedAt = Date()
            $0.lastCheck = Date()  // as up to date as Fiji gets
            $0.lastError = nil
        }
    }

    // MARK: Updating

    /// Reads Fiji's update sites (those its `db.xml.gz` enables) and
    /// compares their files with the installation's, as Fiji's updater does.
    public func checkForUpdates() async throws -> FijiUpdateCheck {
        guard installation.isComplete else { throw FijiError.notInstalled(path: root.path) }
        let version = installation.version
        setStatus(.updating(version, FijiProgress(phase: .checking, detail: "Reading Fiji's update sites")))
        defer { settle() }
        let check = try await Self.check(root: root, client: client)
        lastCheckResult = check
        updateSettings { $0.lastCheck = check.date }
        return check
    }

    static func check(root: URL, client: any HTTPClient) async throws -> FijiUpdateCheck {
        let manager = try PluginManager(root: root)
        try await manager.refresh(client: client)
        let (changes, conflicts) = manager.plan()
        return FijiUpdateCheck(
            date: Date(), changes: changes, warnings: manager.warnings, conflicts: conflicts.filter { !$0.isWarning }.map(\.description))
    }

    /// Applies what the update sites changed: to a copy of the installation,
    /// swapped in now if no helper is running (in any Mancora), else staged
    /// and swapped in before the next helper starts.
    public func applyUpdates(progress: @escaping @Sendable (FijiProgress) -> Void = { _ in }) async throws -> FijiUpdateOutcome {
        guard installation.isComplete else { throw FijiError.notInstalled(path: root.path) }
        guard let updating = try FileLock.acquire(files.updating, .exclusive, wait: false) else { throw FijiError.busy }
        defer { updating.release() }
        let version = installation.version
        let fm = FileManager.default
        files.removeLeftovers()
        defer { settle() }
        let started = FijiProgress(phase: .checking, detail: "Reading Fiji's update sites")
        setStatus(.updating(version, started))
        progress(started)

        // The copy starts from the installation, not an earlier staged update: it holds that update too,
        // and what Fiji's own updater left in update/ (Fiji's launcher would apply it at the next start).
        let building = files.temporary("next")
        let changes: [String]
        do {
            try Files.cloneTree(from: root, to: building)
            if fm.fileExists(atPath: files.fijiUpdates.path) { try Files.overlay(from: files.fijiUpdates, onto: building) }
            changes = try await Self.update(root: building, client: client) { message in
                let p = FijiProgress(phase: .updating, detail: message)
                progress(p)
                Task { await self.note(p) }
            }
            updateSettings { $0.lastCheck = Date() }
            if changes.isEmpty {
                try? fm.removeItem(at: building)
                return .upToDate
            }
            guard FijiInstallation(root: building).isComplete else {
                throw FijiError.incomplete("the update would leave Fiji without ImageJ, its legacy layer or Java")
            }
            try files.markStaged(building, changes: changes)
            if fm.fileExists(atPath: files.next.path) { try fm.removeItem(at: files.next) }
            try fm.moveItem(at: building, to: files.next)
        } catch {
            try? fm.removeItem(at: building)
            throw error
        }

        let applying = FijiProgress(phase: .applying, detail: "Applying \(changes.count) change(s)")
        setStatus(.updating(version, applying))
        progress(applying)
        guard let live = try FileLock.acquire(files.lock, .exclusive, wait: false) else { return .staged(changes) }
        defer { live.release() }
        try files.swapInNext()
        updateSettings { $0.lastUpdate = Date() }
        return .applied(changes)
    }

    /// Refreshes `root` from its sites and applies the changes there; returns them, empty if there were none.
    static func update(root: URL, client: any HTTPClient, progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        let manager = try PluginManager(root: root)
        try await manager.refresh(client: client)
        // A site that couldn't be read would look as if its files had gone.
        guard manager.warnings.isEmpty else { throw FijiError.sitesUnreadable(manager.warnings) }
        let (changes, conflicts) = manager.plan()
        let errors = conflicts.filter { !$0.isWarning }
        guard errors.isEmpty else { throw FijiError.conflicts(errors.map(\.description)) }
        if changes.isEmpty { return [] }
        try await manager.apply(client: client, progress: progress)
        return changes.map(\.description)
    }

    /// Whether an update waits to be swapped in before the next helper starts.
    public var hasStagedUpdate: Bool { files.isStaged }

    /// The staged update's changes.
    public var stagedChanges: [String] { files.stagedChanges }

    /// Checks and updates if automatic updates are on and a day has passed
    /// since the last check. Returns what happened, or `nil` if nothing was
    /// due or it failed (the error is kept in ``FijiSettings/lastError``).
    @discardableResult
    public func updateAutomaticallyIfDue(now: Date = Date()) async -> FijiUpdateOutcome? {
        settings = files.readSettings()
        guard settings.autoUpdate, installation.isComplete, schedule.isDue(lastCheck: settings.lastCheck, now: now) else { return nil }
        if case .installing = status { return nil }
        if case .updating = status { return nil }
        do {
            let check = try await checkForUpdates()
            // A site that couldn't be read says nothing about its files: try again later.
            guard check.warnings.isEmpty else { throw FijiError.sitesUnreadable(check.warnings) }
            if check.isUpToDate {
                updateSettings { $0.lastError = nil }
                return .upToDate
            }
            let outcome = try await applyUpdates()
            updateSettings { $0.lastError = nil }
            return outcome
        } catch {
            updateSettings { $0.lastError = "\(error)" }
            return nil
        }
    }

    /// Updates automatically while Mancora runs: whenever one is due
    /// (``updateAutomaticallyIfDue(now:)``), looking every `interval` seconds.
    public func startAutomaticUpdates(every interval: TimeInterval = 3600) {
        guard automaticUpdates == nil else { return }
        automaticUpdates = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateAutomaticallyIfDue()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopAutomaticUpdates() {
        automaticUpdates?.cancel()
        automaticUpdates = nil
    }

    // MARK: Launching

    /// Called before a helper starts in Fiji: swaps in a staged update (and
    /// applies files Fiji's own updater left in `update/`, as Fiji's launcher
    /// does) if no other helper is running, then holds the installation for
    /// the helper. Release the lease when the helper exits.
    public func prepareForLaunch() throws -> FijiLease {
        let files = files
        if let live = try FileLock.acquire(files.lock, .exclusive, wait: false) {
            files.recover()
            if files.isStaged {
                try files.swapInNext()
                updateSettings { $0.lastUpdate = Date() }
            }
            if FileManager.default.fileExists(atPath: files.fijiUpdates.path),
                let updating = try FileLock.acquire(files.updating, .exclusive, wait: false)
            {
                defer { updating.release() }
                try files.applyFijiUpdates()
            }
            live.release()
            settle()
        }
        guard installation.isComplete else { throw FijiError.notInstalled(path: root.path) }
        guard let shared = try FileLock.acquire(files.lock, .shared, wait: true) else { throw FijiError.busy }
        return FijiLease(installation: installation, lock: shared)
    }
}

/// The files beside an installation, and the operations that change it.
struct Files: Sendable {
    let root: URL
    var parent: URL { root.deletingLastPathComponent() }
    var name: String { root.lastPathComponent }
    var settingsFile: URL { parent.appendingPathComponent(name + ".json") }
    var lock: URL { parent.appendingPathComponent(name + ".lock") }
    var updating: URL { parent.appendingPathComponent(name + ".updating.lock") }
    var next: URL { parent.appendingPathComponent(name + ".next") }
    /// Written last into a prepared update: without it, the folder is unfinished.
    static let stagedMarker = ".mancora-staged.json"
    /// Fiji's updater's own staging folder, applied by Fiji's launcher at start.
    var fijiUpdates: URL { root.appendingPathComponent("update") }

    func temporary(_ kind: String) -> URL { parent.appendingPathComponent("\(name).\(kind)-\(UUID().uuidString)") }

    func readSettings() -> FijiSettings {
        guard let data = try? Data(contentsOf: settingsFile) else { return FijiSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(FijiSettings.self, from: data)) ?? FijiSettings()
    }

    func write(_ settings: FijiSettings) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }

    // MARK: Staged updates

    struct Staged: Codable {
        let date: Date
        let changes: [String]
    }

    var isStaged: Bool { FileManager.default.fileExists(atPath: next.appendingPathComponent(Self.stagedMarker).path) }

    var stagedChanges: [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: next.appendingPathComponent(Self.stagedMarker)),
            let staged = try? decoder.decode(Staged.self, from: data)
        else { return [] }
        return staged.changes
    }

    func markStaged(_ folder: URL, changes: [String]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Staged(date: Date(), changes: changes)).write(to: folder.appendingPathComponent(Self.stagedMarker))
    }

    /// Renames the prepared update into place, the old installation aside
    /// and then away. Call holding the lock exclusively.
    func swapInNext() throws {
        let fm = FileManager.default
        let old = temporary("old")
        if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
        do {
            try fm.moveItem(at: next, to: root)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: root) }
            throw error
        }
        try? fm.removeItem(at: root.appendingPathComponent(Self.stagedMarker))
        try? fm.removeItem(at: old)
    }

    /// After a crash between a swap's renames: puts an installation back
    /// (the prepared one, if finished, else the old one), and removes what
    /// earlier swaps set aside. Call holding the lock exclusively.
    func recover() {
        let fm = FileManager.default
        let olds = siblings(kind: "old")
        if !fm.fileExists(atPath: root.path) {
            if isStaged {
                if (try? fm.moveItem(at: next, to: root)) != nil {
                    try? fm.removeItem(at: root.appendingPathComponent(Self.stagedMarker))
                }
            } else if let newest = olds.max(by: { modified($0) < modified($1) }) {
                try? fm.moveItem(at: newest, to: root)
            }
        }
        for old in olds where fm.fileExists(atPath: old.path) { try? fm.removeItem(at: old) }
    }

    /// Downloads, unpacked archives and unfinished updates left by a run that
    /// stopped. Call holding the updating lock (no install or update is running).
    func removeLeftovers() {
        let fm = FileManager.default
        for kind in ["download", "install", "next"] {
            for url in siblings(kind: kind) { try? fm.removeItem(at: url) }
        }
        if fm.fileExists(atPath: next.path) && !isStaged { try? fm.removeItem(at: next) }
    }

    func siblings(kind: String) -> [URL] {
        let prefix = "\(name).\(kind)-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .map { parent.appendingPathComponent($0) }
    }

    func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Applies what Fiji's own updater (run inside a helper) left in
    /// `update/`, as Fiji's launcher does when it starts: each file replaces
    /// its namesake, an empty one deletes it. Done on a copy that is swapped
    /// in, like Mancora's updates. Call holding both locks exclusively.
    func applyFijiUpdates() throws {
        let fm = FileManager.default
        let building = temporary("next")
        if fm.fileExists(atPath: next.path) { try fm.removeItem(at: next) }
        do {
            try Self.cloneTree(from: root, to: building)
            try Self.overlay(from: fijiUpdates, onto: building)
            try fm.moveItem(at: building, to: next)
        } catch {
            try? fm.removeItem(at: building)
            throw error
        }
        try swapInNext()
    }

    static func overlay(from source: URL, onto target: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            let attributes = try fm.attributesOfItem(atPath: from.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
                try overlay(from: from, onto: to)
                continue
            }
            if fm.fileExists(atPath: to.path) || (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil {
                try fm.removeItem(at: to)
            }
            if (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 { try fm.copyItem(at: from, to: to) }
        }
    }

    // MARK: Copies and archives

    /// Copies a folder as hard links (so it takes no space and the files'
    /// times are kept), symbolic links as links; the files an update rewrites
    /// in place are copied, and Fiji's `update/` folder is left out. Falls
    /// back to copying where hard links don't work.
    static func cloneTree(from source: URL, to target: URL, relative: String = "") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let path = relative.isEmpty ? name : relative + "/" + name
            if path == "update" || path == stagedMarker { continue }
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            let type = try fm.attributesOfItem(atPath: from.path)[.type] as? FileAttributeType
            switch type {
            case .typeDirectory?:
                try cloneTree(from: from, to: to, relative: path)
            case .typeSymbolicLink?:
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: from.path))
            default:
                if copiedNotLinked.contains(path) {
                    try fm.copyItem(at: from, to: to)
                } else if (try? fm.linkItem(at: from, to: to)) == nil {
                    try fm.copyItem(at: from, to: to)
                }
            }
        }
    }

    /// Files the updater writes in place rather than replacing.
    static let copiedNotLinked: Set<String> = ["db.xml.gz", ".checksums"]

    /// The Fiji folder an archive unpacked: its one top-level folder (`Fiji`), or the staging folder itself.
    static func unpackedRoot(in staging: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        if entries.count == 1 {
            let only = staging.appendingPathComponent(entries[0])
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &directory), directory.boolValue { return only }
        }
        return staging
    }
}
