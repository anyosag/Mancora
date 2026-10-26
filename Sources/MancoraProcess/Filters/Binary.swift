public import MancoraCore

/// The commands of Process ▸ Binary that work on 8-bit masks (ImageJ's
/// `ij.plugin.filter.Binary`).
public enum BinaryOperation: String, Sendable, Hashable, CaseIterable {
    /// Removes foreground pixels with at least `count` background neighbors,
    /// `iterations` times (`ByteProcessor.erode(count, background)`).
    case erode
    /// Adds background pixels with at least `count` foreground neighbors,
    /// `iterations` times (`ByteProcessor.dilate(count, background)`).
    case dilate
    /// Erosion followed by dilation, each `iterations` times.
    case open
    /// Dilation followed by erosion, each `iterations` times.
    case close
    /// Keeps only the foreground pixels that touch the background
    /// (`BinaryProcessor.outline`). Edge pixels are left unchanged.
    case outline
    /// Fill Holes: background regions that don't touch the image edge
    /// (4-connected) become foreground (`Binary.fill`).
    case fillHoles
    /// Thins objects to one-pixel-wide skeletons (`BinaryProcessor.skeletonize`).
    case skeletonize
}

/// The settings of Process ▸ Binary ▸ Options that the binary commands use.
public struct BinaryOptions: Sendable, Hashable {
    /// ImageJ's "Black background": `true` means objects are 255 on 0,
    /// `false` that they are 0 on 255.
    ///
    /// ImageJ also swaps the two for an image shown with an inverted LUT;
    /// pass the opposite value for such images.
    public var blackBackground: Bool
    /// How often erode and dilate run (ImageJ's dialog allows 1–100).
    public var iterations: Int
    /// The number of neighbors (1–8) that must differ for erode or dilate to
    /// change a pixel.
    public var count: Int
    /// "Pad edges when eroding": treat out-of-image pixels as foreground when
    /// eroding, so objects don't erode from the image edge. Dilation always
    /// treats them as background.
    public var padEdges: Bool

    public init(blackBackground: Bool, iterations: Int = 1, count: Int = 1, padEdges: Bool = false) {
        self.blackBackground = blackBackground
        self.iterations = iterations
        self.count = count
        self.padEdges = padEdges
    }

    var foreground: UInt8 { blackBackground ? 255 : 0 }
    var background: UInt8 { 255 - foreground }
}

extension Plane {
    /// A Process ▸ Binary command on an 8-bit mask, as ImageJ's
    /// `Binary.run(ip)` performs it.
    ///
    /// The mask should hold only 0 and 255 (ImageJ refuses other images);
    /// other values follow ImageJ's processors, which compare pixels with the
    /// foreground and background values.
    ///
    /// - Throws: ``FilterError/unsupportedPixelType(_:expected:)`` unless
    ///   the plane is 8-bit grayscale.
    public func binary(_ operation: BinaryOperation, options: BinaryOptions, width: Int) throws(FilterError) -> Plane {
        guard case .gray8(let pixels) = self else {
            throw .unsupportedPixelType(pixelType, expected: .gray8)
        }
        let height = filterHeight(width: width)
        guard count > 0 else { return self }
        var mask = BinaryMask(pixels: pixels, width: width, height: height)
        let fg = options.foreground, bg = options.background
        switch operation {
        case .erode:
            mask.iterate(.erode, options)
        case .dilate:
            mask.iterate(.dilate, options)
        case .open:
            mask.iterate(.erode, options)
            mask.iterate(.dilate, options)
        case .close:
            mask.iterate(.dilate, options)
            mask.iterate(.erode, options)
        case .outline:
            mask.outline(background: bg)
        case .fillHoles:
            mask.fillHoles(foreground: fg, background: bg)
        case .skeletonize:
            mask.skeletonize(foreground: fg)
        }
        return .gray8(mask.pixels)
    }
}

