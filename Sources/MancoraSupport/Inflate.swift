/// DEFLATE decompression (RFC 1951) with the zlib (RFC 1950) and gzip
/// (RFC 1952) wrappers, in pure Swift.
///
/// Used for Deflate-compressed TIFFs, zip archives (RoiSet.zip) and Fiji
/// update-site indexes (`db.xml.gz`). Output is capped at `limit` bytes, so a
/// malicious stream can't exhaust memory.
public enum Inflate {
    public enum Error: Swift.Error, Equatable, Sendable {
        case truncated
        case invalidHeader(String)
        case invalidBlock(String)
        case outputLimit(Int)
        case checksumMismatch
    }

    /// Decompresses a raw DEFLATE stream.
    /// - Parameter stopAt: stop once this many bytes are out (TIFF chunks know
    ///   their size; trailing garbage after that point is ignored).
    public static func raw(_ input: ArraySlice<UInt8>, stopAt: Int? = nil, limit: Int = .max) throws(Error) -> [UInt8] {
        var decoder = Decoder(input: input, limit: limit, stopAt: stopAt)
        try decoder.run()
        return decoder.output
    }

    /// Decompresses a zlib stream, checking its Adler-32 when the stream is
    /// complete.
    public static func zlib(_ input: ArraySlice<UInt8>, stopAt: Int? = nil, limit: Int = .max) throws(Error) -> [UInt8] {
        guard input.count >= 2 else { throw .truncated }
        let cmf = input[input.startIndex], flg = input[input.startIndex + 1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw .invalidHeader("not a zlib stream")
        }
        guard flg & 0x20 == 0 else { throw .invalidHeader("preset dictionaries are not supported") }
        var decoder = Decoder(input: input.dropFirst(2), limit: limit, stopAt: stopAt)
        try decoder.run()
        if decoder.finished, let trailer = decoder.bytesAfterStream(4) {
            let expected = trailer.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard adler32(decoder.output) == expected else { throw .checksumMismatch }
        }
        return decoder.output
    }

