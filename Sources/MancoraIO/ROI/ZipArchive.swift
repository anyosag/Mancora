import MancoraSupport

/// A minimal zip reader and writer for ROI sets.
///
/// Reading parses the central directory (including ZIP64 end records and
/// sizes), supports stored and deflated entries, and checks every entry's
/// CRC-32. Writing stores entries uncompressed, with sizes and CRC in each
/// local header, so `java.util.zip.ZipInputStream` (which ImageJ's ROI
/// Manager reads zips with, front to back) accepts them.
enum ZipArchive {
    struct Entry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    // MARK: Reading

    /// The entries in the order of their data in the file, which is the order
    /// `ZipInputStream` returns them.
    static func entries(_ bytes: [UInt8]) throws(MancoraIOError) -> [Entry] {
        let r = ByteReader(bytes)
        // The end-of-central-directory record is within the last 64 KiB + 22 bytes.
        var eocd = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 0xFFFF)
        while eocd >= stop, try r.u32(at: eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= stop, eocd >= 0 else { throw .invalidFormat("not a zip file (no end of central directory)") }
        var count = Int(try r.u16(at: eocd + 10))
        var cdSize = Int(try r.u32(at: eocd + 12))
        var cdOffset = Int(try r.u32(at: eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: a locator just before the record points to the ZIP64 end record.
            let locator = eocd - 20
            if locator >= 0, try r.u32(at: locator) == 0x0706_4B50 {
                let record = try int(r.u64(at: locator + 8))
                guard try r.u32(at: record) == 0x0606_4B50 else { throw .invalidFormat("bad ZIP64 end record") }
                count = try int(r.u64(at: record + 32))
                cdSize = try int(r.u64(at: record + 40))
                cdOffset = try int(r.u64(at: record + 48))
            }
        }
        try r.check(cdOffset, cdSize)
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard try r.u32(at: p) == 0x0201_4B50 else { throw .invalidFormat("bad central directory entry") }
            let flags = try r.u16(at: p + 8)
            let method = try r.u16(at: p + 10)
            let crc = try r.u32(at: p + 16)
            var compressed = Int(try r.u32(at: p + 20))
            var size = Int(try r.u32(at: p + 24))
            let nameLength = Int(try r.u16(at: p + 28))
            let extraLength = Int(try r.u16(at: p + 30))
            let commentLength = Int(try r.u16(at: p + 32))
            var offset = Int(try r.u32(at: p + 42))
            let name = String(decoding: try r.slice(at: p + 46, count: nameLength), as: UTF8.self)
            // ZIP64 extra field: the 64-bit values that are 0xFFFFFFFF above, in this order.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = try r.u16(at: e), length = Int(try r.u16(at: e + 2))
                if id == 1 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF {
                        size = try int(r.u64(at: q))
                        q += 8
                    }
                    if compressed == 0xFFFF_FFFF {
                        compressed = try int(r.u64(at: q))
                        q += 8
                    }
                    if offset == 0xFFFF_FFFF { offset = try int(r.u64(at: q)) }
                }
                e += 4 + length
            }
            entries.append(Entry(
                name: name, flags: flags, method: method, crc: crc, compressedSize: compressed, size: size,
                localHeaderOffset: offset))
            p = extraEnd + commentLength
        }
        return entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
    }

    private static func int(_ v: UInt64) throws(MancoraIOError) -> Int {
        guard v <= UInt64(Int.max / 2) else { throw .invalidFormat("zip offset or size out of range") }
        return Int(v)
    }

    /// The uncompressed contents of an entry, checked against its CRC-32.
    static func data(of entry: Entry, in bytes: [UInt8], limit: Int) throws(MancoraIOError) -> [UInt8] {
        let r = ByteReader(bytes)
        let p = entry.localHeaderOffset
        guard try r.u32(at: p) == 0x0403_4B50 else { throw .invalidFormat("bad local header for \(entry.name)") }
        guard entry.flags & 1 == 0 else { throw .unsupported("encrypted zip entry \(entry.name)") }
        guard entry.size <= limit else { throw .tooLarge(bytes: entry.size, limit: limit) }
        let start = p + 30 + Int(try r.u16(at: p + 26)) + Int(try r.u16(at: p + 28))
        let raw = try r.slice(at: start, count: entry.compressedSize)
        let data: [UInt8]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw .invalidFormat("stored entry \(entry.name) changes size") }
            data = Array(raw)
        case 8:
            do {
                data = try Inflate.raw(raw, limit: entry.size)
            } catch {
                throw .invalidFormat("zip entry \(entry.name): deflate data is corrupt (\(error))")
            }
            guard data.count == entry.size else {
                throw .invalidFormat("zip entry \(entry.name) is \(data.count) bytes, not \(entry.size)")
            }
        default:
            throw .unsupported("zip compression method \(entry.method) in \(entry.name)")
        }
        guard Inflate.crc32(data) == entry.crc else { throw .invalidFormat("CRC-32 mismatch in zip entry \(entry.name)") }
        return data
    }

    // MARK: Writing

    /// A zip of stored (uncompressed) files, dated 1980-01-01 00:00 so the
    /// same input always gives the same bytes.
    static func stored(_ files: [(name: String, data: [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func u16(_ v: Int, _ b: inout [UInt8]) {
            b.append(UInt8(truncatingIfNeeded: v))
            b.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        func u32(_ v: Int, _ b: inout [UInt8]) {
            u16(v & 0xFFFF, &b)
            u16(v >> 16 & 0xFFFF, &b)
        }
        func u64(_ v: Int, _ b: inout [UInt8]) {
            u32(v & 0xFFFF_FFFF, &b)
            u32(v >> 32 & 0xFFFF_FFFF, &b)
        }
        let dosTime = 0, dosDate = 1 << 5 | 1
        for file in files {
            let name = Array(file.name.utf8)
            let flags = name.allSatisfy { $0 < 0x80 } ? 0 : 0x0800  // UTF-8 names, as ZipOutputStream marks them
            let crc = Int(Inflate.crc32(file.data))
            let offset = out.count
            let zip64 = offset >= 0xFFFF_FFFF
            u32(0x0403_4B50, &out)
            u16(10, &out)
            u16(flags, &out)
            u16(0, &out)
            u16(dosTime, &out)
            u16(dosDate, &out)
            u32(crc, &out)
            u32(file.data.count, &out)
            u32(file.data.count, &out)
            u16(name.count, &out)
            u16(0, &out)
            out += name
            out += file.data

            u32(0x0201_4B50, &central)
            u16(zip64 ? 45 : 20, &central)  // made by: MS-DOS, version 2.0 (4.5 with ZIP64)
            u16(zip64 ? 45 : 10, &central)
            u16(flags, &central)
            u16(0, &central)
            u16(dosTime, &central)
            u16(dosDate, &central)
            u32(crc, &central)
            u32(file.data.count, &central)
            u32(file.data.count, &central)
            u16(name.count, &central)
            u16(zip64 ? 12 : 0, &central)
            u16(0, &central)
            u16(0, &central)
            u16(0, &central)
            u32(0, &central)
            u32(zip64 ? 0xFFFF_FFFF : offset, &central)
            central += name
            if zip64 {
                u16(1, &central)
                u16(8, &central)
                u64(offset, &central)
            }
        }
        let cdOffset = out.count
        out += central
        if files.count >= 0xFFFF || cdOffset >= 0xFFFF_FFFF || central.count >= 0xFFFF_FFFF {
            let record = out.count
            u32(0x0606_4B50, &out)
            u64(44, &out)
            u16(45, &out)
            u16(45, &out)
            u32(0, &out)
            u32(0, &out)
            u64(files.count, &out)
            u64(files.count, &out)
            u64(central.count, &out)
            u64(cdOffset, &out)
            u32(0x0706_4B50, &out)
            u32(0, &out)
            u64(record, &out)
            u32(1, &out)
        }
        u32(0x0605_4B50, &out)
        u16(0, &out)
        u16(0, &out)
        u16(min(files.count, 0xFFFF), &out)
        u16(min(files.count, 0xFFFF), &out)
        u32(min(central.count, 0xFFFF_FFFF), &out)
        u32(min(cdOffset, 0xFFFF_FFFF), &out)
        u16(0, &out)
        return out
    }
}

/// Reads every file in a zip (or jar) archive.
public enum ZipContents {
    /// Each entry's name and uncompressed contents (empty for directories),
    /// in the order of their data in the archive; each is checked against
    /// its CRC-32. `limit` bounds any one entry's size.
    public static func read(_ bytes: [UInt8], limit: Int = 1 << 30) throws(MancoraIOError) -> [(name: String, data: [UInt8])] {
        var files: [(name: String, data: [UInt8])] = []
        for entry in try ZipArchive.entries(bytes) {
            files.append((entry.name, try ZipArchive.data(of: entry, in: bytes, limit: limit)))
        }
        return files
    }
}
