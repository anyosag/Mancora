import Foundation
import MancoraCore
import Testing

/// The PNG, GIF and ZIP fixtures `Tools/fixtures/make_formats.py` writes,
/// with what each holds and, where ImageJ converts on opening, what
/// ImageJ 1.54p opens (checked against ImageJ itself by the parity suite).
enum FormatFixtures {
    struct Stored: Decodable, Sendable {
        let pattern: String
        let shift: Int?
        let modulo: Int?
        /// Palette entries, 3 bytes each, as hex.
        let palette: String?
    }

    struct Expect: Decodable, Sendable {
        let type: String
        /// One plane as hex (PNG).
        let pixels: String?
        /// CRC-32 of the planes' bytes, R G B per pixel (for large PNGs).
        let crc32: UInt32?
        /// Every plane as hex (GIF).
        let planes: [String]?
        /// 256 reds, greens and blues as hex.
        let lut: String?
    }

    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        let file: String
        let width: Int
        let height: Int
        let stored: Stored?
        let expect: Expect?
        var testDescription: String { file }
    }

    static func manifest(_ folder: String) -> [Entry] {
        (try? JSONDecoder().decode([Entry].self, from: Fixtures.data("Tests/Fixtures/\(folder)/manifest.json"))) ?? []
    }

    static let png = manifest("png")
    static let gif = manifest("gif")

    static func bytes(hex: String) -> [UInt8] { Fixtures.bytes(fromHex: hex) }

    /// Hex digits per value: 2 for 8-bit, 6 for RGB.
    static func values(hex: String, digits: Int) -> [UInt32] {
        let b = bytes(hex: hex)
        let n = digits / 2
        return stride(from: 0, to: b.count, by: n).map { i in b[i..<(i + n)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }

    /// A LUT from 256 reds, greens and blues in hex.
    static func lut(hex: String) -> LUT? {
        let b = bytes(hex: hex)
        guard b.count == 768 else { return nil }
        return try? LUT(name: "", reds: Array(b[0..<256]), greens: Array(b[256..<512]), blues: Array(b[512..<768]))
    }

    /// A LUT from palette entries (3 bytes each), padded with black.
    static func lut(palette hex: String) -> LUT? {
        let b = bytes(hex: hex)
        var r = [UInt8](repeating: 0, count: 256), g = r, bl = r
        for i in 0..<min(b.count / 3, 256) {
            (r[i], g[i], bl[i]) = (b[3 * i], b[3 * i + 1], b[3 * i + 2])
        }
        return try? LUT(name: "", reds: r, greens: g, blues: bl)
    }

    static func crc32(_ data: [UInt8]) -> UInt32 { RoiFixtures.crc32(data) }

    /// The index of the first value that differs, or -1.
    static func firstDifference<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? (a.count == b.count ? -1 : min(a.count, b.count))
    }
}
