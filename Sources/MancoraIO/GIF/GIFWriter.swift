#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import MancoraCore

/// Saves GIF files as ImageJ 1.54p's `GifWriter` does (File ▸ Save As ▸ GIF):
///
/// - A single image is saved as ImageJ's `getBufferedImage()` presents it
///   (see ``ImageJView``): 8-bit gray, or the raw values with the LUT
///   stretched over the display range as the colour table; 16- and 32-bit
///   images are scaled to 8 bits first. With a transparent index (off by
///   default), the LUT is used as it is and that entry is transparent.
/// - A stack becomes an animated GIF, as `AnimatedGifEncoder2` writes it:
///   every slice with its raw values and the stack's LUT (gray for a
///   composite) as a 256-colour local table, looping forever, each frame
///   shown for 1/fps seconds (ImageJ's animation rate, 7 fps, when the image
///   has none), with ImageJ's own LZW encoder.
///
/// RGB images (which ImageJ reduces to 256 colours with its own
/// quantizers) throw ``MancoraIOError/unsupported(_:)``. Stacks must be
/// 8-bit, as in ImageJ.
public enum GIFWriter {
    public struct Options: Sendable {
        /// The plane to save from a single-slice position, 0-based.
        public var channel: Int
        public var slice: Int
        public var frame: Int
        /// ImageJ's `Prefs.getTransparentIndex()`, or `nil` for none (ImageJ's default).
        public var transparentIndex: Int?
        /// The frame rate an animation uses when the image has none (`Animator.getFrameRate()`).
        public var defaultFrameRate: Double

        public init(channel: Int = 0, slice: Int = 0, frame: Int = 0, transparentIndex: Int? = nil, defaultFrameRate: Double = 7) {
            self.channel = channel
            self.slice = slice
            self.frame = frame
            self.transparentIndex = transparentIndex
            self.defaultFrameRate = defaultFrameRate
        }
    }

    public static func write(_ image: Hyperstack, to path: String, options: Options = Options()) throws(MancoraIOError) {
        let bytes = try encode(image, options: options)
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
    }

    public static func encode(_ image: Hyperstack, options: Options = Options()) throws(MancoraIOError) -> [UInt8] {
        let w = image.width, h = image.height
        guard w <= 0xFFFF, h <= 0xFFFF else { throw .unsupported("GIF images larger than 65535 pixels across") }
        if image.stack.count == 1 {
            let indices: [UInt8], palette: LUT
            var transparent: Int?
            if let t = options.transparentIndex, (0...255).contains(t), image.pixelType != .rgb8,
                case .gray8(let pixels) = image.stack[0]
            {
                (indices, palette, transparent) = (pixels, image.channels[0].lut, t)
            } else {
                switch ImageJView(image, channel: 0, slice: 0, frame: 0) {
                case .gray(let pixels): (indices, palette) = (pixels, .grays)
                case .indexed(let pixels, let lut): (indices, palette) = (pixels, lut)
                case .rgb: throw .unsupported("saving RGB images as GIF (ImageJ reduces them to 256 colours)")
                }
            }
            return gif(width: w, height: h, frames: [(indices, palette)], delay: nil, transparent: transparent)
        }
        guard image.pixelType == .gray8 else {
            if image.pixelType == .rgb8 { throw .unsupported("saving RGB stacks as animated GIF (ImageJ reduces them to 256 colours)") }
            throw .invalidFormat("Image must be 8-bit or RGB")
        }
        let lut = image.dimensions.channels > 1 ? LUT.grays : image.channels[0].lut
        var fps = image.calibration.fps
        if fps == 0 { fps = options.defaultFrameRate }
        fps = min(max(fps, 0.2), 60)
        // setDelay(ms) keeps hundredths of a second, rounded.
        let milliseconds = Int((1.0 / fps) * 1000.0)
        let delay = Int((Float(milliseconds) / 10).rounded(.toNearestOrAwayFromZero))
        let frames = image.stack.planes.map { plane -> ([UInt8], LUT) in
            guard case .gray8(let pixels) = plane else { return ([], lut) }
            return (pixels, lut)
        }
        return gif(width: w, height: h, frames: frames, delay: delay, transparent: nil)
    }

