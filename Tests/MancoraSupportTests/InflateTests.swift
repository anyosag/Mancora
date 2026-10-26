import Foundation
import MancoraSupport
import Testing

enum DeflateFixtures {
    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        let file: String
        let format: String
        let length: Int
        let sha256: String
        var testDescription: String { file }
    }

    static let directory: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        return parts.joined(separator: "/") + "/Tests/Fixtures/deflate"
    }()

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)))
    }

    static let manifest: [Entry] =
        (try? JSONDecoder().decode([Entry].self, from: Data(bytes("manifest.json")))) ?? []
}

@Suite("Inflate")
struct InflateTests {
    @Test func manifestPresent() {
        #expect(DeflateFixtures.manifest.count >= 20)
    }

    /// Streams written by Python's zlib decompress to the recorded data.
    @Test("zlib-written stream", arguments: DeflateFixtures.manifest)
    func decompresses(_ entry: DeflateFixtures.Entry) throws {
        let input = try DeflateFixtures.bytes(entry.file)
        let output: [UInt8] =
            switch entry.format {
            case "zlib": try Inflate.zlib(input[...])
            case "raw": try Inflate.raw(input[...])
            default: try Inflate.gzip(input[...])
            }
        #expect(output.count == entry.length)
        #expect(hexString(SHA256.hash(output)) == entry.sha256)
    }

    @Test func stopAtExpectedSize() throws {
        let input = try DeflateFixtures.bytes("runs-l9.zlib")
        let head = try Inflate.zlib(input[...], stopAt: 100)
        #expect(head == [UInt8](repeating: 0, count: 100))
        // Stopping at the limit cuts the long matches that cross it instead of failing.
        for n in [1, 3, 257, 4999, 5000, 5001] {
            #expect(try Inflate.zlib(input[...], stopAt: n, limit: n).count == n)
        }
    }

    @Test func checksumsAndLimits() throws {
        var zlib = try DeflateFixtures.bytes("text-l9.zlib")
        zlib[zlib.count - 1] ^= 0xFF
        #expect(throws: Inflate.Error.checksumMismatch) { try Inflate.zlib(zlib[...]) }

        var gz = try DeflateFixtures.bytes("text.gz")
        gz[gz.count - 6] ^= 0xFF  // inside the CRC-32
        #expect(throws: Inflate.Error.checksumMismatch) { try Inflate.gzip(gz[...]) }

        let runs = try DeflateFixtures.bytes("runs-l9.zlib")
        #expect(throws: Inflate.Error.outputLimit(1000)) { try Inflate.zlib(runs[...], limit: 1000) }
    }

    @Test func malformedInput() throws {
        #expect(throws: Inflate.Error.self) { try Inflate.zlib([0x78][...]) }
        #expect(throws: Inflate.Error.self) { try Inflate.zlib([0x12, 0x34, 0x56][...]) }
        #expect(throws: Inflate.Error.self) { try Inflate.gzip(Array("not gzip at all, really".utf8)[...]) }
        let text = try DeflateFixtures.bytes("text-l9.zlib")
        #expect(throws: Inflate.Error.self) { try Inflate.zlib(text[0..<(text.count / 2)]) }
        // Block type 3 is reserved.
        #expect(throws: Inflate.Error.self) { try Inflate.raw([0x07, 0x00][...]) }
    }

    @Test func checksumFunctions() {
        #expect(Inflate.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Inflate.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
