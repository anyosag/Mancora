import Foundation
import MancoraSupport
import MancoraUpdate
import Testing

@testable import MancoraPlugins

/// The update-site fixtures: an installation, three sites and what Fiji's
/// own updater (imagej-updater, run by Tools/parity/updater/UpdaterOracle.java)
/// decided at each step. Mancora replays the steps and must agree.
enum UpdaterFixture {
    static let folder: URL = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast()
        return URL(fileURLWithPath: parts.joined(separator: "/") + "/Fixtures/updater")
    }()
    static let base = "https://sites.test/"

    static var expected: [String: Any] {
        let data = try! Data(contentsOf: folder.appendingPathComponent("expected.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Serves the sites from the fixtures, with the oracle's Last-Modified.
    struct Client: HTTPClient {
        let lastModified: Date

        func data(from url: URL) async throws -> Data { try await dataAndLastModified(from: url).data }

        func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?) {
            let path = String(url.absoluteString.dropFirst(UpdaterFixture.base.count)).removingPercentEncoding!
            let file = UpdaterFixture.folder.appendingPathComponent("sites").appendingPathComponent(path)
            guard let data = try? Data(contentsOf: file) else { throw UpdateError.httpStatus(404, url: url.absoluteString) }
            return (data, lastModified)
        }
    }

    /// A fresh copy of the installation, with the oracle's modification times and site list.
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-updater-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("initial"), to: root)
        let mtimes = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("mtimes.json"))) as! [String: Double]
        for (path, millis) in mtimes {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: millis / 1000)], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        let template = try String(contentsOf: folder.appendingPathComponent("local-db.xml"), encoding: .utf8)
        try Data(Deflate.gzip(Array(template.replacingOccurrences(of: "@BASE@", with: base).utf8)))
            .write(to: root.appendingPathComponent("db.xml.gz"))
        return root
    }

    static let utc = TimeZone(identifier: "UTC")!

    static func manager(_ root: URL) throws -> PluginManager {
        // The oracle clears the checksum cache before each read.
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".checksums"))
        return try PluginManager(root: root, activePlatforms: ["linux64"], timeZone: utc)
    }

    /// Each file as the oracle records it.
    static func records(_ files: PluginCollection) -> [[String: String]] {
        files.files.sorted { $0.filename < $1.filename }.map { f in
            [
                "filename": f.filename, "status": f.status.rawValue, "action": f.action.rawValue, "site": f.updateSite ?? "null",
                "local": f.localFilename ?? "null", "overridden": f.overriddenUpdateSites.map(\.site).joined(separator: ","),
            ]
        }
    }

    static func expectedRecords(_ step: String) -> [[String: String]] {
        (expected[step] as! [[String: Any]]).map { r in
            [
                "filename": r["filename"] as! String, "status": r["status"] as! String, "action": r["action"] as! String,
                "site": r["site"] as? String ?? "null", "local": r["local"] as? String ?? "null",
                "overridden": (r["overridden"] as! [String]).joined(separator: ","),
            ]
        }
    }

    /// Every file in the folder: its SHA-1, and whether it's executable.
    static func tree(_ root: URL) throws -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if path == "db.xml.gz" || path == ".checksums" { continue }
            let sha = hexString(SHA1.hash([UInt8](try Data(contentsOf: url))))
            #if os(Windows)
            out.append("\(path) \(sha)")
            #else
            out.append("\(path) \(sha) \(fm.isExecutableFile(atPath: url.path))")
            #endif
        }
        return out.sorted()
    }

    static func expectedTree(_ step: String) -> [String] {
        (expected[step] as! [[String: Any]]).map { r in
            #if os(Windows)
            "\(r["path"] as! String) \(r["sha1"] as! String)"
            #else
            "\(r["path"] as! String) \(r["sha1"] as! String) \(r["executable"] as! Bool)"
            #endif
        }.sorted()
    }

    static func database(_ root: URL) throws -> String {
        let bytes = try Inflate.gzip([UInt8](Data(contentsOf: root.appendingPathComponent("db.xml.gz")))[...])
        return String(decoding: bytes, as: UTF8.self)
    }

    static func expectedDatabase(_ step: String) -> String {
        (expected[step] as! String).replacingOccurrences(of: "@BASE@", with: base)
    }

    static func sitesWithWarnings(_ manager: PluginManager) -> [String] {
        manager.sites.map(\.name).filter { name in manager.warnings.contains { $0.contains("site '\(name)'") } }
    }
}

