public import MancoraCore

/// Opens TIFF files as ``Hyperstack``s, following ImageJ's conventions for
/// stacks, hyperstacks, calibration and display settings.
///
/// Supported:
/// - big- and little-endian classic TIFF and BigTIFF
/// - 1, 8, 16 and 32-bit grayscale (unsigned, signed or float), 16-bit
///   (half) and 64-bit float grayscale (read as 32-bit float), 8-bit
///   RGB/RGBA (alpha is dropped), and 16-bit RGB(A) (one channel per
///   sample, as ImageJ does), chunky or planar
/// - palette (ColorMap) and WhiteIsZero images, read as a LUT
/// - no compression, PackBits, LZW and Deflate, with the horizontal or
///   floating-point predictor
/// - strips and tiles
/// - multi-page files, and ImageJ stacks whose planes follow the first IFD
/// - virtual stacks: planes decoded on demand from a memory-mapped file
public enum TIFFImporter {
    public struct Options: Sendable {
        /// Refuse files whose decoded pixels would exceed this many bytes
        /// (for a virtual stack, one plane at a time).
        public var maximumDecodedBytes: Int
        /// Refuse files larger than this many bytes (unless virtual).
        public var maximumFileBytes: Int
        /// Open as a virtual stack, like File ▸ Import ▸ TIFF Virtual Stack:
        /// the file is memory-mapped and each plane decoded when first shown.
        public var virtual: Bool
        /// Decoded planes a virtual stack keeps for reuse, in bytes.
        public var virtualCacheBytes: Int
        /// Read MetaMorph STK, Zeiss LSM and OME-TIFF files as plain TIFF
        /// pages, ignoring the metadata that gives them their planes,
        /// channels and calibration. Off by default: such files throw
        /// ``MancoraIOError/unsupported(_:)``, so callers hand them to
        /// ImageJ or Bio-Formats rather than show them wrong.
        public var ignoresVendorMetadata: Bool

        public init(
            maximumDecodedBytes: Int = 4 << 30,
            maximumFileBytes: Int = 4 << 30,
            virtual: Bool = false,
            virtualCacheBytes: Int = 256 << 20,
            ignoresVendorMetadata: Bool = false
        ) {
            self.maximumDecodedBytes = maximumDecodedBytes
            self.maximumFileBytes = maximumFileBytes
            self.virtual = virtual
            self.virtualCacheBytes = virtualCacheBytes
            self.ignoresVendorMetadata = ignoresVendorMetadata
        }
    }

    public static func read(path: String, options: Options = Options()) throws(MancoraIOError) -> Hyperstack {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        // Mapped either way: a full read then copies only the pixels it decodes.
        let data = try FileLoader.map(path: path)
        if !options.virtual, data.count > options.maximumFileBytes {
            throw .tooLarge(bytes: data.count, limit: options.maximumFileBytes)
        }
        return try decode(ByteReader(mapped: data), title: name, options: options)
    }

    public static func decode(_ bytes: [UInt8], title: String, options: Options = Options()) throws(MancoraIOError) -> Hyperstack {
        try decode(ByteReader(bytes), title: title, options: options)
    }

