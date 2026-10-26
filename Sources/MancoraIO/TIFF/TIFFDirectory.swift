/// TIFF tag numbers Mancora reads and writes.
enum TIFFTag {
    static let newSubfileType: UInt16 = 254
    static let imageWidth: UInt16 = 256
    static let imageLength: UInt16 = 257
    static let bitsPerSample: UInt16 = 258
    static let compression: UInt16 = 259
    static let photometric: UInt16 = 262
    static let imageDescription: UInt16 = 270
    static let stripOffsets: UInt16 = 273
    static let samplesPerPixel: UInt16 = 277
    static let rowsPerStrip: UInt16 = 278
    static let stripByteCounts: UInt16 = 279
    static let xResolution: UInt16 = 282
    static let yResolution: UInt16 = 283
    static let planarConfiguration: UInt16 = 284
    static let resolutionUnit: UInt16 = 296
    static let predictor: UInt16 = 317
    static let colorMap: UInt16 = 320
    static let tileWidth: UInt16 = 322
    static let tileLength: UInt16 = 323
    static let tileOffsets: UInt16 = 324
    static let tileByteCounts: UInt16 = 325
    static let sampleFormat: UInt16 = 339
    static let software: UInt16 = 305
    static let dateTime: UInt16 = 306
    static let artist: UInt16 = 315
    static let hostComputer: UInt16 = 316
    /// ImageJ's private metadata: byte counts, then the records themselves.
    static let imageJMetadataCounts: UInt16 = 50838
    static let imageJMetadata: UInt16 = 50839
}

/// One IFD entry: where its values live and how they're encoded.
struct TIFFEntry: Sendable {
    let tag: UInt16
    let type: UInt16
    let count: Int
    /// Absolute file offset of the first value.
    let valueOffset: Int

    /// Bytes per value for a TIFF field type, or `nil` if unknown.
    static func size(ofType type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1  // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: 2  // SHORT, SSHORT
        case 4, 9, 11, 13: 4  // LONG, SLONG, FLOAT, IFD
        case 5, 10, 12: 8  // RATIONAL, SRATIONAL, DOUBLE
        case 16, 17, 18: 8  // BigTIFF LONG8, SLONG8, IFD8
        default: nil
        }
    }
}

/// A parsed image file directory, classic TIFF or BigTIFF.
///
/// Classic entries are 12 bytes with values of up to 4 bytes inline;
/// BigTIFF entries are 20 bytes with 64-bit counts and offsets and values of
/// up to 8 bytes inline.
struct TIFFDirectory: Sendable {
    let entries: [UInt16: TIFFEntry]
    /// Offset of the next IFD, 0 at the end of the chain.
    let nextOffset: Int

    init(reader: ByteReader, offset: Int, bigTIFF: Bool = false) throws(MancoraIOError) {
        let countBytes = bigTIFF ? 8 : 2
        let entryBytes = bigTIFF ? 20 : 12
        let inlineBytes = bigTIFF ? 8 : 4
        let rawCount = bigTIFF ? try reader.u64(at: offset) : UInt64(try reader.u16(at: offset))
        guard rawCount <= UInt64(reader.count / entryBytes) else {
            throw .invalidFormat("IFD at \(offset) claims \(rawCount) entries")
        }
        let entryCount = Int(rawCount)
        try reader.check(offset + countBytes, entryCount * entryBytes + inlineBytes)
        var entries: [UInt16: TIFFEntry] = [:]
        for i in 0..<entryCount {
            let base = offset + countBytes + i * entryBytes
            let tag = try reader.u16(at: base)
            let type = try reader.u16(at: base + 2)
            let count = try Self.offset(reader, at: base + 4, bigTIFF: bigTIFF)
            // Unknown field types can't be sized; skip them as libtiff does.
            guard let size = TIFFEntry.size(ofType: type) else { continue }
            let (total, overflow) = count.multipliedReportingOverflow(by: size)
            guard !overflow else { throw .invalidFormat("tag \(tag) has an impossible count \(count)") }
            let valueField = base + 4 + inlineBytes
            let valueOffset = total <= inlineBytes ? valueField : try Self.offset(reader, at: valueField, bigTIFF: bigTIFF)
            if entries[tag] == nil {
                entries[tag] = TIFFEntry(tag: tag, type: type, count: count, valueOffset: valueOffset)
            }
        }
        self.entries = entries
        self.nextOffset = try Self.offset(reader, at: offset + countBytes + entryCount * entryBytes, bigTIFF: bigTIFF)
    }

