import MancoraCore

/// The image-describing fields of one IFD, validated.
struct TIFFPage: Sendable {
    enum SampleFormat: Int, Sendable { case unsigned = 1, signed = 2, float = 3 }

    let width: Int
    let height: Int
    let bitsPerSample: Int
    let samplesPerPixel: Int
    let sampleFormat: SampleFormat
    let photometric: Int
    let compression: Int
    let predictor: Int
    let isPlanar: Bool
    let isReducedResolution: Bool
    /// Tile size, or `nil` for strips.
    let tileSize: (width: Int, height: Int)?
    let rowsPerStrip: Int
    let chunkOffsets: [Int]
    let chunkByteCounts: [Int]?
    let colorMap: [UInt16]?
    let description: String?
    let xResolution: Double?
    let yResolution: Double?
    let resolutionUnit: Int

    init(directory d: TIFFDirectory, reader r: ByteReader) throws(MancoraIOError) {
        guard let width = try d.integer(TIFFTag.imageWidth, r), let height = try d.integer(TIFFTag.imageLength, r),
            width > 0, height > 0
        else { throw .invalidFormat("missing or zero image size") }
        self.width = width
        self.height = height

        let bits = try d.integers(TIFFTag.bitsPerSample, r) ?? [1]
        guard let firstBits = bits.first, bits.allSatisfy({ $0 == firstBits }) else {
            throw .unsupported("samples with different bit depths \(bits)")
        }
        bitsPerSample = firstBits
        samplesPerPixel = try d.integer(TIFFTag.samplesPerPixel, r) ?? 1
        guard (1...4).contains(samplesPerPixel) else {
            throw .unsupported("\(samplesPerPixel) samples per pixel")
        }
        let format = try d.integer(TIFFTag.sampleFormat, r) ?? 1
        guard let sampleFormat = SampleFormat(rawValue: format == 4 ? 1 : format) else {
            throw .unsupported("sample format \(format)")
        }
        self.sampleFormat = sampleFormat
        photometric = try d.integer(TIFFTag.photometric, r) ?? 1
        compression = try d.integer(TIFFTag.compression, r) ?? 1
        predictor = try d.integer(TIFFTag.predictor, r) ?? 1
        isPlanar = (try d.integer(TIFFTag.planarConfiguration, r) ?? 1) == 2 && samplesPerPixel > 1
        isReducedResolution = ((try d.integer(TIFFTag.newSubfileType, r) ?? 0) & 1) != 0

        if let tw = try d.integer(TIFFTag.tileWidth, r), let th = try d.integer(TIFFTag.tileLength, r) {
            guard tw > 0, th > 0 else { throw .invalidFormat("zero tile size") }
            tileSize = (tw, th)
            guard let offsets = try d.integers(TIFFTag.tileOffsets, r) else {
                throw .invalidFormat("tiled image without TileOffsets")
            }
            chunkOffsets = offsets
            chunkByteCounts = try d.integers(TIFFTag.tileByteCounts, r)
        } else {
            tileSize = nil
            guard let offsets = try d.integers(TIFFTag.stripOffsets, r) else {
                throw .invalidFormat("image without StripOffsets")
            }
            chunkOffsets = offsets
            chunkByteCounts = try d.integers(TIFFTag.stripByteCounts, r)
        }
        let rps = try d.integer(TIFFTag.rowsPerStrip, r) ?? height
        rowsPerStrip = rps <= 0 ? height : min(rps, height)

        if photometric == 3, bitsPerSample == 8, samplesPerPixel == 1,
            let map = try d.integers(TIFFTag.colorMap, r), map.count == 768
        {
            colorMap = map.map { UInt16(truncatingIfNeeded: $0) }
        } else {
            colorMap = nil
        }
        // ImageJ ignores descriptions of 3 characters or fewer.
        let text = try d.string(TIFFTag.imageDescription, r)
        description = (text?.count ?? 0) > 3 ? text : nil
        xResolution = try d.rational(TIFFTag.xResolution, r)
        yResolution = try d.rational(TIFFTag.yResolution, r)
        resolutionUnit = try d.integer(TIFFTag.resolutionUnit, r) ?? 2

        try validate()
    }

