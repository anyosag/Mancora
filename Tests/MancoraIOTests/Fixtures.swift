import Foundation
import Testing

/// Locates test data in the source tree (`Tests/Fixtures`, `Resources/LUTs`).
///
/// Paths are built from `#filePath` with forward slashes, which every
/// platform's file APIs accept, so no bundle resources are needed.
enum Fixtures {
    static let repoRoot: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)  // Fixtures.swift, MancoraIOTests, Tests
        return parts.joined(separator: "/")
    }()

    static func path(_ relative: String) -> String { repoRoot + "/" + relative }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(relative)))
    }

    // MARK: LUT goldens (written by ImageJ; see Tools/fixtures)

    struct LUTGolden: Decodable {
        let imagej: String
        let files: [String: String?]
        let builtin: [String: String]
    }

    static let lutGolden: LUTGolden? = try? JSONDecoder().decode(
        LUTGolden.self,
        from: data("Tests/Fixtures/luts-golden.json")
    )

    static var lutFileNames: [String] { (lutGolden?.files.keys).map { $0.sorted() } ?? [] }

    /// 768 bytes (reds, greens, blues) from a golden hex string.
    static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = hex.utf8.makeIterator()
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 0x20) - 87 }
        while let hi = it.next(), let lo = it.next() {
            out.append(nibble(hi) << 4 | nibble(lo))
        }
        return out
    }

    // MARK: TIFF manifest (written by Tools/fixtures/make_tiffs.py)

    struct TIFFEntry: Decodable, Sendable, CustomTestStringConvertible {
        let file: String
        let pattern: String
        let type: String
        let planes: Int
        /// Channels the planes form (16-bit RGB opens as one per sample).
        let channels: Int?
        let width: Int
        let height: Int
        let signed: Bool?
        let lutInverted: Bool?
        let invertPattern: Bool?
        let lut: String?

        var testDescription: String { file }
    }

    static let tiffManifest: [TIFFEntry] =
        (try? JSONDecoder().decode([TIFFEntry].self, from: data("Tests/Fixtures/tiff/manifest.json"))) ?? []
}
