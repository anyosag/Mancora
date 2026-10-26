#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public import Foundation
public import MancoraUpdate
import MancoraSupport

/// Keeps a Fiji-style installation in step with its update sites, as Fiji's
/// updater does: the same `db.xml.gz` (so Fiji can manage the folder too),
/// the same checksums, statuses and shadowing between sites, and the same
/// download URLs (`<site><file>-<timestamp>`), every download checked against
/// the site's checksum before anything is moved into place.
///
/// One difference: a folder without a `db.xml.gz` starts with the ImageJ
/// site disabled. Mancora's bridge runs plain ImageJ 1.x; the ImageJ site
/// installs ImageJ2 and its libraries, which plugins needing them can enable.
public final class PluginManager {
    public let root: URL
    public private(set) var files: PluginCollection
    /// What reading the sites reported (sites that couldn't be read).
    public private(set) var warnings: [String] = []

    public init(root: URL, activePlatforms: Set<String>? = nil, timeZone: TimeZone = .current) throws {
        self.root = root
        files = PluginCollection(root: root, activePlatforms: activePlatforms, timeZone: timeZone)
        let database = root.appendingPathComponent(PluginCollection.databaseName)
        if FileManager.default.fileExists(atPath: database.path) {
            try files.readLocalDatabase()
        } else {
            files.site(named: PluginCollection.defaultSiteName)?.isActive = false
            try files.readLocalDatabase()
        }
    }

    // MARK: Sites

    public var sites: [UpdateSite] { files.sites }

    public enum SiteError: Error, CustomStringConvertible {
        case exists(String)
        case unknown(String)
        case needsURL(String)
        case noSuchFile(String)
        public var description: String {
            switch self {
            case .exists(let name): "An update site named \"\(name)\" exists already."
            case .unknown(let name): "There is no update site named \"\(name)\"."
            case .needsURL(let name): "\"\(name)\" isn't a known update site; give its URL."
            case .noSuchFile(let name): "No enabled update site provides \(name)."
            }
        }
    }

    /// Adds and activates a site. A known site's URL may be left out.
    public func addSite(name: String, url: String?) throws(SiteError) {
        guard files.site(named: name) == nil else { throw .exists(name) }
        guard let url = url ?? KnownSites.url(for: name) else { throw .needsURL(name) }
        let site = UpdateSite(name: name, url: url, description: KnownSites.all.first { $0.name == name }?.description)
        site.isActive = true
        site.isOfficial = KnownSites.all.contains { $0.name == name && UpdateSite.format($0.url) == site.url }
        files.addSite(site)
    }

    /// Enables or disables a site.
    ///
    /// Enabling installs all its files at the next update, as activating a
    /// site in Fiji marks them all: the site's timestamp is reset, so its
    /// files read as new. Disabling marks the files it provides for removal
    /// (or returns them to the sites they shadowed), so `refresh` must have
    /// run first and `apply` should follow, as in Fiji's window.
    public func setActive(_ name: String, _ active: Bool) throws(SiteError) {
        guard let site = files.site(named: name) else { throw .unknown(name) }
        if active {
            guard !site.isActive else { return }
            site.isActive = true
            site.timestamp = 0
        } else {
            staleNames += files.deactivateSite(named: name)
        }
    }

    /// Removes a site; like disabling it, after `refresh` and before `apply`.
    public func removeSite(_ name: String) throws(SiteError) {
        guard files.site(named: name) != nil else { throw .unknown(name) }
        staleNames += files.removeSite(named: name)
    }

    /// Old file names to delete at the next update.
    private var staleNames: [String] = []

