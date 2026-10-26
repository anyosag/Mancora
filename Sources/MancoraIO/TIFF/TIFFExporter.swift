#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import MancoraCore

/// Saves ``Hyperstack``s as uncompressed TIFFs laid out the way ImageJ's
/// `FileSaver`/`TiffEncoder` write them, so ImageJ and Fiji reopen them as
/// the same image: hyperstack layout and composite mode, calibration,
/// display ranges, LUTs, slice labels, Info, properties, and the ROI and
/// overlay records.
///
/// All planes follow the first IFD back to back, with an IFD per plane after
/// them; the ImageDescription carries ImageJ's `images=`, `channels=`, … keys.
public enum TIFFExporter {
    public struct Options: Sendable {
        /// ImageJ 1.54 writes little-endian ("II") files unless Edit ▸
        /// Options ▸ Input/Output turns Intel byte order off.
        public var bigEndian: Bool

        public init(bigEndian: Bool = false) {
            self.bigEndian = bigEndian
        }
    }

    /// The version of ImageJ whose file layout this writer follows; it goes
    /// in the description's `ImageJ=` key, which readers check for.
    public static let imageJVersion = "1.54p"

    public static func write(_ image: Hyperstack, to path: String, options: Options = Options()) throws(MancoraIOError) {
        let bytes = try encode(image, options: options)
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
    }

    public static func encode(_ image: Hyperstack, options: Options = Options()) throws(MancoraIOError) -> [UInt8] {
        guard image.pixelType != .rgb8 || image.dimensions.channels == 1 else {
            throw .unsupported("saving multi-channel RGB images")
        }
        var w = TIFFWriter(bigEndian: options.bigEndian)
        let layout = Layout(image)

        // Values too big for an IFD entry, written between the first IFD and the pixels.
        let description = Array(descriptionString(image).utf8) + [0]
        var metadata = ImageJMetadata()
        metadata.info = image.info
        metadata.labels = image.stack.labels
        metadata.roi = image.encodedROI
        metadata.overlay = image.encodedOverlay
        metadata.properties = image.properties.keys.sorted().flatMap { [$0, image.properties[$0] ?? ""] }
        if image.dimensions.channels > 1 {
            metadata.ranges = image.channels.flatMap { [$0.displayRange.lowerBound, $0.displayRange.upperBound] }
            let custom = image.channels.enumerated().contains { c, display in
                !display.lut.hasSameColors(as: Hyperstack.defaultChannelLUT(c))
            }
            if custom { metadata.luts = image.channels.map { $0.lut.reds + $0.lut.greens + $0.lut.blues } }
        }
        let (metadataCounts, metadataBytes) = metadata.encoded(bigEndian: options.bigEndian)
        let scale = resolution(image.calibration)
        let colorMap = layout.colorMap.map { lut in
            (lut.reds + lut.greens + lut.blues).map { UInt16($0) << 8 }
        }

        var entries: [TIFFWriter.Entry] = [
            .long(TIFFTag.newSubfileType, 0),
            .long(TIFFTag.imageWidth, UInt32(image.width)),
            .long(TIFFTag.imageLength, UInt32(image.height)),
            layout.samplesPerPixel == 3
                ? .shorts(TIFFTag.bitsPerSample, [8, 8, 8]) : .short(TIFFTag.bitsPerSample, UInt16(layout.bitsPerSample)),
            .short(TIFFTag.compression, 1),
            .short(TIFFTag.photometric, UInt16(layout.photometric)),
            .ascii(TIFFTag.imageDescription, description),
            .long(TIFFTag.stripOffsets, 0),  // patched below
            .short(TIFFTag.samplesPerPixel, UInt16(layout.samplesPerPixel)),
            .long(TIFFTag.rowsPerStrip, UInt32(image.height)),
            .long(TIFFTag.stripByteCounts, layout.planeBytes <= Int(UInt32.max) ? UInt32(layout.planeBytes) : 0),
        ]
        if let scale {
            entries.append(.rational(TIFFTag.xResolution, scale.x))
            entries.append(.rational(TIFFTag.yResolution, scale.y))
            entries.append(.short(TIFFTag.resolutionUnit, scale.unit))
        }
        if let colorMap { entries.append(.shorts(TIFFTag.colorMap, colorMap)) }
        if image.pixelType == .gray32Float { entries.append(.short(TIFFTag.sampleFormat, 3)) }
        let firstEntries = entries
        if !metadataCounts.isEmpty {
            entries.append(.longs(TIFFTag.imageJMetadataCounts, metadataCounts))
            entries.append(.bytes(TIFFTag.imageJMetadata, metadataBytes))
        }

        // Header, then the first IFD with its out-of-line values, then pixels.
        w.header()
        let firstIFD = w.directory(entries)
        let imageOffset = w.count
        let planeCount = image.stack.count
        let (stackBytes, overflow) = layout.planeBytes.multipliedReportingOverflow(by: planeCount)
        guard !overflow else { throw .tooLarge(bytes: .max, limit: .max) }
        // Like ImageJ, a stack whose IFDs can't all be addressed with 32-bit
        // offsets gets only the first; `images=` tells readers the rest.
        let writeAllIFDs = planeCount > 1 && imageOffset + stackBytes + planeCount * 512 < Int(UInt32.max)
        w.patch(firstIFD, tag: TIFFTag.stripOffsets, value: UInt32(imageOffset))
        w.reserve(stackBytes)
        for k in 0..<image.stack.count { w.pixels(image.stack[k]) }
        if writeAllIFDs {
            w.patchNextIFD(of: firstIFD, to: UInt32(w.count))
            for k in 1..<planeCount {
                // Later IFDs repeat the first one's values instead of copying them.
                var later = firstEntries
                for (i, entry) in later.enumerated() where entry.tag == TIFFTag.stripOffsets {
                    later[i] = .long(TIFFTag.stripOffsets, UInt32(imageOffset + k * layout.planeBytes))
                }
                let ifd = w.directory(later, sharing: firstIFD)
                if k < planeCount - 1 { w.patchNextIFD(of: ifd, to: UInt32(w.count)) }
            }
        }
        return w.bytes
    }

