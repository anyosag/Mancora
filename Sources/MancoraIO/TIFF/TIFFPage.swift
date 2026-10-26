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
    /// ImageJ's private metadata, when the file has it (first IFD only).
    let imageJMetadata: ImageJMetadata?
    /// What ImageJ shows as the Info of a file without its own: the
    /// ImageDescription (unless ImageJ wrote it) and the Software, DateTime,
    /// Artist and HostComputer tags, as `Name: value` lines.
    let tiffInfo: String?
    let xResolution: Double?
    let yResolution: Double?
    /// `nil` without a ResolutionUnit tag (which ImageJ treats as uncalibrated).
    let resolutionUnit: Int?

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

        // Like ImageJ, read a 768-entry ColorMap whatever the photometric
        // interpretation; it's the LUT of single-sample images.
        if samplesPerPixel == 1, [8, 16, 32].contains(bitsPerSample),
            let map = try d.integers(TIFFTag.colorMap, r), map.count == 768
        {
            colorMap = map.map { UInt16(truncatingIfNeeded: $0) }
        } else {
            colorMap = nil
        }
        // ImageJ ignores text tags of 3 characters or fewer.
        func text(_ tag: UInt16) throws(MancoraIOError) -> String? {
            let value = try d.string(tag, r)
            return (value?.count ?? 0) > 3 ? value : nil
        }
        description = try text(TIFFTag.imageDescription)
        var infoLines: [String] = []
        if let description, !description.hasPrefix("ImageJ") { infoLines.append("ImageDescription: \(description)") }
        for (tag, name) in [
            (TIFFTag.software, "Software"), (TIFFTag.dateTime, "DateTime"), (TIFFTag.artist, "Artist"),
            (TIFFTag.hostComputer, "HostComputer"),
        ] {
            if let value = try text(tag) { infoLines.append("\(name): \(value)") }
        }
        tiffInfo = infoLines.isEmpty ? nil : infoLines.map { $0 + "\n" }.joined()

        // TiffDecoder reads these tags wherever they point and skips records
        // that don't check out, so neither tag being unreadable stops the image.
        if let counts = try? d.integers(TIFFTag.imageJMetadataCounts, r), let entry = d.entries[TIFFTag.imageJMetadata],
            let data = try? r.slice(at: entry.valueOffset, count: entry.count)
        {
            imageJMetadata = ImageJMetadata(counts: counts, data: data, bigEndian: r.bigEndian)
        } else {
            imageJMetadata = nil
        }
        xResolution = try d.rational(TIFFTag.xResolution, r)
        yResolution = try d.rational(TIFFTag.yResolution, r)
        resolutionUnit = try d.integer(TIFFTag.resolutionUnit, r)

        try validate()
    }

    /// The Mancora pixel type these samples decode to. 16-bit RGB becomes
    /// three 16-bit planes (channels), as ImageJ opens it.
    var pixelType: PixelType {
        if samplesPerPixel >= 3 { return bitsPerSample == 16 ? .gray16 : .rgb8 }
        switch bitsPerSample {
        case 16: return sampleFormat == .float ? .gray32Float : .gray16
        case 32, 64: return .gray32Float
        default: return .gray8
        }
    }

    /// Planes one page decodes to: one per sample for 16-bit RGB(A), as
    /// ImageJ opens them as a 3- or 4-channel composite; otherwise 1.
    var planesPerPage: Int { samplesPerPixel >= 3 && bitsPerSample == 16 ? samplesPerPixel : 1 }

    var bytesPerSample: Int { max(bitsPerSample / 8, 1) }

    /// Bytes of one page's decoded planes as stored in Mancora.
    var decodedPlaneBytes: Int { width * height * pixelType.bytesPerPixel * planesPerPage }

    /// Pages that can be stacked together must agree on these.
    var stackSignature: [Int] {
        [width, height, bitsPerSample, samplesPerPixel, sampleFormat.rawValue, photometric]
    }

    private func validate() throws(MancoraIOError) {
        switch (bitsPerSample, samplesPerPixel) {
        case (1, 1), (8, 1), (16, 1), (32, 1): break
        case (64, 1) where sampleFormat == .float: break
        case (8, 3), (8, 4), (16, 3), (16, 4): break
        default: throw .unsupported("\(bitsPerSample)-bit samples with \(samplesPerPixel) samples per pixel")
        }
        if bitsPerSample == 16, sampleFormat == .float, samplesPerPixel > 1 {
            throw .unsupported("16-bit float color images")
        }
        if bitsPerSample == 1, tileSize != nil { throw .unsupported("tiled 1-bit images") }
        switch compression {
        case 1, 5, 8, 32773, 32946: break
        case 7: throw .unsupported("JPEG compression")
        default: throw .unsupported("compression scheme \(compression)")
        }
        switch predictor {
        case 1: break
        case 2 where bitsPerSample >= 8 && sampleFormat != .float: break
        case 3 where sampleFormat == .float: break
        default: throw .unsupported("predictor \(predictor) with \(bitsPerSample)-bit samples")
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
