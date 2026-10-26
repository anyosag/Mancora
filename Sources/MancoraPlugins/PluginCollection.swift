public import Foundation
import MancoraSupport

/// An update site: a URL with a `db.xml.gz` listing its files.
public final class UpdateSite: CustomStringConvertible {
    public var name: String
    public private(set) var url: String
    public var host: String?
    public private(set) var uploadDirectory: String?
    public var siteDescription: String?
    public var maintainer: String?
    /// When the site's index was last read (its `Last-Modified`), as an updater timestamp.
    public var timestamp: Int64
    public var isActive = false
    public var isOfficial = false
    public var keepURL = false
    /// Sites read later shadow earlier ones' files of the same name.
    public internal(set) var rank = 0

    public init(
        name: String, url: String, host: String? = nil, uploadDirectory: String? = nil, description: String? = nil,
        maintainer: String? = nil, timestamp: Int64 = 0
    ) {
        self.name = name
        self.url = Self.format(url)
        self.host = host
        self.siteDescription = description
        self.maintainer = maintainer
        self.timestamp = timestamp
        setUploadDirectory(uploadDirectory)
    }

    public func setURL(_ url: String) { self.url = Self.format(url) }

    func setUploadDirectory(_ directory: String?) {
        if let directory, !directory.isEmpty, !directory.hasSuffix("/") {
            uploadDirectory = directory + "/"
        } else {
            uploadDirectory = directory
        }
    }

    /// A trailing slash, and the old Fiji URLs rewritten.
    public static func format(_ url: String) -> String {
        guard !url.isEmpty else { return url }
        let slashed = url.hasSuffix("/") ? url : url + "/"
        if slashed == "http://pacific.mpi-cbg.de/update/" || slashed == "http://fiji.sc/update/" {
            return "https://update.fiji.sc/"
        }
        return slashed
    }

    /// `setLastModified`: the time the index was served, as a timestamp
    /// (no time is the Unix epoch, as for Java's `getLastModified`).
    public func setLastModified(_ date: Date?, timeZone: TimeZone = .current) {
        timestamp = UpdaterTime.timestamp(date ?? Date(timeIntervalSince1970: 0), timeZone: timeZone)
    }

    public var description: String {
        url + (host.map { ", \($0)" } ?? "") + (uploadDirectory.map { ", \($0)" } ?? "")
    }
}

/// The updater's timestamps: local time as the digits `yyyyMMddHHmmss`.
public enum UpdaterTime {
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let digits = String(format: "%d%02d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return Int64(digits) ?? 0
    }

    public static var now: Int64 { timestamp(Date()) }
}

/// The files and update sites of one installation: a port of the
/// updater's `FilesCollection`. Files are keyed by name without version,
/// so `jars/foo-1.2.jar` and `jars/foo-1.3.jar` are one file.
public final class PluginCollection {
    public static let defaultSiteName = "ImageJ"
    public static let defaultSiteURL = "https://update.imagej.net/"
    public static let databaseName = "db.xml.gz"

    public let root: URL?
    public private(set) var sites: [UpdateSite] = []
    private var keys: [String] = []
    private var byKey: [String: PluginFile] = [:]
    /// Platforms whose files are installed (`activePlatforms`).
    public var activePlatforms: Set<String>
    /// What the checksummer found worth a warning (several versions of one file).
    public var conflicts: [Conflict] = []
    /// The time zone of the updater's timestamps (Java's default zone).
    public var timeZone: TimeZone = .current

    /// Starts as the updater does, with the ImageJ site, active and official.
    public init(root: URL?, activePlatforms: Set<String>? = nil, timeZone: TimeZone = .current) {
        self.root = root
        self.activePlatforms = activePlatforms ?? Platforms.inferActive(root: root)
        self.timeZone = timeZone
        let site = UpdateSite(name: Self.defaultSiteName, url: Self.defaultSiteURL, timestamp: databaseTimestamp())
        site.isActive = true
        site.isOfficial = true
        addSite(site)
    }

    // MARK: Files

    public var files: [PluginFile] { keys.compactMap { byKey[$0] } }

    public subscript(filename: String) -> PluginFile? { byKey[FilenameVersion.strip(filename)] }

    public func add(_ file: PluginFile) {
        let key = file.unversionedFilename
        if byKey[key] == nil { keys.append(key) }
        byKey[key] = file
    }

    public func remove(_ file: PluginFile) { remove(named: file.filename) }

