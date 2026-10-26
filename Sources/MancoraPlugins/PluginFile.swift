/// One file an update site manages: a port of the updater's
/// `net.imagej.updater.FileObject`, with its versions, dependencies and the
/// status and action that decide what an update does to it.
public final class PluginFile {
    /// A version of a file. Its timestamp isn't a Unix time but the
    /// digits of `yyyyMMddHHmmss` read as a number.
    public final class Version: CustomStringConvertible {
        public var checksum: String
        public var timestamp: Int64
        public var timestampObsolete: Int64 = 0
        /// The file name of this version, where it differs from the file's.
        public var filename: String?

        init(checksum: String, timestamp: Int64) {
            self.checksum = checksum
            self.timestamp = timestamp
        }

        init(copying other: Version) {
            checksum = other.checksum
            timestamp = other.timestamp
            timestampObsolete = other.timestampObsolete
            filename = other.filename
        }

        func sameVersion(_ other: Version) -> Bool { timestamp == other.timestamp && checksum == other.checksum }

        public var description: String { "Version(\(checksum);\(timestamp))" }
    }

    public struct Dependency: Sendable, CustomStringConvertible {
        public var filename: String
        public var timestamp: Int64
        public var overrides: Bool
        public var description: String { (overrides ? "obsoletes " : "") + filename }
    }

    public enum Action: String, Sendable, CaseIterable {
        case localOnly = "Local-only"
        case notInstalled = "Not installed"
        case installed = "Up-to-date"
        case updateable = "Update available"
        case modified = "Locally modified"
        case new = "New file"
        case obsolete = "Obsolete"
        case uninstall = "Uninstall it"
        case install = "Install it"
        case update = "Update it"
        case upload = "Upload it"
        case remove = "Remove it"
    }

    public enum Status: String, Sendable, CaseIterable {
        case notInstalled = "NOT_INSTALLED"
        case installed = "INSTALLED"
        case updateable = "UPDATEABLE"
        case modified = "MODIFIED"
        case localOnly = "LOCAL_ONLY"
        case new = "NEW"
        case obsoleteUninstalled = "OBSOLETE_UNINSTALLED"
        case obsolete = "OBSOLETE"
        case obsoleteModified = "OBSOLETE_MODIFIED"

        /// The actions this status allows; the first is "no change".
        public var actions: [Action] {
            switch self {
            case .notInstalled: [.notInstalled, .install, .remove]
            case .installed: [.installed, .uninstall]
            case .updateable: [.updateable, .uninstall, .update, .upload]
            case .modified: [.modified, .uninstall, .update, .upload]
            case .localOnly: [.localOnly, .uninstall, .upload]
            case .new: [.new, .install, .remove]
            case .obsoleteUninstalled: [.notInstalled]
            case .obsolete: [.obsolete, .uninstall, .upload]
            case .obsoleteModified: [.modified, .uninstall, .upload]
            }
        }

        public func isValid(_ action: Action) -> Bool { actions.contains(action) }
        public var noAction: Action { actions[0] }
    }

    /// The same file from lower-ranked sites this one shadows, by site name.
    var overriddenUpdateSites: [(site: String, file: PluginFile)] = []
    public private(set) var status: Status
    public private(set) var action: Action
    public var updateSite: String?
    public var filename: String
    public var description: String?
    public var executable = false
    public var current: Version?
    public var previous: [Version] = []
    public var filesize: Int64
    public var metadataChanged = false

    public var localFilename: String?
    public var localChecksum: String?
    public var localTimestamp: Int64 = 0

    /// Keyed by the dependency's file name without its version, in insertion order.
    public private(set) var dependencies: [Dependency] = []
    public var links: [String] = []
    public var authors: [String] = []
    public var platforms: [String] = []
    public var categories: [String] = []

    init(updateSite: String?, filename: String, filesize: Int64, checksum: String?, timestamp: Int64, status: Status) {
        self.updateSite = updateSite
        self.filename = filename
        self.filesize = filesize
        if let checksum { current = Version(checksum: checksum, timestamp: timestamp) }
        self.status = status
        action = status.noAction
    }

    /// `completeMetadataFrom`: fills unset metadata from another record.
    func completeMetadata(from other: PluginFile) {
        if description?.isEmpty ?? true { description = other.description }
        if links.isEmpty { links = other.links }
        if authors.isEmpty { authors = other.authors }
        if platforms.isEmpty { platforms = other.platforms }
        if categories.isEmpty { categories = other.categories }
    }

