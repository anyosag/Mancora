import Foundation  // pow
public import MancoraCore
import MancoraSupport

/// Opens PNG files as ImageJ 1.54p does: `Opener.openUsingImageIO`, which
/// reads them with Java's ImageIO and then converts.
///
/// - 8-bit gray opens as 8-bit; 16-bit gray as 16-bit.
/// - 1-, 2- and 4-bit gray open as 8-bit with the samples unscaled and a
///   2-, 4- or 16-level gray LUT.
/// - Palette images open as 8-bit with the palette as the LUT, padded with
///   black to 2^depth entries (to 256 in Mancora's LUT).
/// - 8-bit RGB opens as RGB; 16-bit RGB as a 3-channel 16-bit composite.
/// - Anything with transparency (an alpha channel, or a tRNS chunk that
///   makes some pixel transparent) is composited on white, as ImageJ draws
///   it into an RGB image. ImageIO reads gray as linear gray, so gray levels
///   go through Java2D's linear-to-sRGB table on the way.
///
/// Every filter type and Adam7 interlacing are supported. CRCs aren't
/// checked and colour-management chunks are ignored, as ImageIO does.
public enum PNGReader {
    public static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// Reads a PNG file; the title is the file name, as in ImageJ.
    public static func read(path: String, maximumDecodedBytes: Int = 4 << 30) throws(MancoraIOError) -> Hyperstack {
        try decode(FileLoader.load(path: path, limit: 4 << 30), title: FileType.fileName(path),
            maximumDecodedBytes: maximumDecodedBytes)
    }

    public static func decode(_ bytes: [UInt8], title: String, maximumDecodedBytes: Int = 4 << 30) throws(MancoraIOError)
        -> Hyperstack
    {
        let png = try Chunks(bytes)
        let header = png.header
        let target = Target(header, palette: png.palette, transparency: png.transparency)
        let pixels = header.width * header.height
        let (needed, overflow) = pixels.multipliedReportingOverflow(by: target.bytesPerPixel)
        guard !overflow, needed <= maximumDecodedBytes else {
            throw .tooLarge(bytes: overflow ? .max : needed, limit: maximumDecodedBytes)
        }

        // Inflate exactly the filtered rows the header promises.
        var rawSize = 0
        for pass in header.passes { rawSize += (header.rowBytes(pass.width) + 1) * pass.height }
        let raw: [UInt8]
        do {
            raw = try Inflate.zlib(png.data[...], stopAt: rawSize, limit: rawSize)
        } catch {
            throw .invalidFormat("PNG image data is corrupt (\(error))")
        }
        guard raw.count == rawSize else {
            throw .truncated(offset: bytes.count, needed: rawSize, available: raw.count)
        }

        var sink = Sink(target: target, header: header)
        try raw.withUnsafeBufferPointer { (data: UnsafeBufferPointer<UInt8>) throws(MancoraIOError) in
            var offset = 0
            for pass in header.passes {
                let rowBytes = header.rowBytes(pass.width)
                var previous = [UInt8](repeating: 0, count: rowBytes)
                var current = [UInt8](repeating: 0, count: rowBytes)
                for row in 0..<pass.height {
                    let filter = data[offset]
                    for i in 0..<rowBytes { current[i] = data[offset + 1 + i] }
                    offset += rowBytes + 1
                    try unfilter(filter, &current, previous, bpp: header.filterUnit)
                    sink.put(current, y: pass.y0 + row * pass.dy, x0: pass.x0, dx: pass.dx, count: pass.width)
                    swap(&previous, &current)
                }
            }
        }
        return try sink.image(title: title)
    }

    // MARK: Chunks

    struct Header {
        var width: Int
        var height: Int
        var bitDepth: Int
        var colorType: Int
        var interlaced: Bool

        var channels: Int {
            switch colorType {
            case 2: 3
            case 4: 2
            case 6: 4
            default: 1
            }
        }

        /// Bytes per complete pixel for the filters (at least 1).
        var filterUnit: Int { max(1, channels * bitDepth / 8) }

        func rowBytes(_ width: Int) -> Int { (width * channels * bitDepth + 7) / 8 }

        struct Pass {
            var x0: Int, y0: Int, dx: Int, dy: Int, width: Int, height: Int
        }

        /// The Adam7 passes that hold pixels, or the whole image.
        var passes: [Pass] {
            guard interlaced else { return [Pass(x0: 0, y0: 0, dx: 1, dy: 1, width: width, height: height)] }
            let adam7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            return adam7.compactMap { x0, y0, dx, dy in
                let w = (width - x0 + dx - 1) / dx, h = (height - y0 + dy - 1) / dy
                return w > 0 && h > 0 ? Pass(x0: x0, y0: y0, dx: dx, dy: dy, width: w, height: h) : nil
            }
        }
    }

