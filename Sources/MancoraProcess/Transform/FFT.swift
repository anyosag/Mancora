public import MancoraCore

/// The image work of Process ▸ FFT (`ij.plugin.FFT`): the forward
/// transform with its power spectrum, and the inverse transform, filtered
/// by the black or white marks drawn on the spectrum.
public enum FFT {
    /// What the forward transform shows and keeps.
    public struct Forward: Sendable {
        /// The 8-bit power spectrum, `size × size`.
        public var powerSpectrum: [UInt8]
        public var domain: FrequencyDomain
    }

    /// `newFHT` and `doForwardTransform`: the plane (an RGB image's
    /// brightness) is padded to a square power of 2, filled with its mean
    /// (`pad`), and transformed. `nil` when the padded size is 65536 or more.
    public static func forward(_ plane: Plane, width: Int, height: Int, lut: LUT?) -> Forward? {
        let maxN = max(width, height)
        var size = 2
        while size < maxN { size *= 2 }
        let padded = !(size == maxN && width == height)
        if padded, size >= 65536 { return nil }

        var rgb: [UInt32]?
        let values: [Float]
        let fill: Float
        switch plane {
        case .gray8(let p):
            values = p.map { Float($0) }
            fill = Float(min(max(JavaNumerics.int32(integerMean(p)), 0), 255))
        case .gray16(let p):
            values = p.map { Float($0) }
            fill = Float(min(max(JavaNumerics.int32(integerMean(p)), 0), 65535))
        case .gray32Float(let p):
            values = p
            fill = Float(floatMean(p))
        case .rgb8(let p):
            // ColorProcessor.getBrightness(): Color.RGBtoHSB's brightness.
            values = p.map { Float(max($0 >> 16 & 0xFF, $0 >> 8 & 0xFF, $0 & 0xFF)) / 255 }
            fill = Float(floatMean(values))
            rgb = p
        }
        var fht: [Float]
        if padded {
            fht = [Float](repeating: fill, count: size * size)
            for y in 0..<height {
                for x in 0..<width { fht[y * size + x] = values[y * width + x] }
            }
        } else {
            fht = values
        }
        FHT(size: size).transform(&fht, inverse: false)
        let spectrum = FHT(size: size).powerSpectrum(fht)
        let domain = FrequencyDomain(
            transform: fht, size: size, originalWidth: padded ? width : 0, originalHeight: padded ? height : 0,
            originalType: plane.pixelType, originalLUT: rgb == nil ? lut : nil, rgb: rgb,
            powerSpectrumMean: integerMean(spectrum))
        return Forward(powerSpectrum: spectrum, domain: domain)
    }

    /// `ByteStatistics`' or `ShortStatistics`' mean: the exact sum over the count.
    public static func integerMean<T: FixedWidthInteger>(_ pixels: [T]) -> Double {
        var sum = 0
        for v in pixels { sum += Int(v) }
        return Double(sum) / Double(pixels.count)
    }

    /// `FloatStatistics`' mean: the finite values summed in `double`, in order.
    static func floatMean(_ pixels: [Float]) -> Double {
        var sum = 0.0
        var count = 0
        for v in pixels where v >= -Float.greatestFiniteMagnitude && v <= Float.greatestFiniteMagnitude {
            sum += Double(v)
            count += 1
        }
        return sum / Double(count)
    }

    /// `doMasking`'s filter, from the (8-bit) power spectrum as edited:
    /// with pixels set to 255 only they and their mirror images pass,
    /// otherwise those set to 0 (and theirs) are removed; the edges are
    /// smoothed three times, and the quadrants swapped back. `nil` when no
    /// pixel is 0 or 255.
    public static func filterMask(_ spectrum: [UInt8], size: Int) -> [UInt8]? {
        let hasBlack = spectrum.contains(0)
        let hasWhite = spectrum.contains(255)
        guard hasBlack || hasWhite else { return nil }
        var mask = spectrum
        if hasWhite {
            changeValuesAndSymmetrize(&mask, size: size, keep: 255, others: 0)
        } else {
            changeValuesAndSymmetrize(&mask, size: size, keep: 0, others: 255)
        }
        for _ in 0..<3 { smooth(&mask, size: size) }
        FHT.swapQuadrants(&mask, width: size)
        return mask
    }

    /// `changeValuesAndSymmetrize`: pixels other than `keep` become
    /// `others`; each `keep` pixel's mirror image becomes `keep`, in one
    /// pass, as ImageJ does it.
    static func changeValuesAndSymmetrize(_ pixels: inout [UInt8], size n: Int, keep: UInt8, others: UInt8) {
        for i in pixels.indices {
            if pixels[i] == keep {
                if i % n == 0 {
                    if i > 0 { pixels[n * n - i] = keep }
                } else if i < n {
                    pixels[n - i] = keep
                } else {
                    pixels[n * (n + 1) - i] = keep
                }
            } else {
                pixels[i] = others
            }
        }
    }

    /// `FFT.smooth`: the 3×3 mean, rounded, with periodic edges.
    static func smooth(_ pixels: inout [UInt8], size n: Int) {
        let source = pixels
        for y in 0..<n {
            let rows = [(y - 1 + n) % n * n, y * n, (y + 1) % n * n]
            for x in 0..<n {
                let columns = [(x - 1 + n) % n, x, (x + 1) % n]
                var sum = 0
                for r in rows {
                    for c in columns { sum += Int(source[r + c]) }
                }
                pixels[y * n + x] = UInt8((sum + 4) / 9)
            }
        }
    }

