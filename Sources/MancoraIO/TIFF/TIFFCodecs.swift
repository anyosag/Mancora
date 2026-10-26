/// Decompressors for the TIFF compression schemes Mancora reads.
///
/// Each one writes at most `expectedCount` bytes and pads a short result
/// with zeros, so a corrupt chunk can't grow beyond the size the IFD
/// promised.
enum TIFFCodecs {
    /// Compression 32773 (Apple PackBits run-length encoding).
    static func unpackBits(_ input: ArraySlice<UInt8>, expectedCount: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expectedCount)
        var i = input.startIndex
        while i < input.endIndex, out.count < expectedCount {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                let run = min(n + 1, input.endIndex - i, expectedCount - out.count)
                out.append(contentsOf: input[i..<(i + run)])
                i += n + 1
            } else if n != -128 {
                guard i < input.endIndex else { break }
                let run = min(1 - n, expectedCount - out.count)
                out.append(contentsOf: repeatElement(input[i], count: run))
                i += 1
            }
        }
        if out.count < expectedCount { out.append(contentsOf: repeatElement(0, count: expectedCount - out.count)) }
        return out
    }

    /// Compression 5 (LZW, MSB-first codes with TIFF's "early change").
    ///
    /// Table entries are stored as (offset, length) spans of the output
    /// already written: an entry is always the previous code's output plus
    /// the first byte of the current one, which sits right after it.
    static func lzwDecode(_ input: ArraySlice<UInt8>, expectedCount: Int) throws(MancoraIOError) -> [UInt8] {
        let clearCode = 256, endCode = 257
        var out = [UInt8]()
        out.reserveCapacity(expectedCount)
        var spanStart = [Int](repeating: 0, count: 4096)
        var spanLength = [Int](repeating: 0, count: 4096)
        var nextCode = 258
        var codeWidth = 9
        var previous: (start: Int, length: Int)? = nil

        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var i = input.startIndex

        func emit(start: Int, length: Int) {
            // Copy forward one byte at a time: the source may overlap the
            // destination (the KwKwK case).
            for k in 0..<length where out.count < expectedCount {
                out.append(out[start + k])
            }
        }

        decoding: while out.count < expectedCount {
            while bitCount < codeWidth {
                guard i < input.endIndex else { break decoding }
                bitBuffer = bitBuffer << 8 | UInt32(input[i])
                bitCount += 8
                i += 1
            }
            let code = Int((bitBuffer >> UInt32(bitCount - codeWidth)) & ((1 << UInt32(codeWidth)) - 1))
            bitCount -= codeWidth
            bitBuffer &= (1 << UInt32(bitCount)) &- 1

            if code == clearCode {
                nextCode = 258
                codeWidth = 9
                previous = nil
                continue
            }
            if code == endCode { break }

            let start = out.count
            if code < 256 {
                out.append(UInt8(code))
            } else if code < nextCode {
                emit(start: spanStart[code], length: spanLength[code])
            } else if code == nextCode, let prev = previous {
                // The code being defined right now: previous + its first byte.
                emit(start: prev.start, length: prev.length)
                if out.count < expectedCount { out.append(out[prev.start]) }
            } else {
                throw .invalidFormat("corrupt LZW data (code \(code), next free code \(nextCode))")
            }
            let length = out.count - start

            if let prev = previous, nextCode < 4096 {
                spanStart[nextCode] = prev.start
                spanLength[nextCode] = prev.length + 1
                nextCode += 1
                if nextCode >= (1 << codeWidth) - 1, codeWidth < 12 { codeWidth += 1 }
            }
            previous = (start, length)
        }
        if out.count < expectedCount { out.append(contentsOf: repeatElement(0, count: expectedCount - out.count)) }
        return out
    }

    /// Undoes predictor 2 (horizontal differencing) on one chunk, in place.
    static func undoHorizontalDifferencing(
        _ data: inout [UInt8],
        rowBytes: Int,
        rows: Int,
        samplesPerPixel: Int,
        bitsPerSample: Int,
        bigEndian: Bool
    ) throws(MancoraIOError) {
        let bytesPerSample = bitsPerSample / 8
        let stride = samplesPerPixel * bytesPerSample
        guard [1, 2, 4].contains(bytesPerSample), bitsPerSample % 8 == 0 else {
            throw .unsupported("horizontal predictor with \(bitsPerSample)-bit samples")
        }
        for row in 0..<rows {
            let base = row * rowBytes
            var k = base + stride
            let end = base + rowBytes - (rowBytes % bytesPerSample)
            while k + bytesPerSample <= end {
                switch bytesPerSample {
                case 1:
                    data[k] = data[k] &+ data[k - stride]
                case 2:
                    let v = load16(data, k, bigEndian) &+ load16(data, k - stride, bigEndian)
                    store16(&data, k, v, bigEndian)
                default:
                    let v = load32(data, k, bigEndian) &+ load32(data, k - stride, bigEndian)
                    store32(&data, k, v, bigEndian)
                }
                k += bytesPerSample
            }
        }
    }

    /// Undoes predictor 3 (TIFF Technical Note 3, floating point) on one
    /// chunk, in place: byte-wise differencing across each row, whose bytes
    /// are stored most significant byte plane first.
    static func undoFloatingPointPredictor(
        _ data: inout [UInt8],
        rowBytes: Int,
        rows: Int,
        samplesPerPixel: Int,
        bytesPerSample: Int,
        bigEndian: Bool
    ) {
        let samples = rowBytes / bytesPerSample
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        for row in 0..<rows {
            let base = row * rowBytes
            for i in samplesPerPixel..<rowBytes {
                data[base + i] = data[base + i] &+ data[base + i - samplesPerPixel]
            }
            for i in 0..<rowBytes { scratch[i] = data[base + i] }
            for s in 0..<samples {
                for b in 0..<bytesPerSample {
                    let byte = scratch[b * samples + s]  // plane 0 holds the most significant bytes
                    data[base + s * bytesPerSample + (bigEndian ? b : bytesPerSample - 1 - b)] = byte
                }
            }
        }
    }

    /// IEEE 754 half precision to single precision.
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exponent = Int(h >> 10) & 0x1F
        let mantissa = UInt32(h & 0x03FF)
        switch exponent {
        case 0:
            // Zero or subnormal: mantissa × 2^-24.
            let value = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign != 0 ? -value : value
        case 31:
            return Float(bitPattern: sign | 0x7F80_0000 | mantissa << 13)
        default:
            return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | mantissa << 13)
        }
    }

    @inline(__always)
    static func load16(_ d: [UInt8], _ i: Int, _ be: Bool) -> UInt16 {
        be ? UInt16(d[i]) << 8 | UInt16(d[i + 1]) : UInt16(d[i + 1]) << 8 | UInt16(d[i])
    }

    @inline(__always)
    static func store16(_ d: inout [UInt8], _ i: Int, _ v: UInt16, _ be: Bool) {
        let hi = UInt8(v >> 8), lo = UInt8(v & 0xFF)
        if be { d[i] = hi; d[i + 1] = lo } else { d[i] = lo; d[i + 1] = hi }
    }

    @inline(__always)
    static func load32(_ d: [UInt8], _ i: Int, _ be: Bool) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v = v << 8 | UInt32(d[i + (be ? k : 3 - k)]) }
        return v
    }

    @inline(__always)
    static func store32(_ d: inout [UInt8], _ i: Int, _ v: UInt32, _ be: Bool) {
        for k in 0..<4 {
            let byte = UInt8(truncatingIfNeeded: v >> UInt32(8 * (3 - k)))
            d[i + (be ? k : 3 - k)] = byte
        }
    }
}
