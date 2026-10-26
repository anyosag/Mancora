public import MancoraCore

/// Opens GIF and animated GIF files as ImageJ 1.54p's `GIF_Reader` does.
///
/// - A GIF with one image opens as 8-bit, its colour table as the LUT
///   (Java's own GIF decoder, through `Toolkit.createImage`). Transparency
///   is ignored: the transparent entry keeps its colour.
/// - An animated GIF opens as an RGB stack, one slice per frame, each
///   frame composed on the logical screen as ImageJ's `GifDecoder` composes
///   it, quirks included: transparent pixels are drawn black, the disposal
///   method is read doubled (so "do not dispose" restores the background,
///   when the background colour isn't black, and the other methods keep the
///   previous frame), and a frame inherits the last graphic control
///   extension's settings. If the first frame is gray, the stack becomes
///   8-bit, as `Opener.convertGrayJpegTo8Bits` makes it.
///
/// Frame delays aren't kept: ImageJ sets no frame rate.
public enum GIFReader {
    /// Reads a GIF file; the title is the file name, as in ImageJ.
    public static func read(path: String, maximumDecodedBytes: Int = 4 << 30) throws(MancoraIOError) -> Hyperstack {
        try decode(FileLoader.load(path: path, limit: 4 << 30), title: FileType.fileName(path),
            maximumDecodedBytes: maximumDecodedBytes)
    }

    public static func decode(_ bytes: [UInt8], title: String, maximumDecodedBytes: Int = 4 << 30) throws(MancoraIOError)
        -> Hyperstack
    {
        guard bytes.count >= 6, bytes[0] == 71, bytes[1] == 73, bytes[2] == 70 else {
            throw .invalidFormat("not a GIF file")
        }
        var decoder = Decoder(bytes: bytes, maximumDecodedBytes: maximumDecodedBytes)
        try decoder.run()
        let (w, h) = (decoder.width, decoder.height)
        guard decoder.frames.count > 0, w > 0, h > 0 else { throw .invalidFormat("GIF file without an image") }
        do {
            if decoder.frames.count == 1, let single = decoder.single {
                let stack = try ImageStack(width: w, height: h, planes: [.gray8(single.indices)])
                var lut = try LUT(name: LUTReader.baseName(of: title), reds: single.lut.0, greens: single.lut.1, blues: single.lut.2)
                if lut.hasSameColors(as: .grays) { lut = .grays }
                return try Hyperstack(title: title, stack: stack, channels: [ChannelDisplay(lut: lut, displayRange: 0...255)])
            }
            let frames = decoder.frames
            let first = frames[0]
            let gray = first.allSatisfy { c in (c >> 16 & 0xFF) == (c >> 8 & 0xFF) && (c >> 8 & 0xFF) == (c & 0xFF) }
            let planes: [Plane]
            if gray {
                // TypeConverter.convertRGBToByte with the default 1/3 weights.
                let third = 1.0 / 3.0
                planes = frames.map { frame in
                    .gray8(frame.map { c in
                        let r = Double(c >> 16 & 0xFF), g = Double(c >> 8 & 0xFF), b = Double(c & 0xFF)
                        return UInt8(truncatingIfNeeded: Int(r * third + g * third + b * third + 0.5))
                    })
                }
            } else {
                planes = frames.map { frame in .rgb8(frame.map { 0xFF00_0000 | $0 }) }
            }
            return try Hyperstack(title: title, stack: ImageStack(width: w, height: h, planes: planes))
        } catch let error as ImageModelError {
            throw .model(error)
        } catch {
            throw .invalidFormat("\(error)")
        }
    }

    /// A port of the `GifDecoder` in ImageJ's GIF_Reader.java (Kevin
    /// Weiner's decoder with ImageMagick's LZW), reading from memory.
    /// Reads past the end return -1, as `InputStream.read` does.
    struct Decoder {
        let bytes: [UInt8]
        let maximumDecodedBytes: Int
        var position = 0
        var failed = false

