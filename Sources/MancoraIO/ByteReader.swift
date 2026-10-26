#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bounds-checked, endian-aware reads from bytes in memory or a
/// memory-mapped file.
///
/// Every read validates its range first, so malformed files produce a
/// ``MancoraIOError/truncated(offset:needed:available:)`` error rather than a
/// crash.
struct ByteReader: Sendable {
    private enum Storage: Sendable {
        case array([UInt8])
        /// A mapped file: only the pages that are read get loaded.
        case mapped(Data)
    }

    private let storage: Storage
    var bigEndian: Bool
    let count: Int

    init(_ bytes: [UInt8], bigEndian: Bool = false) {
        storage = .array(bytes)
        count = bytes.count
        self.bigEndian = bigEndian
    }

    init(mapped data: Data, bigEndian: Bool = false) {
        storage = .mapped(data)
        count = data.count
        self.bigEndian = bigEndian
    }

    func check(_ offset: Int, _ length: Int) throws(MancoraIOError) {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw .truncated(offset: offset, needed: length, available: max(0, count - max(offset, 0)))
        }
    }

    @inline(__always)
    private func byte(_ offset: Int) -> UInt8 {
        switch storage {
        case .array(let bytes): bytes[offset]
        case .mapped(let data): data[data.startIndex + offset]
        }
    }

    func u8(at offset: Int) throws(MancoraIOError) -> UInt8 {
        try check(offset, 1)
        return byte(offset)
    }

    func u16(at offset: Int) throws(MancoraIOError) -> UInt16 {
        try check(offset, 2)
        let a = UInt16(byte(offset)), b = UInt16(byte(offset + 1))
        return bigEndian ? a << 8 | b : b << 8 | a
    }

    func u32(at offset: Int) throws(MancoraIOError) -> UInt32 {
        try check(offset, 4)
        var v: UInt32 = 0
        for i in 0..<4 {
            v = v << 8 | UInt32(byte(offset + (bigEndian ? i : 3 - i)))
        }
        return v
    }

    func u64(at offset: Int) throws(MancoraIOError) -> UInt64 {
        try check(offset, 8)
        var v: UInt64 = 0
        for i in 0..<8 {
            v = v << 8 | UInt64(byte(offset + (bigEndian ? i : 7 - i)))
        }
        return v
    }

    /// The bytes at `offset`; from a mapped file they're copied out.
    func slice(at offset: Int, count: Int) throws(MancoraIOError) -> ArraySlice<UInt8> {
        try check(offset, count)
        switch storage {
        case .array(let bytes):
            return bytes[offset..<(offset + count)]
        case .mapped(let data):
            let start = data.startIndex + offset
            return ArraySlice(
                [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                    initialized = data.copyBytes(to: buffer, from: start..<(start + count))
                })
        }
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

    /// Maps a file into memory, so its pages load only when read.
    static func map(path: String) throws(MancoraIOError) -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
    }
}
