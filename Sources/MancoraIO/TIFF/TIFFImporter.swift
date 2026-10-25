public import MancoraCore

/// Opens TIFF files as ``Hyperstack``s, following ImageJ's conventions for
/// stacks, hyperstacks, calibration and display settings.
///
/// Supported in Phase 0:
/// - big- and little-endian classic TIFF
/// - 1, 8, 16 and 32-bit grayscale (unsigned, signed or float) and 8-bit
///   RGB/RGBA (alpha is dropped), chunky or planar
/// - palette (ColorMap) and WhiteIsZero images, read as a LUT
/// - no compression, PackBits, and LZW (with or without horizontal predictor)
/// - strips and tiles
/// - multi-page files, and ImageJ stacks whose planes follow the first IFD
public enum TIFFImporter {
    public struct Options: Sendable {
        /// Refuse files whose decoded pixels would exceed this many bytes.
        public var maximumDecodedBytes: Int
        /// Refuse files larger than this many bytes.
        public var maximumFileBytes: Int

        public init(maximumDecodedBytes: Int = 4 << 30, maximumFileBytes: Int = 4 << 30) {
            self.maximumDecodedBytes = maximumDecodedBytes
            self.maximumFileBytes = maximumFileBytes
        }
    }

    public static func read(path: String, options: Options = Options()) throws(MancoraIOError) -> Hyperstack {
        let bytes = try FileLoader.load(path: path, limit: options.maximumFileBytes)
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        return try decode(bytes, title: name, options: options)
    }