    // MARK: Layout

    /// The TIFF image type ImageJ's `ImagePlus.getFileInfo` picks.
    struct Layout {
        var bitsPerSample = 8
        var samplesPerPixel = 1
        var photometric = 1
        /// A LUT to save as the ColorMap, for single-channel images.
        var colorMap: LUT?
        var planeBytes: Int

        init(_ image: Hyperstack) {
            planeBytes = image.width * image.height * image.pixelType.bytesPerPixel
            let lut = image.channels[0].lut
            let singleChannel = image.dimensions.channels == 1
            switch image.pixelType {
            case .gray8:
                // Any LUT but plain gray is saved as a palette (FileInfo.COLOR8).
                if singleChannel, !lut.hasSameColors(as: .grays) {
                    photometric = 3
                    colorMap = lut
                }
            case .gray16, .gray32Float:
                bitsPerSample = image.pixelType == .gray16 ? 16 : 32
                if singleChannel, !lut.hasSameColors(as: .grays) {
                    colorMap = lut
                    if Self.isInverted(lut) { photometric = 0 }
                }
            case .rgb8:
                samplesPerPixel = 3
                photometric = 2
                planeBytes = image.width * image.height * 3
            }
        }

        /// ImageJ's `ImageProcessor.isInvertedLut`: no step gets brighter.
        static func isInverted(_ lut: LUT) -> Bool {
            func brightness(_ i: Int) -> Int { Int(lut.reds[i]) + Int(lut.greens[i]) + Int(lut.blues[i]) }
            return !(1..<255).contains { brightness($0 - 1) < brightness($0) }
        }
    }

    // MARK: Description