    /// Writes the site list (and what's installed) to `db.xml.gz`.
    public func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gzip = Deflate.gzip(DatabaseWriter.xml(files, local: true, timestampObsolete: UpdaterTime.timestamp(Date(), timeZone: files.timeZone)))
        let database = root.appendingPathComponent(PluginCollection.databaseName)
        try Data(gzip).write(to: database, options: .atomic)
    }

    // MARK: Status

    /// `reloadCollectionAndChecksum`: reads every active site's index, then
    /// checksums the local files, then marks what an update would do.
    public func refresh(client: any HTTPClient) async throws {
        files.removeAllFiles()
        files.conflicts = []
        warnings = []
        for site in files.activeSites {
            guard let url = URL(string: site.url + "db.xml.gz") else {
                warnings.append("Could not update from site '\(site.name)': invalid URL \(site.url)")
                continue
            }
            do {
                let (data, lastModified) = try await client.dataAndLastModified(from: url)
                let xml = try PluginCollection.gunzip([UInt8](data))
                try files.readSiteDatabase(site, xml: xml)
                site.setLastModified(lastModified, timeZone: files.timeZone)
            } catch UpdateError.httpStatus(404, _) {
                // A site whose index is gone (Java's FileNotFoundException).
                site.setLastModified(nil, timeZone: files.timeZone)
                warnings.append("Could not update from site '\(site.name)': \(url.absoluteString) does not exist")
            } catch {
                warnings.append("Could not update from site '\(site.name)': \(Self.describe(error))")
            }
        }
        var checksummer = Checksummer(files: files, root: root)
        checksummer.updateFromLocal()
        files.heedUpstreamDependencies()
        files.markForUpdate()
    }

    /// `ImageJ-updater update <files>`: after `refresh`, plans only these
    /// files (and what they need) instead of everything the sites offer.
    public func select(_ names: [String]) throws(SiteError) {
        let wanted = Set(names.map(FilenameVersion.strip))
        for file in files.files where !wanted.contains(file.unversionedFilename) { file.setNoAction() }
        for name in names {
            guard let file = files[name] else { throw .noSuchFile(name) }
            if !file.stageForUpdate(files, evenForced: false) && file.isObsolete { file.setFirstValidAction(.uninstall) }
        }
    }

    /// One planned change.
    public struct Change: Sendable, CustomStringConvertible {
        public enum Kind: String, Sendable { case install, update, uninstall }
        public let kind: Kind
        public let filename: String
        public let site: String?
        public let size: Int64
        public var description: String { "\(kind.rawValue) \(filename)" + (site.map { " (\($0))" } ?? "") }
    }

    /// What `apply` would do, after adding what the planned files depend on.
    public func plan() -> (changes: [Change], conflicts: [PluginCollection.Conflict]) {
        let (_, conflicts) = files.resolveDependencies()
        var changes: [Change] = []
        for file in files.files {
            switch file.action {
            case .install: changes.append(Change(kind: .install, filename: file.filename, site: file.updateSite, size: file.filesize))
            case .update: changes.append(Change(kind: .update, filename: file.filename, site: file.updateSite, size: file.filesize))
            case .uninstall:
                changes.append(Change(kind: .uninstall, filename: file.localFilename(forDisplay: false), site: file.updateSite, size: 0))
            default: break
            }
        }
        return (changes, conflicts)
    }

    public enum InstallError: Error, CustomStringConvertible {
        case conflicts([PluginCollection.Conflict])
        case noURL(String)
        case wrongSize(String, actual: Int, expected: Int64)
        case wrongChecksum(String, actual: String, expected: String)
        case download(String, any Error)
        case move(String, any Error)
        public var description: String {
            switch self {
            case .conflicts(let list): "Unresolved conflicts:\n" + list.map(\.description).joined(separator: "\n")
            case .noURL(let name): "\(name) has no active update site to download it from."
            case .wrongSize(let name, let actual, let expected): "Incorrect file size for \(name): \(actual) (expected \(expected))"
            case .wrongChecksum(let name, let actual, let expected): "Incorrect checksum for \(name):\n\(actual)\n(expected \(expected))"
            case .download(let name, let error): "Could not download \(name): \(PluginManager.describe(error))"
            case .move(let name, let error): "Could not move \(name) into place: \(PluginManager.describe(error))"
            }
        }
    }

    /// Downloads and verifies everything planned into `update/`, then moves
    /// it into place, removes what's uninstalled and saves `db.xml.gz`. If
    /// any download fails or doesn't match its checksum, nothing changes.
    /// Warnings (a locally modified file another one may need a newer
    /// version of) keep the local file, as the updater's first resolution does.
    public func apply(client: any HTTPClient, progress: (String) -> Void = { _ in }) async throws {
        let (_, conflicts) = plan()
        let errors = conflicts.filter { !$0.isWarning }
        guard errors.isEmpty else { throw InstallError.conflicts(errors) }
        let fm = FileManager.default
        let staging = root.appendingPathComponent("update")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }

        // Download and verify everything into update/ before changing anything.
        let downloads = files.toInstallOrUpdate
        var deletions = staleNames
        do {
            for file in downloads {
                guard let address = files.url(of: file), let url = URL(string: address) else { throw InstallError.noURL(file.filename) }
                progress("Downloading \(file.filename)")
                let data: Data
                do { data = try await client.data(from: url) } catch { throw InstallError.download(file.filename, error) }
                try Self.verify(file, [UInt8](data))
                let staged = staging.appendingPathComponent(file.filename)
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: staged)
                // A file renamed upstream (a new version in its name) replaces the old name.
                if let local = file.localFilename, local != file.filename { deletions.append(local) }
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // Launchers are swapped in place, the old one kept as .old (or .old.exe).
        for file in downloads where file.executable {
            let target = root.appendingPathComponent(file.filename)
            if fm.fileExists(atPath: target.path) {
                let old = Self.oldName(target)
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: target, to: old)
            }
        }
        try Self.moveIntoPlace(from: staging, to: root)
        if !Platforms.isWindows(Platforms.current) {
            for file in downloads where file.executable {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(file.filename).path)
            }
        }
        for file in downloads {
            file.setLocalVersion(filename: file.filename, checksum: file.checksum ?? "", timestamp: file.timestamp)
            file.setStatus(.installed)
        }

        // Uninstalling removes the local copy (the updater stages an empty file for it).
        for file in files.toUninstall {
            progress("Removing \(file.localFilename(forDisplay: false))")
            deletions.append(file.localFilename(forDisplay: false))
            if file.isLocalOnly {
                files.remove(file)
            } else {
                file.setStatus(file.isObsolete ? .obsoleteUninstalled : .notInstalled)
            }
        }
        // Never what was just installed under the same name.
        for name in Set(deletions).subtracting(downloads.map(\.filename)) {
            let target = root.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                do { try fm.removeItem(at: target) } catch { throw InstallError.move(name, error) }
            }
        }
        staleNames = []
        try save()
    }

    /// An error as one readable line (Foundation's URL errors print their whole user info).
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? ns.localizedDescription : "\(error)"
    }

    /// `Installer.verify`: the size and the updater's checksum (or one an
    /// older updater computed) must be the site's.
    static func verify(_ file: PluginFile, _ data: [UInt8]) throws {
        if file.filesize >= 0, Int64(data.count) != file.filesize {
            throw InstallError.wrongSize(file.filename, actual: data.count, expected: file.filesize)
        }
        let expected = file.checksum ?? ""
        var actual = try FijiChecksum.digest(path: file.filename, contents: data)
        if actual != expected, try FijiChecksum.obsoleteDigests(path: file.filename, contents: data).contains(expected) {
            actual = expected
        }
        guard actual == expected else { throw InstallError.wrongChecksum(file.filename, actual: actual, expected: expected) }
    }

    /// `x.old`, or `x.old.exe` for `x.exe`.
    static func oldName(_ url: URL) -> URL {
        let name = url.lastPathComponent
        let old = name.hasSuffix(".exe") ? String(name.dropLast(4)) + ".old.exe" : name + ".old"
        return url.deletingLastPathComponent().appendingPathComponent(old)
    }

    /// `moveUpdatedIntoPlace`: each staged file replaces its target; the
    /// staging folder is removed.
    static func moveIntoPlace(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            var childIsDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: from.path, isDirectory: &childIsDirectory)
            if childIsDirectory.boolValue {
                try moveIntoPlace(from: from, to: to)
                continue
            }
            do {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.moveItem(at: from, to: to)
            } catch {
                throw InstallError.move(name, error)
            }
        }
        try fm.removeItem(at: source)
    }
}