    private static func decode(_ source: ByteReader, title: String, options: Options) throws(MancoraIOError) -> Hyperstack {
        var reader = source
        guard reader.count >= 8 else { throw .invalidFormat("too short to be a TIFF file") }
        switch (try reader.u8(at: 0), try reader.u8(at: 1)) {
        case (0x49, 0x49): reader.bigEndian = false
        case (0x4D, 0x4D): reader.bigEndian = true
        default: throw .invalidFormat("not a TIFF file")
        }
        let bigTIFF: Bool
        let firstOffset: Int
        switch try reader.u16(at: 2) {
        case 42:
            bigTIFF = false
            firstOffset = Int(try reader.u32(at: 4))
        case 43:
            // BigTIFF: offset size 8, a reserved zero, then a 64-bit first IFD offset.
            guard reader.count >= 16, try reader.u16(at: 4) == 8, try reader.u16(at: 6) == 0 else {
                throw .invalidFormat("BigTIFF header with an unsupported offset size")
            }
            bigTIFF = true
            firstOffset = try TIFFDirectory.offset(reader, at: 8, bigTIFF: true)
        default:
            throw .invalidFormat("not a TIFF file")
        }

        if !options.ignoresVendorMetadata,
            let vendor = try VendorTIFF(TIFFDirectory(reader: reader, offset: firstOffset, bigTIFF: bigTIFF), reader)
        {
            throw .unsupported("\(vendor.rawValue) files (\(vendor.missing)); ImageJ or Bio-Formats can open them")
        }
        let pages = try readPages(reader: reader, firstOffset: firstOffset, bigTIFF: bigTIFF)
        guard let first = pages.first else { throw .invalidFormat("no images in file") }
        let description = first.description.flatMap(ImageJDescription.init)

        // Where each plane's pixels are: in each IFD, or (ImageJ stacks)
        // back to back after the first.
        var units: [TIFFPlaneSource.Unit] = []
        if let n = description?.images, n > 1, first.compression == 1, !first.isPlanar,
            first.bitsPerSample >= 8, let start = contiguousStart(of: first)
        {
            let planeBytes = first.chunkRowBytes(first.width) * first.height
            units = (0..<n).map { .contiguous(first, offset: start + $0 * planeBytes) }
        } else {
            units = pages.filter { !$0.isReducedResolution && $0.stackSignature == first.stackSignature }.map {
                .page($0)
            }
        }
        let planeCount = units.count * first.planesPerPage

        let metadata = first.imageJMetadata
        var labels = [String?](repeating: nil, count: planeCount)
        if let saved = metadata?.labels, !saved.isEmpty, saved.count <= planeCount {
            labels.replaceSubrange(0..<saved.count, with: saved)
        } else if pages.count == 1, first.planesPerPage > 1 {
            // ImageJ's FileOpener names the samples of a 16-bit RGB(A) image.
            labels = Array(["Red", "Green", "Blue", "Gray"].prefix(planeCount))
        }

        let stack: ImageStack
        do {
            if options.virtual {
                try checkBudget(planes: 1, page: first, options: options)
                let source = TIFFPlaneSource(
                    reader: reader, first: first, units: units, cacheBytes: options.virtualCacheBytes)
                stack = try ImageStack(source: source, labels: labels)
            } else {
                try checkBudget(planes: units.count, page: first, options: options)
                var planes: [Plane] = []
                planes.reserveCapacity(planeCount)
                for unit in units { planes += try unit.decode(reader) }
                stack = try ImageStack(width: first.width, height: first.height, planes: planes, labels: labels)
            }
        } catch let error as MancoraIOError {
            throw error
        } catch let error as ImageModelError {
            throw .model(error)
        } catch {
            throw .invalidFormat("\(error)")
        }

        let samplePlanes = first.planesPerPage
        var dims =
            samplePlanes > 1
            ? HyperstackDimensions(channels: samplePlanes, slices: planeCount / samplePlanes)
            : HyperstackDimensions(slices: planeCount)
        if let d = description {
            let candidate = HyperstackDimensions(
                channels: max(d.channels ?? 1, 1),
                slices: max(d.slices ?? 1, 1),
                frames: max(d.frames ?? 1, 1)
            )
            if candidate.planeCount == planeCount, !(stack.pixelType == .rgb8 && candidate.channels > 1) {
                dims = candidate
            } else if d.frames == planeCount, d.slices == nil {
                dims = HyperstackDimensions(frames: planeCount)
            }
        }

        var channels = Hyperstack.defaultChannels(for: stack, dimensions: dims)
        if dims.channels == 1, stack.pixelType.usesLUT {
            channels[0].lut = singleChannelLUT(first, name: LUTReader.baseName(of: title))
        }
        let savedRanges = metadata?.ranges ?? []
        if dims.channels > 1, savedRanges.count == dims.channels * 2 {
            // A composite's own ranges, as CompositeImage.setupLuts applies them.
            for c in channels.indices where savedRanges[2 * c] <= savedRanges[2 * c + 1] {
                channels[c].displayRange = savedRanges[2 * c]...savedRanges[2 * c + 1]
            }
        } else if let range = description?.displayRange, stack.pixelType.usesLUT {
            for c in channels.indices { channels[c].displayRange = range }
        } else if samplePlanes > 1, planeCount == samplePlanes, !first.isPlanar {
            // FileOpener: a chunky 16-bit RGB image shows one range spanning all three
            // samples; with a fourth sample, each channel gets its own (resetDisplayRanges).
            let ranges = (0..<samplePlanes).map { stack[$0].valueRange() ?? 0...0 }
            if samplePlanes == 3, let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() {
                for c in channels.indices { channels[c].displayRange = low...high }
            } else {
                for c in channels.indices { channels[c].displayRange = ranges[c] }
            }
        }
        if dims.channels > 1, let luts = metadata?.luts {
            for (c, bytes) in luts.prefix(dims.channels).enumerated() {
                channels[c].lut = channelLUT(bytes, index: c)
            }
        }

        var properties: [String: String] = [:]
        let pairs = metadata?.properties ?? []
        for i in stride(from: 0, to: pairs.count - 1, by: 2) { properties[pairs[i]] = pairs[i + 1] }

        do {
            var image = try Hyperstack(
                title: title,
                stack: stack,
                dimensions: dims,
                calibration: calibration(first, description),
                channels: channels,
                compositeMode: description?.compositeMode ?? (samplePlanes > 1 ? .composite : .color),
                info: metadata?.info ?? first.tiffInfo,
                properties: properties
            )
            image.encodedROI = metadata?.roi
            image.encodedOverlay = metadata?.overlay ?? []
            return image
        } catch {
            throw .model(error)
        }
    }