    /// ImageJ's `FileSaver.getDescriptionString`, key for key.
    static func descriptionString(_ image: Hyperstack) -> String {
        let cal = image.calibration
        let dims = image.dimensions
        let planes = image.stack.count
        var lines = ["ImageJ=\(imageJVersion)"]
        func number(_ v: Double) -> String { JavaNumerics.string(v) }
        func escaped(_ key: String, _ value: String) {
            lines.append(key + "=" + Self.escapedForProperties(value))
        }
        if planes > 1 { lines.append("images=\(planes)") }
        if dims.channels > 1 { lines.append("channels=\(dims.channels)") }
        if dims.slices > 1 { lines.append("slices=\(dims.slices)") }
        if dims.frames > 1 { lines.append("frames=\(dims.frames)") }
        if [dims.channels, dims.slices, dims.frames].filter({ $0 > 1 }).count >= 2 { lines.append("hyperstack=true") }
        if dims.channels > 1 { lines.append("mode=\(image.compositeMode.rawValue)") }
        if isScaled(cal) { escaped("unit", cal.unit) }

        let isFloat = image.pixelType == .gray32Float
        if let function = cal.valueFunction, !isFloat {
            switch function {
            case .straightLine(let intercept, let slope):
                lines += ["cf=0", "c0=\(number(intercept))", "c1=\(number(slope))"]
            }
            escaped("vunit", cal.valueUnit)
        } else if cal.valueUnit != Calibration().valueUnit {
            escaped("vunit", cal.valueUnit)
        }
        if cal.frameInterval != 0 {
            let whole = cal.frameInterval == cal.frameInterval.rounded(.towardZero) && abs(cal.frameInterval) < 2e9
            lines.append("finterval=" + (whole ? String(Int(cal.frameInterval)) : number(cal.frameInterval)))
        }
        if cal.timeUnit != "sec" { escaped("tunit", cal.timeUnit) }
        if let y = cal.yUnit, y != cal.unit { escaped("yunit", y) }
        if let z = cal.zUnit, z != cal.unit { escaped("zunit", z) }
        if planes > 1 {
            if cal.pixelDepth != 1 { lines.append("spacing=\(number(cal.pixelDepth))") }
            if cal.fps != 0 {
                let whole = cal.fps == cal.fps.rounded(.towardZero) && abs(cal.fps) < 2e9
                lines.append("fps=" + (whole ? String(Int(cal.fps)) : number(cal.fps)))
            }
            lines.append("loop=\(cal.loop)")
        }

        // The display range of the first channel (ImageJ's current processor).
        let range = image.channels[0].displayRange
        switch image.pixelType {
        case .gray8 where range != 0...255, .gray16, .gray32Float:
            lines += ["min=\(number(range.lowerBound))", "max=\(number(range.upperBound))"]
        default: break
        }
        if cal.xOrigin != 0 { lines.append("xorigin=\(number(cal.xOrigin))") }
        if cal.yOrigin != 0 { lines.append("yorigin=\(number(cal.yOrigin))") }
        if cal.zOrigin != 0 { lines.append("zorigin=\(number(cal.zOrigin))") }
        if cal.invertY { lines.append("inverty=true") }
        return lines.map { $0 + "\n" }.joined()
    }

    /// ImageJ's `Calibration.scaled`.
    static func isScaled(_ cal: Calibration) -> Bool {
        cal.pixelWidth != 1 || cal.pixelHeight != 1 || cal.pixelDepth != 1 || cal.unit != "pixel"
    }

    /// `FileSaver.appendEscapedLine`: printable ASCII stays, everything else
    /// (and the backslash) becomes `\uXXXX`. Unlike ImageJ, a leading space
    /// is escaped too, since Java's Properties parser would drop it (ImageJ
    /// loses the `" "` unit it gives TIFFs with ResolutionUnit 1 that way).
    static func escapedForProperties(_ text: String) -> String {
        var out = ""
        for (i, unit) in text.utf16.enumerated() {
            if unit >= 0x20, unit < 0x7F, unit != 0x5C, !(i == 0 && unit == 0x20) {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                let hex = String(unit, radix: 16, uppercase: true)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            }
        }
        return out
    }

    /// X/Y resolution as `TiffEncoder.writeScale` computes them, and the
    /// ResolutionUnit (2 inch, 3 cm, 1 anything else), when the image is
    /// spatially scaled.
    static func resolution(_ cal: Calibration) -> (x: (UInt32, UInt32), y: (UInt32, UInt32), unit: UInt16)? {
        guard isScaled(cal), cal.pixelWidth != 0, cal.pixelHeight != 0 else { return nil }
        let xscale = 1 / cal.pixelWidth, yscale = 1 / cal.pixelHeight
        var scale = 1_000_000.0
        if xscale * scale > Double(Int32.max) || yscale * scale > Double(Int32.max) {
            scale = Double(JavaNumerics.int32(Double(Int32.max) / max(xscale, yscale)))
        }
        func field(_ v: Double) -> UInt32 { UInt32(bitPattern: JavaNumerics.int32(v)) }
        let unit: UInt16 = cal.unit == "inch" ? 2 : cal.unit == "cm" ? 3 : 1
        return ((field(xscale * scale), field(scale)), (field(yscale * scale), field(scale)), unit)
    }
}

/// Assembles a classic TIFF in memory.
struct TIFFWriter {
    enum Entry {
        case short(UInt16, UInt16)
        case shorts(UInt16, [UInt16])
        case long(UInt16, UInt32)
        case longs(UInt16, [UInt32])
        case rational(UInt16, (UInt32, UInt32))
        case ascii(UInt16, [UInt8])
        case bytes(UInt16, [UInt8])

