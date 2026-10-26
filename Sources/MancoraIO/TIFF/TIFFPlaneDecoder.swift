import MancoraCore
import MancoraSupport

/// Decodes one TIFF page (IFD) into planes: one, or one per sample for
/// 16-bit RGB(A).
enum TIFFPlaneDecoder {
    /// The most a scheme can expand its input. A chunk claiming to decode to
    /// more than this is corrupt, so it's rejected before anything is allocated.
    static func maximumExpansion(forCompression compression: Int) -> Int {
        switch compression {
        case 1: 1
        case 32773: 64  // 2 bytes → 128 bytes
        case 8, 32946: 1100  // DEFLATE tops out near 1032:1
        default: 4096  // LZW: one 9-bit code yields at most 4096 bytes
        }
    }

    static func decode(_ page: TIFFPage, reader: ByteReader) throws(MancoraIOError) -> [Plane] {
        let samplePlaneCount = page.isPlanar ? page.samplesPerPixel : 1
        let rowBytes = page.chunkRowBytes(page.width)
        let chunkRowBytes = page.chunkRowBytes(page.chunkWidth)
        var samplePlanes: [[UInt8]] = []
        samplePlanes.reserveCapacity(samplePlaneCount)

        for sample in 0..<samplePlaneCount {
            var buffer = [UInt8](repeating: 0, count: rowBytes * page.height)
            for cy in 0..<page.chunksDown {
                for cx in 0..<page.chunksAcross {
                    let index = sample * page.chunksPerSamplePlane + cy * page.chunksAcross + cx
                    let x0 = cx * page.chunkWidth, y0 = cy * page.chunkHeight
                    // Strips end at the image edge; tiles are always full size.
                    let rows = page.tileSize == nil ? min(page.chunkHeight, page.height - y0) : page.chunkHeight
                    var chunk = try chunkBytes(page, index: index, expected: chunkRowBytes * rows, reader: reader)
                    if page.predictor == 2 {
                        try TIFFCodecs.undoHorizontalDifferencing(
                            &chunk,
                            rowBytes: chunkRowBytes,
                            rows: rows,
                            samplesPerPixel: page.samplesPerChunkPixel,
                            bitsPerSample: page.bitsPerSample,
                            bigEndian: reader.bigEndian
                        )
                    } else if page.predictor == 3 {
                        TIFFCodecs.undoFloatingPointPredictor(
                            &chunk,
                            rowBytes: chunkRowBytes,
                            rows: rows,
                            samplesPerPixel: page.samplesPerChunkPixel,
                            bytesPerSample: page.bytesPerSample,
                            bigEndian: reader.bigEndian
                        )
                    }
                    let copyBytes = page.chunkRowBytes(min(page.chunkWidth, page.width - x0))
                    let dstX = page.chunkRowBytes(x0)
                    let visibleRows = min(rows, page.height - y0)
                    buffer.withUnsafeMutableBytes { dst in
                        chunk.withUnsafeBytes { src in
                            for r in 0..<visibleRows {
                                let s = r * chunkRowBytes, d = (y0 + r) * rowBytes + dstX
                                UnsafeMutableRawBufferPointer(rebasing: dst[d..<(d + copyBytes)])
                                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: src[s..<(s + copyBytes)]))
                            }
                        }
                    }
                }
            }
            samplePlanes.append(buffer)
        }
        return try convert(page, samplePlanes, bigEndian: reader.bigEndian)
    }

    /// Decodes uncompressed chunky pixel data that starts at `offset`, as in
    /// ImageJ stacks whose planes follow each other with no IFD of their own.
    static func decodeContiguous(_ page: TIFFPage, at offset: Int, reader: ByteReader) throws(MancoraIOError) -> [Plane] {
        let count = page.chunkRowBytes(page.width) * page.height
        return try convert(page, [Array(try reader.slice(at: offset, count: count))], bigEndian: reader.bigEndian)
    }

    private static func chunkBytes(
        _ page: TIFFPage,
        index: Int,
        expected: Int,
        reader: ByteReader
    ) throws(MancoraIOError) -> [UInt8] {
        let offset = page.chunkOffsets[index]
        if page.compression == 1 {
            // Like ImageJ, trust the geometry over StripByteCounts for raw data.
            return Array(try reader.slice(at: offset, count: expected))
        }
        guard offset >= 0, offset <= reader.count else {
            throw .truncated(offset: offset, needed: 1, available: 0)
        }
        let available = reader.count - offset
        let count = min(page.chunkByteCounts?[index] ?? available, available)
        let (limit, overflow) = max(count, 1).multipliedReportingOverflow(
            by: maximumExpansion(forCompression: page.compression)
        )
        guard overflow || expected <= limit else {
            throw .invalidFormat("chunk \(index) claims to expand \(count) bytes to \(expected)")
        }
        let input = try reader.slice(at: offset, count: count)
        switch page.compression {
        case 5: return try TIFFCodecs.lzwDecode(input, expectedCount: expected)
        case 32773: return TIFFCodecs.unpackBits(input, expectedCount: expected)
        case 8, 32946:
            do {
                var out = try Inflate.zlib(input, stopAt: expected, limit: expected)
                if out.count < expected { out.append(contentsOf: repeatElement(0, count: expected - out.count)) }
                return out
            } catch {
                throw .invalidFormat("corrupt Deflate data in chunk \(index) (\(error))")
            }
        default: throw .unsupported("compression scheme \(page.compression)")
        }
    }

    private static func convert(_ page: TIFFPage, _ planes: [[UInt8]], bigEndian: Bool) throws(MancoraIOError) -> [Plane] {
        if page.planesPerPage > 1 {
            // 16-bit RGB(A): one 16-bit plane per sample, from planar or chunky data.
            let n = page.width * page.height
            return (0..<page.planesPerPage).map { c in
                var out = [UInt16](repeating: 0, count: n)
                if page.isPlanar {
                    for i in 0..<n { out[i] = TIFFCodecs.load16(planes[c], i * 2, bigEndian) }
                } else {
                    let stride = page.samplesPerPixel * 2
                    for i in 0..<n { out[i] = TIFFCodecs.load16(planes[0], i * stride + c * 2, bigEndian) }
                }
                return .gray16(out)
            }
        }
        return [try convertSingle(page, planes, bigEndian: bigEndian)]
    }

    private static func convertSingle(_ page: TIFFPage, _ planes: [[UInt8]], bigEndian: Bool) throws(MancoraIOError) -> Plane {
        let n = page.width * page.height
        let data = planes[0]
        switch (page.bitsPerSample, page.samplesPerPixel) {
        case (1, 1):
            let rowBytes = (page.width + 7) / 8
            var out = [UInt8](repeating: 0, count: n)
            for y in 0..<page.height {
                for x in 0..<page.width where data[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 {
                    out[y * page.width + x] = 255
                }
            }
            return .gray8(out)

        case (8, 1):
            return .gray8(data)

        case (16, 1) where page.sampleFormat == .float:
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = TIFFCodecs.halfToFloat(TIFFCodecs.load16(data, i * 2, bigEndian)) }
            return .gray32Float(out)

        case (64, 1):
            // Double-precision data is narrowed to float, like ImageJ's 32-bit type.
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let hi = UInt64(TIFFCodecs.load32(data, i * 8 + (bigEndian ? 0 : 4), bigEndian))
                let lo = UInt64(TIFFCodecs.load32(data, i * 8 + (bigEndian ? 4 : 0), bigEndian))
                out[i] = Float(Double(bitPattern: hi << 32 | lo))
            }
            return .gray32Float(out)

        case (16, 1):
            var out = [UInt16](repeating: 0, count: n)
            let flip: UInt16 = page.sampleFormat == .signed ? 0x8000 : 0  // signed → offset by 32768
            for i in 0..<n {
                out[i] = TIFFCodecs.load16(data, i * 2, bigEndian) ^ flip
            }
            return .gray16(out)

        case (32, 1):
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let bits = TIFFCodecs.load32(data, i * 4, bigEndian)
                switch page.sampleFormat {
                case .float: out[i] = Float(bitPattern: bits)
                case .unsigned: out[i] = Float(bits)
                case .signed: out[i] = Float(Int32(bitPattern: bits))
                }
            }
            return .gray32Float(out)

        case (8, 3...4):
            var out = [UInt32](repeating: 0, count: n)
            if page.isPlanar {
                let (r, g, b) = (planes[0], planes[1], planes[2])
                for i in 0..<n {
                    out[i] = 0xFF00_0000 | UInt32(r[i]) << 16 | UInt32(g[i]) << 8 | UInt32(b[i])
                }
            } else {
                let spp = page.samplesPerPixel
                for i in 0..<n {
                    let p = i * spp
                    out[i] = 0xFF00_0000 | UInt32(data[p]) << 16 | UInt32(data[p + 1]) << 8 | UInt32(data[p + 2])
                }
            }
            return .rgb8(out)

        default:
            throw .unsupported("\(page.bitsPerSample)-bit samples with \(page.samplesPerPixel) samples per pixel")
        }
    }
}
