import Foundation
import MancoraPlugins
import MancoraSupport
import MancoraUpdate
import Testing

@testable import MancoraFiji

/// A folder holding the fake Fiji archive and its `.sha256`, as
/// `downloads.imagej.net/fiji/latest/` holds the real ones.
struct FakeDownloads {
    let folder: URL
    let distribution: FijiDistribution

    init(checksum: String? = nil, archive: Data = FakeFiji.archive()) throws {
        folder = FakeFiji.temporaryFolder("fiji-downloads")
        distribution = FijiDistribution(baseURL: folder, platform: FakeFiji.platform)
        let name = try #require(distribution.archiveName)
        try archive.write(to: folder.appendingPathComponent(name))
        let digest = checksum ?? hexString(SHA256.hash([UInt8](archive)))
        try Data("\(digest)\n".utf8).write(to: folder.appendingPathComponent(name + ".sha256"))
    }
}

/// Recorded progress.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FijiProgress] = []
    func add(_ p: FijiProgress) { lock.withLock { entries.append(p) } }
    var all: [FijiProgress] { lock.withLock { entries } }
}

func leftovers(beside root: URL) -> [String] {
    let name = root.lastPathComponent
    return ((try? FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)) ?? [])
        .filter { $0.hasPrefix(name + ".") && !$0.hasSuffix(".json") && !$0.hasSuffix(".lock") }
}

@Suite("Fiji: installing", .disabled(if: onWindows, "Fiji runs on macOS and Linux"))
struct FijiInstallTests {
    @Test func installsAtomicallyFromAVerifiedDownload() async throws {
        let downloads = try FakeDownloads()
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: downloads.folder) }
        let root = parent.appendingPathComponent("Fiji")
        let manager = FijiManager(root: root, distribution: downloads.distribution, client: MemorySites())
        #expect(await manager.status == .notInstalled)
        let statuses = await manager.statusUpdates()
        let log = ProgressLog()
        var downloader = URLSessionFijiDownloader(userAgent: "test")
        downloader.chunkSize = 1000
        let chunked = FijiManager(
            root: root, distribution: downloads.distribution, client: MemorySites(), downloader: downloader)
        try await chunked.install { log.add($0) }

        let fiji = FijiInstallation(root: root)
        #expect(fiji.isComplete)
        #expect(await chunked.status == .installed(fiji.version))
        // Bytes as they arrived, then unpacking.
        let downloading = log.all.filter { $0.phase == .downloading && $0.totalBytes != nil }
        let size = Int64(try Data(contentsOf: downloads.distribution.archiveURL!).count)
        #expect(downloading.count > 2)
        #expect(downloading.last?.completedBytes == size && downloading.last?.totalBytes == size)
        #expect(zip(downloading, downloading.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(log.all.last?.phase == .unpacking)
        // Executable bits and links survive unpacking.
        #expect(FileManager.default.isExecutableFile(atPath: fiji.javaExecutable!.path))
        let link = root.appendingPathComponent("java/\(FakeFiji.platform)/zulu21-fake/linked-bin")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == FakeFiji.linkTarget)
        // Nothing left beside it but the settings and lock files.
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
        let settings = await chunked.settings
        #expect(settings.installedFrom?.contains("SHA-256 ") == true)
        #expect(settings.lastCheck != nil && settings.autoUpdate)
        // Another manager (another Mancora) sees it installed.
        #expect(manager.isInstalled)
        _ = statuses
        // Installing again does nothing.
        try await chunked.install()
    }

    @Test func aCorruptDownloadInstallsNothing() async throws {
        let downloads = try FakeDownloads(checksum: String(repeating: "0", count: 64))
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: downloads.folder) }
        let root = parent.appendingPathComponent("Fiji")
        let manager = FijiManager(root: root, distribution: downloads.distribution, client: MemorySites())
        await #expect(throws: FijiError.self) { try await manager.install() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(leftovers(beside: root).isEmpty)
        #expect(await manager.status == .notInstalled)
    }

    @Test func anArchiveWithoutFijiIsRefused() async throws {
        var zip = ZipWriter()
        zip.file("Something/readme.txt", Data("not Fiji".utf8))
        let downloads = try FakeDownloads(archive: zip.finish())
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: downloads.folder) }
        let root = parent.appendingPathComponent("Fiji")
        let manager = FijiManager(root: root, distribution: downloads.distribution, client: MemorySites())
        await #expect {
            try await manager.install()
        } throws: { error in
            if case FijiError.incomplete = error { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(leftovers(beside: root).isEmpty)
    }

    @Test func cancellingStopsTheInstallAndCleansUp() async throws {
        let downloads = try FakeDownloads()
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: downloads.folder) }
        let root = parent.appendingPathComponent("Fiji")
        var downloader = URLSessionFijiDownloader(userAgent: "test")
        downloader.chunkSize = 64
        let manager = FijiManager(root: root, distribution: downloads.distribution, client: MemorySites(), downloader: downloader)
        let started = AsyncStream<Void>.makeStream()
        let install = Task {
            try await manager.install { progress in
                if progress.completedBytes > 0 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        install.cancel()
        await #expect(throws: CancellationError.self) { try await install.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
        #expect(await manager.status == .notInstalled)
        // A later install starts afresh and succeeds.
        try await manager.install()
        #expect(manager.isInstalled)
    }

    @Test func noDownloadForThisPlatformIsSaid() async throws {
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = FijiManager(
            root: parent.appendingPathComponent("Fiji"), distribution: FijiDistribution(platform: "linux32"), client: MemorySites())
        await #expect(throws: FijiError.unsupportedPlatform("linux32")) { try await manager.install() }
    }
}

