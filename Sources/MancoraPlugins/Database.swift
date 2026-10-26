/// Reads a `db.xml.gz` into a collection: a port of the updater's
/// `XMLFileReader`, including how a file from a higher-ranked site shadows
/// the same file from a lower one.
struct DatabaseReader {
    let files: PluginCollection
    /// The site being read; nil for the installation's own database.
    let site: String?
    /// The site's timestamp when it was last read: newer files are new.
    let timestamp: Int64

    final class State {
        var current: PluginFile?
        var body = ""
        var filesFromThisSite: [PluginFile] = []
    }

    func read(_ xml: [UInt8]) throws {
        let state = State()
        for event in try XML.parse(xml) {
            switch event {
            case .start(let name, let attributes):
                try start(name, Dictionary(attributes.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }), state)
            case .end(let name):
                end(name, state)
            case .text(let text):
                state.body += text
            }
        }
    }

    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    private func long(_ attributes: [String: String], _ key: String) throws -> Int64 {
        guard let value = attributes[key] else { return 0 }
        guard let number = Int64(value) else { throw Malformed(description: "\(key)=\"\(value)\" is not a number") }
        return number
    }

    private func start(_ tag: String, _ atts: [String: String], _ state: State) throws {
        switch tag {
        case "plugin":
            // Old databases name no site: their files came from Fiji's.
            let updateSite = site ?? atts["update-site"] ?? "Fiji"
            let file = PluginFile(
                updateSite: updateSite, filename: atts["filename"] ?? "", filesize: -1, checksum: nil, timestamp: 0,
                status: .notInstalled)
            if atts["executable"]?.lowercased() == "true" { file.executable = true }
            state.current = file
        case "previous-version":
            state.current?.addPreviousVersion(
                checksum: atts["checksum"] ?? "", timestamp: try long(atts, "timestamp"), filename: atts["filename"],
                timestampObsolete: try long(atts, "timestamp-obsolete"))
        case "version":
            state.current?.setVersion(checksum: atts["checksum"] ?? "", timestamp: try long(atts, "timestamp"))
            state.current?.filesize = try long(atts, "filesize")
        case "dependency":
            state.current?.addDependency(
                filename: atts["filename"] ?? "", timestamp: try long(atts, "timestamp"), overrides: atts["overrides"] == "true")
        case "update-site", "disabled-update-site":
            guard site == nil else { break }
            guard let timestamp = atts["timestamp"].flatMap({ Int64($0) }) else {
                throw Malformed(description: "update site \(atts["name"] ?? "") has no timestamp")
            }
            let updateSite = UpdateSite(
                name: atts["name"] ?? "", url: atts["url"] ?? "", host: atts["ssh-host"],
                uploadDirectory: atts["upload-directory"], description: atts["description"], maintainer: atts["maintainer"],
                timestamp: timestamp)
            if let official = atts["official"] { updateSite.isOfficial = official.lowercased() == "true" }
            updateSite.keepURL = atts["keep-url"]?.lowercased() == "true"
            updateSite.isActive = tag == "update-site"
            // A site already known keeps its rank and official flag.
            files.addSite(updateSite)
        default:
            break
        }
    }

    private func end(_ tag: String, _ state: State) {
        defer { state.body = "" }
        guard let current = state.current else { return }
        switch tag {
        case "description": current.description = state.body
        case "author": current.addAuthor(state.body)
        case "platform": current.addPlatform(state.body)
        case "category": current.addCategory(state.body)
        case "link": current.addLink(state.body)
        case "plugin":
            finish(current, state)
            state.current = nil
        default: break
        }
    }

    private func finish(_ incoming: PluginFile, _ state: State) {
        var current = incoming
        Self.fillPreviousFilenames(current)
        if current.current == nil {
            current.setStatus(.obsoleteUninstalled)
        } else if current.isNewer(than: timestamp) {
            current.setStatus(.new)
            try? current.setAction(current.isActivePlatform(files) ? .install : .new)
        }
        let existing = files[current.filename]
        if site == nil, let name = current.updateSite, files.site(named: name, evenDisabled: false) == nil {
            // A file of an unknown or disabled site.
            return
        }
        guard var file = existing else {
            files.add(current)
            state.filesFromThisSite.append(current)
            return
        }
        if state.filesFromThisSite.contains(where: { $0 === file }) {
            // Old-style sites listed Jama-1.0.2.jar and Jama.jar separately.
            if file.isObsolete {
                files.remove(named: file.filename)
                swap(&file, &current)
                files.add(file)
                state.filesFromThisSite.append(file)
            }
            Self.addPreviousVersions(from: current, to: file)
        } else if file.isObsolete {
            if let fileSite = file.updateSite {
                for (name, overridden) in file.overriddenUpdateSites { current.setOverridden(name, overridden) }
                current.setOverridden(fileSite, file)
            }
            files.add(current)
            state.filesFromThisSite.append(current)
        } else if current.isObsolete {
            if let currentSite = current.updateSite { file.setOverridden(currentSite, current) }
        } else if rank(site) >= rank(file.updateSite) {
            if site != file.updateSite {
                for (name, overridden) in file.overriddenUpdateSites { current.setOverridden(name, overridden) }
                if let fileSite = file.updateSite, fileSite != site { current.setOverridden(fileSite, file) }
            }
            if let local = file.localFilename { current.localFilename = local }
            current.completeMetadata(from: file)
            files.add(current)
            state.filesFromThisSite.append(current)
        } else {
            file.setOverridden(site ?? "", current)
        }
    }

    private func rank(_ name: String?) -> Int {
        guard let name, let site = files.site(named: name, evenDisabled: false) else { return -1 }
        return site.rank
    }

    /// Every version gets a file name: the newest one's, unless it names its own.
    static func fillPreviousFilenames(_ file: PluginFile) {
        var versions: [PluginFile.Version] = []
        if let current = file.current { versions.append(current) }
        versions += file.previous
        // Collections.sort is stable: newest first, ties in their order.
        let sorted = versions.enumerated().sorted { a, b in
            a.element.timestamp != b.element.timestamp ? a.element.timestamp > b.element.timestamp : a.offset < b.offset
        }.map(\.element)
        var filename = file.filename
        for version in sorted {
            if let own = version.filename { filename = own } else { version.filename = filename }
        }
    }

    static func addPreviousVersions(from: PluginFile, to: PluginFile) {
        if let current = from.current {
            to.addPreviousVersion(
                checksum: current.checksum, timestamp: current.timestamp, filename: from.localFilename(forDisplay: false),
                timestampObsolete: 0)
        }
        for version in from.previous { to.addPreviousVersion(version) }
    }
}