@Suite("Update sites behave as Fiji's updater")
struct UpdaterParityTests {
    typealias F = UpdaterFixture

    @Test func checksumsMatchTheUpdater() throws {
        for case let entry as [String: Any] in F.expected["checksums"] as! [Any] {
            guard let file = entry["file"] as? String else { continue }
            let bytes = [UInt8](try Data(contentsOf: F.folder.appendingPathComponent("checksums/\(file)")))
            if let path = entry["path"] as? String {
                #expect(try FijiChecksum.digest(path: path, contents: bytes) == entry["digest"] as? String, "\(path)")
                continue
            }
            #expect(try FijiChecksum.digest(path: "jars/\(file)", contents: bytes) == entry["digest"] as? String, "\(file)")
            #expect(
                try FijiChecksum.jarDigest(bytes, properties: false, manifests: false, keepOnlyMainClass: false)
                    == entry["plain"] as? String, "\(file) plain")
            #expect(try FijiChecksum.obsoleteDigests(path: "jars/\(file)", contents: bytes) == entry["obsolete"] as? [String], "\(file) obsolete")
        }
    }

    @Test func everyDownloadMatchesItsSitesChecksum() throws {
        for site in ["Alpha", "Beta"] {
            let collection = PluginCollection(root: nil, activePlatforms: ["linux64"], timeZone: F.utc)
            let s = UpdateSite(name: site, url: F.base + site + "/")
            s.isActive = true
            collection.addSite(s)
            let gz = try Data(contentsOf: F.folder.appendingPathComponent("sites/\(site)/db.xml.gz"))
            try collection.readSiteDatabase(s, xml: try PluginCollection.gunzip([UInt8](gz)))
            for file in collection.files where file.current != nil {
                let download = F.folder.appendingPathComponent("sites/\(site)/\(file.filename)-\(file.timestamp)")
                let data = [UInt8](try Data(contentsOf: download))
                try PluginManager.verify(file, data)
            }
        }
    }

    @Test func installingAndDisablingASiteAsFijiDoes() async throws {
        let root = try F.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = F.Client(lastModified: Date(timeIntervalSince1970: (F.expected["lastModified"] as! Double) / 1000))

        // 1. Read the sites and checksum the folder.
        var manager = try F.manager(root)
        try await manager.refresh(client: client)
        #expect(F.sitesWithWarnings(manager) == F.expected["warnings1"] as! [String])
        #expect(F.records(manager.files) == F.expectedRecords("refresh"))
        #expect(manager.files.conflicts.map(\.filename) == F.expected["refreshConflicts"] as! [String])

        // 2. Dependencies of what's planned are added.
        let (_, conflicts) = manager.plan()
        #expect(conflicts.map(\.description) == F.expected["resolveConflicts"] as! [String])
        #expect(F.records(manager.files) == F.expectedRecords("resolved"))

        // 3. Install.
        try await manager.apply(client: client)
        #expect(try F.tree(root) == F.expectedTree("installed"))
        #expect(try F.database(root) == F.expectedDatabase("installedDatabase"))

        // 4. Read again.
        manager = try F.manager(root)
        try await manager.refresh(client: client)
        #expect(F.records(manager.files) == F.expectedRecords("afterInstall"))

        // 5. Disable Beta and apply.
        try manager.setActive("Beta", false)
        #expect(F.records(manager.files) == F.expectedRecords("betaDisabled"))
        try await manager.apply(client: client)
        #expect(try F.tree(root) == F.expectedTree("betaRemoved"))
        #expect(try F.database(root) == F.expectedDatabase("betaRemovedDatabase"))

        manager = try F.manager(root)
        try await manager.refresh(client: client)
        #expect(F.records(manager.files) == F.expectedRecords("final"))
    }

    @Test func aDownloadThatDoesNotMatchChangesNothing() async throws {
        let root = try F.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        struct Corrupting: HTTPClient {
            let inner: UpdaterFixture.Client
            func data(from url: URL) async throws -> Data {
                var data = try await inner.data(from: url)
                if url.absoluteString.hasSuffix("new-macro.ijm-20240601000000") { data[0] ^= 1 }
                return data
            }
            func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?) {
                try await inner.dataAndLastModified(from: url)
            }
        }
        let client = Corrupting(inner: F.Client(lastModified: Date(timeIntervalSince1970: 1_719_835_200)))
        let manager = try F.manager(root)
        try await manager.refresh(client: client)
        let before = try F.tree(root)
        await #expect(throws: PluginManager.InstallError.self) { try await manager.apply(client: client) }
        #expect(try F.tree(root) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("update").path))
    }
}

