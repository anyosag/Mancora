import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("ROI sets")
struct RoiSetTests {
    static let imagejZip = "Tests/Fixtures/roi/RoiSet.zip"
    static let mancoraZip = "Tests/Fixtures/roi/mancora/RoiSet.zip"

    /// The ROI Manager's own saveMultiple() wrote this zip (deflated entries
    /// with data descriptors) from ImageJ's reading of every fixture.
    @Test func readsTheRoiManagersZip() throws {
        let bytes = try [UInt8](Fixtures.data(Self.imagejZip))
        let zipEntries = try ZipArchive.entries(bytes)
        #expect(zipEntries.allSatisfy { $0.method == 8 && $0.flags & 8 != 0 })
        let set = try RoiSet.decode(bytes)
        #expect(set.map(\.name) == RoiFixtures.entries.map(\.stem))
        for (entry, fixture) in zip(set, RoiFixtures.entries) {
            // The ROI Manager re-encoded what RoiDecoder read, default name included.
            let expected = try RoiCodec.decode(fixture.reencodedBytes, name: fixture.file)
            if fixture.isOpaque {
                #expect(entry.roi.kind == expected.kind && entry.roi.name == expected.name, "\(fixture.file)")
            } else {
                #expect(entry.roi == expected, "\(fixture.file)")
            }
        }
    }

    @Test func roundTrip() throws {
        let rois = try RoiSet.decode(try [UInt8](Fixtures.data(Self.imagejZip)))
        let bytes = RoiSet.encode(rois)
        #expect(try RoiSet.decode(bytes) == rois)
        #expect(RoiSet.encode(rois) == bytes, "encoding is deterministic")
    }

    /// Stored entries need their sizes and CRC in the local header, without
    /// a data descriptor, for java.util.zip.ZipInputStream.
    @Test func storedEntriesCarrySizesAndCRC() throws {
        let roi = Roi(.oval(.integer(x: 1, y: 2, width: 3, height: 4)))
        let bytes = RoiSet.encode([RoiSet.Entry(name: "ø", roi: roi), RoiSet.Entry(name: "b.roi", roi: roi)])
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let data = RoiCodec.encode(roi)
        var p = 0
        for name in ["ø.roi", "b.roi"] {
            #expect(u32(p) == 0x0403_4B50)
            #expect(u16(p + 6) == (name == "ø.roi" ? 0x0800 : 0), "UTF-8 flag only for non-ASCII names, no data descriptor")
            #expect(u16(p + 8) == 0)
            #expect(u32(p + 14) == Int(RoiFixtures.crc32(data)))
            #expect(u32(p + 18) == data.count && u32(p + 22) == data.count)
            let nameLength = u16(p + 26)
            #expect(String(decoding: bytes[(p + 30)..<(p + 30 + nameLength)], as: UTF8.self) == name)
            #expect(Array(bytes[(p + 30 + nameLength)..<(p + 30 + nameLength + data.count)]) == data)
            p += 30 + nameLength + data.count
        }
        #expect(u32(p) == 0x0201_4B50)
        #expect(try RoiSet.decode(bytes).map(\.name) == ["ø", "b"])
    }

    /// RoiManager.getUniqueName, which saveMultiple uses for repeated names.
    @Test func repeatedNamesAreMadeUnique() throws {
        let roi = Roi(.rectangle(.integer(x: 0, y: 0, width: 2, height: 2)))
        let names = ["a", "a", "a-1", "b", "b"]
        let set = try RoiSet.decode(RoiSet.encode(names.map { RoiSet.Entry(name: $0, roi: roi) }))
        #expect(set.map(\.name) == ["a", "a-2", "a-1", "b", "b-1"])
    }

    @Test func zip64ForManyEntries() throws {
        let roi = Roi(.points(Roi.Points(.integer([.init(x: 1, y: 1)]))))
        let entries = (0..<65_536).map { RoiSet.Entry(name: "p\($0)", roi: roi) }
        let bytes = RoiSet.encode(entries)
        let back = try RoiSet.decode(bytes)
        #expect(back.count == 65_536)
        #expect(back.last?.name == "p65535")
    }

    // MARK: Mancora-written files, checked by ImageJ

    /// Every fixture ROI, built from ImageJ's description (opaque ones from
    /// their files), named as the ROI Manager names them.
    static var mancoraEntries: [RoiSet.Entry] {
        RoiFixtures.entries.compactMap { fixture in
            let roi = fixture.isOpaque ? try? RoiCodec.decode(fixture.bytes, name: fixture.file) : fixture.roi()
            return roi.map { RoiSet.Entry(name: fixture.stem, roi: $0) }
        }
    }

    /// Tests/Fixtures/roi/mancora/RoiSet.zip is what Mancora writes today.
    /// Set MANCORA_UPDATE_ROI_FIXTURES=1 to rewrite it, then run
    /// Tools/fixtures/RoiFixtures.java to have ImageJ check it again.
    @Test func committedSetIsCurrent() throws {
        let entries = Self.mancoraEntries
        #expect(entries.count == RoiFixtures.entries.count)
        let bytes = RoiSet.encode(entries)
        if ProcessInfo.processInfo.environment["MANCORA_UPDATE_ROI_FIXTURES"] == "1" {
            let url = URL(fileURLWithPath: Fixtures.path(Self.mancoraZip))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
            return
        }
        #expect(bytes == (try [UInt8](Fixtures.data(Self.mancoraZip))), "Mancora's ROI encoding changed; see Tools/fixtures/README.md")
    }