    public func hasPreviousVersion(_ checksum: String) -> Bool {
        if current?.checksum == checksum { return true }
        if previous.contains(where: { $0.checksum == checksum }) { return true }
        return overriddenUpdateSites.contains { $0.file.hasPreviousVersion(checksum) }
    }

    public var overridesOtherUpdateSite: Bool { !overriddenUpdateSites.isEmpty }

    func overridden(by site: String) -> PluginFile? { overriddenUpdateSites.first { $0.site == site }?.file }

    func setOverridden(_ site: String, _ file: PluginFile) {
        if let i = overriddenUpdateSites.firstIndex(where: { $0.site == site }) {
            overriddenUpdateSites[i].file = file
        } else {
            overriddenUpdateSites.append((site, file))
        }
    }

    /// Whether every version is newer than `timestamp` (the file appeared
    /// on its site after the site was last checked).
    func isNewer(than timestamp: Int64) -> Bool {
        if let current, current.timestamp <= timestamp { return false }
        return !previous.contains { $0.timestamp <= timestamp }
    }

    func setVersion(checksum: String, timestamp: Int64) {
        if let current { previous.append(current) }
        let version = Version(checksum: checksum, timestamp: timestamp)
        version.filename = filename
        current = version
    }

    /// Records the local copy's checksum and decides the status.
    public func setLocalVersion(filename: String, checksum: String, timestamp: Int64) {
        localFilename = filename
        if filename != self.filename { metadataChanged = true }
        localChecksum = checksum
        localTimestamp = timestamp
        if let current, checksum == current.checksum {
            if status != .localOnly { status = .installed }
            setNoAction()
            return
        }
        status =
            hasPreviousVersion(checksum)
            ? (current == nil ? .obsolete : .updateable) : (current == nil ? .obsoleteModified : .modified)
        setNoAction()
    }

    func addDependency(filename: String, timestamp: Int64, overrides: Bool) {
        guard !filename.trimmingWhitespace().isEmpty else { return }
        let key = FilenameVersion.strip(filename)
        if let i = dependencies.firstIndex(where: { $0.filename == key }) {
            // The updater compares the stored, already stripped name with the new one.
            let other = dependencies[i]
            if other.filename == filename || other.timestamp >= timestamp { return }
            dependencies[i] = Dependency(filename: key, timestamp: timestamp, overrides: overrides)
            return
        }
        dependencies.append(Dependency(filename: key, timestamp: timestamp, overrides: overrides))
    }

    public func hasDependency(_ filename: String) -> Bool {
        let key = FilenameVersion.strip(filename)
        return dependencies.contains { $0.filename == key }
    }

    func addPlatform(_ platform: String) {
        for part in platform.split(separator: ",", omittingEmptySubsequences: false) {
            let p = part.trimmingWhitespace()
            let name = p == "linux" ? "linux32" : p
            if !name.isEmpty, !platforms.contains(name) { platforms.append(name) }
        }
    }

    func addAuthor(_ author: String) { if !authors.contains(author) { authors.append(author) } }
    func addLink(_ link: String) { if !links.contains(link) { links.append(link) } }
    func addCategory(_ category: String) { if !categories.contains(category) { categories.append(category) } }

    func addPreviousVersion(_ version: Version) {
        if !previous.contains(where: { $0.sameVersion(version) }) { previous.append(Version(copying: version)) }
    }

    func addPreviousVersion(checksum: String, timestamp: Int64, filename: String?, timestampObsolete: Int64) {
        let version = Version(checksum: checksum, timestamp: timestamp)
        version.timestampObsolete = timestampObsolete
        if let filename, !filename.isEmpty { version.filename = filename }
        addPreviousVersion(version)
    }

    public func setNoAction() { action = status.noAction }

    public struct InvalidAction: Error, CustomStringConvertible {
        public let filename: String
        public let action: Action
        public let status: Status
        public var description: String { "Invalid action requested for file \(filename) (\(action.rawValue), \(status.rawValue))" }
    }

    /// Chooses what happens to the file. Only actions its status allows.
    public func setAction(_ action: Action) throws(InvalidAction) {
        guard status.isValid(action) || (action == .remove && overridesOtherUpdateSite) else {
            throw InvalidAction(filename: filename, action: action, status: status)
        }
        self.action = action
    }

    /// The first of `actions` the status allows; false when none.
    @discardableResult
    public func setFirstValidAction(_ actions: Action...) -> Bool {
        for action in actions where status.isValid(action) {
            self.action = action
            return true
        }
        return false
    }