    public func remove(named filename: String) {
        let key = FilenameVersion.strip(filename)
        guard byKey.removeValue(forKey: key) != nil else { return }
        keys.removeAll { $0 == key }
    }

    func removeAllFiles() {
        keys.removeAll()
        byKey.removeAll()
    }

    public func isActivePlatform(_ platform: String) -> Bool { Platforms.matches(active: activePlatforms, platform) }

    /// The site's files for this computer's platforms, without uninstalled obsolete ones.
    public func files(forSite name: String) -> [PluginFile] {
        files.filter { $0.updateSite == name && $0.isActivePlatform(self) && $0.status != .obsoleteUninstalled }
    }

    /// Files the updater manages (all but local-only ones).
    public var managedFiles: [PluginFile] { files.filter { $0.status != .localOnly } }

    public var toInstallOrUpdate: [PluginFile] { files.filter { $0.action == .install || $0.action == .update } }
    public var toUninstall: [PluginFile] { files.filter { $0.action == .uninstall } }

    // MARK: Sites

    public func site(named name: String, evenDisabled: Bool = true) -> UpdateSite? {
        guard let site = sites.first(where: { $0.name == name }) else { return nil }
        return evenDisabled || site.isActive ? site : nil
    }

    public var activeSites: [UpdateSite] { sites.filter(\.isActive) }

    /// Adds a site after the others, or replaces the one of the same name (keeping its rank).
    public func addSite(_ site: UpdateSite) {
        if let i = sites.firstIndex(where: { $0.name == site.name }) {
            site.rank = sites[i].rank
            site.isOfficial = sites[i].isOfficial
            sites[i] = site
        } else {
            site.rank = sites.count
            sites.append(site)
        }
    }

    /// `removeUpdateSite`: its files go back to the sites they shadowed, or become obsolete.
    /// Returns files whose old names should be deleted.
    @discardableResult
    public func removeSite(named name: String) -> [String] {
        var stale: [String] = []
        for file in files(forSite: name) { stale += file.removeFromUpdateSite(name, self) }
        sites.removeAll { $0.name == name }
        for (i, site) in sites.enumerated() { site.rank = i + 1 }
        return stale
    }

    /// `deactivateUpdateSite`.
    @discardableResult
    public func deactivateSite(named name: String) -> [String] {
        guard let site = site(named: name), site.isActive else { return [] }
        var stale: [String] = []
        for file in files(forSite: name) { stale += file.removeFromUpdateSite(name, self) }
        site.isActive = false
        return stale
    }

    // MARK: Reading

    /// Reads the installation's own `db.xml.gz` (its sites), as `tryLoadingCollection`.
    public func readLocalDatabase() throws {
        guard let root else { return }
        let url = root.appendingPathComponent(Self.databaseName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins/Fiji_Updater.jar").path),
                site(named: "Fiji") == nil
            {
                let fiji = UpdateSite(name: "Fiji", url: "https://update.fiji.sc/")
                fiji.isActive = true
                addSite(fiji)
            }
            return
        }
        let data = try Data(contentsOf: url)
        try DatabaseReader(files: self, site: nil, timestamp: .max).read(try Self.gunzip([UInt8](data)))
    }

    /// Reads a site's index into the collection (`XMLFileReader.read(site, in, timestamp)`).
    public func readSiteDatabase(_ site: UpdateSite, xml: [UInt8]) throws {
        try DatabaseReader(files: self, site: site.name, timestamp: site.timestamp).read(xml)
    }

    static func gunzip(_ bytes: [UInt8]) throws -> [UInt8] {
        try Inflate.gzip(bytes[...], limit: 1 << 30)
    }

