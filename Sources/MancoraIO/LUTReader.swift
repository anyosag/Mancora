public import MancoraCore

/// Reads LUT files in the formats ImageJ's `LutLoader` accepts:
///
/// - **NIH Image**: a 32-byte big-endian header starting with `ICOL`, then
///   `n` reds, `n` greens and `n` blues (stretched to 256 if `n < 256`).
/// - **Raw**: exactly 768 (or 970) bytes, 256 reds then 256 greens then
///   256 blues.
/// - **Text**: 256 rows (plus an optional header row) of 3 columns
///   (R G B) or 4 columns (index R G B), separated by spaces, tabs or
///   commas, with LF or CRLF line ends.
///
/// One deliberate difference from ImageJ: a text LUT whose values all lie in
/// `0...1` and include fractions (such as `cividis.txt`) is scaled to
/// `0...255`. ImageJ truncates those values to 0 and 1, so the LUT comes out
/// black.
public enum LUTReader {
    /// ImageJ refuses LUT files larger than this.
    public static let maximumFileSize = 10_000

    public static func read(path: String) throws(MancoraIOError) -> LUT {
        let bytes = try FileLoader.load(path: path, limit: maximumFileSize)
        return try decode(bytes, name: baseName(of: path))
    }

    public static func decode(_ bytes: [UInt8], name: String) throws(MancoraIOError) -> LUT {
        let length = bytes.count
        guard length <= maximumFileSize else { throw .tooLarge(bytes: length, limit: maximumFileSize) }
        if length > 768, let lut = try decodeNIH(bytes, name: name) { return lut }
        if length == 768 || length == 970 { return try decodeRaw(bytes, name: name) }
        if length > 768 { return try decodeText(bytes, name: name) }
        throw .invalidFormat(
            "\(name) is not an NIH Image LUT, a 768-byte raw LUT, or a LUT in text format (\(length) bytes)"
        )
    }

    // MARK: Binary

    static func decodeNIH(_ bytes: [UInt8], name: String) throws(MancoraIOError) -> LUT? {
        let reader = ByteReader(bytes, bigEndian: true)
        guard try reader.u32(at: 0) == 0x4943_4F4C else { return nil }  // "ICOL"
        let colorCount = Int(Int16(bitPattern: try reader.u16(at: 6)))
        guard (1...256).contains(colorCount) else {
            throw .invalidFormat("\(name) has an NIH Image header with \(colorCount) colors")
        }
        let start = 32
        let r = try reader.slice(at: start, count: colorCount)
        let g = try reader.slice(at: start + colorCount, count: colorCount)
        let b = try reader.slice(at: start + 2 * colorCount, count: colorCount)
        return try makeLUT(name: name, Array(r), Array(g), Array(b), colorCount: colorCount)
    }

    static func decodeRaw(_ bytes: [UInt8], name: String) throws(MancoraIOError) -> LUT {
        try makeLUT(
            name: name,
            Array(bytes[0..<256]),
            Array(bytes[256..<512]),
            Array(bytes[512..<768]),
            colorCount: 256
        )
    }

    // MARK: Text

    static func decodeText(_ bytes: [UInt8], name: String) throws(MancoraIOError) -> LUT {
        var rows = try TextTable.parse(bytes)
        // ImageJ's TextReader treats a first row with no numbers as a header.
        if let first = rows.first, first.allSatisfy({ $0.isNaN }) {
            rows.removeFirst()
        }
        let width = rows.first?.count ?? 0
        let height = rows.count
        guard (3...4).contains(width), (256...258).contains(height) else {
            throw .invalidFormat("\(name) is a \(width)×\(height) table; a text LUT needs 3 or 4 columns and 256 rows")
        }
        let x = width == 4 ? 1 : 0
        let y = height > 256 ? 1 : 0
        let table = rows[y..<(y + 256)].map { Array($0[x..<(x + 3)]) }
        let values = table.flatMap { $0 }
        let normalized =
            values.allSatisfy { $0 >= 0 && $0 <= 1 } && values.contains { $0 != $0.rounded(.towardZero) }
        func channel(_ c: Int) -> [UInt8] {
            table.map { row in
                normalized
                    ? UInt8(clamping: Int((row[c] * 255).rounded()))
                    : JavaNumerics.byte(Float(row[c]))
            }
        }
        return try makeLUT(name: name, channel(0), channel(1), channel(2), colorCount: 256)
    }

    private static func makeLUT(
        name: String,
        _ r: [UInt8],
        _ g: [UInt8],
        _ b: [UInt8],
        colorCount: Int
    ) throws(MancoraIOError) -> LUT {
        do {
            return try LUT(name: name, interpolating: r, g, b, colorCount: colorCount)
        } catch {
            throw .invalidFormat("\(name): \(error)")
        }
    }

    static func baseName(of path: String) -> String {
        let file = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            return String(file[..<dot])
        }
        return file
    }
}

/// A port of the tokenizing rules of ImageJ's `TextReader`: words are runs of
/// `+` and characters 45–127; everything else, including commas, separates
/// words. Lines with no words are skipped. Every non-empty line must have the
/// same number of words.
enum TextTable {
    static func parse(_ bytes: [UInt8]) throws(MancoraIOError) -> [[Double]] {
        var rows: [[Double]] = []
        var row: [Double] = []
        var word: [UInt8] = []
        var lineNumber = 1

        func endWord() {
            guard !word.isEmpty else { return }
            row.append(parseNumber(word))
            word.removeAll(keepingCapacity: true)
        }
        func endLine() throws(MancoraIOError) {
            endWord()
            if !row.isEmpty {
                if let width = rows.first?.count, width != row.count {
                    throw .invalidFormat("line \(lineNumber) has \(row.count) values; the first line has \(width)")
                }
                rows.append(row)
                row.removeAll(keepingCapacity: true)
            }
            lineNumber += 1
        }

        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x0D || c == 0x0A {
                try endLine()
                if c == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            } else if c == 43 || (45...127).contains(c) {
                word.append(c)
            } else {
                endWord()
            }
            i += 1
        }
        try endLine()
        return rows
    }

    /// Java `Double.parseDouble` for the plain decimal forms LUT files use;
    /// anything else is NaN, as in ImageJ's `Tools.parseDouble`.
    static func parseNumber(_ word: [UInt8]) -> Double {
        Double(String(decoding: word, as: UTF8.self)) ?? .nan
    }
}