    struct Verified: Decodable {
        struct Entry: Decodable {
            let name: String
            let decodes: String
            let identicalBytes: Bool
        }

        let imagej: String
        let bytes: Int
        let crc32: UInt32
        let openedByRoiManager: Bool
        let count: Int
        let entries: [Entry]
    }

    /// ImageJ's ROI Manager opened the committed zip (openZip, through
    /// ZipInputStream), and every ROI decoded exactly as the entry the ROI
    /// Manager saved for it: geometry, properties, Roi.getMask() and fill.
    /// The bytes are the same too, except for arrows (head bounds), spline
    /// fits (spline bounds) and the text ROI (kept as read, without the
    /// default name the ROI Manager adds).
    @Test func imageJReadsMancorasSet() throws {
        let zip = try [UInt8](Fixtures.data(Self.mancoraZip))
        let verified = try JSONDecoder().decode(Verified.self, from: Fixtures.data("Tests/Fixtures/roi/mancora/verified.json"))
        #expect(verified.imagej == "1.54p")
        #expect(verified.bytes == zip.count && verified.crc32 == RoiFixtures.crc32(zip), "verified.json is for another zip")
        #expect(verified.openedByRoiManager)
        #expect(verified.count == RoiFixtures.entries.count)
        #expect(verified.entries.map(\.name) == RoiFixtures.entries.map(\.stem))
        let differentBytes: Set = ["arrow", "arrow-default", "polygon-spline", "polyline-spline", "text"]
        for entry in verified.entries {
            #expect(entry.decodes == "same", "\(entry.name)")
            #expect(entry.identicalBytes || differentBytes.contains(entry.name), "\(entry.name)")
        }
    }
}

@Suite("Malformed ROI sets fail safely")
struct MalformedRoiSetTests {
    static let small: [UInt8] = RoiSet.encode([
        RoiSet.Entry(name: "a", roi: Roi(.oval(.integer(x: 1, y: 2, width: 3, height: 4)))),
        RoiSet.Entry(name: "b", roi: Roi(.line(Roi.Line(x1: 0, y1: 0, x2: 5, y2: 5)))),
    ])

    @Test func truncationsThrow() throws {
        let deflated = try [UInt8](Fixtures.data(RoiSetTests.imagejZip)).prefix(3000)
        for bytes in [Self.small, Array(deflated)] {
            for length in 0..<bytes.count {
                _ = try? RoiSet.decode(Array(bytes[..<length]))
            }
        }
        #expect(throws: MancoraIOError.self) { try RoiSet.decode(Array(Self.small.dropLast(1))) }
        #expect(throws: MancoraIOError.self) { try RoiSet.decode([UInt8]("not a zip at all, just some text".utf8)) }
    }

    @Test func corruptDataThrows() throws {
        var bytes = Self.small
        bytes[40] ^= 0xFF  // inside the first entry's data
        #expect(throws: MancoraIOError.invalidFormat("CRC-32 mismatch in zip entry a.roi")) { try RoiSet.decode(bytes) }
        var encrypted = Self.small
        encrypted[6] |= 1
        let cen = encrypted.count - 22 - (46 + 5) * 2
        encrypted[cen + 8] |= 1
        #expect(throws: MancoraIOError.unsupported("encrypted zip entry a.roi")) { try RoiSet.decode(encrypted) }
    }

    @Test func limitStopsDecompressionBombs() throws {
        let bytes = try [UInt8](Fixtures.data(RoiSetTests.imagejZip))
        #expect(throws: MancoraIOError.self) { try RoiSet.decode(bytes, limit: 1000) }
        // A central directory that understates an entry's size stops inflation there.
        var lying = bytes
        let entries = try ZipArchive.entries(lying)
        var cen = 0
        for i in stride(from: lying.count - 4, through: 0, by: -1) where lying[i..<(i + 4)] == [0x50, 0x4B, 0x01, 0x02] { cen = i }
        #expect(entries.first?.size ?? 0 > 10)
        lying.replaceSubrange((cen + 24)..<(cen + 28), with: [10, 0, 0, 0])
        #expect(throws: MancoraIOError.self) { try RoiSet.decode(lying) }
    }

    @Test func badRoisNameTheirEntry() throws {
        let zip = ZipArchive.stored([("fine.roi", RoiCodec.encode(Roi(.oval(.integer(x: 0, y: 0, width: 2, height: 2))))),
                                     ("bad.roi", [UInt8]("Iout, but nothing else".utf8))])
        #expect(throws: MancoraIOError.self) { try RoiSet.decode(zip) }
        do {
            _ = try RoiSet.decode(zip)
        } catch {
            #expect("\(error)".contains("bad.roi"))
        }
        // Entries that aren't .roi files are skipped, as the ROI Manager does.
        let mixed = ZipArchive.stored([("notes.txt", [1, 2, 3]), ("a.roi", RoiCodec.encode(Roi(.oval(.integer(x: 0, y: 0, width: 2, height: 2)))))])
        #expect(try RoiSet.decode(mixed).map(\.name) == ["a"])
    }
}