    /// A 32-bit (classic) or 64-bit (BigTIFF) count or offset field.
    static func offset(_ reader: ByteReader, at position: Int, bigTIFF: Bool) throws(MancoraIOError) -> Int {
        guard bigTIFF else { return Int(try reader.u32(at: position)) }
        let value = try reader.u64(at: position)
        // Anything past Int.max can't be a position in an in-memory file.
        guard value <= UInt64(Int.max) else { throw .invalidFormat("offset \(value) at \(position) is out of range") }
        return Int(value)
    }

    func has(_ tag: UInt16) -> Bool { entries[tag] != nil }

    /// Integer values of a BYTE/SHORT/LONG (or signed) entry.
    func integers(_ tag: UInt16, _ reader: ByteReader) throws(MancoraIOError) -> [Int]? {
        guard let e = entries[tag] else { return nil }
        guard let size = TIFFEntry.size(ofType: e.type) else { return nil }
        try reader.check(e.valueOffset, e.count * size)
        var values: [Int] = []
        values.reserveCapacity(e.count)
        for i in 0..<e.count {
            let at = e.valueOffset + i * size
            switch e.type {
            case 1, 7: values.append(Int(try reader.u8(at: at)))
            case 6: values.append(Int(Int8(bitPattern: try reader.u8(at: at))))
            case 3: values.append(Int(try reader.u16(at: at)))
            case 8: values.append(Int(Int16(bitPattern: try reader.u16(at: at))))
            case 4, 13: values.append(Int(try reader.u32(at: at)))
            case 9: values.append(Int(Int32(bitPattern: try reader.u32(at: at))))
            case 16, 18:
                let v = try reader.u64(at: at)
                guard v <= UInt64(Int.max) else { throw .invalidFormat("tag \(tag) value \(v) is out of range") }
                values.append(Int(v))
            case 17: values.append(Int(Int64(bitPattern: try reader.u64(at: at))))
            default: throw .invalidFormat("tag \(tag) has non-integer type \(e.type)")
            }
        }
        return values
    }

    func integer(_ tag: UInt16, _ reader: ByteReader) throws(MancoraIOError) -> Int? {
        guard let e = entries[tag], e.count >= 1 else { return nil }
        return try integers(tag, reader)?.first
    }

    /// The first value of a RATIONAL entry.
    func rational(_ tag: UInt16, _ reader: ByteReader) throws(MancoraIOError) -> Double? {
        guard let e = entries[tag], e.count >= 1 else { return nil }
        switch e.type {
        case 5:
            let n = Double(try reader.u32(at: e.valueOffset))
            let d = Double(try reader.u32(at: e.valueOffset + 4))
            return d == 0 ? nil : n / d
        case 10:
            let n = Double(Int32(bitPattern: try reader.u32(at: e.valueOffset)))
            let d = Double(Int32(bitPattern: try reader.u32(at: e.valueOffset + 4)))
            return d == 0 ? nil : n / d
        default:
            return try integer(tag, reader).map(Double.init)
        }
    }

    /// An ASCII entry without its trailing NUL, or `nil` if absent.
    func string(_ tag: UInt16, _ reader: ByteReader) throws(MancoraIOError) -> String? {
        guard let e = entries[tag] else { return nil }
        var bytes = Array(try reader.slice(at: e.valueOffset, count: e.count))
        while bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
