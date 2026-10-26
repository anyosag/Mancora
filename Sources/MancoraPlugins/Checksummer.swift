import Foundation

/// Finds the files of an installation and how each compares with the
/// update sites' records: a port of the updater's `Checksummer`, with its
/// `.checksums` cache (the same file Fiji keeps, so either can reuse it).
struct Checksummer {
    let files: PluginCollection
    let root: URL
    let isWindows: Bool
    var cache: [String: (checksum: String, timestamp: Int64)] = [:]
    var cacheLoaded = false

    init(files: PluginCollection, root: URL) {
        self.files = files
        self.root = root
        isWindows = Platforms.isWindows(Platforms.current)
    }

    /// Folders the updater looks in, with the extensions it considers ("" is any).
    static let directories: [(dirs: [String], extensions: Set<String>)] = [
        (["jars", "retro", "misc"], [".jar", ".class"]),
        (["config"], [".toml", ".class", ".py", ".txt"]),
        (["plugins"], [".jar", ".class", ".txt", ".ijm", ".py", ".rb", ".clj", ".js", ".bsh", ".groovy", ".gvy"]),
        (["scripts"], [".m", ".ijm", ".py", ".rb", ".clj", ".js", ".bsh", ".groovy", ".gvy"]),
        (["macros"], [".txt", ".ijm", ".png"]),
        (["models"], [""]),
        (["luts"], [".lut"]),
        (["images"], [".png", ".tif", ".txt", ".ico"]),
        (["Contents"], [".icns", ".plist"]),
        (["lib"], [""]),
        (["config"], [""]),
        (["licenses"], [""]),
        (["mm"], [""]),
        (["mmautofocus"], [""]),
        (["mmplugins"], [""]),
    ]

    struct Candidate {
        let path: String
        let url: URL
        var timestamp: Int64 = 0
        var checksum: String?
    }