    /// The image the inverse transform makes.
    public struct Inverse: Sendable {
        public var plane: Plane
        public var width: Int
        public var height: Int
        /// The display range, `nil` for RGB.
        public var displayRange: ClosedRange<Double>?
        public var lut: LUT?
    }

    /// `doInverseTransform`: the transform (times `mask`/255) transformed
    /// back, cropped to the size before padding and converted to the
    /// original type without scaling; an RGB image gets it as brightness.
    public static func inverse(_ domain: FrequencyDomain, mask: [UInt8]?) -> Inverse {
        var fht = domain.transform
        if let mask {
            for i in fht.indices { fht[i] = Float(Double(fht[i] * Float(mask[i])) / 255.0) }
        }
        let n = domain.size
        FHT(size: n).transform(&fht, inverse: true)
        // resetMinAndMax(), which the cropped processor inherits.
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for v in fht where !v.isInfinite {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        var (width, height) = (n, n)
        var values = fht
        if domain.originalWidth > 0 {
            (width, height) = (domain.originalWidth, domain.originalHeight)
            values = []
            values.reserveCapacity(width * height)
            for y in 0..<height { values += fht[(y * n)..<(y * n + width)] }
        }
        switch domain.originalType {
        case .gray8:
            // ByteProcessor.setPixels(0, fp)
            let p = values.map { v -> UInt8 in
                var value = v + 0.5
                if value < 0 { value = 0 }
                if value > 255 { value = 255 }
                return UInt8(truncatingIfNeeded: JavaNumerics.int32(value))
            }
            return Inverse(plane: .gray8(p), width: width, height: height, displayRange: 0...255, lut: domain.originalLUT)
        case .gray16:
            // TypeConverter.convertFloatToShort() without scaling
            let p = values.map { v -> UInt16 in
                var value = Double(v)
                if value < 0 { value = 0 }
                if value > 65535 { value = 65535 }
                return UInt16(truncatingIfNeeded: JavaNumerics.int32(value + 0.5))
            }
            let plane = Plane.gray16(p)
            return Inverse(
                plane: plane, width: width, height: height, displayRange: plane.valueRange() ?? 0...0,
                lut: domain.originalLUT)
        case .gray32Float:
            return Inverse(
                plane: .gray32Float(values), width: width, height: height,
                displayRange: lo <= hi ? Double(lo)...Double(hi) : 0...0, lut: domain.originalLUT)
        case .rgb8:
            // ColorProcessor.setBrightness(fp)
            let original = domain.rgb ?? []
            var p = [UInt32](repeating: 0xFF00_0000, count: width * height)
            for i in p.indices where i < original.count {
                let c = original[i]
                let (hue, saturation, _) = rgbToHSB(Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF))
                p[i] = hsbToRGB(hue, saturation, min(max(values[i], 0), 1))
            }
            return Inverse(plane: .rgb8(p), width: width, height: height, displayRange: nil, lut: nil)
        }
    }

    /// `java.awt.Color.RGBtoHSB`, in `float`.
    static func rgbToHSB(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
        let cmax = max(r, g, b)
        let cmin = min(r, g, b)
        let brightness = Float(cmax) / 255
        let saturation: Float = cmax != 0 ? Float(cmax - cmin) / Float(cmax) : 0
        guard saturation != 0 else { return (0, saturation, brightness) }
        let range = Float(cmax - cmin)
        let redc = Float(cmax - r) / range
        let greenc = Float(cmax - g) / range
        let bluec = Float(cmax - b) / range
        var hue: Float
        if r == cmax {
            hue = bluec - greenc
        } else if g == cmax {
            hue = 2 + redc - bluec
        } else {
            hue = 4 + greenc - redc
        }
        hue = hue / 6
        if hue < 0 { hue = hue + 1 }
        return (hue, saturation, brightness)
    }

    /// `java.awt.Color.HSBtoRGB`, in `float`.
    static func hsbToRGB(_ hue: Float, _ saturation: Float, _ brightness: Float) -> UInt32 {
        func channel(_ v: Float) -> UInt32 { UInt32(truncatingIfNeeded: JavaNumerics.int32(v * 255 + 0.5)) & 0xFF }
        var (r, g, b): (UInt32, UInt32, UInt32)
        if saturation == 0 {
            r = channel(brightness)
            (g, b) = (r, r)
        } else {
            let h = (hue - hue.rounded(.down)) * 6
            let f = h - h.rounded(.down)
            let p = brightness * (1 - saturation)
            let q = brightness * (1 - saturation * f)
            let t = brightness * (1 - (saturation * (1 - f)))
            switch JavaNumerics.int32(h) {
            case 0: (r, g, b) = (channel(brightness), channel(t), channel(p))
            case 1: (r, g, b) = (channel(q), channel(brightness), channel(p))
            case 2: (r, g, b) = (channel(p), channel(brightness), channel(t))
            case 3: (r, g, b) = (channel(p), channel(q), channel(brightness))
            case 4: (r, g, b) = (channel(t), channel(p), channel(brightness))
            case 5: (r, g, b) = (channel(brightness), channel(p), channel(q))
            default: (r, g, b) = (0, 0, 0)
            }
        }
        return 0xFF00_0000 | r << 16 | g << 8 | b
    }
}