    /// The Mancora pixel type these samples decode to.
    var pixelType: PixelType {
        if samplesPerPixel >= 3 { return .rgb8 }
        switch bitsPerSample {
        case 16: return .gray16
        case 32: return .gray32Float
        default: return .gray8
        }
    }

    var bytesPerSample: Int { max(bitsPerSample / 8, 1) }

    /// Bytes of one decoded plane as stored in Mancora.
    var decodedPlaneBytes: Int { width * height * pixelType.bytesPerPixel }

    /// Pages that can be stacked together must agree on these.
    var stackSignature: [Int] {
        [width, height, bitsPerSample, samplesPerPixel, sampleFormat.rawValue, photometric]
    }

    private func validate() throws(MancoraIOError) {
        switch (bitsPerSample, samplesPerPixel) {
        case (1, 1), (8, 1), (16, 1), (32, 1): break
        case (8, 3), (8, 4): break
        case (16, 3), (16, 4): throw .unsupported("48-bit RGB (arrives in Phase 1)")
        default: throw .unsupported("\(bitsPerSample)-bit samples with \(samplesPerPixel) samples per pixel")
        }
        if bitsPerSample == 16, sampleFormat == .float { throw .unsupported("16-bit float samples") }
        if bitsPerSample == 1, tileSize != nil { throw .unsupported("tiled 1-bit images") }
        if bitsPerSample == 1, compression != 1, compression != 32773 {
            throw .unsupported("1-bit images with compression \(compression)")
        }
        switch compression {
        case 1, 5, 32773: break
        case 8, 32946: throw .unsupported("Deflate compression (arrives in Phase 1)")
        case 7: throw .unsupported("JPEG compression")
        default: throw .unsupported("compression scheme \(compression)")
        }
        switch predictor {
        case 1: break
        case 2 where bitsPerSample >= 8: break
        default: throw .unsupported("predictor \(predictor)")
        }
        // Like ImageJ, read any 3- or 4-sample 8-bit image as RGB, except
        // CMYK and YCbCr, whose values would need converting.
        if samplesPerPixel >= 3, photometric == 5 { throw .unsupported("CMYK images") }
        if samplesPerPixel >= 3, photometric == 6 { throw .unsupported("YCbCr images") }
        let expectedChunks = chunkCount
        guard chunkOffsets.count >= expectedChunks else {
            throw .invalidFormat("\(chunkOffsets.count) image chunks; expected \(expectedChunks)")
        }
        if let counts = chunkByteCounts, counts.count < expectedChunks {
            throw .invalidFormat("\(counts.count) chunk byte counts; expected \(expectedChunks)")
        }
    }

    // MARK: Chunk geometry

    /// Samples per pixel within one chunk (1 for planar data).
    var samplesPerChunkPixel: Int { isPlanar ? 1 : samplesPerPixel }

    var chunksAcross: Int { tileSize.map { (width + $0.width - 1) / $0.width } ?? 1 }
    var chunksDown: Int {
        if let t = tileSize { return (height + t.height - 1) / t.height }
        return (height + rowsPerStrip - 1) / rowsPerStrip
    }
    var chunksPerSamplePlane: Int { chunksAcross * chunksDown }
    var chunkCount: Int { chunksPerSamplePlane * (isPlanar ? samplesPerPixel : 1) }

    /// Width and height of the chunk grid cell in pixels (tiles are padded).
    var chunkWidth: Int { tileSize?.width ?? width }
    var chunkHeight: Int { tileSize?.height ?? rowsPerStrip }

    func chunkRowBytes(_ pixelsAcross: Int) -> Int {
        (pixelsAcross * samplesPerChunkPixel * bitsPerSample + 7) / 8
    }
}