    /// Paths grouped by their name without version, in the order found.
    private var queue: [(unversioned: String, candidates: [Candidate])] = []

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(path).path, isDirectory: &directory) && directory.boolValue
    }

    mutating func queue(_ path: String) {
        let unversioned = FilenameVersion.strip(path)
        // Backups left by updating a launcher stay out.
        if unversioned.contains(".old") { return }
        let candidate = Candidate(path: path, url: url(path))
        if let i = queue.firstIndex(where: { $0.unversioned == unversioned }) {
            if !queue[i].candidates.contains(where: { $0.path == path }) { queue[i].candidates.append(candidate) }
        } else {
            queue.append((unversioned, [candidate]))
        }
    }

    mutating func queueDirectory(_ dir: String, _ extensions: Set<String>) {
        guard exists(dir), let items = try? FileManager.default.contentsOfDirectory(atPath: url(dir).path) else { return }
        for item in items.sorted() {
            let path = dir + "/" + item
            if item.hasPrefix(".") { continue }
            if isDirectory(path) {
                queueDirectory(path, extensions)
                continue
            }
            if !extensions.contains("") {
                guard let dot = item.lastIndex(of: "."), extensions.contains(String(item[dot...])) else { continue }
            }
            if exists(path) { queue(path) }
        }
    }

    mutating func initializeQueue() {
        queue = []
        for path in ["README.md", "WELCOME.md", "fiji", "fiji.bat", "ImageJ.sh"] + Platforms.launchers.keys.sorted()
        where exists(path) {
            queue(path)
        }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for item in items.sorted() where item.hasSuffix(".app") && isDirectory(item) { queueDirectory(item, [""]) }
        }
        for (dirs, extensions) in Self.directories {
            for dir in dirs { queueDirectory(dir, extensions) }
        }
        for file in files.files where !queue.contains(where: { $0.unversioned == file.unversionedFilename }) {
            queue(file.filename)
        }
    }

    /// `updateFromLocal`: checksums every file and sets each record's status.
    mutating func updateFromLocal() {
        initializeQueue()
        for i in queue.indices { handle(i) }
        writeCache()
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    mutating func handle(_ index: Int) {
        var candidates = queue[index].candidates
        let unversioned = queue[index].unversioned
        for i in candidates.indices where FileManager.default.fileExists(atPath: candidates[i].url.path) {
            let date = Self.modificationDate(candidates[i].url) ?? Date(timeIntervalSince1970: 0)
            candidates[i].timestamp = UpdaterTime.timestamp(date, timeZone: files.timeZone)
            candidates[i].checksum = try? digest(candidates[i].path, candidates[i].url, candidates[i].timestamp)
        }
        if candidates.count == 1 {
            handle(candidates[0])
            return
        }
        // Several versions of one file.
        func modified(_ c: Candidate) -> Date { Self.modificationDate(c.url) ?? .distantPast }
        let chosen: Candidate
        if let object = files[unversioned], !object.isObsolete, let current = object.current {
            var upToDate: [Candidate] = [], obsolete: [Candidate] = [], modifiedLocally: [Candidate] = []
            for c in candidates {
                if c.checksum == current.checksum {
                    upToDate.append(c)
                } else if let checksum = c.checksum, object.hasPreviousVersion(checksum) {
                    obsolete.append(c)
                } else {
                    modifiedLocally.append(c)
                }
            }
            // Newest first (a stable sort, as Java's).
            func newestFirst(_ list: [Candidate]) -> [Candidate] {
                list.enumerated().sorted { a, b in
                    let x = modified(a.element), y = modified(b.element)
                    return x != y ? x > y : a.offset < b.offset
                }.map(\.element)
            }
            upToDate = newestFirst(upToDate)
            obsolete = newestFirst(obsolete)
            modifiedLocally = newestFirst(modifiedLocally)
            if !upToDate.isEmpty {
                chosen = Self.pickNewest(&upToDate)
            } else if !obsolete.isEmpty {
                chosen = Self.pickNewest(&obsolete)
            } else {
                chosen = Self.pickNewest(&modifiedLocally)
            }
            for (list, adjective) in [(modifiedLocally, "locally-modified "), (obsolete, "obsolete "), (upToDate, "up-to-date ")]
            where !list.isEmpty {
                files.conflicts.append(
                    PluginCollection.Conflict(
                        filename: chosen.path,
                        message: "Multiple \(adjective)versions of \(chosen.path) exist: \(list.map(\.path).joined(separator: ", "))"))
            }
        } else {
            // Local-only: the newest wins.
            var pick: Candidate?
            for c in candidates {
                if pick == nil || (modified(c) > modified(pick!) && pick!.path == FilenameVersion.strip(pick!.path)) { pick = c }
            }
            chosen = pick!
            let others = candidates.filter { $0.path != chosen.path }.map(\.path)
            files.conflicts.append(
                PluginCollection.Conflict(
                    filename: chosen.path, message: "Multiple versions of \(chosen.path) exist: \(others.joined(separator: ", "))"))
        }
        handle(chosen)
    }

    /// The newest, unless that's the unversioned name and there's another.
    static func pickNewest(_ list: inout [Candidate]) -> Candidate {
        var index = 0
        if list.count > 1, list[0].path == FilenameVersion.strip(list[0].path) { index += 1 }
        return list.remove(at: index)
    }

    mutating func handle(_ candidate: Candidate) {
        guard var checksum = candidate.checksum else {
            guard let object = files[candidate.path] else { return }
            switch object.status {
            case .obsolete, .obsoleteModified: object.setStatus(.obsoleteUninstalled)
            case .installed, .modified, .updateable: object.setStatus(.notInstalled)
            case .localOnly: files.remove(named: candidate.path)
            case .new, .notInstalled, .obsoleteUninstalled: break
            }
            return
        }
        guard let object = files[candidate.path] else {
            let size = ((try? FileManager.default.attributesOfItem(atPath: candidate.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let file = PluginFile(
                updateSite: nil, filename: candidate.path, filesize: size, checksum: checksum, timestamp: candidate.timestamp,
                status: .localOnly)
            file.localFilename = candidate.path
            file.localChecksum = checksum
            file.localTimestamp = candidate.timestamp
            if (!isWindows && FileManager.default.isExecutableFile(atPath: candidate.url.path)) || candidate.path.hasSuffix(".exe") {
                file.executable = true
            }
            Self.guessPlatform(file)
            files.add(file)
            return
        }
        // The digests an older updater computed matter only for a file that
        // isn't the site's current version, and cost three more passes over a
        // jar: they're computed (and cached, as the updater caches them) then.
        if !object.hasPreviousVersion(checksum) {
            // The site may record the digest an older updater computed.
            if let older = obsoleteDigests(candidate, checksum).first(where: { object.hasPreviousVersion($0) }) { checksum = older }
        } else if let current = object.current, current.checksum != checksum,
            obsoleteDigests(candidate, checksum).contains(current.checksum)
        {
            checksum = current.checksum
        }
        object.setLocalVersion(filename: candidate.path, checksum: checksum, timestamp: candidate.timestamp)
        if object.status == .obsoleteUninstalled { object.setStatus(.obsolete) }
    }

    /// A local-only file in a platform folder (`jars/linux64/...`) belongs to that platform.
    static func guessPlatform(_ file: PluginFile) {
        var platform: String
        if file.executable {
            guard let p = Platforms.platformForLauncher(file.filename) else { return }
            platform = p
        } else {
            let rest: Substring
            if file.filename.hasPrefix("jars/") {
                rest = file.filename.dropFirst(5)
            } else if file.filename.hasPrefix("lib/") {
                rest = file.filename.dropFirst(4)
            } else if file.filename.hasPrefix("mm/") {
                rest = file.filename.dropFirst(3)
            } else {
                return
            }
            guard let slash = rest.firstIndex(of: "/") else { return }
            platform = String(rest[..<slash])
        }
        if platform == "linux" { platform = "linux32" }
        if Platforms.known.contains(platform) { file.addPlatform(platform) }
    }

    // MARK: The checksum cache

    mutating func readCache() {
        cacheLoaded = true
        guard let text = try? String(contentsOf: url(".checksums"), encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            guard let space = line.firstIndex(of: " ") else { continue }
            let rest = line[line.index(after: space)...]
            guard let space2 = rest.firstIndex(of: " "), let timestamp = Int64(rest[..<space2]) else { continue }
            cache[String(rest[rest.index(after: space2)...])] = (String(line[..<space]), timestamp)
        }
    }

    func writeCache() {
        guard cacheLoaded else { return }
        var out = ""
        // A TreeMap in the updater: sorted by UTF-16 code unit.
        for key in cache.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) })
        where key.hasPrefix(":") || exists(key) {
            let entry = cache[key]!
            out += "\(entry.checksum) \(entry.timestamp) \(key)\n"
        }
        try? out.write(to: url(".checksums"), atomically: true, encoding: .utf8)
    }

    mutating func digest(_ path: String, _ file: URL, _ timestamp: Int64) throws -> String {
        if !cacheLoaded { readCache() }
        var contents: [UInt8]?
        let checksum: String
        if let cached = cache[path], cached.timestamp == timestamp {
            checksum = cached.checksum
        } else {
            let bytes = [UInt8](try Data(contentsOf: file))
            contents = bytes
            checksum =
                path == "plugins/Fiji_Updater.jar"
                ? try FijiChecksum.jarDigest(bytes, properties: false, manifests: false, keepOnlyMainClass: false)
                : try FijiChecksum.digest(path: path, contents: bytes)
            cache[path] = (checksum, timestamp)
        }
        lastContents = path.hasSuffix(".jar") ? contents.map { (path, $0) } : nil
        return checksum
    }

    /// The jar just digested, kept for its obsolete digests.
    private var lastContents: (path: String, bytes: [UInt8])?

    /// The digests older updaters computed for a jar with `checksum` (none for other files), cached as `:<checksum>`.
    mutating func obsoleteDigests(_ candidate: Candidate, _ checksum: String) -> [String] {
        guard candidate.path.hasSuffix(".jar") else { return [] }
        if let cached = cache[":" + checksum] { return cached.checksum.split(separator: ":").map(String.init) }
        let bytes = lastContents?.path == candidate.path ? lastContents?.bytes : (try? [UInt8](Data(contentsOf: candidate.url)))
        guard let bytes, let obsoletes = try? FijiChecksum.obsoleteDigests(path: candidate.path, contents: bytes) else { return [] }
        cache[":" + checksum] = (obsoletes.joined(separator: ":"), candidate.timestamp)
        return obsoletes
    }

    /// Records the checksums of files just installed (each checked against
    /// its site's), so the next check needn't read them again.
    mutating func remember(_ installed: [(path: String, checksum: String)]) {
        if !cacheLoaded { readCache() }
        for (path, checksum) in installed where !checksum.isEmpty {
            guard let date = Self.modificationDate(url(path)) else { continue }
            cache[path] = (checksum, UpdaterTime.timestamp(date, timeZone: files.timeZone))
        }
        writeCache()
    }
}