extension ImageStack {
    /// A Process ▸ Binary command on every plane; see
    /// `Plane.binary(_:options:width:)`.
    public func binary(_ operation: BinaryOperation, options: BinaryOptions) throws(FilterError) -> ImageStack {
        guard pixelType == .gray8 else { throw .unsupportedPixelType(pixelType, expected: .gray8) }
        return mapPlanes { plane in
            do {
                return try plane.binary(operation, options: options, width: width)
            } catch {
                preconditionFailure("8-bit plane rejected: \(error)")
            }
        }
    }
}

/// Ports of ImageJ 1.54p's binary operations (`ByteProcessor.filter` with
/// ERODE and DILATE, `BinaryProcessor.outline` and `skeletonize`,
/// `Binary.fill`).
struct BinaryMask {
    var pixels: [UInt8]
    let width: Int
    let height: Int

    enum Morphology { case erode, dilate }

    mutating func iterate(_ op: Morphology, _ options: BinaryOptions) {
        var i = 0
        while i < options.iterations {
            morph(op, count: options.count, background: options.background, padEdges: options.padEdges)
            i += 1
        }
    }

    /// `ByteProcessor.filter(ERODE or DILATE)` with `binaryCount = count`.
    /// Out-of-image pixels are background, or foreground when padding
    /// erosion (`getEdgePixel0` and `getEdgePixel1`).
    mutating func morph(_ op: Morphology, count: Int, background bg: UInt8, padEdges: Bool) {
        let fg = 255 - bg
        let pad = op == .erode && padEdges ? fg : bg
        let pw = width + 2
        var src = [UInt8](repeating: pad, count: pw * (height + 2))
        for y in 0..<height {
            for x in 0..<width { src[(y + 1) * pw + x + 1] = pixels[y * width + x] }
        }
        // ERODE counts background neighbors of foreground pixels, DILATE
        // foreground neighbors of background pixels.
        let keep = op == .erode ? bg : fg  // the center value that is never changed
        let other = op == .erode ? fg : bg
        src.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    for x in 0..<width {
                        let t = y * pw + x, m = t + pw, b = m + pw
                        if src[m + 1] == keep {
                            out[y * width + x] = keep
                            continue
                        }
                        var n = 0
                        if src[t] == keep { n += 1 }
                        if src[t + 1] == keep { n += 1 }
                        if src[t + 2] == keep { n += 1 }
                        if src[m] == keep { n += 1 }
                        if src[m + 2] == keep { n += 1 }
                        if src[b] == keep { n += 1 }
                        if src[b + 1] == keep { n += 1 }
                        if src[b + 2] == keep { n += 1 }
                        out[y * width + x] = n >= count ? keep : other
                    }
                }
            }
        }
    }

    /// `BinaryProcessor.outline` on the inner pixels (with a black
    /// background, Binary inverts around it, which comes to the same).
    mutating func outline(background bg: UInt8) {
        guard width > 2, height > 2 else { return }
        let src = pixels
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let p = y * width + x
                guard src[p] != bg else { continue }
                if src[p - width - 1] != bg && src[p - width] != bg && src[p - width + 1] != bg
                    && src[p - 1] != bg && src[p + 1] != bg
                    && src[p + width - 1] != bg && src[p + width] != bg && src[p + width + 1] != bg
                {
                    pixels[p] = bg
                }
            }
        }
    }

    /// `Binary.fill`: flood-fills (4-connected) the background from every
    /// background pixel on the edge; the rest becomes foreground.
    mutating func fillHoles(foreground fg: UInt8, background bg: UInt8) {
        var reached = [Bool](repeating: false, count: pixels.count)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if pixels[i] == bg && !reached[i] {
                reached[i] = true
                stack.append(i)
            }
        }
        for y in 0..<height {
            seed(y * width)
            seed(y * width + width - 1)
        }
        for x in 0..<width {
            seed(x)
            seed((height - 1) * width + x)
        }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { seed(i - 1) }
            if x < width - 1 { seed(i + 1) }
            if y > 0 { seed(i - width) }
            if y < height - 1 { seed(i + width) }
        }
        // ImageJ fills with 127 and then maps 127 to background, so a 127
        // pixel in a (non-binary) input ends up as background too.
        for i in pixels.indices { pixels[i] = reached[i] || pixels[i] == 127 ? bg : fg }
    }

    /// `BinaryProcessor.skeletonize(foreground)`.
    mutating func skeletonize(foreground fg: UInt8) {
        let bg = 255 - fg
        var hasEdgePixels = false
        for x in 0..<width where pixels[x] == fg || pixels[(height - 1) * width + x] == fg { hasEdgePixels = true }
        for y in 0..<height where pixels[y * width] == fg || pixels[y * width + width - 1] == fg { hasEdgePixels = true }
        // Objects touching the edge are thinned inside a one-pixel background border.
        var work: BinaryMask
        if hasEdgePixels {
            work = BinaryMask(pixels: [UInt8](repeating: bg, count: (width + 2) * (height + 2)), width: width + 2, height: height + 2)
            for y in 0..<height {
                for x in 0..<width { work.pixels[(y + 1) * (width + 2) + x + 1] = pixels[y * width + x] }
            }
        } else {
            work = self
        }
        work.skeletonize2(foreground: fg)
        if hasEdgePixels {
            for y in 0..<height {
                for x in 0..<width { pixels[y * width + x] = work.pixels[(y + 1) * (width + 2) + x + 1] }
            }
        } else {
            self = work
        }
    }

    /// `BinaryProcessor.skeletonize2`: clears the border, then thins with
    /// `table` until nothing changes, then with `table2`.
    mutating func skeletonize2(foreground fg: UInt8) {
        let bg = 255 - fg
        for x in 0..<width {
            pixels[x] = bg
            pixels[(height - 1) * width + x] = bg
        }
        for y in 0..<height {
            pixels[y * width] = bg
            pixels[y * width + width - 1] = bg
        }
        var pass = 0
        var removed: Int
        repeat {
            removed = thin(pass, Self.table, background: bg)
            pass += 1
            removed += thin(pass, Self.table, background: bg)
            pass += 1
        } while removed > 0
        repeat {  // the second table removes "stuck" pixels
            removed = thin(pass, Self.table2, background: bg)
            pass += 1
            removed += thin(pass, Self.table2, background: bg)
            pass += 1
        } while removed > 0
    }

    /// `BinaryProcessor.thin`: one pass of deleting pixels whose
    /// neighborhood the table marks for this pass (1: even passes, 2: odd
    /// passes, 3: both).
    mutating func thin(_ pass: Int, _ table: [UInt8], background bg: UInt8) -> Int {
        guard width > 2, height > 2 else { return 0 }
        let src = pixels
        var removedCount = 0
        let deleting: (UInt8, UInt8) = pass & 1 == 1 ? (2, 3) : (1, 3)
        src.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let p = y * width + x
                        guard src[p] != bg else { continue }
                        var index = 0
                        if src[p - width - 1] != bg { index |= 1 }
                        if src[p - width] != bg { index |= 2 }
                        if src[p - width + 1] != bg { index |= 4 }
                        if src[p + 1] != bg { index |= 8 }
                        if src[p + width + 1] != bg { index |= 16 }
                        if src[p + width] != bg { index |= 32 }
                        if src[p + width - 1] != bg { index |= 64 }
                        if src[p - 1] != bg { index |= 128 }
                        let code = table[index]
                        if code == deleting.0 || code == deleting.1 {
                            out[p] = bg
                            removedCount += 1
                        }
                    }
                }
            }
        }
        return removedCount
    }

    // The lookup tables of BinaryProcessor, indexed by the 8 neighbors.
    static let table: [UInt8] = [
        0, 0, 0, 0, 0, 0, 1, 3, 0, 0, 3, 1, 1, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 3, 0, 3, 3,
        0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 2, 2,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 3, 0, 2, 0,
        0, 0, 3, 1, 0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
        3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 3, 1, 3, 0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 0, 1, 0, 0, 0, 0, 2, 2, 0, 0, 2, 0, 0, 0,
    ]

    static let table2: [UInt8] = [
        0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 2, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
}