@Suite("Fiji: updating", .disabled(if: onWindows, "Fiji runs on macOS and Linux"))
struct FijiUpdateTests {
    /// A fake Fiji in a fresh folder, with a manager on a site offering a newer macro.
    static func installed(newMacro: Bool = true) throws -> (FijiManager, MemorySites, URL) {
        let parent = FakeFiji.temporaryFolder()
        let root = parent.appendingPathComponent("Fiji")
        try FakeFiji.make(at: root)
        let sites = MemorySites()
        if newMacro { try siteWithNewMacro(sites) } else { try sites.publish([]) }
        return (FijiManager(root: root, client: sites), sites, root)
    }

    static func macro(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("macros/hello.ijm"), encoding: .utf8)
    }

    @Test func checkingListsWhatTheSitesChanged() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let check = try await manager.checkForUpdates()
        #expect(check.warnings.isEmpty, "\(check.warnings)")
        #expect(check.changes.map(\.description) == ["update macros/hello.ijm (Test)"])
        #expect(await manager.settings.lastCheck != nil)
        // Checking changes nothing.
        #expect(try Self.macro(root) == "print('v1');")
    }

    @Test func updatesApplyAtOnceWhenNoHelperRuns() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let log = ProgressLog()
        let outcome = try await manager.applyUpdates { log.add($0) }
        #expect(outcome == .applied(["update macros/hello.ijm (Test)"]))
        #expect(try Self.macro(root) == "print('v2');")
        #expect(FijiInstallation(root: root).isComplete)
        #expect(log.all.contains { $0.phase == .updating && $0.detail == "Downloading macros/hello.ijm" })
        #expect(await !manager.hasStagedUpdate)
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
        #expect(await manager.settings.lastUpdate != nil)
        // The installation's database now records the new version: nothing more to do.
        #expect(try await manager.applyUpdates() == .upToDate)
    }

    @Test func disablingASiteInAnUpdateRemovesItsFiles() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        _ = try await manager.applyUpdates()
        #expect(try Self.macro(root) == "print('v2');")
        // What the app's Update Sites window does when a site is switched off and the change applied.
        let outcome = try await manager.applyUpdates(siteChanges: { try $0.setActive(FakeFiji.site, false) })
        #expect(outcome == .applied(["uninstall macros/hello.ijm (Test)"]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("macros/hello.ijm").path))
        #expect(FijiInstallation(root: root).isComplete)
        let site = try #require(PluginManager(root: root).sites.first { $0.name == FakeFiji.site })
        #expect(!site.isActive)
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
    }

    @Test func changesToTheSitesAloneAreAnUpdate() async throws {
        let (manager, _, root) = try Self.installed(newMacro: false)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let outcome = try await manager.applyUpdates(siteChanges: { try $0.addSite(name: "Extra", url: "https://sites.test/Extra/") })
        #expect(outcome == .applied(["update sites"]))
        #expect(try PluginManager(root: root).sites.contains { $0.name == "Extra" })
        #expect(FijiInstallation(root: root).isComplete)
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
    }

    @Test func updatesWaitForTheRunningHelper() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // A helper is running (in this Mancora or another).
        let lease = try await manager.prepareForLaunch()
        #expect(lease.installation.root == root.standardizedFileURL)
        let outcome = try await manager.applyUpdates()
        #expect(outcome == .staged(["update macros/hello.ijm (Test)"]))
        // The running helper's Fiji is untouched; the update waits beside it.
        #expect(try Self.macro(root) == "print('v1');")
        #expect(await manager.hasStagedUpdate)
        #expect(await manager.stagedChanges == ["update macros/hello.ijm (Test)"])
        // Another helper starting meanwhile gets the same Fiji.
        let second = try await manager.prepareForLaunch()
        #expect(try Self.macro(root) == "print('v1');")
        second.release()
        // Once no helper runs, the next start swaps it in first.
        lease.release()
        let next = try await manager.prepareForLaunch()
        defer { next.release() }
        #expect(try Self.macro(root) == "print('v2');")
        #expect(await !manager.hasStagedUpdate)
        #expect(FijiInstallation(root: root).isComplete)
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
    }

    @Test func aFailedUpdateLeavesFijiAsItWas() async throws {
        let (manager, sites, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // The download doesn't match the site's checksum.
        sites.serve(FakeFiji.siteURL + "macros/hello.ijm-20260102000000", Data("print('tampered');".utf8))
        await #expect(throws: (any Error).self) { try await manager.applyUpdates() }
        #expect(try Self.macro(root) == "print('v1');")
        #expect(await !manager.hasStagedUpdate)
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")
        #expect(await manager.status == .installed(FijiInstallation(root: root).version))
    }

    @Test func anUnreadableSiteStopsAnUpdate() async throws {
        let (manager, _, root) = try Self.installed(newMacro: false)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // The site's index is gone (404): its files would look removed.
        let gone = FijiManager(root: root, client: MemorySites())
        await #expect(throws: FijiError.self) { try await gone.applyUpdates() }
        #expect(try Self.macro(root) == "print('v1');")
        _ = manager
    }

    @Test func automaticUpdatesRunOnceADayAndCanBeTurnedOff() async throws {
        let (manager, sites, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(await manager.autoUpdate)
        // Never checked: due now.
        let now = Date()
        #expect(await manager.updateAutomaticallyIfDue(now: now) == .applied(["update macros/hello.ijm (Test)"]))
        #expect(try Self.macro(root) == "print('v2');")
        // Within a day: not again, and the sites aren't asked.
        let asked = sites.requestCount
        #expect(await manager.updateAutomaticallyIfDue(now: now.addingTimeInterval(3600)) == nil)
        #expect(sites.requestCount == asked)
        // A day later, again.
        try siteWithNewMacro(sites, macro: "print('v3');")
        #expect(await manager.updateAutomaticallyIfDue(now: now.addingTimeInterval(25 * 3600)) != nil)
        // Turned off, it never checks; the setting is kept for every Mancora.
        try await manager.setAutoUpdate(false)
        let other = FijiManager(root: root, client: sites)
        #expect(await !other.autoUpdate)
        let before = sites.requestCount
        #expect(await other.updateAutomaticallyIfDue(now: now.addingTimeInterval(100 * 3600)) == nil)
        #expect(sites.requestCount == before)
        try await other.setAutoUpdate(true)
        #expect(await FijiManager(root: root, client: sites).autoUpdate)
    }

    @Test func aFailedAutomaticUpdateIsRemembered() async throws {
        let (_, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let offline = FijiManager(root: root, client: MemorySites())
        #expect(await offline.updateAutomaticallyIfDue() == nil)
        #expect(await offline.settings.lastError != nil)
    }

    @Test func fijisOwnStagedFilesGoInBeforeTheNextStart() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // What Fiji's updater, run in a helper, leaves for its launcher.
        let update = root.appendingPathComponent("update")
        try FileManager.default.createDirectory(at: update.appendingPathComponent("macros"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: update.appendingPathComponent("jars"), withIntermediateDirectories: true)
        try Data("print('new');".utf8).write(to: update.appendingPathComponent("macros/new.ijm"))
        try Data().write(to: update.appendingPathComponent("jars/fiji-lib-2.1.3.jar"))
        let lease = try await manager.prepareForLaunch()
        lease.release()
        #expect(try String(contentsOf: root.appendingPathComponent("macros/new.ijm"), encoding: .utf8) == "print('new');")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("jars/fiji-lib-2.1.3.jar").path))
        #expect(!FileManager.default.fileExists(atPath: update.path))
        #expect(FijiInstallation(root: root).isComplete)
    }

    @Test func aSwapInterruptedBetweenItsRenamesIsFinished() async throws {
        let (manager, _, root) = try Self.installed()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lease = try await manager.prepareForLaunch()
        _ = try await manager.applyUpdates()
        lease.release()
        // Mancora stopped after moving the old Fiji aside, before moving the new one in.
        let files = Files(root: root.standardizedFileURL)
        try FileManager.default.moveItem(at: root, to: files.temporary("old"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let restarted = FijiManager(root: root, client: MemorySites())
        #expect(restarted.isInstalled)
        #expect(try Self.macro(root) == "print('v2');")
        #expect(leftovers(beside: root).isEmpty, "\(leftovers(beside: root))")

        // Or before anything new was ready: the old one comes back.
        try FileManager.default.moveItem(at: root, to: files.temporary("old"))
        let again = FijiManager(root: root, client: MemorySites())
        #expect(again.isInstalled)
        #expect(try Self.macro(root) == "print('v2');")
    }

    @Test func theCopyAnUpdateWorksOnSharesTheFiles() throws {
        let parent = FakeFiji.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Fiji")
        try FakeFiji.make(at: root)
        let copy = parent.appendingPathComponent("Copy")
        try Files.cloneTree(from: root, to: copy)
        let fm = FileManager.default
        func inode(_ url: URL) throws -> UInt64? { (try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value }
        let jar = "jars/ij-1.54p.jar"
        #expect(try inode(root.appendingPathComponent(jar)) == inode(copy.appendingPathComponent(jar)))
        // The database is copied: the updater rewrites it.
        #expect(try inode(root.appendingPathComponent("db.xml.gz")) != inode(copy.appendingPathComponent("db.xml.gz")))
        #expect(FijiInstallation(root: copy).isComplete)
    }
}