@Suite("Update-site building blocks")
struct UpdaterUnitTests {
    @Test func versionsAreStrippedAsSciJavaDoes() {
        // What org.scijava.util.FileUtils.stripFilenameVersion returns (scijava-common 2.99.2).
        let cases = [
            "jars/foo-1.2.3.jar": "jars/foo.jar", "jars/foo.jar": "jars/foo.jar", "jars/ij-1.54p.jar": "jars/ij.jar",
            "jars/bio-formats/formats-gpl-7.3.1.jar": "jars/bio-formats/formats-gpl.jar",
            "jars/jogl-all-2.3.2-natives-linux-amd64.jar": "jars/jogl-all-natives-linux-amd64.jar",
            "jars/scijava-common-2.99.2-SNAPSHOT.jar": "jars/scijava-common.jar", "jars/foo-20240101.jar": "jars/foo.jar",
            "macros/a-1.0.ijm": "macros/a-1.0.ijm", "jars/j3dcore-1.6.0-scijava-2.jar": "jars/j3dcore.jar",
            "jars/x-1.0-sources.jar": "jars/x-sources.jar", "jars/x-1.0.jar-old": "jars/x.jar-old", "jars/a-b-c.jar": "jars/a-b-c.jar",
            "jars/lib-2.0b3.jar": "jars/lib.jar",
            "jars/natives-1.0-natives-windows-x86_64.jar": "jars/natives-natives-windows-x86_64.jar",
        ]
        for (name, stripped) in cases { #expect(FilenameVersion.strip(name) == stripped, "\(name)") }
    }

    @Test func platformsMatchTheirGroups() {
        #expect(Platforms.matches("linux64", "linuxx"))
        #expect(Platforms.matches("macos-arm64", "macosx"))
        #expect(!Platforms.matches("win64", "linuxx"))
        #expect(Platforms.known.contains("win-arm64"))
        #expect(Platforms.platformForLauncher("Fiji.app/Contents/MacOS/fiji") == "macosx")
    }

    @Test func xmlEventsAreWhatSAXReports() throws {
        // Whitespace between elements is ignorable only where the DTD says so.
        let withDTD = Array("<!DOCTYPE r [<!ELEMENT r (e)*><!ELEMENT e (#PCDATA)>]>\n<r>\n  <e> a &amp; b </e>\n</r>".utf8)
        #expect(try XML.parse(withDTD) == [.start(name: "r", attributes: []), .start(name: "e", attributes: []), .text(" a & b "), .end(name: "e"), .end(name: "r")])
        let without = Array("<r>\n  <e>x</e></r>".utf8)
        #expect(try XML.parse(without) == [.start(name: "r", attributes: []), .text("\n  "), .start(name: "e", attributes: []), .text("x"), .end(name: "e"), .end(name: "r")])
        // Attribute normalization, as in the oracle's probe of Xerces.
        let attributes = Array("<r a=\"x\ny\tz\r\nw&#10;v&#9;u&#13;\" b='&lt;&#x41;&apos;'/>".utf8)
        #expect(try XML.parse(attributes) == [.start(name: "r", attributes: [("a", "x y z w\nv\tu\r"), ("b", "<A'")]), .end(name: "r")])
        #expect(throws: XML.ParseError.self) { try XML.parse(Array("<r a='1' a='2'/>".utf8)) }
        #expect(throws: XML.ParseError.self) { try XML.parse(Array("<r>&unknown;</r>".utf8)) }
        #expect(throws: XML.ParseError.self) { try XML.parse(Array("<r/><s/>".utf8)) }
    }

    /// An internal entity's character references are expanded where it is
    /// declared, and its replacement text is parsed where it is referenced
    /// (XML 1.0 §4.4–4.5, as Xerces does).
    @Test func xmlEntitiesExpandAsXercesDoes() throws {
        let xml = """
            <!DOCTYPE r [
            <!ENTITY who "J&#246;rg"><!ENTITY amp2 "a&amp;b"><!ENTITY both "&who; and &amp2;">
            <!ENTITY em "<i a='&who;'>x</i>">
            ]>
            <r><a>&who;</a><b>&amp2;</b><c>&both;</c><f>&em;</f><g v="&both;"/></r>
            """
        #expect(
            try XML.parse(Array(xml.utf8)) == [
                .start(name: "r", attributes: []),
                .start(name: "a", attributes: []), .text("Jörg"), .end(name: "a"),
                .start(name: "b", attributes: []), .text("a&b"), .end(name: "b"),
                .start(name: "c", attributes: []), .text("Jörg and a&b"), .end(name: "c"),
                .start(name: "f", attributes: []), .start(name: "i", attributes: [("a", "Jörg")]), .text("x"), .end(name: "i"),
                .end(name: "f"),
                .start(name: "g", attributes: [("v", "Jörg and a&b")]), .end(name: "g"),
                .end(name: "r"),
            ])
        // Recursive entities and entity bombs are errors, as in the JDK's parser.
        #expect(throws: XML.ParseError.self) { try XML.parse(Array("<!DOCTYPE r [<!ENTITY a \"x&a;\">]><r>&a;</r>".utf8)) }
        var bomb = "<!DOCTYPE r [<!ENTITY l0 \"lol\">"
        for i in 1...9 { bomb += "<!ENTITY l\(i) \"" + String(repeating: "&l\(i - 1);", count: 10) + "\">" }
        bomb += "]><r a=\"&l9;\">&l9;</r>"
        #expect(throws: XML.ParseError.self) { try XML.parse(Array(bomb.utf8)) }
    }