    struct Chunks {
        var header: Header
        var palette: [UInt8]?
        var transparency: [UInt8]?
        var data: [UInt8] = []

        init(_ bytes: [UInt8]) throws(MancoraIOError) {
            guard bytes.count >= 8, Array(bytes[0..<8]) == PNGReader.signature else {
                throw .invalidFormat("not a PNG file")
            }
            let r = ByteReader(bytes, bigEndian: true)
            var p = 8
            var header: Header?
            var sawEnd = false
            while p + 8 <= bytes.count, !sawEnd {
                let length = Int(try r.u32(at: p))
                let type = String(decoding: try r.slice(at: p + 4, count: 4), as: UTF8.self)
                let body: ArraySlice<UInt8>
                do {
                    body = try r.slice(at: p + 8, count: length)
                } catch {
                    // A file cut short after its image data still opens.
                    if data.isEmpty { throw error }
                    break
                }
                switch type {
                case "IHDR":
                    guard length >= 13 else { throw .invalidFormat("short PNG header") }
                    let b = Array(body)
                    let width = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                    let height = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
                    header = Header(width: width, height: height, bitDepth: Int(b[8]), colorType: Int(b[9]), interlaced: b[12] == 1)
                    guard b[10] == 0, b[11] == 0, b[12] <= 1 else {
                        throw .invalidFormat("unknown PNG compression, filter or interlace method")
                    }
                case "PLTE": palette = Array(body)
                case "tRNS": transparency = Array(body)
                case "IDAT": data += body
                case "IEND": sawEnd = true
                default: break  // ancillary chunks (text, gamma, ICC profiles...) change nothing in ImageJ
                }
                p += 12 + length
            }
            guard let header else { throw .invalidFormat("PNG file without a header") }
            guard header.width > 0, header.height > 0, header.width < 1 << 31, header.height < 1 << 31 else {
                throw .invalidFormat("PNG image size \(header.width) × \(header.height)")
            }
            let depths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
            guard depths[header.colorType]?.contains(header.bitDepth) == true else {
                throw .invalidFormat("PNG colour type \(header.colorType) with \(header.bitDepth)-bit samples")
            }
            if header.colorType == 3 {
                guard let palette, !palette.isEmpty, palette.count % 3 == 0 else {
                    throw .invalidFormat("PNG palette image without a palette")
                }
            }
            guard !data.isEmpty else { throw .invalidFormat("PNG file without image data") }
            self.header = header
        }
    }

    // MARK: Filters

