/// ImageJ's private TIFF metadata: tag 50839 holds an `IJIJ` header and a
/// sequence of typed records, and tag 50838 the byte count of the header and
/// of each record (`TiffEncoder.writeMetaData`, `TiffDecoder.getMetaData`).
struct ImageJMetadata: Sendable, Equatable {
    /// Record types, as the four ASCII bytes ImageJ writes for each.
    enum RecordType: UInt32 {
        case info = 0x696E_666F  // "info"
        case labels = 0x6C61_626C  // "labl"
        case ranges = 0x7261_6E67  // "rang"
        case luts = 0x6C75_7473  // "luts"
        case plot = 0x706C_6F74  // "plot"
        case roi = 0x726F_6920  // "roi "
        case overlay = 0x6F76_6572  // "over"
        case properties = 0x7072_6F70  // "prop"
    }

    static let magic: UInt32 = 0x494A_494A  // "IJIJ"

    var info: String?
    /// One per image, `nil` for unlabeled ones.
    var labels: [String?] = []
    /// Display range pairs, `min0, max0, min1, max1, …`, one per channel.
    var ranges: [Double] = []
    /// 768 bytes per channel: 256 reds, then greens, then blues.
    var luts: [[UInt8]] = []
    var plot: [UInt8]?
    var roi: [UInt8]?
    var overlay: [[UInt8]] = []
    /// Alternating keys and values.
    var properties: [String] = []

    var isEmpty: Bool {
        info == nil && labels.isEmpty && ranges.isEmpty && luts.isEmpty && plot == nil && roi == nil
            && overlay.isEmpty && properties.isEmpty
    }

    // MARK: Reading

    /// Parses the records, or returns `nil` for anything ImageJ itself would
    /// skip: a missing or odd header, or counts that run past the data.
    /// Unknown record types are skipped.
    init?(counts: [Int], data: ArraySlice<UInt8>, bigEndian: Bool) {
        guard let headerSize = counts.first, (12...804).contains(headerSize), headerSize <= data.count else {
            return nil
        }
        let reader = ByteReader(Array(data), bigEndian: bigEndian)
        guard (try? reader.u32(at: 0)) == Self.magic else { return nil }

        var position = headerSize
        var countIndex = 1
        for t in 0..<(headerSize - 4) / 8 {
            guard let rawType = try? reader.u32(at: 4 + t * 8), let rawCount = try? reader.u32(at: 8 + t * 8),
                rawCount <= UInt32(counts.count - countIndex)
            else { return nil }
            var records: [[UInt8]] = []
            for _ in 0..<Int(rawCount) {
                let length = counts[countIndex]
                guard length >= 0, let bytes = try? reader.slice(at: position, count: length) else { return nil }
                records.append(Array(bytes))
                position += length
                countIndex += 1
            }
            switch RecordType(rawValue: rawType) {
            case .info: info = records.first.map { Self.string(fromUTF16: $0, bigEndian: bigEndian) }
            case .labels:
                labels = records.map { $0.isEmpty ? nil : Self.string(fromUTF16: $0, bigEndian: bigEndian) }
            case .ranges:
                guard let bytes = records.first else { break }
                let r = ByteReader(bytes, bigEndian: bigEndian)
                ranges = (0..<bytes.count / 8).compactMap { i in
                    (try? r.u64(at: i * 8)).map { Double(bitPattern: $0) }
                }
            case .luts: luts = records
            case .plot: plot = records.first
            case .roi: roi = records.first
            case .overlay: overlay = records
            case .properties: properties = records.map { Self.string(fromUTF16: $0, bigEndian: bigEndian) }
            case nil: break
            }
        }
    }

    /// Java `char`s in the file's byte order. (ImageJ's own little-endian
    /// decoding drops the high byte of each char; Mancora decodes them whole.)
    static func string(fromUTF16 bytes: [UInt8], bigEndian: Bool) -> String {
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { i in
            bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Writing

    init() {}

    /// The values of tags 50838 (byte counts) and 50839 (data), in the
    /// order `TiffEncoder` writes them; empty if there's nothing to save.
    func encoded(bigEndian: Bool) -> (counts: [UInt32], data: [UInt8]) {
        var types: [(RecordType, [[UInt8]])] = []
        func utf16(_ s: String) -> [UInt8] {
            s.utf16.flatMap { u in bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)] }
        }
        if let info, !info.isEmpty { types.append((.info, [utf16(info)])) }
        if labels.contains(where: { !($0 ?? "").isEmpty }) { types.append((.labels, labels.map { utf16($0 ?? "") })) }
        if !ranges.isEmpty {
            types.append((.ranges, [ranges.flatMap { Self.bytes(of: $0.bitPattern, count: 8, bigEndian: bigEndian) }]))
        }
        if !luts.isEmpty { types.append((.luts, luts)) }
        if let plot { types.append((.plot, [plot])) }
        if let roi { types.append((.roi, [roi])) }
        if !overlay.isEmpty { types.append((.overlay, overlay)) }
        if !properties.isEmpty { types.append((.properties, properties.map(utf16))) }
        guard !types.isEmpty else { return ([], []) }

        let headerSize = 4 + types.count * 8
        var counts = [UInt32(headerSize)]
        var data = Self.bytes(of: UInt64(Self.magic), count: 4, bigEndian: bigEndian)
        for (type, records) in types {
            data += Self.bytes(of: UInt64(type.rawValue), count: 4, bigEndian: bigEndian)
            data += Self.bytes(of: UInt64(records.count), count: 4, bigEndian: bigEndian)
        }
        for (_, records) in types {
            for record in records {
                counts.append(UInt32(record.count))
                data += record
            }
        }
        return (counts, data)
    }

    static func bytes(of value: UInt64, count: Int, bigEndian: Bool) -> [UInt8] {
        let little = (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
        return bigEndian ? little.reversed() : little
    }
}