    // MARK: Pages

    /// TIFF-based formats whose own metadata defines the image, which a plain
    /// TIFF reading gets wrong.
    enum VendorTIFF: String {
        case metaMorph = "MetaMorph STK"
        case lsm = "Zeiss LSM"
        case ome = "OME-TIFF"

        /// What reading the pages alone would miss.
        var missing: String {
            switch self {
            case .metaMorph: "planes after the first"
            case .lsm: "channels, dimensions and calibration from CZ_LSMINFO"
            case .ome: "dimensions, channels and physical sizes from the OME-XML"
            }
        }

        /// The vendor format a first IFD belongs to, if any: CZ_LSMINFO (tag
        /// 34412); MetaMorph's UIC2 table (tag 33629) listing more than one
        /// plane, all stored after the single IFD; or OME-XML in an
        /// ImageDescription that ImageJ didn't write.
        init?(_ d: TIFFDirectory, _ r: ByteReader) throws(MancoraIOError) {
            if d.entries[34412] != nil {
                self = .lsm
            } else if let uic2 = d.entries[33629], uic2.count > 1 {
                self = .metaMorph
            } else if let text = try d.string(TIFFTag.imageDescription, r), !text.hasPrefix("ImageJ="), text.contains("<OME") {
                self = .ome
            } else {
                return nil
            }
        }
    }