        var width = 0, height = 0
        var gctFlag = false, gctSize = 0, bgIndex = 0, bgColor: UInt32 = 0, lastBgColor: UInt32 = 0
        var gct: [UInt32]?
        var lctFlag = false, interlace = false, lctSize = 0
        var ix = 0, iy = 0, iw = 0, ih = 0
        var lastRect = (x: 0, y: 0, w: 0, h: 0)
        var dispose = 0, lastDispose = 0
        var transparency = false
        var transIndex = 0
        var block = [UInt8](repeating: 0, count: 256)
        var blockSize = 0

        /// Composed frames, 0xAARRGGBB (alpha 0 where a transparent pixel was drawn).
        var frames: [[UInt32]] = []
        /// The first frame as Java's own decoder delivers a single image: indices and the active colour table.
        var single: (indices: [UInt8], lut: ([UInt8], [UInt8], [UInt8]))?

        init(bytes: [UInt8], maximumDecodedBytes: Int) {
            self.bytes = bytes
            self.maximumDecodedBytes = maximumDecodedBytes
        }

        mutating func read() -> Int {
            guard position < bytes.count else { return -1 }
            position += 1
            return Int(bytes[position - 1])
        }

        mutating func readShort() -> Int { read() | (read() << 8) }

        mutating func readBlock() -> Int {
            blockSize = read()
            var n = 0
            if blockSize > 0 {
                while n < blockSize, position < bytes.count {
                    block[n] = bytes[position]
                    position += 1
                    n += 1
                }
                if n < blockSize { failed = true }
            }
            return n
        }

        mutating func skip() {
            repeat { _ = readBlock() } while blockSize > 0 && !failed
        }