    public func setStatus(_ status: Status) {
        self.status = status
        setNoAction()
    }

    public func localFilename(forDisplay: Bool) -> String {
        guard let localFilename, localFilename != filename else { return filename }
        return forDisplay ? "\(filename) (local: \(localFilename))" : localFilename
    }

    public var unversionedFilename: String { FilenameVersion.strip(filename) }

    public var checksum: String? {
        action == .upload ? localChecksum : (action == .remove ? nil : current?.checksum)
    }

    public var timestamp: Int64 {
        action == .upload
            ? (status == .localOnly && current != nil ? current!.timestamp : localTimestamp)
            : (action == .remove ? 0 : current?.timestamp ?? 0)
    }

    /// The files this one depends on (and, recursively, theirs), leaving out obsolete ones.
    public func fileDependencies(in files: PluginCollection, recursive: Bool) -> [PluginFile] {
        var result: [PluginFile] = recursive ? [self] : []
        var stack: [PluginFile] = [self]
        while let file = stack.popLast() {
            for dependency in file.dependencies {
                guard let other = files[dependency.filename], !other.isObsolete else { continue }
                let seen = result.contains { $0 === other }
                if recursive && !seen { stack.append(other) }
                if !seen { result.append(other) }
            }
        }
        return result
    }

    public var isInstallable: Bool { status.isValid(.install) }
    public var isUpdateable: Bool { status.isValid(.update) }
    public var isUninstallable: Bool { status.isValid(.uninstall) }
    public var isLocallyModified: Bool { status.noAction == .modified }
    public var actionSpecified: Bool { action != status.noAction }

    public var isObsolete: Bool {
        switch status {
        case .obsolete, .obsoleteModified, .obsoleteUninstalled: true
        default: false
        }
    }

    public func isForPlatform(_ platform: String) -> Bool {
        platforms.isEmpty || platforms.contains { Platforms.matches(platform, $0) }
    }

    public func isActivePlatform(_ files: PluginCollection) -> Bool {
        platforms.isEmpty || platforms.contains { files.isActivePlatform($0) }
    }

    public var isLocalOnly: Bool { status == .localOnly }

    /// True also when the file is to be uninstalled.
    public var willNotBeInstalled: Bool {
        switch action {
        case .notInstalled, .new, .uninstall, .remove: true
        default: false
        }
    }

    public var willBeUpToDate: Bool {
        switch action {
        case .installed, .install, .update, .upload, .localOnly: true
        default: false
        }
    }

    /// `isUpdateable(evenForcedUpdates)`: whether an update would change the file.
    public func wantsUpdate(evenForced: Bool) -> Bool {
        action == .update || action == .install || status == .updateable || status == .obsolete
            || (evenForced && (status.isValid(.update) || status == .obsoleteModified))
    }

    /// Marks the file, and what it depends on, for installation or update.
    @discardableResult
    public func stageForUpdate(_ files: PluginCollection, evenForced: Bool) -> Bool {
        if !evenForced && status == .modified { return false }
        guard setFirstValidAction(.update, .install) else { return false }
        for file in fileDependencies(in: files, recursive: true) {
            if !evenForced && (file.status == .modified || file.status == .obsoleteModified) { continue }
            file.setFirstValidAction(.update, .install)
        }
        return true
    }

    /// `removeFromUpdateSite`: what disabling or removing a site does to its files.
    func removeFromUpdateSite(_ site: String, _ files: PluginCollection) -> [String] {
        guard site == updateSite else { return [] }
        var staleNames: [String] = []
        switch status {
        case .localOnly: return []
        case .new, .notInstalled, .obsoleteUninstalled: files.remove(self)
        default: break
        }
        guard let overridden = overriddenUpdateSites.last?.file else {
            setStatus(.obsolete)
            action = .uninstall
            return []
        }
        files.add(overridden)
        if checksum == overridden.checksum && filename == overridden.filename {
            overridden.setStatus(.installed)
            overridden.action = .installed
        } else if overridden.current != nil {
            overridden.setStatus(.modified)
            overridden.action = .update
            if filename != overridden.filename { staleNames.append(filename) }
        } else {
            overridden.setStatus(.obsolete)
            overridden.action = .uninstall
            overridden.filename = filename
        }
        return staleNames
    }
}

extension StringProtocol {
    /// Java's `String.trim()`: drops characters up to U+0020 at both ends.
    func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
            let last = scalars.lastIndex(where: { $0.value > 0x20 })
        else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }
}