    private func databaseTimestamp() -> Int64 {
        guard let root,
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(Self.databaseName).path),
            let date = attributes[.modificationDate] as? Date
        else { return 0 }
        return UpdaterTime.timestamp(date, timeZone: timeZone)
    }

    // MARK: Planning

    /// `markForUpdate(false)`: every file an update changes is marked for it,
    /// as the updater's window starts out.
    public func markForUpdate(evenForced: Bool = false) {
        for file in files where file.wantsUpdate(evenForced: evenForced) && file.isActivePlatform(self) {
            file.setFirstValidAction(.update, .uninstall, .install)
        }
    }

    /// `markForUpdate(site, false)`, which activating a site does.
    public func markForUpdate(site name: String) {
        for file in files(forSite: name)
        where (file.wantsUpdate(evenForced: false) || file.status.isValid(.install)) && file.isActivePlatform(self) {
            file.setFirstValidAction(.update, .uninstall, .install)
        }
    }

    /// After checksumming: files an up-to-date file needs, but that are
    /// missing, are installed (`reloadCollectionAndChecksum`).
    func heedUpstreamDependencies() {
        for file in files where file.status == .installed {
            for dependency in file.fileDependencies(in: self, recursive: false)
            where dependency.action == .notInstalled && dependency.isActivePlatform(self) {
                try? dependency.setAction(.install)
            }
        }
    }

    /// The files that installing or updating `files` needs too, and the
    /// files that need them (`getDependencies(false)`); with `overriding`,
    /// the files they obsolete instead.
    func dependencies(of files: [PluginFile], overriding: Bool) -> [(file: PluginFile, neededBy: [PluginFile])] {
        var result: [(file: PluginFile, neededBy: [PluginFile])] = []
        func add(_ file: PluginFile) {
            for dependency in file.dependencies {
                guard let other = self[dependency.filename], overriding == dependency.overrides, other.isActivePlatform(self)
                else { continue }
                if other.isObsolete && other.willNotBeInstalled { continue }
                if dependency.overrides {
                    if other.willNotBeInstalled { continue }
                } else if other.willBeUpToDate {
                    continue
                }
                if let i = result.firstIndex(where: { $0.file === other }) {
                    result[i].neededBy.append(file)
                    continue
                }
                result.append((other, [file]))
                if !overriding { add(other) }
            }
        }
        for file in files { add(file) }
        return result
    }

    /// A problem that stops an update until someone decides.
    public struct Conflict: Sendable, CustomStringConvertible {
        public let filename: String
        public let message: String
        /// The updater's warning severity: its first resolution, keeping the
        /// local file, is what an update does when nobody can be asked.
        public var isWarning = false
        public var description: String { "\(filename): \(message)" }
    }

    /// `Conflicts.listUpdateIssues`: marks what the planned files need for
    /// installation (the updater does this on its own, with a notice) and
    /// returns the problems that need a decision.
    public func resolveDependencies() -> (installedForDependencies: [PluginFile], conflicts: [Conflict]) {
        let toInstall = dependencies(of: toInstallOrUpdate, overriding: false)
        let obsoleted = dependencies(of: toInstallOrUpdate, overriding: true)
        var automatic: [PluginFile] = []
        var conflicts: [Conflict] = []
        for (file, reasons) in toInstall {
            if let obsoleteReasons = obsoleted.first(where: { $0.file === file })?.neededBy {
                conflicts.append(
                    Conflict(
                        filename: file.filename,
                        message: "Required by \(Self.join(reasons)) but made obsolete by \(Self.join(obsoleteReasons))"))
            } else if !file.willBeUpToDate {
                if file.isLocallyModified {
                    conflicts.append(
                        Conflict(
                            filename: file.filename,
                            message: "Locally modified and the Updater cannot determine its status. "
                                + "A newer version might be required by \(Self.join(reasons))",
                            isWarning: true))
                } else if !automatic.contains(where: { $0 === file }) {
                    automatic.append(file)
                }
            }
        }
        for (file, reasons) in obsoleted where toInstall.first(where: { $0.file === file }) == nil && !file.willNotBeInstalled {
            conflicts.append(Conflict(filename: file.filename, message: "Locally modified but made obsolete by \(Self.join(reasons))"))
        }
        for file in automatic { file.setFirstValidAction(.update, .install) }
        return (automatic, conflicts)
    }

    static func join(_ files: [PluginFile]) -> String { files.map(\.filename).joined(separator: ", ") }

    /// The download URL of a file's current version: the site's URL, the file
    /// name and `-<timestamp>`. The name is percent-encoded where a URL path
    /// needs it (spaces become `%20`, as in the updater's `getURL`), so a `#`,
    /// `?` or `%` in it doesn't start a fragment, a query or an escape.
    public func url(of file: PluginFile) -> String? {
        guard let name = file.updateSite, let site = site(named: name, evenDisabled: false) else { return nil }
        let path = file.filename.addingPercentEncoding(withAllowedCharacters: Self.urlPathCharacters) ?? file.filename
        return site.url + path + "-\(file.timestamp)"
    }

    /// What RFC 3986 lets a path hold unencoded: unreserved and sub-delimiter characters, `:`, `@` and `/`.
    static let urlPathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/")
}