        mutating func readColorTable(_ count: Int) -> [UInt32]? {
            guard position + 3 * count <= bytes.count else {
                failed = true
                return nil
            }
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0..<count {
                let p = position + 3 * i
                table[i] = 0xFF00_0000 | UInt32(bytes[p]) << 16 | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2])
            }
            position += 3 * count
            return table
        }

        mutating func run() throws(MancoraIOError) {
            position = 6
            width = readShort()
            height = readShort()
            let packed = read()
            gctFlag = packed & 0x80 != 0
            gctSize = 2 << (packed & 7)
            bgIndex = read()
            _ = read()  // pixel aspect ratio
            if gctFlag {
                guard let table = readColorTable(gctSize) else { throw .invalidFormat("GIF colour table is cut short") }
                gct = table
                bgColor = table[bgIndex]
            }
            let (planeBytes, overflow) = (width * height).multipliedReportingOverflow(by: 4)
            guard !overflow, planeBytes <= maximumDecodedBytes else {
                throw .tooLarge(bytes: overflow ? .max : planeBytes, limit: maximumDecodedBytes)
            }
            var done = false
            while !(done || failed) {
                switch read() {
                case 0x2C:
                    try readImage()
                case 0x21:
                    switch read() {
                    case 0xF9: readGraphicControlExtension()
                    case 0xFF:
                        // Application extensions (NETSCAPE2.0 looping) don't change the frames.
                        _ = readBlock()
                        skip()
                    default: skip()
                    }
                case 0x3B: done = true
                default: failed = true
                }
            }
        }

        mutating func readGraphicControlExtension() {
            _ = read()  // block size
            let packed = read()
            dispose = (packed & 0x1C) >> 1  // sic: ImageJ shifts by one, not two
            transparency = packed & 1 != 0
            _ = readShort()  // delay
            transIndex = read()
            _ = read()  // block terminator
        }

        mutating func readImage() throws(MancoraIOError) {
            ix = readShort()
            iy = readShort()
            iw = readShort()
            ih = readShort()
            let packed = read()
            lctFlag = packed & 0x80 != 0
            interlace = packed & 0x40 != 0
            lctSize = 2 << (packed & 7)
            var act: [UInt32]
            var tableSize: Int
            if lctFlag {
                guard let table = readColorTable(lctSize) else { return }
                act = table
                tableSize = lctSize
            } else {
                guard let table = gct else {
                    failed = true  // no colour table
                    return
                }
                act = table
                tableSize = gctSize
                if bgIndex == transIndex { bgColor = 0 }
            }
            let palette = act
            if transparency, transIndex >= 0, transIndex < 256 { act[transIndex] = 0 }
            guard iw * ih <= maximumDecodedBytes else { throw .tooLarge(bytes: iw * ih, limit: maximumDecodedBytes) }
            let start = position
            let pixels = decodeImageData(count: iw * ih, deferredClear: false)
            skip()
            if failed { return }

            if frames.isEmpty {
                // Java's own decoder, which shows a single image, keeps decoding
                // once the code table is full (a "deferred clear").
                let end = position
                position = start
                let standard = decodeImageData(count: iw * ih, deferredClear: true)
                position = end
                single = Self.singleImage(standard, palette: palette, tableSize: tableSize, frame: (ix, iy, iw, ih),
                    interlaced: interlace, width: width, height: height)
            }
            frames.append(compose(pixels, act: act))
            lastDispose = dispose
            lastRect = (ix, iy, iw, ih)
            lastBgColor = bgColor
        }

        /// `GifDecoder.setPixels`: starts from the previous frame as its
        /// disposal says, then draws this one (rows reordered if interlaced).
        func compose(_ pixels: [UInt8], act: [UInt32]) -> [UInt32] {
            var dest = [UInt32](repeating: 0, count: width * height)
            if lastDispose > 0 {
                var lastImage = frames.last
                if lastDispose == 3 {
                    let n = frames.count - 1
                    lastImage = n > 0 ? frames[n - 1] : nil
                }
                if let lastImage {
                    dest = lastImage
                    if lastDispose == 2, lastBgColor != 0 {
                        // ColorProcessor.fill() on the last frame's rectangle, clipped to the image.
                        let fill = 0xFF00_0000 | lastBgColor
                        let x0 = max(0, lastRect.x), x1 = min(width, lastRect.x + lastRect.w)
                        let y0 = max(0, lastRect.y), y1 = min(height, lastRect.y + lastRect.h)
                        if x0 < x1, y0 < y1 {
                            for y in y0..<y1 {
                                for x in x0..<x1 { dest[y * width + x] = fill }
                            }
                        }
                    }
                }
            }
            var pass = 1, inc = 8, iline = 0
            for i in 0..<ih {
                var line = i
                if interlace {
                    if iline >= ih {
                        pass += 1
                        switch pass {
                        case 2: iline = 4
                        case 3: (iline, inc) = (2, 4)
                        case 4: (iline, inc) = (1, 2)
                        default: break
                        }
                    }
                    line = iline
                    iline += inc
                }
                line += iy
                if line < height {
                    let k = line * width
                    var dx = k + ix
                    let dlim = min(dx + iw, k + width)
                    var sx = i * iw
                    while dx < dlim {
                        dest[dx] = act[Int(pixels[sx])]
                        sx += 1
                        dx += 1
                    }
                }
            }
            return dest
        }

        /// The first image as Java's GIF decoder gives a single-image GIF:
        /// colour-table indices on the logical screen (0 outside the frame)
        /// and the active table, of its own size, as the LUT.
        static func singleImage(
            _ pixels: [UInt8], palette: [UInt32], tableSize: Int, frame: (Int, Int, Int, Int), interlaced: Bool,
            width: Int, height: Int
        ) -> (indices: [UInt8], lut: ([UInt8], [UInt8], [UInt8])) {
            let (fx, fy, fw, fh) = frame
            var rows = Array(0..<fh)
            if interlaced {
                rows = []
                for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] { rows += Array(stride(from: start, to: fh, by: step)) }
            }
            var indices = [UInt8](repeating: 0, count: width * height)
            for (i, row) in rows.enumerated() {
                let y = fy + row
                guard y < height else { continue }
                for x in 0..<fw where fx + x < width {
                    indices[y * width + fx + x] = pixels[i * fw + x]
                }
            }
            var r = [UInt8](repeating: 0, count: 256), g = r, b = r
            for i in 0..<min(tableSize, 256) {
                r[i] = UInt8(palette[i] >> 16 & 0xFF)
                g[i] = UInt8(palette[i] >> 8 & 0xFF)
                b[i] = UInt8(palette[i] & 0xFF)
            }
            return (indices, (r, g, b))
        }

        /// `GifDecoder.decodeImageData`: LZW codes to indices, missing pixels 0.
        /// GifDecoder stops when the code table fills; with `deferredClear`
        /// decoding goes on with the full table, as other decoders do.
        mutating func decodeImageData(count npix: Int, deferredClear: Bool) -> [UInt8] {
            let maxStackSize = 4096
            let nullCode = -1
            var pixels = [UInt8](repeating: 0, count: npix)
            var prefix = [Int](repeating: 0, count: maxStackSize)
            var suffix = [UInt8](repeating: 0, count: maxStackSize)
            var pixelStack = [UInt8](repeating: 0, count: maxStackSize + 1)

            let dataSize = read()
            guard dataSize >= 0, dataSize < 12 else {
                // GifDecoder overruns its tables here and the file doesn't open.
                failed = true
                return pixels
            }
            let clear = 1 << dataSize
            let endOfInformation = clear + 1
            var available = clear + 2
            var oldCode = nullCode
            var codeSize = dataSize + 1
            var codeMask = (1 << codeSize) - 1
            for code in 0..<clear {
                prefix[code] = 0
                suffix[code] = UInt8(truncatingIfNeeded: code)
            }
            var datum = 0, bits = 0, count = 0, first = 0, top = 0, pi = 0, bi = 0
            var i = 0
            while i < npix {
                if top == 0 {
                    if bits < codeSize {
                        if count == 0 {
                            count = readBlock()
                            if count <= 0 { break }
                            bi = 0
                        }
                        datum += Int(block[bi]) << bits
                        bits += 8
                        bi += 1
                        count -= 1
                        continue
                    }
                    var code = datum & codeMask
                    datum >>= codeSize
                    bits -= codeSize
                    if code > available || code == endOfInformation { break }
                    if code == clear {
                        codeSize = dataSize + 1
                        codeMask = (1 << codeSize) - 1
                        available = clear + 2
                        oldCode = nullCode
                        continue
                    }
                    if oldCode == nullCode {
                        pixelStack[top] = suffix[code]
                        top += 1
                        oldCode = code
                        first = code
                        continue
                    }
                    let inCode = code
                    if code == available {
                        pixelStack[top] = UInt8(truncatingIfNeeded: first)
                        top += 1
                        code = oldCode
                    }
                    while code > clear, top < maxStackSize {
                        pixelStack[top] = suffix[code]
                        top += 1
                        code = prefix[code]
                    }
                    first = Int(suffix[code])
                    if available >= maxStackSize {
                        if !deferredClear { break }
                        pixelStack[top] = UInt8(truncatingIfNeeded: first)
                        top += 1
                        oldCode = inCode
                        continue
                    }
                    pixelStack[top] = UInt8(truncatingIfNeeded: first)
                    top += 1
                    prefix[available] = oldCode
                    suffix[available] = UInt8(truncatingIfNeeded: first)
                    available += 1
                    if available & codeMask == 0, available < maxStackSize {
                        codeSize += 1
                        codeMask += available
                    }
                    oldCode = inCode
                }
                top -= 1
                pixels[pi] = pixelStack[top]
                pi += 1
                i += 1
            }
            return pixels
        }
    }
}