    /// One image with a global colour table (`delay == nil`), or an
    /// animation of frames with local tables, as AnimatedGifEncoder2 lays it out.
    static func gif(width: Int, height: Int, frames: [([UInt8], LUT)], delay: Int?, transparent: Int?) -> [UInt8] {
        var out = Array("GIF89a".utf8)
        func short(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func table(_ lut: LUT) {
            for i in 0..<256 { out += [lut.reds[i], lut.greens[i], lut.blues[i]] }
        }
        short(width)
        short(height)
        if let delay {
            out += [0x70, 0, 0]  // no global table, colour resolution 7
            out += [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]  // loop forever
            for (pixels, lut) in frames {
                out += [0x21, 0xF9, 4, 0]
                short(delay)
                out += [0, 0]
                out += [0x2C]
                short(0)
                short(0)
                short(width)
                short(height)
                out += [0x87]  // local 256-entry table, not interlaced
                table(lut)
                out += LZW.encode(pixels)
            }
        } else if let (pixels, lut) = frames.first {
            out += [0xF7, 0, 0]  // global 256-entry table
            table(lut)
            if let transparent { out += [0x21, 0xF9, 4, 1, 0, 0, UInt8(transparent), 0] }
            out += [0x2C]
            short(0)
            short(0)
            short(width)
            short(height)
            out += [0]
            out += LZW.encode(pixels)
        }
        out.append(0x3B)
        return out
    }

    /// ImageJ's `LZWEncoder2` (Jef Poskanzer's compress, by way of Kevin
    /// Weiner) for 8-bit pixels: the minimum code size byte, the data in
    /// sub-blocks of 254 bytes, and the block terminator.
    enum LZW {
        static func encode(_ pixels: [UInt8]) -> [UInt8] {
            let initCodeSize = 8
            let maxbits = 12, maxmaxcode = 1 << 12, hsize = 5003
            var htab = [Int](repeating: -1, count: hsize)
            var codetab = [Int](repeating: 0, count: hsize)
            let initBits = initCodeSize + 1
            var nBits = initBits
            var maxcode = (1 << nBits) - 1
            let clearCode = 1 << (initBits - 1), eofCode = clearCode + 1
            var freeEnt = clearCode + 2
            var clearFlag = false
            var accumulator = 0, accumulated = 0
            var packet: [UInt8] = []
            var out: [UInt8] = [UInt8(initCodeSize)]

            func charOut(_ c: UInt8) {
                packet.append(c)
                if packet.count >= 254 { flush() }
            }
            func flush() {
                guard !packet.isEmpty else { return }
                out.append(UInt8(packet.count))
                out += packet
                packet.removeAll(keepingCapacity: true)
            }
            func output(_ code: Int) {
                accumulator &= (1 << accumulated) - 1
                accumulator = accumulated > 0 ? accumulator | code << accumulated : code
                accumulated += nBits
                while accumulated >= 8 {
                    charOut(UInt8(accumulator & 0xFF))
                    accumulator >>= 8
                    accumulated -= 8
                }
                if freeEnt > maxcode || clearFlag {
                    if clearFlag {
                        nBits = initBits
                        maxcode = (1 << nBits) - 1
                        clearFlag = false
                    } else {
                        nBits += 1
                        maxcode = nBits == maxbits ? maxmaxcode : (1 << nBits) - 1
                    }
                }
                if code == eofCode {
                    while accumulated > 0 {
                        charOut(UInt8(accumulator & 0xFF))
                        accumulator >>= 8
                        accumulated -= 8
                    }
                    flush()
                }
            }

            var hshift = 0
            var f = hsize
            while f < 65536 {
                hshift += 1
                f *= 2
            }
            hshift = 8 - hshift
            output(clearCode)
            guard var ent = pixels.first.map(Int.init) else {
                output(eofCode)
                out.append(0)
                return out
            }
            var p = 1
            outer: while p < pixels.count {
                let c = Int(pixels[p])
                p += 1
                let fcode = (c << maxbits) + ent
                var i = (c << hshift) ^ ent
                if htab[i] == fcode {
                    ent = codetab[i]
                    continue
                } else if htab[i] >= 0 {
                    var disp = hsize - i
                    if i == 0 { disp = 1 }
                    repeat {
                        i -= disp
                        if i < 0 { i += hsize }
                        if htab[i] == fcode {
                            ent = codetab[i]
                            continue outer
                        }
                    } while htab[i] >= 0
                }
                output(ent)
                ent = c
                if freeEnt < maxmaxcode {
                    codetab[i] = freeEnt
                    freeEnt += 1
                    htab[i] = fcode
                } else {
                    // cl_block: clear the table and say so.
                    for k in 0..<hsize { htab[k] = -1 }
                    freeEnt = clearCode + 2
                    clearFlag = true
                    output(clearCode)
                }
            }
            output(ent)
            output(eofCode)
            out.append(0)
            return out
        }
    }
}
