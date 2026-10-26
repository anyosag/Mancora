public import MancoraCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Android)
import Android
#endif

/// ImageJ's interpolation methods (`ImageProcessor.NONE`, `BILINEAR` and
/// `BICUBIC`), in the order of its "Interpolation" choices.
public enum InterpolationMethod: Int, Sendable, Hashable, CaseIterable {
    case none = 0
    case bilinear = 1
    case bicubic = 2

    /// `ImageProcessor.getInterpolationMethods()`: "None", "Bilinear", "Bicubic".
    public var name: String { ["None", "Bilinear", "Bicubic"][rawValue] }

    public init?(name: String) {
        guard let method = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = method
    }

    /// The kernel size `DownsizeTable` averages over (1, 2 or 4 pixels).
    var kernelSize: Int { [1, 2, 4][rawValue] }
}

/// One plane with the state an ImageJ `ImageProcessor` carries into its
/// geometric operations: the rectangular selection (`roiX`, `roiY`, …),
/// the interpolation method, the background value and the display range
/// (`getMin`/`getMax`, which 16- and 32-bit scaling fills with).
///
/// The operations are ports of `ImageProcessor`, `ByteProcessor`,
/// `ShortProcessor`, `FloatProcessor` and `ColorProcessor` 1.54p:
/// `getInterpolatedPixel`, `getBicubicInterpolatedPixel`,
/// `getPixelInterpolated`, `resize`, `scale`, `rotate` and `translate`, with
/// the same arithmetic, so 8- and 16-bit and RGB results match ImageJ
/// exactly and 32-bit results to the last bit. RGB images are processed
/// per channel where ImageJ does (`filterRGB`).
///
/// Where ImageJ would read past the end of its pixel array (bilinear
/// interpolation on images one pixel wide, which throws there), the missing
/// neighbors read as 0 instead.
public struct GeometryProcessor: Sendable, Equatable {
    public internal(set) var plane: Plane
    public let width: Int
    public let height: Int
    /// The rectangle operations work on (ImageJ's processor ROI).
    public private(set) var roi: RoiBounds
    public var interpolation: InterpolationMethod
    /// The LUT is inverted (`isInvertedLut`): 8-bit scaling and rotation then
    /// fill with 0 instead of the default white, unless a background was set.
    public var invertedLUT: Bool
    /// Signed 16-bit data (stored +32768): rotation shifts its background.
    public var signed16: Bool
    /// `getMin`/`getMax` as set; `nil` means the pixel range (ImageJ's
    /// `findMinAndMax`), or 0–255 for 8-bit and RGB.
    var minMax: (min: Double, max: Double)?
    /// The background value as the processor type stores it.
    var background: Double
    /// `ByteProcessor.bgColorSet`.
    var backgroundSet = false

    /// A processor for `plane`, with no selection, no interpolation and the
    /// type's default background (white for 8-bit and RGB, 0 otherwise).
    /// `displayRange` is what `setMinAndMax` was given (none for RGB).
    public init(_ plane: Plane, width: Int, displayRange: ClosedRange<Double>? = nil) {
        precondition(width > 0 && plane.count % width == 0, "plane of \(plane.count) pixels can't be \(width) pixels wide")
        self.plane = plane
        self.width = width
        self.height = plane.count / width
        self.roi = RoiBounds(x: 0, y: 0, width: width, height: plane.count / width)
        self.interpolation = .none
        self.invertedLUT = false
        self.signed16 = false
        self.background = Self.defaultBackground(plane.pixelType)
        if let displayRange { setMinAndMax(displayRange.lowerBound, displayRange.upperBound) }
    }

    static func defaultBackground(_ type: PixelType) -> Double {
        switch type {
        case .gray8: 255
        case .gray16, .gray32Float: 0
        case .rgb8: -1  // 0xffffffff
        }
    }

