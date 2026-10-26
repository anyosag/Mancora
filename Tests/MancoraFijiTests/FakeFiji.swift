import Foundation
import MancoraPlugins
import MancoraSupport
import MancoraUpdate

@testable import MancoraFiji

/// A Fiji folder with the layout Fiji's downloads have, but tiny: placeholder
/// jars, a `java` that is a shell script, and a `db.xml.gz` naming one
/// update site (``MemorySites``).
/// Fiji is installed and run on macOS and Linux; on Windows the tests that
/// unpack archives, link files or run Fiji's Java are skipped.
let onWindows: Bool = {
    #if os(Windows)
    true
    #else
    false
    #endif
}()

enum FakeFiji {
    static let platform = Platforms.current
    static let site = "Test"
    static let siteURL = MemorySites.base + site + "/"

    static func temporaryFolder(_ name: String = "fiji-test") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The files of a fake Fiji, by path: contents, and whether executable.
    static func entries(macro: String = "print('v1');", javaVersion: String = "21.0.7") -> [(path: String, contents: Data, executable: Bool)] {
        let jdk = "java/\(platform)/zulu21-fake"
        var java = jdk
        if Platforms.isMac(platform) { java += "/zulu-21.jdk/Contents/Home" }
        let exe = Platforms.isWindows(platform) ? ".exe" : ""
        return [
            ("jars/ij-1.54p.jar", Data("ij".utf8), false),
            ("jars/imagej-legacy-3.0.0.jar", Data("legacy".utf8), false),
            ("jars/imagej-2.18.0.jar", Data("imagej".utf8), false),
            ("jars/fiji-2.18.1-SNAPSHOT.jar", Data("fiji".utf8), false),
            ("jars/fiji-lib-2.1.3.jar", Data("fiji-lib".utf8), false),
            ("jars/bio-formats/formats-api-8.5.0.jar", Data("formats".utf8), false),
            ("jars/\(platform)/javafx-base-23.0.2.jar", Data("fx".utf8), false),
            ("jars/win-arm64/elsewhere.jar", Data("no".utf8), false),
            ("jars/notes.txt", Data("not a jar".utf8), false),
            ("plugins/Fiji_Plugins-3.2.0.jar", Data("plugins".utf8), false),
            ("plugins/Sub/nested.jar", Data("nested".utf8), false),
            ("plugins/Examples/script.bsh", Data("x".utf8), false),
            ("macros/hello.ijm", Data(macro.utf8), false),
            ("images/icon.png", Data("png".utf8), false),
            ("\(java)/bin/java\(exe)", Data("#!/bin/sh\necho fake java\n".utf8), true),
            ("\(java)/bin/javac\(exe)", Data("#!/bin/sh\necho fake javac\n".utf8), true),
            ("\(java)/release", Data("JAVA_VERSION=\"\(javaVersion)\"\n".utf8), false),
            ("db.xml.gz", database(), false),
        ]
    }