/// Writes a collection as a `db.xml.gz`: a port of the updater's
/// `XMLFileWriter`. The local form lists the sites and which site each
/// file came from; a site's own form doesn't.
enum DatabaseWriter {
    static let dtd = """
        <!DOCTYPE pluginRecords [
        <!ELEMENT pluginRecords ((update-site | disabled-update-site)*, plugin*)>
        <!ELEMENT update-site EMPTY>
        <!ELEMENT disabled-update-site EMPTY>
        <!ELEMENT plugin (platform*, category*, version?, previous-version*)>
        <!ELEMENT version (description?, dependency*, link*, author*)>
        <!ELEMENT previous-version EMPTY>
        <!ELEMENT description (#PCDATA)>
        <!ELEMENT dependency EMPTY>
        <!ELEMENT link (#PCDATA)>
        <!ELEMENT author (#PCDATA)>
        <!ELEMENT platform (#PCDATA)>
        <!ELEMENT category (#PCDATA)>
        <!ATTLIST update-site name CDATA #REQUIRED>
        <!ATTLIST update-site url CDATA #REQUIRED>
        <!ATTLIST update-site keep-url CDATA #IMPLIED>
        <!ATTLIST update-site official CDATA #IMPLIED>
        <!ATTLIST update-site ssh-host CDATA #IMPLIED>
        <!ATTLIST update-site upload-directory CDATA #IMPLIED>
        <!ATTLIST update-site description CDATA #IMPLIED>
        <!ATTLIST update-site maintainer CDATA #IMPLIED>
        <!ATTLIST update-site timestamp CDATA #REQUIRED>
        <!ATTLIST disabled-update-site name CDATA #REQUIRED>
        <!ATTLIST disabled-update-site url CDATA #REQUIRED>
        <!ATTLIST disabled-update-site keep-url CDATA #IMPLIED>
        <!ATTLIST disabled-update-site official CDATA #IMPLIED>
        <!ATTLIST disabled-update-site ssh-host CDATA #IMPLIED>
        <!ATTLIST disabled-update-site upload-directory CDATA #IMPLIED>
        <!ATTLIST disabled-update-site description CDATA #IMPLIED>
        <!ATTLIST disabled-update-site maintainer CDATA #IMPLIED>
        <!ATTLIST disabled-update-site timestamp CDATA #REQUIRED>
        <!ATTLIST plugin update-site CDATA #IMPLIED>
        <!ATTLIST plugin filename CDATA #REQUIRED>
        <!ATTLIST plugin executable CDATA #IMPLIED>
        <!ATTLIST dependency filename CDATA #REQUIRED>
        <!ATTLIST dependency timestamp CDATA #IMPLIED>
        <!ATTLIST dependency overrides CDATA #IMPLIED>
        <!ATTLIST version timestamp CDATA #REQUIRED>
        <!ATTLIST version checksum CDATA #REQUIRED>
        <!ATTLIST version filesize CDATA #REQUIRED>
        <!ATTLIST previous-version filename CDATA #IMPLIED>
        <!ATTLIST previous-version timestamp CDATA #REQUIRED>
        <!ATTLIST previous-version timestamp-obsolete CDATA #IMPLIED>
        <!ATTLIST previous-version checksum CDATA #REQUIRED>]>

        """

