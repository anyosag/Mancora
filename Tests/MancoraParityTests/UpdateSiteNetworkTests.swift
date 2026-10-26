import Foundation
import MancoraCore
import MancoraPlugins
import MancoraSupport
import MancoraUpdate
import Testing

@testable import MancoraBridge

/// Fiji's real update sites, end to end: their indexes parse, and plugins
/// installed from them (checked against the checksums Fiji's uploader
/// recorded) run in ImageJ through the bridge. They need the network, so
/// they run only with `MANCORA_NETWORK_TESTS=1` (CI's parity job).
@Suite(
    "Fiji update sites over the network", .enabled(if: ProcessInfo.processInfo.environment["MANCORA_NETWORK_TESTS"] == "1"),
    .serialized)
struct UpdateSiteNetworkTests {
    let client = URLSessionHTTPClient(userAgent: "mancora-tests")

    @Test(arguments: KnownSites.all.map(\.name)) func knownSiteServesItsIndex(_ name: String) async throws {
        let known = try #require(KnownSites.all.first { $0.name == name })
        let collection = PluginCollection(root: nil)
        let site = UpdateSite(name: known.name, url: known.url)
        site.isActive = true
        collection.addSite(site)
        let url = URL(string: site.url + "db.xml.gz")!
        let (data, lastModified): (Data, Date?)
        do {
            (data, lastModified) = try await client.dataAndLastModified(from: url)
        } catch {
            // One retry: a site's server may be slow to answer.
            (data, lastModified) = try await client.dataAndLastModified(from: url)
        }
        try collection.readSiteDatabase(site, xml: try Inflate.gzip([UInt8](data)[...], limit: 1 << 30))
        #expect(!collection.files.isEmpty, "\(known.name) lists no files")
        #expect(lastModified != nil, "\(known.name) sends no Last-Modified")
    }

    /// A fresh bridge home with ImageJ 1.54p.
    static func home() throws -> BridgeHome {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-sites-\(UUID().uuidString)"))
        try home.createFolders()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Parity.imageJJar!), to: home.imageJJar)
        return home
    }

    static func bridge(_ home: BridgeHome) -> Bridge {
        var config = Bridge.Configuration(
            java: Parity.java!, home: home, helperSource: Parity.url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: Parity.url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 300
        return Bridge(configuration: config)
    }

    @Test(.enabled(if: Parity.available)) func morphoLibJFromItsSiteRunsInImageJ() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let manager = try PluginManager(root: home.root)
        try manager.addSite(name: "IJPB-plugins", url: nil)
        try await manager.refresh(client: client)
        #expect(manager.warnings.isEmpty, "\(manager.warnings)")
        let (changes, conflicts) = manager.plan()
        #expect(conflicts.isEmpty, "\(conflicts)")
        #expect(changes.contains { $0.kind == .install && $0.filename.contains("MorphoLibJ") }, "\(changes)")
        // Every download is checked against the site's checksum.
        try await manager.apply(client: client)

        // Reading again, everything is installed: Mancora's checksums of the
        // downloaded files are the ones Fiji's uploader recorded.
        let again = try PluginManager(root: home.root)
        try await again.refresh(client: client)
        let fromSite = again.files.files.filter { $0.updateSite == "IJPB-plugins" && $0.isActivePlatform(again.files) && $0.current != nil }
        #expect(!fromSite.isEmpty)
        for file in fromSite { #expect(file.status == .installed, "\(file.filename): \(file.status)") }

        // The plugin runs: a dilation with a 3×3 square grows a point into a square.
        let bridge = Self.bridge(home)
        let commands = try await bridge.commands()
        #expect(commands.contains { $0.name == "Morphological Filters" })
        let result = try await bridge.runMacro(
            """
            newImage("point", "8-bit black", 9, 9, 1);
            setPixel(4, 4, 255);
            run("Morphological Filters", "operation=Dilation element=Square radius=1");
            """)
        await bridge.stop()
        let dilated = try #require(result.images.first { $0.title.contains("Dilation") }, "log: \(result.log)")
        let expected = (0..<81).map { i -> UInt8 in (3...5).contains(i % 9) && (3...5).contains(i / 9) ? 255 : 0 }
        #expect(dilated.image.stack[0] == .gray8(expected))
    }

    @Test(.enabled(if: Parity.available)) func bioFormatsFromFijisSitesOpensFilesInTheBridge() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let manager = try PluginManager(root: home.root)
        try manager.setActive("ImageJ", true)
        try manager.addSite(name: "Fiji", url: nil)
        try await manager.refresh(client: client)
        // Only Bio-Formats' ImageJ plugin (the current record, wherever the sites keep it), and what it needs.
        let plugin = try #require(
            manager.files.files.filter { $0.unversionedFilename.hasSuffix("/bio-formats_plugins.jar") && $0.current != nil }
                .max { $0.timestamp < $1.timestamp })
        try manager.select([plugin.filename])
        let (changes, conflicts) = manager.plan()
        // The bridge's own ImageJ may differ from the ImageJ site's: that's a warning, and it stays.
        let errors = conflicts.filter { !$0.isWarning }
        #expect(errors.isEmpty, "\(errors)")
        #expect(changes.contains { $0.filename.contains("formats-") }, "\(plugin.filename): \(changes)")
        try await manager.apply(client: client)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Bio-Formats' "fake" reader makes up an image from its file name.
        let fake = folder.appendingPathComponent("test&sizeX=64&sizeY=32&pixelType=uint16.fake")
        try Data().write(to: fake)
        let bridge = Self.bridge(home)
        let result = try await bridge.open(fake.path)
        await bridge.stop()
        let opened = try #require(result.images.first, "log: \(result.log)")
        #expect(result.value == "Bio-Formats")
        #expect(opened.image.width == 64 && opened.image.height == 32)
        #expect(opened.image.pixelType == .gray16)
    }
}
