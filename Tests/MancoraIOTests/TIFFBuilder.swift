/// Writes small, deliberately malformed classic TIFFs for robustness tests.
/// Well-formed files come from independent writers instead (Tools/fixtures).
struct TIFFBuilder {
    struct Entry {
        let tag: UInt16
        let type: UInt16  // 3 = SHORT, 4 = LONG
        let values: [UInt32]
    }

    var bigEndian = false
    var magic: UInt16 = 42
    var entries: [Entry] = []
    var pixels: [UInt8] = []
    /// Replaces the next-IFD pointer; by default the chain ends after one IFD.
    var nextIFD: UInt32? = nil
    /// When set, a second copy of the IFD is written and the first points to it.
    var secondIFDPointsBackToFirst = false

    /// An uncompressed 8-bit image with one strip.
    static func gray8(width: Int, height: Int, pixels: [UInt8]? = nil) -> TIFFBuilder {
        var b = TIFFBuilder()
        b.pixels = pixels ?? [UInt8](repeating: 7, count: width * height)
        b.entries = [
            Entry(tag: 256, type: 4, values: [UInt32(width)]),
            Entry(tag: 257, type: 4, values: [UInt32(height)]),
            Entry(tag: 258, type: 3, values: [8]),
            Entry(tag: 259, type: 3, values: [1]),
            Entry(tag: 262, type: 3, values: [1]),
            Entry(tag: 273, type: 4, values: [8]),
            Entry(tag: 277, type: 3, values: [1]),
            Entry(tag: 278, type: 4, values: [UInt32(height)]),
            Entry(tag: 279, type: 4, values: [UInt32(width * height)]),
        ]
        return b
    }

    /// Bytes per value: 1 for BYTE and ASCII, 2 for SHORT, 4 otherwise.
    static func size(of type: UInt16) -> Int { type == 3 ? 2 : type == 1 || type == 2 ? 1 : 4 }

    /// An ASCII tag (type 2), NUL-terminated.
    mutating func set(_ tag: UInt16, text: String) {
        set(tag, 2, Array(text.utf8).map(UInt32.init) + [0])
    }

    mutating func set(_ tag: UInt16, _ type: UInt16 = 4, _ values: [UInt32]) {
        entries.removeAll { $0.tag == tag }
        entries.append(Entry(tag: tag, type: type, values: values))
    }

    func build() -> [UInt8] {
        var out: [UInt8] = []
        func u16(_ v: UInt16) { out += bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) {
            let b = (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            out += bigEndian ? b.reversed() : b
        }
        out += bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        u16(magic)
        let ifdOffset = UInt32(8 + pixels.count + (pixels.count & 1))
        u32(ifdOffset)
        out += pixels
        if pixels.count & 1 == 1 { out.append(0) }

        let sorted = entries.sorted { $0.tag < $1.tag }
        let ifdSize = UInt32(2 + sorted.count * 12 + 4)
        func writeIFD(at start: UInt32, next: UInt32) {
            var extra: [UInt8] = []
            var extraOffset = start + ifdSize
            u16(UInt16(sorted.count))
            for e in sorted {
                u16(e.tag)
                u16(e.type)
                u32(UInt32(e.values.count))
                let size = Self.size(of: e.type)
                if e.values.count * size <= 4 {
                    var inline: [UInt8] = []
                    for v in e.values {
                        let bytes = (0..<size).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
                        inline += bigEndian ? bytes.reversed() : bytes
                    }
                    out += inline + [UInt8](repeating: 0, count: 4 - inline.count)
                } else {
                    u32(extraOffset)
                    for v in e.values {
                        let bytes = (0..<size).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
                        extra += bigEndian ? bytes.reversed() : bytes
                    }
                    extraOffset += UInt32(e.values.count * size)
                }
            }
            u32(next)
            out += extra
        }
        if secondIFDPointsBackToFirst {
            // Estimate the second IFD's start: after the first IFD and its values.
            let extraBytes = sorted.reduce(0) { acc, e in
                let size = Self.size(of: e.type)
                return acc + (e.values.count * size > 4 ? e.values.count * size : 0)
            }
            let second = ifdOffset + ifdSize + UInt32(extraBytes)
            writeIFD(at: ifdOffset, next: second)
            writeIFD(at: second, next: ifdOffset)
        } else {
            writeIFD(at: ifdOffset, next: nextIFD ?? 0)
        }
        return out
    }
}