/// Update sites listed on imagej.net that Mancora knows by name.
public enum KnownSites {
    public struct Site: Sendable {
        public let name: String
        public let url: String
        public let description: String
    }

    public static let all: [Site] = [
        Site(name: "ImageJ", url: "https://update.imagej.net/", description: "ImageJ2 and its libraries."),
        Site(name: "Fiji", url: "https://update.fiji.sc/", description: "Fiji's plugins and libraries, Bio-Formats included."),
        Site(name: "Java-8", url: "https://sites.imagej.net/Java-8/", description: "Libraries Fiji needed on Java 8."),
        Site(name: "IJPB-plugins", url: "https://sites.imagej.net/IJPB-plugins/", description: "MorphoLibJ and other INRAE plugins."),
        Site(name: "BAR", url: "https://sites.imagej.net/Tiago/", description: "Broadly Applicable Routines."),
        Site(name: "BioVoxxel", url: "https://sites.imagej.net/BioVoxxel/", description: "BioVoxxel Toolbox."),
        Site(name: "CLIJ", url: "https://sites.imagej.net/clij/", description: "GPU-accelerated image processing."),
        Site(name: "CLIJ2", url: "https://sites.imagej.net/clij2/", description: "GPU-accelerated image processing, version 2."),
        Site(name: "CSBDeep", url: "https://sites.imagej.net/CSBDeep/", description: "Deep-learning restoration (CARE)."),
        Site(name: "StarDist", url: "https://sites.imagej.net/StarDist/", description: "Star-convex object detection."),
        Site(name: "3D ImageJ Suite", url: "https://sites.imagej.net/Tboudier/", description: "3D segmentation and analysis."),
        Site(name: "PTBIOP", url: "https://biop.epfl.ch/Fiji-Update/", description: "EPFL BIOP's plugins."),
    ]

    public static func url(for name: String) -> String? { all.first { $0.name == name }?.url }
}