    /// The installation's own database: the test site enabled, ImageJ's disabled.
    static func database() -> Data {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?><pluginRecords>\
            <update-site name="\(site)" url="\(siteURL)" official="true" timestamp="0"/>\
            <disabled-update-site name="ImageJ" url="https://update.imagej.net/" official="true" timestamp="0"/>\
            </pluginRecords>
            """
        return Data(Deflate.gzip(Array(xml.utf8)))
    }

    /// Writes a fake Fiji into `root`.
    @discardableResult
    static func make(at root: URL, macro: String = "print('v1');") throws -> FijiInstallation {
        let fm = FileManager.default
        for entry in entries(macro: macro) {
            let url = root.appendingPathComponent(entry.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.contents.write(to: url)
            #if !os(Windows)
            if entry.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            #endif
            // As unpacked from Fiji's archive: built some time ago (the updater's checksum cache goes by the second).
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        }
        return FijiInstallation(root: root)
    }

    /// The fake Fiji as Fiji publishes it: a zip holding `Fiji/`, with the
    /// executable bits and (on macOS, as there) the JDK's `bin` linked.
    static func archive() -> Data {
        var zip = ZipWriter()
        zip.directory("Fiji/")
        for entry in entries() {
            zip.file("Fiji/" + entry.path, entry.contents, mode: entry.executable ? 0o755 : 0o644)
        }
        // As the macOS JDK links its bin folder from the JDK's folder into its Home.
        zip.symlink("Fiji/java/\(platform)/zulu21-fake/linked-bin", to: linkTarget)
        return zip.finish()
    }

    static var linkTarget: String { Platforms.isMac(platform) ? "zulu-21.jdk/Contents/Home/bin" : "bin" }
}

/// Writes a zip archive (stored, not compressed) as Info-ZIP does on Unix:
/// permissions and symbolic links in each entry's external attributes.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count = 0

    mutating func directory(_ name: String) { add(name, Data(), mode: 0o040755) }
    mutating func file(_ name: String, _ contents: Data, mode: UInt32 = 0o644) { add(name, contents, mode: 0o100000 | mode) }
    mutating func symlink(_ name: String, to target: String) { add(name, Data(target.utf8), mode: 0o120777) }

    private mutating func add(_ name: String, _ contents: Data, mode: UInt32) {
        let nameBytes = Data(name.utf8)
        let crc = Inflate.crc32([UInt8](contents))
        let offset = UInt32(data.count)
        // Local file header.
        append32(&data, 0x0403_4b50)
        append16(&data, 10)  // version needed
        append16(&data, 0x0800)  // UTF-8 names
        append16(&data, 0)  // stored
        append16(&data, 0)  // time
        append16(&data, 0x5821)  // date: 2024-01-01
        append32(&data, crc)
        append32(&data, UInt32(contents.count))
        append32(&data, UInt32(contents.count))
        append16(&data, UInt16(nameBytes.count))
        append16(&data, 0)
        data.append(nameBytes)
        data.append(contents)
        // Central directory entry.
        append32(&central, 0x0201_4b50)
        append16(&central, 0x031E)  // made by Unix, version 3.0
        append16(&central, 10)
        append16(&central, 0x0800)
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0x5821)
        append32(&central, crc)
        append32(&central, UInt32(contents.count))
        append32(&central, UInt32(contents.count))
        append16(&central, UInt16(nameBytes.count))
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0)
        append32(&central, mode << 16)
        append32(&central, offset)
        central.append(nameBytes)
        count += 1
    }

    mutating func finish() -> Data {
        var out = data
        let offset = UInt32(out.count)
        out.append(central)
        append32(&out, 0x0605_4b50)
        append16(&out, 0)
        append16(&out, 0)
        append16(&out, UInt16(count))
        append16(&out, UInt16(count))
        append32(&out, UInt32(central.count))
        append32(&out, offset)
        append16(&out, 0)
        return out
    }

    private func append16(_ d: inout Data, _ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func append32(_ d: inout Data, _ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { d.append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
}

/// Update sites served from memory, laid out as the updater uploads them,
/// and `file:` URLs read from disk; counts what was asked for.
final class MemorySites: HTTPClient, @unchecked Sendable {
    static let base = "https://sites.test/"
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private(set) var requests: [String] = []

    func data(from url: URL) async throws -> Data { try await dataAndLastModified(from: url).data }

    func dataAndLastModified(from url: URL) async throws -> (data: Data, lastModified: Date?) {
        let data = lock.withLock {
            requests.append(url.absoluteString)
            return files[url.absoluteString]
        }
        if url.isFileURL { return (try Data(contentsOf: url), nil) }
        guard let data else { throw UpdateError.httpStatus(404, url: url.absoluteString) }
        return (data, Date(timeIntervalSince1970: 1_719_835_200))
    }

    var requestCount: Int { lock.withLock { requests.count } }

    /// Makes the site offer these files, each with the versions it replaced.
    func publish(
        site: String = FakeFiji.site,
        _ entries: [(filename: String, contents: [UInt8], timestamp: Int64, previous: [(contents: [UInt8], timestamp: Int64)])]
    ) throws {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><pluginRecords>"#
        for entry in entries {
            let checksum = try FijiChecksum.digest(path: entry.filename, contents: entry.contents)
            xml += #"<plugin filename="\#(entry.filename)">"#
            xml += #"<version checksum="\#(checksum)" timestamp="\#(entry.timestamp)" filesize="\#(entry.contents.count)"/>"#
            for old in entry.previous {
                let oldChecksum = try FijiChecksum.digest(path: entry.filename, contents: old.contents)
                xml += #"<previous-version timestamp="\#(old.timestamp)" checksum="\#(oldChecksum)"/>"#
            }
            xml += "</plugin>"
            lock.withLock { files["\(Self.base)\(site)/\(entry.filename)-\(entry.timestamp)"] = Data(entry.contents) }
        }
        let index = Data(Deflate.gzip(Array((xml + "</pluginRecords>").utf8)))
        lock.withLock { files["\(Self.base)\(site)/db.xml.gz"] = index }
    }

    /// Serves `contents` at `url` (a download whose checksum won't match, say).
    func serve(_ url: String, _ contents: Data) { lock.withLock { files[url] = contents } }
}

/// A site offering version 2 of the fake Fiji's macro.
func siteWithNewMacro(_ sites: MemorySites, macro: String = "print('v2');") throws {
    try sites.publish([
        (filename: "macros/hello.ijm", contents: Array(macro.utf8), timestamp: 20_260_102_000_000,
         previous: [(contents: Array("print('v1');".utf8), timestamp: 20_260_101_000_000)])
    ])
}