    private static func readPages(reader: ByteReader, firstOffset: Int, bigTIFF: Bool) throws(MancoraIOError) -> [TIFFPage] {
        var pages: [TIFFPage] = []
        var visited = Set<Int>()
        var offset = firstOffset
        while offset != 0 {
            // A loop in the IFD chain would otherwise never end.
            guard visited.insert(offset).inserted else { break }
            do {
                let directory = try TIFFDirectory(reader: reader, offset: offset, bigTIFF: bigTIFF)
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

    /// A saved channel LUT; ImageJ shows anything but 768 bytes as white.
    private static func channelLUT(_ bytes: [UInt8], index: Int) -> LUT {
        guard bytes.count == 768,
            let lut = try? LUT(
                name: "Channel \(index + 1)", reds: Array(bytes[0..<256]), greens: Array(bytes[256..<512]),
                blues: Array(bytes[512..<768]))
        else { return LUT.grays }
        // Keep the familiar name when the colors are a built-in LUT's.
        return LUT.builtIn.first { $0.hasSameColors(as: lut) } ?? lut
    }

    private static func singleChannelLUT(_ page: TIFFPage, name: String) -> LUT {
        // ImageJ ignores the ColorMap of unsigned 16-bit files it didn't write.
        let trusted = !(page.bitsPerSample == 16 && page.sampleFormat == .unsigned && page.description == nil)
        if let map = page.colorMap, trusted {
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

    /// Spatial calibration as ImageJ derives it: TiffDecoder reads the
    /// resolution fields, FileOpener lets an ImageJ description's `unit`
    /// replace the ResolutionUnit's, then converts tiny centimeter pixels to
    /// microns (`Prefs.convertToMicrons`, on by default).
    private static func calibration(_ page: TIFFPage, _ description: ImageJDescription?) -> Calibration {
        var cal = Calibration()
        var pixelWidth = 1.0, pixelHeight = 1.0, pixelDepth = 1.0
        if let xr = page.xResolution, xr != 0 { pixelWidth = 1 / xr }
        if let yr = page.yResolution, yr != 0 { pixelHeight = 1 / yr }
        var unit: String?
        switch page.resolutionUnit {
        case 1: unit = " "
        case 2:
            // 72 dpi is a placeholder, not a calibration.
            if pixelWidth == 1.0 / 72.0 {
                pixelWidth = 1
                pixelHeight = 1
            } else {
                unit = "inch"
            }
        case 3: unit = "cm"
        default: break  // no ResolutionUnit tag: uncalibrated, whatever TIFF's default
        }
        if let d = description {
            let saved = d.unit ?? ""
            if unit == "cm", saved == "um" {
                pixelWidth *= 10000
                pixelHeight *= 10000
            }
            unit = saved
            if let spacing = d.spacing { pixelDepth = abs(spacing) }
        }
        if pixelWidth > 0, var unit {
            let threshold = description == nil ? 0.001 : 0.0001
            if pixelWidth <= threshold, unit == "cm" {
                pixelWidth *= 10000
                pixelHeight *= 10000
                if pixelDepth != 1 { pixelDepth *= 10000 }
                unit = "um"
            }
            cal.pixelWidth = pixelWidth
            cal.pixelHeight = pixelHeight
            cal.pixelDepth = pixelDepth
            cal.unit = sanitizedUnit(unit) ?? "pixel"
        }
        if let d = description {
            cal.frameInterval = d.frameInterval ?? 0
            if let tunit = d.timeUnit, !tunit.isEmpty { cal.timeUnit = tunit }
            cal.yUnit = d.yUnit.flatMap(sanitizedUnit)
            cal.zUnit = d.zUnit.flatMap(sanitizedUnit)
            cal.fps = d.fps ?? 0
            cal.loop = d.loop
            // FileOpener: 32-bit images take only the unit; others a straight-line
            // function (the one calibration Mancora models so far).
            if let vunit = d.valueUnit {
                if page.sampleFormat == .float || page.bitsPerSample == 32 {
                    cal.valueUnit = vunit
                } else if d.calibrationFunction == 0, d.coefficients.count >= 2 {
                    cal.valueFunction = .straightLine(intercept: d.coefficients[0], slope: d.coefficients[1])
                    cal.valueUnit = vunit
                }
            }
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

    /// ImageJ's `Calibration.sanitizeUnit`; `nil` for an empty unit.
    private static func sanitizedUnit(_ unit: String) -> String? {
        switch unit {
        case "": nil
        case "um": "µm"
        case "A": "Å"
        default: unit
        }
    }
}