    /// The uncompressed XML. `timestampObsolete` stamps versions this write retires.
    static func xml(_ files: PluginCollection, local: Bool, timestampObsolete: Int64 = UpdaterTime.now) -> [UInt8] {
        var w = XMLWriter()
        w.raw(dtd)
        w.start("pluginRecords")
        if local {
            for site in files.sites {
                var attributes: [(String, String)] = [("name", site.name), ("url", site.url)]
                if site.keepURL { attributes.append(("keep-url", "true")) }
                attributes.append(("official", site.isOfficial ? "true" : "false"))
                if let host = site.host { attributes.append(("ssh-host", host)) }
                if let directory = site.uploadDirectory { attributes.append(("upload-directory", directory)) }
                // The updater adds the maintainer as a second "description",
                // and the serializer keeps the last value of a repeated attribute.
                if let description = site.maintainer ?? site.siteDescription { attributes.append(("description", description)) }
                attributes.append(("timestamp", "\(site.timestamp)"))
                w.element((site.isActive ? "" : "disabled-") + "update-site", attributes)
            }
        }
        for file in files.managedFiles { write(file, local: local, timestampObsolete: timestampObsolete, to: &w) }
        w.end("pluginRecords")
        w.endDocument()
        return w.bytes
    }

    static func write(_ file: PluginFile, local: Bool, timestampObsolete: Int64, to w: inout XMLWriter) {
        var attributes: [(String, String)] = []
        if local { attributes.append(("update-site", file.updateSite ?? "")) }
        attributes.append(("filename", file.filename))
        if file.executable { attributes.append(("executable", "true")) }
        w.start("plugin", attributes)
        for platform in file.platforms { w.element("platform", text: platform) }
        for category in file.categories { w.element("category", text: category) }
        if let checksum = file.checksum {
            w.start("version", [("checksum", checksum), ("timestamp", "\(file.timestamp)"), ("filesize", "\(file.filesize)")])
            if let description = file.description { w.element("description", text: description) }
            for dependency in file.dependencies {
                var attributes = [("filename", dependency.filename), ("timestamp", "\(dependency.timestamp)")]
                if dependency.overrides { attributes.append(("overrides", "true")) }
                w.element("dependency", attributes)
            }
            for link in file.links { w.element("link", text: link) }
            for author in file.authors { w.element("author", text: author) }
            w.end("version")
        }
        if let current = file.current, current.checksum != file.checksum {
            current.timestampObsolete = timestampObsolete
            file.addPreviousVersion(current)
        }
        for version in file.previous {
            var attributes = [
                ("timestamp", "\(version.timestamp)"), ("timestamp-obsolete", "\(version.timestampObsolete)"),
                ("checksum", version.checksum),
            ]
            if let filename = version.filename { attributes.append(("filename", filename)) }
            w.element("previous-version", attributes)
        }
        w.end("plugin")
    }
}
