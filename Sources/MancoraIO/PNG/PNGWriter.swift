#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import MancoraCore
import MancoraSupport

/// Saves PNG files as ImageJ 1.54p's `PNG_Writer` does (File ▸ Save As ▸
/// PNG), one plane at a time:
///
/// - an 8-bit stack of four slices whose fourth is labelled "alpha" as RGBA;
/// - with a transparent index (Edit ▸ Options ▸ Input/Output; off by
///   default), an 8-bit image as a palette PNG whose palette is the LUT,
///   that entry transparent;
/// - 16-bit with the default gray LUT, and not a composite, as 16-bit gray;
/// - everything else as ImageJ's `getBufferedImage()` presents the plane
///   (see ``ImageJView``): 8-bit gray, a palette of the LUT, or RGB for RGB
///   images and composites.
///
/// An overlay isn't drawn into the image (ImageJ flattens a visible one).
public enum PNGWriter {
    public struct Options: Sendable {
        /// The plane to save, 0-based, as the image's current position.
        public var channel: Int
        public var slice: Int
        public var frame: Int
        /// ImageJ's `Prefs.getTransparentIndex()`: an 8-bit LUT index to make
        /// transparent, or `nil` (ImageJ's default, -1).
        public var transparentIndex: Int?

        public init(channel: Int = 0, slice: Int = 0, frame: Int = 0, transparentIndex: Int? = nil) {
            self.channel = channel
            self.slice = slice
            self.frame = frame
            self.transparentIndex = transparentIndex
        }
    }

    public static func write(_ image: Hyperstack, to path: String, options: Options = Options()) throws(MancoraIOError) {
        let bytes = encode(image, options: options)
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
    }

    public static func encode(_ image: Hyperstack, options: Options = Options()) -> [UInt8] {
        let w = image.width, h = image.height
        let stack = image.stack
        let index = image.dimensions.planeIndex(
            channel: min(max(options.channel, 0), image.dimensions.channels - 1),
            slice: min(max(options.slice, 0), image.dimensions.slices - 1),
            frame: min(max(options.frame, 0), image.dimensions.frames - 1))

        if stack.count == 4, image.pixelType == .gray8, stack.labels[3]?.lowercased() == "alpha" {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for c in 0..<4 {
                guard case .gray8(let p) = stack[c] else { continue }
                for i in 0..<(w * h) { rgba[4 * i + c] = p[i] }
            }
            return png(width: w, height: h, colorType: 6, depth: 8, samples: rgba)
        }
        if let t = options.transparentIndex, (0...255).contains(t), image.pixelType == .gray8,
            case .gray8(let pixels) = stack[index]
        {
            // writeImageWithTransparency: the LUT as it is, not stretched over the display range.
            let lut = image.channels[image.dimensions.channels > 1 ? options.channel : 0].lut
            let alpha = [UInt8](repeating: 255, count: t) + [0]
            return png(width: w, height: h, colorType: 3, depth: 8, samples: pixels, palette: lut, transparency: alpha)
        }
        if image.pixelType == .gray16, image.dimensions.channels == 1, image.channels[0].lut.hasSameColors(as: .grays),
            case .gray16(let pixels) = stack[index]
        {
            var samples = [UInt8](repeating: 0, count: w * h * 2)
            for (i, v) in pixels.enumerated() {
                samples[2 * i] = UInt8(v >> 8)
                samples[2 * i + 1] = UInt8(v & 0xFF)
            }
            return png(width: w, height: h, colorType: 0, depth: 16, samples: samples)
        }
        let slice = image.dimensions.position(ofPlane: index)
        switch ImageJView(image, channel: slice.channel, slice: slice.slice, frame: slice.frame) {
        case .gray(let pixels):
            return png(width: w, height: h, colorType: 0, depth: 8, samples: pixels)
        case .indexed(let pixels, let palette):
            return png(width: w, height: h, colorType: 3, depth: 8, samples: pixels, palette: palette)
        case .rgb(let pixels):
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for (i, c) in pixels.enumerated() {
                rgb[3 * i] = UInt8(c >> 16 & 0xFF)
                rgb[3 * i + 1] = UInt8(c >> 8 & 0xFF)
                rgb[3 * i + 2] = UInt8(c & 0xFF)
            }
            return png(width: w, height: h, colorType: 2, depth: 8, samples: rgb)
        }
    }

    /// A PNG of interleaved big-endian `samples`, each row filtered with the
    /// filter whose output has the smallest sum of absolute values (the
    /// usual heuristic, which ImageIO's writer also uses).
    static func png(
        width: Int, height: Int, colorType: UInt8, depth: Int, samples: [UInt8], palette: LUT? = nil,
        transparency: [UInt8]? = nil
    ) -> [UInt8] {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(colorType)] ?? 1
        let bpp = channels * depth / 8
        let rowBytes = width * bpp
        var filtered = [UInt8]()
        filtered.reserveCapacity((rowBytes + 1) * height)
        var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
        samples.withUnsafeBufferPointer { s in
            for y in 0..<height {
                let row = y * rowBytes, up = row - rowBytes
                var best = 0, bestScore = Int.max
                for f in 0..<5 {
                    var score = 0
                    candidates[f].withUnsafeMutableBufferPointer { out in
                        for i in 0..<rowBytes {
                            let x = Int(s[row + i])
                            let a = i >= bpp ? Int(s[row + i - bpp]) : 0
                            let b = y > 0 ? Int(s[up + i]) : 0
                            let c = y > 0 && i >= bpp ? Int(s[up + i - bpp]) : 0
                            let predicted: Int
                            switch f {
                            case 0: predicted = 0
                            case 1: predicted = a
                            case 2: predicted = b
                            case 3: predicted = (a + b) >> 1
                            default:
                                let p = a + b - c
                                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                                predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                            }
                            let v = UInt8(truncatingIfNeeded: x - predicted)
                            out[i] = v
                            score += v < 128 ? Int(v) : 256 - Int(v)
                        }
                    }
                    if score < bestScore {
                        bestScore = score
                        best = f
                    }
                }
                filtered.append(UInt8(best))
                filtered += candidates[best]
            }
        }

        var out: [UInt8] = PNGReader.signature
        func chunk(_ type: String, _ data: [UInt8]) {
            let body = Array(type.utf8) + data
            out += be32(data.count) + body + be32(Int(Inflate.crc32(body)))
        }
        chunk("IHDR", be32(width) + be32(height) + [UInt8(depth), colorType, 0, 0, 0])
        if let palette {
            var plte = [UInt8]()
            plte.reserveCapacity(768)
            for i in 0..<256 { plte += [palette.reds[i], palette.greens[i], palette.blues[i]] }
            chunk("PLTE", plte)
        }
        if let transparency { chunk("tRNS", transparency) }
        chunk("IDAT", Deflate.zlib(filtered))
        chunk("IEND", [])
        return out
    }

    static func be32(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v)]
    }
}
