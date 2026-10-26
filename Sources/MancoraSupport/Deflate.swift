/// A DEFLATE (RFC 1951) compressor: greedy LZ77 matches over a 32 KiB
/// window, coded with the fixed Huffman codes. Simple rather than small,
/// but any inflater reads it.
public enum Deflate {
    /// Raw DEFLATE data.
    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var out = BitWriter()
        // One final block with the fixed codes.
        out.write(1, bits: 1)
        out.write(1, bits: 2)
        let n = input.count
        let hashSize = 1 << 15
        var head = [Int32](repeating: -1, count: hashSize)
        var previous = [Int32](repeating: -1, count: 1 << 15)
        func hash(_ i: Int) -> Int {
            (Int(input[i]) << 10 ^ Int(input[i + 1]) << 5 ^ Int(input[i + 2])) & (hashSize - 1)
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            previous[i & 0x7FFF] = head[h]
            head[h] = Int32(i)
        }
        var i = 0
        while i < n {
            var bestLength = 0, bestDistance = 0
            if i + 2 < n {
                var candidate = Int(head[hash(i)])
                var chain = 128
                let maxLength = min(258, n - i)
                while candidate >= 0, i - candidate <= 32768, chain > 0 {
                    if input[candidate + bestLength] == input[i + bestLength] || bestLength == 0 {
                        var length = 0
                        while length < maxLength, input[candidate + length] == input[i + length] { length += 1 }
                        if length > bestLength {
                            bestLength = length
                            bestDistance = i - candidate
                            if length == maxLength { break }
                        }
                    }
                    let next = Int(previous[candidate & 0x7FFF])
                    if next >= candidate { break }
                    candidate = next
                    chain -= 1
                }
            }
            if bestLength >= 3 {
                out.writeLength(bestLength)
                out.writeDistance(bestDistance)
                for j in i..<(i + bestLength) { insert(j) }
                i += bestLength
            } else {
                out.writeLiteral(Int(input[i]))
                insert(i)
                i += 1
            }
        }
        out.writeLiteral(256)
        return out.finish()
    }

    /// A zlib stream (RFC 1950) holding `input`, as PNG's image data is.
    public static func zlib(_ input: [UInt8]) -> [UInt8] {
        let adler = Inflate.adler32(input)
        // CMF 0x78 (deflate, 32 KiB window), FLG 0x01 (no dictionary, check bits).
        return [0x78, 0x01] + compress(input)
            + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    /// A gzip member (RFC 1952) holding `input`.
    public static func gzip(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255]
        out += compress(input)
        let crc = Inflate.crc32(input)
        let size = UInt32(truncatingIfNeeded: input.count)
        for v in [crc, size] {
            out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        }
        return out
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
        6145, 8193, 12289, 16385, 24577,
    ]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    struct BitWriter {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var count = 0

        mutating func write(_ value: Int, bits: Int) {
            buffer |= UInt32(value) << UInt32(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        /// Huffman codes go most significant bit first.
        mutating func writeCode(_ code: Int, bits: Int) {
            var reversed = 0
            for b in 0..<bits where code & (1 << b) != 0 { reversed |= 1 << (bits - 1 - b) }
            write(reversed, bits: bits)
        }

        mutating func writeLiteral(_ symbol: Int) {
            switch symbol {
            case 0...143: writeCode(0x30 + symbol, bits: 8)
            case 144...255: writeCode(0x190 + symbol - 144, bits: 9)
            case 256...279: writeCode(symbol - 256, bits: 7)
            default: writeCode(0xC0 + symbol - 280, bits: 8)
            }
        }

        mutating func writeLength(_ length: Int) {
            var code = Deflate.lengthBase.count - 1
            while Deflate.lengthBase[code] > length { code -= 1 }
            writeLiteral(257 + code)
            if Deflate.lengthExtra[code] > 0 { write(length - Deflate.lengthBase[code], bits: Deflate.lengthExtra[code]) }
        }

        mutating func writeDistance(_ distance: Int) {
            var code = Deflate.distanceBase.count - 1
            while Deflate.distanceBase[code] > distance { code -= 1 }
            writeCode(code, bits: 5)
            if Deflate.distanceExtra[code] > 0 { write(distance - Deflate.distanceBase[code], bits: Deflate.distanceExtra[code]) }
        }

        mutating func finish() -> [UInt8] {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
            return bytes
        }
    }
}