    @Test func xmlIsWrittenAsTheJDKSerializes() {
        var w = XMLWriter()
        w.start("pluginRecords")
        w.element("update-site", [("name", "A&B <\"x\"> 'y'\n\t\r\u{E9}\u{1F600}"), ("timestamp", "0")])
        w.start("plugin", [("filename", "jars/x.jar")])
        w.element("platform", text: "linux64")
        w.start("version", [("checksum", "abc")])
        w.element("description", text: "A&B <\"x\"> 'y' ]]> \n\t\r\u{E9}\u{85}\u{7F}\u{80}\u{9F}\u{1F600} end")
        w.element("author")
        w.element("link", text: "")
        w.end("version")
        w.end("plugin")
        w.end("pluginRecords")
        w.endDocument()
        // The output of the oracle's probe of the JDK's TransformerHandler.
        let expected =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><pluginRecords>\n"
            + "    <update-site name=\"A&amp;B &lt;&quot;x&quot;&gt; 'y'&#10;&#9;&#13;\u{E9}&#128512;\" timestamp=\"0\"/>\n"
            + "    <plugin filename=\"jars/x.jar\">\n"
            + "        <platform>linux64</platform>\n"
            + "        <version checksum=\"abc\">\n"
            + "            <description>A&amp;B &lt;\"x\"&gt; 'y' ]]&gt; \n\t&#13;\u{E9}&#133;&#127;&#128;&#159;&#128512; end</description>\n"
            + "            <author/>\n"
            + "            <link/>\n"
            + "        </version>\n"
            + "    </plugin>\n"
            + "</pluginRecords>\n"
        #expect(String(decoding: w.bytes, as: UTF8.self) == expected)
    }

    @Test func deflateRoundTrips() throws {
        var random = SystemRandomNumberGenerator()
        let samples: [[UInt8]] = [
            [], Array("a".utf8), Array(String(repeating: "abcabcabd", count: 5000).utf8),
            (0..<70000).map { _ in UInt8.random(in: 0...255, using: &random) },
            (0..<100000).map { UInt8(($0 / 7) % 3) },
        ]
        for sample in samples {
            #expect(try Inflate.gzip(Deflate.gzip(sample)[...]) == sample)
        }
        let text = Array(String(repeating: "<plugin filename=\"jars/x.jar\"/>\n", count: 1000).utf8)
        #expect(Deflate.gzip(text).count < text.count / 10)
    }
}