    public static func decode(_ bytes: [UInt8], title: String, options: Options = Options()) throws(MancoraIOError) -> Hyperstack {
        var reader = ByteReader(bytes)
        guard bytes.count >= 8 else { throw .invalidFormat("too short to be a TIFF file") }
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): reader.bigEndian = false
        case (0x4D, 0x4D): reader.bigEndian = true
        default: throw .invalidFormat("not a TIFF file")
        }
        switch try reader.u16(at: 2) {
        case 42: break
        case 43: throw .unsupported("BigTIFF (arrives in Phase 1)")
        default: throw .invalidFormat("not a TIFF file")
        }

        let pages = try readPages(reader: reader)
        guard let first = pages.first else { throw .invalidFormat("no images in file") }
        let description = first.description.flatMap(ImageJDescription.init)

        // Planes, either from each IFD or (ImageJ stacks) contiguous after the first.
        var planes: [Plane] = []
        if let n = description?.images, n > 1, first.compression == 1, !first.isPlanar,
            first.bitsPerSample >= 8, let start = contiguousStart(of: first)
        {
            let planeBytes = first.chunkRowBytes(first.width) * first.height
            try checkBudget(planes: n, page: first, options: options)
            for k in 0..<n {
                planes.append(try TIFFPlaneDecoder.decodeContiguous(first, at: start + k * planeBytes, reader: reader))
            }
        } else {
            let stackable = pages.filter { !$0.isReducedResolution && $0.stackSignature == first.stackSignature }
            try checkBudget(planes: stackable.count, page: first, options: options)
            for page in stackable {
                planes.append(try TIFFPlaneDecoder.decode(page, reader: reader))
            }
        }

        let stack: ImageStack
        do {
            stack = try ImageStack(width: first.width, height: first.height, planes: planes)
        } catch {
            throw .model(error)
        }

        var dims = HyperstackDimensions(slices: planes.count)
        if let d = description {
            let candidate = HyperstackDimensions(
                channels: max(d.channels ?? 1, 1),
                slices: max(d.slices ?? 1, 1),
                frames: max(d.frames ?? 1, 1)
            )
            if candidate.planeCount == planes.count, !(stack.pixelType == .rgb8 && candidate.channels > 1) {
                dims = candidate
            } else if d.frames == planes.count, d.slices == nil {
                dims = HyperstackDimensions(frames: planes.count)
            }
        }

        var channels = Hyperstack.defaultChannels(for: stack, dimensions: dims)
        if dims.channels == 1, stack.pixelType.usesLUT {
            channels[0].lut = singleChannelLUT(first, name: LUTReader.baseName(of: title))
        }
        if let range = description?.displayRange, stack.pixelType.usesLUT {
            for c in channels.indices { channels[c].displayRange = range }
        }

        var properties: [String: String] = [:]
        if let text = first.description { properties["ImageDescription"] = text }

        do {
            return try Hyperstack(
                title: title,
                stack: stack,
                dimensions: dims,
                calibration: calibration(first, description),
                channels: channels,
                compositeMode: description?.compositeMode ?? .color,
                properties: properties
            )
        } catch {
            throw .model(error)
        }
    }

    // MARK: Pages

    private static func readPages(reader: ByteReader) throws(MancoraIOError) -> [TIFFPage] {
        var pages: [TIFFPage] = []
        var visited = Set<Int>()
        var offset = Int(try reader.u32(at: 4))
        while offset != 0 {
            // A loop in the IFD chain would otherwise never end.
            guard visited.insert(offset).inserted else { break }
            do {
                let directory = try TIFFDirectory(reader: reader, offset: offset)
                let page = try TIFFPage(directory: directory, reader: reader)
                pages.append(page)
                // ImageJ stacks list every plane after the first IFD; stop here.
                if pages.count == 1, let d = page.description.flatMap(ImageJDescription.init),
                    (d.images ?? 1) > 1, page.compression == 1
                {
                    break
                }
                offset = directory.nextOffset
            } catch {
                // A damaged later IFD ends the stack; a damaged first one is fatal.
                if pages.isEmpty { throw error }
                break
            }
        }
        return pages
    }

    /// The first pixel's offset if the page's chunks are stored back to back.
    private static func contiguousStart(of page: TIFFPage) -> Int? {
        guard let start = page.chunkOffsets.first else { return nil }
        var next = start
        for (i, offset) in page.chunkOffsets.prefix(page.chunkCount).enumerated() {
            guard offset == next else { return nil }
            let rows = min(page.chunkHeight, page.height - i * page.chunkHeight)
            next = offset + page.chunkRowBytes(page.chunkWidth) * rows
        }
        return start
    }

    private static func checkBudget(planes: Int, page: TIFFPage, options: Options) throws(MancoraIOError) {
        let (total, overflow) = page.decodedPlaneBytes.multipliedReportingOverflow(by: planes)
        guard !overflow, total <= options.maximumDecodedBytes else {
            throw .tooLarge(bytes: overflow ? .max : total, limit: options.maximumDecodedBytes)
        }
    }

    // MARK: Display and calibration

    private static func singleChannelLUT(_ page: TIFFPage, name: String) -> LUT {
        if let map = page.colorMap {
            // ImageJ keeps the high byte of each 16-bit entry and ignores an
            // all-zero map.
            let r = map[0..<256].map { UInt8($0 >> 8) }
            let g = map[256..<512].map { UInt8($0 >> 8) }
            let b = map[512..<768].map { UInt8($0 >> 8) }
            if r.contains(where: { $0 != 0 }) || g.contains(where: { $0 != 0 }) || b.contains(where: { $0 != 0 }),
                let lut = try? LUT(name: name, reds: r, greens: g, blues: b)
            {
                return lut
            }
        }
        return page.photometric == 0 ? LUT.grays.inverted() : .grays
    }

    private static func calibration(_ page: TIFFPage, _ description: ImageJDescription?) -> Calibration {
        var cal = Calibration()
        if let xr = page.xResolution, xr > 0 {
            let yr = page.yResolution.flatMap { $0 > 0 ? $0 : nil } ?? xr
            var unit: String?
            switch page.resolutionUnit {
            case 3: unit = "cm"
            case 2: unit = xr == 72 ? nil : "inch"  // 72 dpi is "no calibration"
            default: unit = nil
            }
            if let d = description, let u = d.unit, !u.trimmingWhitespace().isEmpty { unit = u }
            if let unit {
                cal.pixelWidth = 1 / xr
                cal.pixelHeight = 1 / yr
                cal.unit = unit
            }
        }
        if let d = description {
            if let spacing = d.spacing, spacing != 0 { cal.pixelDepth = spacing }
            if let interval = d.frameInterval { cal.frameInterval = interval }
            if let tunit = d.timeUnit { cal.timeUnit = tunit }
            cal.xOrigin = d.xOrigin ?? 0
            cal.yOrigin = d.yOrigin ?? 0
            cal.zOrigin = d.zOrigin ?? 0
            cal.invertY = d.invertY
        }
        if page.bitsPerSample == 16, page.sampleFormat == .signed {
            cal.valueFunction = .straightLine(intercept: -32768, slope: 1)
        }
        return cal
    }
}