    static func unfilter(_ type: UInt8, _ row: inout [UInt8], _ previous: [UInt8], bpp: Int) throws(MancoraIOError) {
        let n = row.count
        row.withUnsafeMutableBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                switch type {
                case 1:
                    if n > bpp { for i in bpp..<n { cur[i] &+= cur[i - bpp] } }
                case 2:
                    for i in 0..<n { cur[i] &+= prev[i] }
                case 3:
                    for i in 0..<n {
                        let left = i >= bpp ? Int(cur[i - bpp]) : 0
                        cur[i] &+= UInt8((left + Int(prev[i])) >> 1)
                    }
                case 4:
                    for i in 0..<n {
                        let a = i >= bpp ? Int(cur[i - bpp]) : 0
                        let b = Int(prev[i])
                        let c = i >= bpp ? Int(prev[i - bpp]) : 0
                        let p = a + b - c
                        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                        cur[i] &+= UInt8(pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
                    }
                default:
                    break
                }
            }
        }
        guard type <= 4 else { throw .invalidFormat("unknown PNG row filter \(type)") }
    }

    // MARK: Conversion

    /// What ImageJ makes of the samples.
    enum Target {
        /// Samples (gray levels or palette indices) as 8-bit pixels, with a LUT.
        case gray8(lut: LUT)
        case gray16
        /// 16-bit RGB: one 16-bit channel per sample.
        case rgb16
        case rgb8
        /// Transparency composited on white.
        case composited(Transparency)

        enum Transparency {
            /// A gray or RGB key colour (tRNS), compared with the raw samples.
            case key([Int])
            /// Palette entries' colours and alphas, 256 of each.
            case palette(colors: [UInt32], alphas: [UInt8])
            /// The last sample is alpha.
            case alphaChannel
        }

        init(_ h: Header, palette: [UInt8]?, transparency: [UInt8]?) {
            switch h.colorType {
            case 3:
                let p = palette ?? []
                let entries = p.count / 3
                var colors = [UInt32](repeating: 0, count: 256), alphas = [UInt8](repeating: 255, count: 256)
                for i in 0..<min(entries, 1 << h.bitDepth) {
                    colors[i] = UInt32(p[3 * i]) << 16 | UInt32(p[3 * i + 1]) << 8 | UInt32(p[3 * i + 2])
                }
                // ImageIO's palette has 2^depth entries; an alpha below 255 within it makes the image translucent.
                let tableSize = 1 << h.bitDepth
                for (i, a) in (transparency ?? []).prefix(min(entries, tableSize)).enumerated() { alphas[i] = a }
                if alphas.prefix(tableSize).contains(where: { $0 < 255 }) {
                    self = .composited(.palette(colors: colors, alphas: alphas))
                } else {
                    func channel(_ shift: UInt32) -> [UInt8] { colors.map { UInt8(truncatingIfNeeded: $0 >> shift) } }
                    self = .gray8(lut: (try? LUT(name: "", reds: channel(16), greens: channel(8), blues: channel(0))) ?? .grays)
                }
            case 0, 2:
                let samples = h.channels
                if let t = transparency, t.count >= 2 * samples {
                    let key = (0..<samples).map { Int(t[2 * $0]) << 8 | Int(t[2 * $0 + 1]) }
                    self = .composited(.key(key))
                } else if h.colorType == 2 {
                    self = h.bitDepth == 16 ? .rgb16 : .rgb8
                } else if h.bitDepth == 16 {
                    self = .gray16
                } else if h.bitDepth == 8 {
                    self = .gray8(lut: .grays)
                } else {
                    // ImageIO's 1-, 2- and 4-bit gray: 2^depth evenly spaced levels.
                    let levels = 1 << h.bitDepth
                    let ramp = (0..<256).map { $0 < levels ? UInt8($0 * 255 / (levels - 1)) : 0 }
                    self = .gray8(lut: (try? LUT(name: "", reds: ramp, greens: ramp, blues: ramp)) ?? .grays)
                }
            default:
                self = .composited(.alphaChannel)
            }
        }

        var bytesPerPixel: Int {
            switch self {
            case .gray8: 1
            case .gray16: 2
            case .rgb16: 6
            case .rgb8, .composited: 4
            }
        }
    }

    /// Collects decoded rows into planes.
    struct Sink {
        let target: Target
        let header: Header
        var bytes: [UInt8] = []
        var shorts: [[UInt16]] = []
        var ints: [UInt32] = []

        init(target: Target, header: Header) {
            self.target = target
            self.header = header
            let n = header.width * header.height
            switch target {
            case .gray8: bytes = [UInt8](repeating: 0, count: n)
            case .gray16: shorts = [[UInt16](repeating: 0, count: n)]
            case .rgb16: shorts = Array(repeating: [UInt16](repeating: 0, count: n), count: 3)
            case .rgb8, .composited: ints = [UInt32](repeating: 0xFF00_0000, count: n)
            }
        }

        mutating func put(_ row: [UInt8], y: Int, x0: Int, dx: Int, count: Int) {
            let depth = header.bitDepth, channels = header.channels
            let width = header.width
            row.withUnsafeBufferPointer { row in
                @inline(__always) func sample(_ index: Int) -> Int {
                    switch depth {
                    case 8: return Int(row[index])
                    case 16: return Int(row[2 * index]) << 8 | Int(row[2 * index + 1])
                    default:
                        let bit = index * depth
                        return Int(row[bit >> 3] >> UInt8(8 - depth - (bit & 7))) & ((1 << depth) - 1)
                    }
                }
                switch target {
                case .gray8:
                    for i in 0..<count { bytes[y * width + x0 + i * dx] = UInt8(sample(i)) }
                case .gray16:
                    for i in 0..<count { shorts[0][y * width + x0 + i * dx] = UInt16(sample(i)) }
                case .rgb16:
                    for i in 0..<count {
                        for c in 0..<3 { shorts[c][y * width + x0 + i * dx] = UInt16(sample(3 * i + c)) }
                    }
                case .rgb8:
                    for i in 0..<count {
                        ints[y * width + x0 + i * dx] =
                            0xFF00_0000 | UInt32(sample(3 * i)) << 16 | UInt32(sample(3 * i + 1)) << 8 | UInt32(sample(3 * i + 2))
                    }
                case .composited(let transparency):
                    for i in 0..<count {
                        let (r, g, b, a) = Self.rgba(transparency, i, sample: sample, depth: depth, channels: channels)
                        ints[y * width + x0 + i * dx] =
                            0xFF00_0000 | UInt32(Self.overWhite(r, a)) << 16 | UInt32(Self.overWhite(g, a)) << 8
                            | UInt32(Self.overWhite(b, a))
                    }
                }
            }
        }

        /// Pixel `i` as 8-bit sRGB and alpha, as Java2D's ColorModel gives it.
        @inline(__always)
        static func rgba(_ t: Target.Transparency, _ i: Int, sample: (Int) -> Int, depth: Int, channels: Int)
            -> (Int, Int, Int, Int)
        {
            switch t {
            case .palette(let colors, let alphas):
                let index = sample(i), c = colors[index]
                return (Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF), Int(alphas[index]))
            case .key(let key):
                if channels == 1 {
                    let s = sample(i)
                    let a = s == key[0] ? 0 : 255
                    let v = depth == 16 ? Int(SRGB.from16[s]) : Int(SRGB.from8[depth == 8 ? s : s * 255 / ((1 << depth) - 1)])
                    return (v, v, v, a)
                }
                let r = sample(3 * i), g = sample(3 * i + 1), b = sample(3 * i + 2)
                let a = r == key[0] && g == key[1] && b == key[2] ? 0 : 255
                return depth == 16 ? (to8(r), to8(g), to8(b), a) : (r, g, b, a)
            case .alphaChannel:
                if channels == 2 {
                    let v = depth == 16 ? Int(SRGB.from16[sample(2 * i)]) : Int(SRGB.from8[sample(2 * i)])
                    let a = sample(2 * i + 1)
                    return (v, v, v, depth == 16 ? to8(a) : a)
                }
                let r = sample(4 * i), g = sample(4 * i + 1), b = sample(4 * i + 2), a = sample(4 * i + 3)
                return depth == 16 ? (to8(r), to8(g), to8(b), to8(a)) : (r, g, b, a)
            }
        }

        /// ComponentColorModel's 16- to 8-bit scaling, round(v · 255 / 65535).
        @inline(__always) static func to8(_ v: Int) -> Int { (2 * v + 257) / 514 }

        /// Java2D's SrcOver onto opaque white: mul8(a, c) + mul8(255 − a, 255),
        /// with mul8 its rounded product table.
        @inline(__always) static func overWhite(_ c: Int, _ a: Int) -> Int {
            (a * c + 127) / 255 + ((255 - a) * 255 + 127) / 255
        }

        func image(title: String) throws(MancoraIOError) -> Hyperstack {
            let w = header.width, h = header.height
            do {
                switch target {
                case .gray8(let lut):
                    let stack = try ImageStack(width: w, height: h, planes: [.gray8(bytes)])
                    var named = lut
                    if !lut.hasSameColors(as: .grays) { named.name = LUTReader.baseName(of: title) }
                    let display = ChannelDisplay(lut: lut.hasSameColors(as: .grays) ? .grays : named, displayRange: 0...255)
                    return try Hyperstack(title: title, stack: stack, channels: [display])
                case .gray16:
                    return try Hyperstack(title: title, stack: ImageStack(width: w, height: h, planes: [.gray16(shorts[0])]))
                case .rgb16:
                    // `new CompositeImage(imp, COMPOSITE)` on the three samples.
                    let stack = try ImageStack(width: w, height: h, planes: shorts.map { .gray16($0) })
                    return try Hyperstack(
                        title: title, stack: stack, dimensions: HyperstackDimensions(channels: 3), compositeMode: .composite)
                case .rgb8, .composited:
                    return try Hyperstack(title: title, stack: ImageStack(width: w, height: h, planes: [.rgb8(ints)]))
                }
            } catch {
                throw .model(error)
            }
        }
    }
}

/// OpenJDK's linear-to-sRGB tables (`ColorModel.getLinearRGB8TosRGB8LUT`
/// and `getLinearRGB16TosRGB8LUT`): the IEC 61966-2-1 curve in Java's
/// float arithmetic, rounded with `Math.round`.
enum SRGB {
    static let from8: [UInt8] = (0...255).map { encode(Float($0) / 255) }
    static let from16: [UInt8] = (0...65535).map { encode(Float($0) / 65535) }

    static func encode(_ v: Float) -> UInt8 {
        let out: Float = v <= 0.0031308 ? v * 12.92 : 1.055 * Float(pow(Double(v), 1.0 / 2.4)) - 0.055
        return UInt8(clamping: Int((out * 255 + 0.5).rounded(.down)))
    }
}
