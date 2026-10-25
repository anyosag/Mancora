#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bounds-checked, endian-aware reads from an in-memory byte buffer.
///
/// Every read validates its range first, so malformed files produce a
/// ``MancoraIOError/truncated(offset:needed:available:)`` error rather than a
/// crash.
struct ByteReader: Sendable {
    let bytes: [UInt8]
    var bigEndian: Bool

    init(_ bytes: [UInt8], bigEndian: Bool = false) {
        self.bytes = bytes
        self.bigEndian = bigEndian
    }

    var count: Int { bytes.count }

    func check(_ offset: Int, _ length: Int) throws(MancoraIOError) {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw .truncated(offset: offset, needed: length, available: max(0, bytes.count - max(offset, 0)))
        }
    }

    func u8(at offset: Int) throws(MancoraIOError) -> UInt8 {
        try check(offset, 1)
        return bytes[offset]
    }

    func u16(at offset: Int) throws(MancoraIOError) -> UInt16 {
        try check(offset, 2)
        let a = UInt16(bytes[offset]), b = UInt16(bytes[offset + 1])
        return bigEndian ? a << 8 | b : b << 8 | a
    }

    func u32(at offset: Int) throws(MancoraIOError) -> UInt32 {
        try check(offset, 4)
        var v: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(bytes[offset + (bigEndian ? i : 3 - i)])
            v = v << 8 | byte
        }
        return v
    }

    func u64(at offset: Int) throws(MancoraIOError) -> UInt64 {
        try check(offset, 8)
        var v: UInt64 = 0
        for i in 0..<8 {
            let byte = UInt64(bytes[offset + (bigEndian ? i : 7 - i)])
            v = v << 8 | byte
        }
        return v
    }

    func slice(at offset: Int, count: Int) throws(MancoraIOError) -> ArraySlice<UInt8> {
        try check(offset, count)
        return bytes[offset..<(offset + count)]
    }
}

enum FileLoader {
    /// Reads a whole file, refusing files larger than `limit` bytes.
    static func load(path: String, limit: Int) throws(MancoraIOError) -> [UInt8] {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
        guard data.count <= limit else { throw .tooLarge(bytes: data.count, limit: limit) }
        return [UInt8](data)
    }
}