    /// Decompresses a gzip file, including multi-member files, checking each
    /// member's CRC-32.
    public static func gzip(_ input: ArraySlice<UInt8>, limit: Int = .max) throws(Error) -> [UInt8] {
        var output: [UInt8] = []
        var rest = input
        repeat {
            guard rest.count >= 18 else { throw .truncated }
            let s = rest.startIndex
            guard rest[s] == 0x1F, rest[s + 1] == 0x8B, rest[s + 2] == 8 else { throw .invalidHeader("not a gzip file") }
            let flags = rest[s + 3]
            var i = s + 10
            if flags & 0x04 != 0 {  // FEXTRA
                guard i + 2 <= rest.endIndex else { throw .truncated }
                i += 2 + (Int(rest[i]) | Int(rest[i + 1]) << 8)
            }
            for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {  // FNAME, FCOMMENT
                while i < rest.endIndex, rest[i] != 0 { i += 1 }
                i += 1
            }
            if flags & 0x02 != 0 { i += 2 }  // FHCRC
            guard i <= rest.endIndex else { throw .truncated }
            var decoder = Decoder(input: rest[i...], limit: limit - output.count, stopAt: nil)
            try decoder.run()
            guard let trailer = decoder.bytesAfterStream(8) else { throw .truncated }
            let crc = trailer[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard crc32(decoder.output) == crc else { throw .checksumMismatch }
            output += decoder.output
            rest = rest[(decoder.streamEnd + 8)...]
        } while rest.count >= 2 && rest[rest.startIndex] == 0x1F && rest[rest.startIndex + 1] == 0x8B
        return output
    }

    public static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 5552, data.count)  // largest run before the sums can overflow
            while i < end {
                a &+= UInt32(data[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - Decoder

extension Inflate {
    /// A canonical Huffman code as a lookup table indexed by the next
    /// `maxLength` input bits (LSB first): each entry is symbol << 4 | length.
    struct HuffmanTable {
        var entries: [UInt32]
        var maxLength: Int

        init(lengths: ArraySlice<UInt8>) throws(Error) {
            let maxLength = Int(lengths.max() ?? 0)
            var count = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { count[Int(l)] += 1 }
            // Reject over-subscribed codes (incomplete ones are allowed, as zlib does).
            var left = 1
            for len in 1...15 {
                left <<= 1
                left -= count[len]
                guard left >= 0 else { throw .invalidBlock("over-subscribed Huffman code") }
            }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for len in 1...15 {
                code = (code + count[len - 1]) << 1
                next[len] = code
            }
            let size = 1 << max(maxLength, 1)
            var entries = [UInt32](repeating: 0, count: size)
            for (symbol, l) in lengths.enumerated() where l > 0 {
                let len = Int(l)
                let c = next[len]
                next[len] += 1
                // Reverse the code: DEFLATE sends Huffman codes MSB first.
                var reversed = 0
                for bit in 0..<len where c & (1 << bit) != 0 { reversed |= 1 << (len - 1 - bit) }
                let entry = UInt32(symbol) << 4 | UInt32(len)
                var index = reversed
                while index < size {
                    entries[index] = entry
                    index += 1 << len
                }
            }
            self.entries = entries
            self.maxLength = max(maxLength, 1)
        }
    }

    struct Decoder {
        let input: ArraySlice<UInt8>
        let limit: Int
        let stopAt: Int?
        var output: [UInt8] = []
        var position: Int
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var finished = false

        init(input: ArraySlice<UInt8>, limit: Int, stopAt: Int?) {
            self.input = input
            self.limit = limit
            self.stopAt = stopAt
            self.position = input.startIndex
            if let stopAt { output.reserveCapacity(min(stopAt, limit)) }
        }

        /// The input index just past the deflate stream (after the final block,
        /// rounded up to a whole byte).
        var streamEnd: Int { position - bitCount / 8 }

        func bytesAfterStream(_ n: Int) -> [UInt8]? {
            let start = streamEnd
            guard start + n <= input.endIndex else { return nil }
            return Array(input[start..<(start + n)])
        }

        var done: Bool { stopAt.map { output.count >= $0 } ?? false }

        @inline(__always)
        mutating func need(_ n: Int) throws(Error) {
            while bitCount < n {
                guard position < input.endIndex else { throw .truncated }
                bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
                position += 1
                bitCount += 8
            }
        }

        @inline(__always)
        mutating func bits(_ n: Int) throws(Error) -> Int {
            if n == 0 { return 0 }
            try need(n)
            let v = Int(bitBuffer & ((1 << UInt64(n)) - 1))
            bitBuffer >>= UInt64(n)
            bitCount -= n
            return v
        }

        @inline(__always)
        mutating func decode(_ table: HuffmanTable) throws(Error) -> Int {
            // Near the end of the input there may be fewer bits than the table
            // width; pad with zeros and check the code actually fits.
            while bitCount < table.maxLength, position < input.endIndex {
                bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
                position += 1
                bitCount += 8
            }
            let entry = table.entries[Int(bitBuffer & ((1 << UInt64(table.maxLength)) - 1))]
            let length = Int(entry & 0xF)
            guard length > 0, length <= bitCount else { throw length == 0 ? .invalidBlock("bad Huffman code") : .truncated }
            bitBuffer >>= UInt64(length)
            bitCount -= length
            return Int(entry >> 4)
        }

        mutating func emit(_ byte: UInt8) throws(Error) {
            guard output.count < limit else { throw .outputLimit(limit) }
            output.append(byte)
        }

        /// Decodes blocks until the final one ends, or until `stopAt` bytes are
        /// out (then `finished` stays false and trailers aren't checked).
        mutating func run() throws(Error) {
            while !done {
                let last = try bits(1) == 1
                let completed: Bool
                switch try bits(2) {
                case 0: completed = try stored()
                case 1: completed = try codes(literal: Self.fixedLiteral, distance: Self.fixedDistance)
                case 2:
                    let (lit, dist) = try dynamicTables()
                    completed = try codes(literal: lit, distance: dist)
                default: throw .invalidBlock("reserved block type")
                }
                if completed && last {
                    finished = true
                    return
                }
            }
        }

        /// Returns whether the block ended (rather than stopping at `stopAt`).
        mutating func stored() throws(Error) -> Bool {
            // Drop to a byte boundary.
            bitBuffer >>= UInt64(bitCount % 8)
            bitCount -= bitCount % 8
            let len = try bits(16)
            let nlen = try bits(16)
            guard len == ~nlen & 0xFFFF else { throw .invalidBlock("stored block length check failed") }
            for _ in 0..<len {
                if done { return false }
                try emit(UInt8(try bits(8)))
            }
            return true
        }

        static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        static let fixedLiteral: HuffmanTable = {
            var lengths = [UInt8](repeating: 8, count: 288)
            for i in 144..<256 { lengths[i] = 9 }
            for i in 256..<280 { lengths[i] = 7 }
            return try! HuffmanTable(lengths: lengths[...])
        }()
        static let fixedDistance = try! HuffmanTable(lengths: [UInt8](repeating: 5, count: 30)[...])

        mutating func dynamicTables() throws(Error) -> (HuffmanTable, HuffmanTable) {
            let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
            guard hlit <= 286, hdist <= 30 else { throw .invalidBlock("too many length or distance codes") }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var codeLengths = [UInt8](repeating: 0, count: 19)
            for i in 0..<hclen { codeLengths[order[i]] = UInt8(try bits(3)) }
            let codeTable = try HuffmanTable(lengths: codeLengths[...])
            var lengths: [UInt8] = []
            lengths.reserveCapacity(hlit + hdist)
            while lengths.count < hlit + hdist {
                let symbol = try decode(codeTable)
                switch symbol {
                case 0..<16: lengths.append(UInt8(symbol))
                case 16:
                    guard let previous = lengths.last else { throw .invalidBlock("repeat with no previous length") }
                    lengths += repeatElement(previous, count: 3 + (try bits(2)))
                case 17: lengths += repeatElement(0, count: 3 + (try bits(3)))
                default: lengths += repeatElement(0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == hlit + hdist else { throw .invalidBlock("code lengths overrun") }
            guard lengths[256] != 0 else { throw .invalidBlock("no end-of-block code") }
            return (try HuffmanTable(lengths: lengths[0..<hlit]), try HuffmanTable(lengths: lengths[hlit...]))
        }

        mutating func codes(literal: HuffmanTable, distance: HuffmanTable) throws(Error) -> Bool {
            while !done {
                let symbol = try decode(literal)
                if symbol < 256 {
                    try emit(UInt8(symbol))
                } else if symbol == 256 {
                    return true
                } else {
                    let li = symbol - 257
                    guard li < 29 else { throw .invalidBlock("bad length code") }
                    let length = Self.lengthBase[li] + (try bits(Self.lengthExtra[li]))
                    let di = try decode(distance)
                    guard di < 30 else { throw .invalidBlock("bad distance code") }
                    let dist = Self.distanceBase[di] + (try bits(Self.distanceExtra[di]))
                    guard dist <= output.count else { throw .invalidBlock("distance too far back") }
                    // A match that crosses `stopAt` is cut there, not counted against `limit`.
                    let copied = stopAt.map { min(length, $0 - output.count) } ?? length
                    guard output.count + copied <= limit else { throw .outputLimit(limit) }
                    let start = output.count - dist
                    for k in 0..<copied { output.append(output[start + k]) }
                    if copied < length { return false }
                }
            }
            return false
        }
    }
}