    public static func == (a: GeometryProcessor, b: GeometryProcessor) -> Bool {
        a.plane == b.plane && a.width == b.width && a.roi == b.roi && a.interpolation == b.interpolation
            && a.invertedLUT == b.invertedLUT && a.signed16 == b.signed16 && a.minMax?.min == b.minMax?.min
            && a.minMax?.max == b.minMax?.max && a.background == b.background && a.backgroundSet == b.backgroundSet
    }

    public var pixelType: PixelType { plane.pixelType }

    // MARK: Selection

    /// `setRoi(Rectangle)`: the rectangle clipped to the image; `nil` (or a
    /// rectangle outside the image) selects everything.
    public mutating func setRoi(_ rect: RoiBounds?) {
        guard let rect, rect.width > 0, rect.height > 0 else {
            roi = RoiBounds(x: 0, y: 0, width: width, height: height)
            return
        }
        let x1 = max(rect.x, 0), y1 = max(rect.y, 0)
        let x2 = min(rect.x + rect.width, width), y2 = min(rect.y + rect.height, height)
        guard x2 > x1, y2 > y1 else {
            roi = RoiBounds(x: 0, y: 0, width: width, height: height)
            return
        }
        roi = RoiBounds(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    // MARK: Display range and background

    /// `getMin()`.
    public var displayMin: Double { currentMinMax.min }
    /// `getMax()`.
    public var displayMax: Double { currentMinMax.max }

    var currentMinMax: (min: Double, max: Double) {
        if let minMax { return minMax }
        switch plane {
        case .gray8, .rgb8: return (0, 255)
        case .gray16(let p):
            let r = ImageJRules.pixelRange(p)
            return (Double(r.min), Double(r.max))
        case .gray32Float(let p): return ImageJRules.pixelRange(p)
        }
    }

    /// The display range as set, or `nil` when it follows the pixels.
    public var displayRange: ClosedRange<Double>? {
        guard let minMax else { return nil }
        return ImageJRules.closed(minMax.min, minMax.max)
    }

    /// `setMinAndMax`: 8- and 16-bit round to integers, 32-bit to `float`;
    /// `0, 0` resets 16- and 32-bit images to their pixel range. RGB
    /// processors keep no range here.
    public mutating func setMinAndMax(_ min: Double, _ max: Double) {
        switch plane {
        case .gray8:
            guard max >= min else { return }
            minMax = (Double(ImageJRules.roundToInt(min)), Double(ImageJRules.roundToInt(max)))
        case .gray16:
            minMax = min == 0 && max == 0 ? nil : (Double(ImageJRules.roundToInt(min)), Double(ImageJRules.roundToInt(max)))
        case .gray32Float:
            minMax = min == 0 && max == 0 ? nil : (Double(Float(min)), Double(Float(max)))
        case .rgb8:
            break
        }
    }

    /// `resetMinAndMax`.
    public mutating func resetMinAndMax() { minMax = nil }

    /// `getBackgroundValue()`: an index for 8-bit, a value for 16- and
    /// 32-bit, a packed `0xAARRGGBB` (as a signed `int`) for RGB.
    public var backgroundValue: Double { background }

    /// `setBackgroundValue`: clamped to 0–255 or 0–65535 and truncated for
    /// 8- and 16-bit, rounded to `float` for 32-bit, a packed color for RGB.
    public mutating func setBackgroundValue(_ value: Double) {
        switch plane {
        case .gray8:
            background = Double(Swift.min(Swift.max(ImageJRules.int(value), 0), 255))
            backgroundSet = true
        case .gray16: background = Double(Swift.min(Swift.max(ImageJRules.int(value), 0), 65535))
        case .gray32Float: background = Double(Float(value))
        case .rgb8: background = Double(JavaNumerics.int32(value))
        }
    }

    /// `setBackgroundColor(color)` for an `0xRRGGBB` color, with `lut` the
    /// image's LUT: the closest LUT entry for 8-bit, that entry mapped
    /// through the display range for 16- and 32-bit, the color for RGB.
    public mutating func setBackgroundColor(_ rgb: UInt32, lut: LUT) {
        let best = Double(GeometryProcessor.bestIndex(rgb, lut))
        switch plane {
        case .gray8: setBackgroundValue(best)
        case .gray16:
            let (lo, hi) = currentMinMax
            setBackgroundValue(Double(ImageJRules.int(lo + (hi - lo) * (best / 255.0))))
        case .gray32Float:
            let (lo, hi) = currentMinMax
            setBackgroundValue(lo + (hi - lo) * (best / 255.0))
        case .rgb8: setBackgroundValue(Double(Int32(bitPattern: 0xFF00_0000 | (rgb & 0xFF_FFFF))))
        }
    }

    /// `ImageProcessor.getBestIndex(Color)`: the LUT entry closest to the color.
    public static func bestIndex(_ color: UInt32, _ lut: LUT) -> Int {
        let r = Int((color >> 16) & 0xFF), g = Int((color >> 8) & 0xFF), b = Int(color & 0xFF)
        var minDistance = Double.greatestFiniteMagnitude
        var minIndex = 0
        for i in 0..<256 {
            let rd = Double(r - Int(lut.reds[i])), gd = Double(g - Int(lut.greens[i])), bd = Double(b - Int(lut.blues[i]))
            let distance = rd * rd + gd * gd + bd * bd
            if distance < minDistance {
                minDistance = distance
                minIndex = i
            }
            if distance == 0 { break }
        }
        return minIndex
    }

    // MARK: Pixel access

    /// `getPixel(x, y)`: the raw value (float bits for 32-bit, the packed
    /// color for RGB), 0 outside the image.
    public func pixel(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return raw(y * width + x)
    }

    /// `get(index)`: the raw value as `int`.
    func raw(_ i: Int) -> Int {
        switch plane {
        case .gray8(let p): return Int(p[i])
        case .gray16(let p): return Int(p[i])
        case .gray32Float(let p): return Int(Int32(bitPattern: p[i].bitPattern))
        case .rgb8(let p): return Int(Int32(bitPattern: p[i]))
        }
    }

    /// `getPixelValue(x, y)`: the value (RGB: the mean of R, G and B), NaN outside.
    public func pixelValue(_ x: Int, _ y: Int) -> Float {
        guard x >= 0, x < width, y >= 0, y < height else { return .nan }
        let i = y * width + x
        switch plane {
        case .gray8(let p): return Float(p[i])
        case .gray16(let p): return Float(p[i])
        case .gray32Float(let p): return p[i]
        case .rgb8(let p):
            let c = p[i]
            let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
            let w = 1.0 / 3.0
            return Float(r * w + g * w + b * w)
        }
    }

    /// The value `getBicubicInterpolatedPixel` reads: `getf` for 32-bit, `get` otherwise.
    @inline(__always)
    func sample(_ u: Int, _ v: Int) -> Double {
        let i = v * width + u
        switch plane {
        case .gray8(let p): return Double(Kernels.at(p, i))
        case .gray16(let p): return Double(Kernels.at(p, i))
        case .gray32Float(let p): return Double(Kernels.at(p, i))
        case .rgb8(let p): return Double(Int32(bitPattern: Kernels.at(p, i)))
        }
    }

    // MARK: Interpolation

    /// `getInterpolatedPixel(x, y)` with the current method: bicubic, or
    /// bilinear with the coordinates clamped to the image. RGB processors
    /// return the nearest pixel's value.
    public func interpolatedPixel(x: Double, y: Double) -> Double {
        if case .rgb8 = plane {
            var ix = ImageJRules.int(x + 0.5), iy = ImageJRules.int(y + 0.5)
            if ix < 0 { ix = 0 }
            if ix >= width { ix = width - 1 }
            if iy < 0 { iy = 0 }
            if iy >= height { iy = height - 1 }
            return Double(pixelValue(ix, iy))
        }
        if interpolation == .bicubic { return bicubicInterpolatedPixel(x: x, y: y, source: self) }
        var x = x, y = y
        if x < 0.0 { x = 0.0 }
        if x >= Double(width) - 1.0 { x = Double(width) - 1.001 }
        if y < 0.0 { y = 0.0 }
        if y >= Double(height) - 1.0 { y = Double(height) - 1.001 }
        return bilinear(x, y)
    }

    /// The bilinear kernel of each processor type, without clamping.
    func bilinear(_ x: Double, _ y: Double) -> Double {
        switch plane {
        case .gray8(let p): Kernels.bilinear(x, y, p, width)
        case .gray16(let p): Kernels.bilinear(x, y, p, width)
        case .gray32Float(let p): Kernels.bilinear(x, y, p, width)
        case .rgb8(let p): Double(Int32(bitPattern: Kernels.bilinearRGB(x, y, p, width)))
        }
    }

    /// `getBicubicInterpolatedPixel(x0, y0, ip2)`: Catmull-Rom over the 4×4
    /// neighbors read from `source`, falling back to `source`'s bilinear value
    /// (or its background, beyond a pixel outside) near the edges.
    public func bicubicInterpolatedPixel(x x0: Double, y y0: Double, source: GeometryProcessor) -> Double {
        let u0 = ImageJRules.int(x0.rounded(.down))
        let v0 = ImageJRules.int(y0.rounded(.down))
        if u0 <= 0 || u0 >= width - 2 || v0 <= 0 || v0 >= height - 2 {
            return source.bilinearInterpolatedPixel(x: x0, y: y0)
        }
        var q = 0.0
        for j in 0...3 {
            let v = v0 - 1 + j
            var p = 0.0
            for i in 0...3 {
                let u = u0 - 1 + i
                p = p + source.sample(u, v) * Kernels.cubic(x0 - Double(u))
            }
            q = q + p * Kernels.cubic(y0 - Double(v))
        }
        return q
    }

    /// `getBilinearInterpolatedPixel`: bilinear within a pixel of the image,
    /// the background beyond.
    func bilinearInterpolatedPixel(x: Double, y: Double) -> Double {
        if x >= -1 && x < Double(width) && y >= -1 && y < Double(height) {
            var bilinear = self
            bilinear.interpolation = .bilinear
            return bilinear.interpolatedPixel(x: x, y: y)
        }
        return backgroundValue
    }

    /// `getPixelInterpolated(x, y)`: the interpolated raw value (float bits
    /// for 32-bit, a packed color for RGB), 0 where bilinear interpolation
    /// has no neighbors.
    public func pixelInterpolated(x: Double, y: Double) -> Int {
        switch plane {
        case .gray8, .gray16:
            let maxValue = pixelType == .gray8 ? 255 : 65535
            switch interpolation {
            case .bilinear:
                if x < 0.0 || y < 0.0 || x >= Double(width - 1) || y >= Double(height - 1) { return 0 }
                return ImageJRules.roundToInt(bilinear(x, y))
            case .bicubic:
                var value = ImageJRules.int(bicubicInterpolatedPixel(x: x, y: y, source: self) + 0.5)
                if value < 0 { value = 0 }
                if value > maxValue { value = maxValue }
                return value
            case .none:
                return pixel(ImageJRules.int(x + 0.5), ImageJRules.int(y + 0.5))
            }
        case .gray32Float:
            switch interpolation {
            case .bilinear:
                if x < 0.0 || y < 0.0 || x >= Double(width - 1) || y >= Double(height - 1) { return 0 }
                return Kernels.floatBits(bilinear(x, y))
            case .bicubic:
                return Kernels.floatBits(bicubicInterpolatedPixel(x: x, y: y, source: self))
            case .none:
                return pixel(ImageJRules.int(x + 0.5), ImageJRules.int(y + 0.5))
            }
        case .rgb8(let p):
            if x < 0.0 || y < 0.0 || x >= Double(width - 1) || y >= Double(height - 1) { return 0 }
            return Int(Int32(bitPattern: Kernels.bilinearRGB(x, y, p, width)))
        }
    }

    /// `getInterpolatedValue(x, y)`: bilinear interpolation of
    /// `getPixelValue`, with edge pixels repeated half a pixel out and 0 beyond.
    public func interpolatedValue(x: Double, y: Double) -> Double {
        let w = Double(width), h = Double(height)
        let edge = x < 0.0 || x >= w - 1.0 || y < 0.0 || y >= h - 1.0
        if edge, x < -1.0 || x >= w || y < -1.0 || y >= h { return 0.0 }
        let xbase = ImageJRules.int(x), ybase = ImageJRules.int(y)
        var xFraction = x - Double(xbase), yFraction = y - Double(ybase)
        if xFraction < 0.0 { xFraction = 0.0 }
        if yFraction < 0.0 { yFraction = 0.0 }
        func value(_ x: Int, _ y: Int) -> Double {
            guard edge else { return Double(pixelValue(x, y)) }
            return Double(pixelValue(Swift.min(Swift.max(x, 0), width - 1), Swift.min(Swift.max(y, 0), height - 1)))
        }
        let lowerLeft = value(xbase, ybase), lowerRight = value(xbase + 1, ybase)
        let upperRight = value(xbase + 1, ybase + 1), upperLeft = value(xbase, ybase + 1)
        let upperAverage = upperLeft + xFraction * (upperRight - upperLeft)
        let lowerAverage = lowerLeft + xFraction * (lowerRight - lowerLeft)
        return lowerAverage + yFraction * (upperAverage - lowerAverage)
    }

    /// `ColorProcessor.getInterpolatedRGBPixel(x, y)`: bilinear per channel,
    /// coordinates clamped to the image; the pixel itself for images one
    /// pixel wide or high. Non-RGB processors return 0.
    public func interpolatedRGBPixel(x: Double, y: Double) -> UInt32 {
        guard case .rgb8(let p) = plane else { return 0 }
        if width == 1 || height == 1 { return UInt32(bitPattern: Int32(truncatingIfNeeded: pixel(ImageJRules.int(x), ImageJRules.int(y)))) }
        var x = x, y = y
        if x < 0.0 { x = 0.0 }
        if x >= Double(width) - 1.0 { x = Double(width) - 1.001 }
        if y < 0.0 { y = 0.0 }
        if y >= Double(height) - 1.0 { y = Double(height) - 1.001 }
        return Kernels.bilinearRGB(x, y, p, width)
    }
}

/// The per-type interpolation kernels of ImageJ's processors.
enum Kernels {
    /// `p[i]`, or 0 where Java would throw `ArrayIndexOutOfBoundsException`.
    @inline(__always)
    static func at<T: Numeric>(_ p: [T], _ i: Int) -> T {
        i >= 0 && i < p.count ? p[i] : 0
    }

    /// `ByteProcessor`'s and `ShortProcessor`'s private `getInterpolatedPixel(x, y, pixels)`.
    @inline(__always)
    static func bilinear<T: FixedWidthInteger>(_ x: Double, _ y: Double, _ p: [T], _ width: Int) -> Double {
        let xbase = ImageJRules.int(x), ybase = ImageJRules.int(y)
        let xFraction = x - Double(xbase), yFraction = y - Double(ybase)
        let offset = ybase * width + xbase
        let lowerLeft = Int(at(p, offset)), lowerRight = Int(at(p, offset + 1))
        let upperRight = Int(at(p, offset + width + 1)), upperLeft = Int(at(p, offset + width))
        let upperAverage = Double(upperLeft) + xFraction * Double(upperRight - upperLeft)
        let lowerAverage = Double(lowerLeft) + xFraction * Double(lowerRight - lowerLeft)
        return lowerAverage + yFraction * (upperAverage - lowerAverage)
    }

    /// `FloatProcessor.getInterpolatedPixel(x, y, pixels)`: a NaN neighbor is
    /// skipped when the other one is nearer.
    @inline(__always)
    static func bilinear(_ x: Double, _ y: Double, _ p: [Float], _ width: Int) -> Double {
        let xbase = ImageJRules.int(x), ybase = ImageJRules.int(y)
        let xFraction = x - Double(xbase), yFraction = y - Double(ybase)
        let offset = ybase * width + xbase
        let lowerLeft = Double(at(p, offset)), lowerRight = Double(at(p, offset + 1))
        let upperRight = Double(at(p, offset + width + 1)), upperLeft = Double(at(p, offset + width))
        let upperAverage: Double
        if upperLeft.isNaN && xFraction >= 0.5 {
            upperAverage = upperRight
        } else if upperRight.isNaN && xFraction < 0.5 {
            upperAverage = upperLeft
        } else {
            upperAverage = upperLeft + xFraction * (upperRight - upperLeft)
        }
        let lowerAverage: Double
        if lowerLeft.isNaN && xFraction >= 0.5 {
            lowerAverage = lowerRight
        } else if lowerRight.isNaN && xFraction < 0.5 {
            lowerAverage = lowerLeft
        } else {
            lowerAverage = lowerLeft + xFraction * (lowerRight - lowerLeft)
        }
        if lowerAverage.isNaN && yFraction >= 0.5 { return upperAverage }
        if upperAverage.isNaN && yFraction < 0.5 { return lowerAverage }
        return lowerAverage + yFraction * (upperAverage - lowerAverage)
    }

    /// `ColorProcessor.getInterpolatedPixel(x, y, pixels)`: each channel
    /// interpolated and rounded.
    @inline(__always)
    static func bilinearRGB(_ x: Double, _ y: Double, _ p: [UInt32], _ width: Int) -> UInt32 {
        let xbase = ImageJRules.int(x), ybase = ImageJRules.int(y)
        let xFraction = x - Double(xbase), yFraction = y - Double(ybase)
        let offset = ybase * width + xbase
        let lowerLeft = at(p, offset), lowerRight = at(p, offset + 1)
        let upperRight = at(p, offset + width + 1), upperLeft = at(p, offset + width)
        func channel(_ shift: UInt32) -> UInt32 {
            let ll = Int((lowerLeft >> shift) & 0xFF), lr = Int((lowerRight >> shift) & 0xFF)
            let ur = Int((upperRight >> shift) & 0xFF), ul = Int((upperLeft >> shift) & 0xFF)
            let upperAverage = Double(ul) + xFraction * Double(ur - ul)
            let lowerAverage = Double(ll) + xFraction * Double(lr - ll)
            let v = ImageJRules.int(lowerAverage + yFraction * (upperAverage - lowerAverage) + 0.5)
            return UInt32(truncatingIfNeeded: v) & 0xFF
        }
        return 0xFF00_0000 | channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// `ImageProcessor.cubic(x)`: the Catmull-Rom kernel (a = 0.5).
    @inline(__always)
    static func cubic(_ x: Double) -> Double {
        let a = 0.5
        var x = x
        if x < 0.0 { x = -x }
        var z = 0.0
        if x < 1.0 {
            z = x * x * (x * (-a + 2.0) + (a - 3.0)) + 1.0
        } else if x < 2.0 {
            z = -a * x * x * x + 5.0 * a * x * x - 8.0 * a * x + 4.0 * a
        }
        return z
    }

    /// `Float.floatToIntBits((float)v)`.
    @inline(__always)
    static func floatBits(_ v: Double) -> Int {
        let f = Float(v)
        return Int(Int32(bitPattern: f.isNaN ? 0x7FC0_0000 : f.bitPattern))
    }
}

/// Java's `Math` functions the geometry ports need.
enum GeometryMath {
    @inline(__always) static func sine(_ x: Double) -> Double { sin(x) }
    @inline(__always) static func cosine(_ x: Double) -> Double { cos(x) }
    @inline(__always) static func arcTangent(_ y: Double, _ x: Double) -> Double { atan2(y, x) }
}