        var tag: UInt16 {
            switch self {
            case .short(let t, _), .shorts(let t, _), .long(let t, _), .longs(let t, _), .rational(let t, _),
                .ascii(let t, _), .bytes(let t, _):
                t
            }
        }
    }

    /// Where an IFD and its entries landed, for later patching.
    struct WrittenIFD {
        let offset: Int
        let entryOffsets: [UInt16: Int]
        /// Out-of-line value offsets, which later IFDs can point at.
        let valueOffsets: [UInt16: Int]
        let nextOffsetField: Int
    }

    let bigEndian: Bool
    private(set) var bytes: [UInt8] = []
    var count: Int { bytes.count }

    init(bigEndian: Bool) {
        self.bigEndian = bigEndian
    }

    mutating func reserve(_ extra: Int) { bytes.reserveCapacity(bytes.count + extra) }

    mutating func u16(_ v: UInt16) {
        bytes += bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    mutating func u32(_ v: UInt32) {
        bytes += ImageJMetadata.bytes(of: UInt64(v), count: 4, bigEndian: bigEndian)
    }

    mutating func header() {
        bytes += bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        u16(42)
        u32(8)
    }

    /// Writes an IFD at the current position, then any values over 4 bytes
    /// right after it (or, with `sharing`, points at that IFD's copies).
    mutating func directory(_ entries: [Entry], sharing shared: WrittenIFD? = nil) -> WrittenIFD {
        let sorted = entries.sorted { $0.tag < $1.tag }
        let start = bytes.count
        var valueOffset = start + 2 + sorted.count * 12 + 4
        var pending: [[UInt8]] = []
        var entryOffsets: [UInt16: Int] = [:]
        var valueOffsets: [UInt16: Int] = [:]
        u16(UInt16(sorted.count))
        for entry in sorted {
            entryOffsets[entry.tag] = bytes.count
            let (type, count, data) = encodedValue(entry)
            u16(entry.tag)
            u16(type)
            u32(UInt32(count))
            if data.count <= 4 {
                bytes += data + [UInt8](repeating: 0, count: 4 - data.count)
            } else if let shared, let existing = shared.valueOffsets[entry.tag] {
                u32(UInt32(existing))
                valueOffsets[entry.tag] = existing
            } else {
                u32(UInt32(valueOffset))
                valueOffsets[entry.tag] = valueOffset
                pending.append(data)
                valueOffset += data.count
            }
        }
        let nextField = bytes.count
        u32(0)
        for data in pending { bytes += data }
        return WrittenIFD(offset: start, entryOffsets: entryOffsets, valueOffsets: valueOffsets, nextOffsetField: nextField)
    }

    mutating func patch(_ ifd: WrittenIFD, tag: UInt16, value: UInt32) {
        guard let at = ifd.entryOffsets[tag] else { return }
        set32(at + 8, value)
    }

    mutating func patchNextIFD(of ifd: WrittenIFD, to offset: UInt32) {
        set32(ifd.nextOffsetField, offset)
    }

    private mutating func set32(_ at: Int, _ value: UInt32) {
        let b = ImageJMetadata.bytes(of: UInt64(value), count: 4, bigEndian: bigEndian)
        bytes.replaceSubrange(at..<(at + 4), with: b)
    }

    /// Field type, value count and the value bytes in file order.
    private func encodedValue(_ entry: Entry) -> (UInt16, Int, [UInt8]) {
        func b16(_ v: UInt16) -> [UInt8] { ImageJMetadata.bytes(of: UInt64(v), count: 2, bigEndian: bigEndian) }
        func b32(_ v: UInt32) -> [UInt8] { ImageJMetadata.bytes(of: UInt64(v), count: 4, bigEndian: bigEndian) }
        switch entry {
        case .short(_, let v): return (3, 1, b16(v))
        case .shorts(_, let v): return (3, v.count, v.flatMap(b16))
        case .long(_, let v): return (4, 1, b32(v))
        case .longs(_, let v): return (4, v.count, v.flatMap(b32))
        case .rational(_, let (n, d)): return (5, 1, b32(n) + b32(d))
        case .ascii(_, let v): return (2, v.count, v)
        case .bytes(_, let v): return (1, v.count, v)
        }
    }

    /// Appends one plane's samples in file byte order.
    mutating func pixels(_ plane: Plane) {
        switch plane {
        case .gray8(let p):
            bytes += p
        case .gray16(let p):
            for v in p { u16(v) }
        case .gray32Float(let p):
            for v in p { u32(v.bitPattern) }
        case .rgb8(let p):
            for v in p { bytes += [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        }
    }
}
