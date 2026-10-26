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

/// Image ▸ Type ▸ RGB Stack, HSB Stack, HSB (32-bit) and Lab Stack, and
/// RGB Color from them: a port of ImageJ's `ij.process.ImageConverter`,
/// `StackConverter`, `ij.process.ColorSpaceConverter`, `CompositeConverter`
/// and the HSB methods of `ColorProcessor` (with `java.awt.Color`'s).
public enum ColorSpaceConverter {
    /// A three-plane stack ImageJ recognizes as a color space by its first
    /// slice label (`ImageStack.isRGB`, `isHSB`, `isHSB32`, `isLab`), which
    /// RGB Color recombines into one RGB image.
    public enum Space: Sendable, Equatable {
        case rgb, hsb, hsb32, lab
    }

    /// The color space of `image`'s stack, if it is one: three planes, 8-bit
    /// with the first labeled "Red" (or "Hue"), 32-bit labeled "Hue", or
    /// labeled "L*".
    public static func space(of image: Hyperstack) -> Space? {
        guard image.stack.count == 3, let label = image.stack.labels[0] else { return nil }
        let type = image.pixelType
        if type == .gray8 && label == "Red" { return .rgb }
        if type == .gray8 && label == "Hue" { return .hsb }
        if type == .gray32Float && label == "Hue" { return .hsb32 }
        if label == "L*" { return .lab }
        return nil
    }

    // MARK: From RGB

    static func components(_ plane: Plane) -> [UInt32] {
        guard case .rgb8(let p) = plane else { preconditionFailure("RGB plane required") }
        return p
    }

    /// `ColorProcessor.getRGB`: the red, green and blue planes.
    public static func rgbPlanes(_ plane: Plane) -> [Plane] {
        let p = components(plane)
        return [16, 8, 0].map { shift in .gray8(p.map { UInt8(truncatingIfNeeded: $0 >> UInt32(shift)) }) }
    }

    /// `java.awt.Color.RGBtoHSB`, in `float` as Java computes it.
    static func hsb(_ c: UInt32) -> (Float, Float, Float) {
        let r = Int((c >> 16) & 0xFF), g = Int((c >> 8) & 0xFF), b = Int(c & 0xFF)
        let cmax = max(r, g, b), cmin = min(r, g, b)
        let brightness = Float(cmax) / 255
        let saturation: Float = cmax != 0 ? Float(cmax - cmin) / Float(cmax) : 0
        var hue: Float = 0
        if saturation != 0 {
            let range = Float(cmax - cmin)
            let redc = Float(cmax - r) / range, greenc = Float(cmax - g) / range, bluec = Float(cmax - b) / range
            if r == cmax {
                hue = bluec - greenc
            } else if g == cmax {
                hue = 2 + redc - bluec
            } else {
                hue = 4 + greenc - redc
            }
            hue = hue / 6
            if hue < 0 { hue = hue + 1 }
        }
        return (hue, saturation, brightness)
    }

    /// `ColorProcessor.getHSB(byte[]...)`: each component times 255, truncated.
    public static func hsbPlanes(_ plane: Plane) -> [Plane] {
        let p = components(plane)
        var h = [UInt8](repeating: 0, count: p.count), s = h, v = h
        func byte(_ x: Float) -> UInt8 { UInt8(truncatingIfNeeded: Int32(Double(x) * 255.0)) }
        for i in p.indices {
            let (a, b, c) = hsb(p[i])
            (h[i], s[i], v[i]) = (byte(a), byte(b), byte(c))
        }
        return [.gray8(h), .gray8(s), .gray8(v)]
    }

    /// `ColorProcessor.getHSB(float[]...)`.
    public static func hsb32Planes(_ plane: Plane) -> [Plane] {
        let p = components(plane)
        var h = [Float](repeating: 0, count: p.count), s = h, v = h
        for i in p.indices { (h[i], s[i], v[i]) = hsb(p[i]) }
        return [.gray32Float(h), .gray32Float(s), .gray32Float(v)]
    }

    /// `ColorSpaceConverter.RGBToLab`: L*, a* and b* (D65 white), as `float`.
    public static func labPlanes(_ plane: Plane) -> [Plane] {
        let p = components(plane)
        var l = [Float](repeating: 0, count: p.count), a = l, b = l
        for i in p.indices {
            let (x, y, z) = lab(p[i])
            (l[i], a[i], b[i]) = (Float(x), Float(y), Float(z))
        }
        return [.gray32Float(l), .gray32Float(a), .gray32Float(b)]
    }

    static let white = (95.0429, 100.0, 108.8900)

    /// `RGBtoLAB(int)`: `RGBtoXYZ` (sRGB) then `XYZtoLAB`.
    static func lab(_ c: UInt32) -> (Double, Double, Double) {
        func linear(_ v: Int) -> Double {
            let x = Double(v) / 255.0
            return (x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)) * 100.0
        }
        let r = linear(Int((c >> 16) & 0xFF)), g = linear(Int((c >> 8) & 0xFF)), b = linear(Int(c & 0xFF))
        let X = r * 0.4124 + g * 0.3576 + b * 0.1805
        let Y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let Z = r * 0.0193 + g * 0.1192 + b * 0.9505
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
        let x = f(X / white.0), y = f(Y / white.1), z = f(Z / white.2)
        return (116.0 * y - 16.0, 500.0 * (x - y), 200.0 * (y - z))
    }

    // MARK: To RGB

    /// `ColorProcessor.setRGB`: an RGB plane from 8-bit red, green and blue
    /// (blue all 0 when there are only two planes).
    public static func rgb(red: Plane, green: Plane, blue: Plane?) -> Plane {
        guard case .gray8(let r) = red, case .gray8(let g) = green else { preconditionFailure("8-bit planes required") }
        var b = [UInt8](repeating: 0, count: r.count)
        if let blue, case .gray8(let p) = blue { b = p }
        return .rgb8((0..<r.count).map { 0xFF00_0000 | UInt32(r[$0]) << 16 | UInt32(g[$0]) << 8 | UInt32(b[$0]) })
    }

    /// `java.awt.Color.HSBtoRGB`, in `float` as Java computes it.
    static func rgb(hue: Float, saturation: Float, brightness: Float) -> UInt32 {
        func int(_ x: Float) -> Int32 { Int32(truncatingIfNeeded: Int(JavaNumerics.int32(x * 255 + 0.5))) }
        var r: Int32 = 0, g: Int32 = 0, b: Int32 = 0
        if saturation == 0 {
            r = int(brightness)
            g = r
            b = r
        } else {
            let h = (hue - Float(Double(hue).rounded(.down))) * 6
            let f = h - Float(Double(h).rounded(.down))
            let p = brightness * (1 - saturation)
            let q = brightness * (1 - saturation * f)
            let t = brightness * (1 - (saturation * (1 - f)))
            switch JavaNumerics.int32(h) {
            case 0: (r, g, b) = (int(brightness), int(t), int(p))
            case 1: (r, g, b) = (int(q), int(brightness), int(p))
            case 2: (r, g, b) = (int(p), int(brightness), int(t))
            case 3: (r, g, b) = (int(p), int(q), int(brightness))
            case 4: (r, g, b) = (int(t), int(p), int(brightness))
            case 5: (r, g, b) = (int(brightness), int(p), int(q))
            default: break
            }
        }
        return UInt32(bitPattern: Int32(bitPattern: 0xFF00_0000) | (r << 16) | (g << 8) | b)
    }

    /// `ColorProcessor.setHSB(byte[]...)`: each component over 255, as `float`.
    public static func rgb(hsb planes: [Plane]) -> Plane {
        guard case .gray8(let h) = planes[0], case .gray8(let s) = planes[1], case .gray8(let v) = planes[2] else {
            preconditionFailure("8-bit planes required")
        }
        return .rgb8(
            (0..<h.count).map {
                rgb(hue: Float(Double(h[$0]) / 255.0), saturation: Float(Double(s[$0]) / 255.0), brightness: Float(Double(v[$0]) / 255.0))
            })
    }

    /// `ColorProcessor.setHSB(float[]...)`.
    public static func rgb(hsb32 planes: [Plane]) -> Plane {
        guard case .gray32Float(let h) = planes[0], case .gray32Float(let s) = planes[1], case .gray32Float(let v) = planes[2]
        else { preconditionFailure("32-bit planes required") }
        return .rgb8((0..<h.count).map { rgb(hue: h[$0], saturation: s[$0], brightness: v[$0]) })
    }

    /// `ColorSpaceConverter.LabToRGB`: `LABtoXYZ` then `XYZtoRGB` (sRGB),
    /// each component rounded and packed without clamping above 255, as
    /// `ColorProcessor.putPixel(x, y, int[])` packs it.
    public static func rgb(lab planes: [Plane]) -> Plane {
        guard case .gray32Float(let l) = planes[0], case .gray32Float(let a) = planes[1], case .gray32Float(let b) = planes[2]
        else { preconditionFailure("32-bit planes required") }
        return .rgb8(
            (0..<l.count).map { i in
                let (r, g, bl) = rgb(L: Double(l[i]), a: Double(a[i]), b: Double(b[i]))
                let packed = Int32(truncatingIfNeeded: (r << 16) &+ (g << 8) &+ bl)
                return UInt32(bitPattern: packed) | 0xFF00_0000
            })
    }

    static func rgb(L: Double, a: Double, b: Double) -> (Int, Int, Int) {
        var y = (L + 16.0) / 116.0
        let y3 = pow(y, 3.0)
        var x = a / 500.0 + y
        let x3 = pow(x, 3.0)
        var z = y - b / 200.0
        let z3 = pow(z, 3.0)
        y = y3 > 0.008856 ? y3 : (y - 16.0 / 116.0) / 7.787
        x = x3 > 0.008856 ? x3 : (x - 16.0 / 116.0) / 7.787
        z = z3 > 0.008856 ? z3 : (z - 16.0 / 116.0) / 7.787
        let X = x * white.0 / 100.0, Y = y * white.1 / 100.0, Z = z * white.2 / 100.0
        var r = X * 3.2406 + Y * -1.5372 + Z * -0.4986
        var g = X * -0.9689 + Y * 1.8758 + Z * 0.0415
        var bl = X * 0.0557 + Y * -0.2040 + Z * 1.0570
        func gamma(_ v: Double) -> Double { v > 0.0031308 ? 1.055 * pow(v, 1.0 / 2.4) - 0.055 : v * 12.92 }
        r = max(gamma(r), 0)
        g = max(gamma(g), 0)
        bl = max(gamma(bl), 0)
        func round(_ v: Double) -> Int { Int(Int32(truncatingIfNeeded: ImageJRules.round(v * 255))) }
        return (round(r), round(g), round(bl))
    }

    // MARK: Images

    /// Three planes in place of an RGB image's one, as ImageJ's single image
    /// becomes a three-channel stack that isn't a composite: each channel is
    /// shown through a gray LUT with the same display range. The labels
    /// name the components; the calibration, selection, Info and
    /// properties stay.
    static func threeChannels(_ image: Hyperstack, _ planes: [Plane], labels: [String], range: ClosedRange<Double>) -> Hyperstack {
        let type = planes[0].pixelType
        return ImageJRules.image(
            like: image, planes: planes, labels: labels, dimensions: HyperstackDimensions(channels: 3),
            channels: Array(repeating: ChannelDisplay(lut: .grays, displayRange: range), count: 3),
            calibration: ImageJRules.calibration(image.calibration, from: .rgb8, to: type), compositeMode: .color)
    }

    /// RGB Stack for a single RGB image (`ImageConverter.convertToRGBStack`).
    public static func rgbStack(_ image: Hyperstack) -> Hyperstack {
        threeChannels(image, rgbPlanes(image.stack[0]), labels: ["Red", "Green", "Blue"], range: 0...255)
    }

    /// HSB Stack for a single RGB image (`ImageConverter.convertToHSB`).
    public static func hsbStack(_ image: Hyperstack) -> Hyperstack {
        threeChannels(image, hsbPlanes(image.stack[0]), labels: ["Hue", "Saturation", "Brightness"], range: 0...255)
    }

    /// HSB (32-bit) for a single RGB image (`ImageConverter.convertToHSB32`):
    /// the hue's range is shown.
    public static func hsb32Stack(_ image: Hyperstack) -> Hyperstack {
        let planes = hsb32Planes(image.stack[0])
        return threeChannels(image, planes, labels: ["Hue", "Saturation", "Brightness"], range: ImageJRules.resetRange(planes[0]))
    }

    /// Lab Stack for a single RGB image (`ImageConverter.convertToLab`): a
    /// new composite shown in grayscale, each channel with its own range,
    /// that takes over the image's title, calibration and Info.
    public static func labStack(_ image: Hyperstack) -> Hyperstack {
        let planes = labPlanes(image.stack[0])
        let channels = planes.enumerated().map { c, plane in
            ChannelDisplay(lut: Hyperstack.defaultChannelLUT(c), displayRange: ImageJRules.resetRange(plane))
        }
        let stack = ImageJRules.stack(planes, width: image.width, height: image.height, labels: ["L*", "a*", "b*"])
        do {
            return try Hyperstack(
                title: image.title, stack: stack, dimensions: HyperstackDimensions(channels: 3),
                calibration: ImageJRules.calibration(image.calibration, from: .rgb8, to: .gray32Float), channels: channels,
                compositeMode: .grayscale, info: image.info)
        } catch {
            preconditionFailure("Lab Stack built an invalid image: \(error)")
        }
    }

    /// HSB Stack or HSB (32-bit) for an RGB stack
    /// (`StackConverter.convertToHSBHyperstack`): three channels per plane,
    /// every plane a slice, in a new composite shown in grayscale. Each
    /// component keeps its plane's label; the 8-bit version is marked with
    /// the `HSB_Stack` property.
    public static func hsbHyperstack(_ image: Hyperstack, float: Bool) -> Hyperstack {
        var planes: [Plane] = []
        var labels: [String?] = []
        for i in 0..<image.stack.count {
            planes += float ? hsb32Planes(image.stack[i]) : hsbPlanes(image.stack[i])
            labels += Array(repeating: image.stack.labels[i], count: 3)
        }
        let range = float ? ImageJRules.resetRange(planes[0]) : 0...255
        let channels = (0..<3).map { ChannelDisplay(lut: Hyperstack.defaultChannelLUT($0), displayRange: range) }
        var out = ImageJRules.image(
            like: image, planes: planes, labels: labels,
            dimensions: HyperstackDimensions(channels: 3, slices: image.stack.count), channels: channels,
            calibration: ImageJRules.calibration(image.calibration, from: .rgb8, to: float ? .gray32Float : .gray8),
            compositeMode: .grayscale)
        out.encodedROI = nil
        out.encodedOverlay = []
        if !float { out.properties["HSB_Stack"] = "true" }
        return out
    }

    /// RGB Stack for a composite of channels only
    /// (`Converter.convertCompositeToRGBStack`): each channel drawn in RGB
    /// through its LUT and display range, as a stack in the image's place.
    public static func channelsAsRGB(_ image: Hyperstack) -> Hyperstack {
        let n = image.stack.count
        let planes = (0..<n).map { c in
            TypeConverter.toRGB(image.stack[c], lut: image.channels[c].lut, displayRange: image.channels[c].displayRange)
        }
        return ImageJRules.image(
            like: image, planes: planes, labels: nil, dimensions: HyperstackDimensions(slices: n),
            channels: [ChannelDisplay(lut: .grays, displayRange: 0...255)],
            calibration: ImageJRules.calibration(image.calibration, from: image.pixelType, to: .rgb8), compositeMode: .color)
    }

    /// Make Composite, or RGB Stack, for an RGB stack
    /// (`CompositeConverter.convertRGBToComposite`): red, green and blue
    /// channels for each slice and frame, in a new composite without the
    /// stack's calibration or labels.
    public static func rgbComposite(_ image: Hyperstack, mode: CompositeMode = .composite) -> Hyperstack {
        var planes: [Plane] = []
        for i in 0..<image.stack.count { planes += rgbPlanes(image.stack[i]) }
        let d = image.dimensions
        let channels = (0..<3).map { ChannelDisplay(lut: Hyperstack.defaultChannelLUT($0), displayRange: 0...255) }
        let stack = ImageJRules.stack(planes, width: image.width, height: image.height, labels: nil)
        do {
            return try Hyperstack(
                title: image.title, stack: stack, dimensions: HyperstackDimensions(channels: 3, slices: d.slices, frames: d.frames),
                channels: channels, compositeMode: mode)
        } catch {
            preconditionFailure("Make Composite built an invalid image: \(error)")
        }
    }

    /// RGB Color for a color-space stack (`ImageConverter.convertRGBStackToRGB`,
    /// `convertHSBToRGB`, `convertHSB32ToRGB`, `convertLabToRGB`): one RGB
    /// image in its place. Red, green and blue planes shown through an
    /// inverted LUT are inverted.
    public static func toRGB(_ image: Hyperstack, from space: Space) -> Hyperstack {
        let planes = (0..<3).map { image.stack[$0] }
        var plane: Plane
        switch space {
        case .rgb:
            plane = rgb(red: planes[0], green: planes[1], blue: planes[2])
            if ImageJRules.isInvertedLUT(image.channels[0].lut) { plane = plane.invertedBytes() }
        case .hsb: plane = rgb(hsb: planes)
        case .hsb32: plane = rgb(hsb32: planes)
        case .lab: plane = rgb(lab: planes)
        }
        var out = ImageJRules.image(
            like: image, planes: [plane], labels: nil, dimensions: HyperstackDimensions(),
            channels: [ChannelDisplay(lut: .grays, displayRange: 0...255)],
            calibration: ImageJRules.calibration(image.calibration, from: image.pixelType, to: .rgb8), compositeMode: .color)
        if space == .lab {
            // ImagePlus.setImage(LabToRGB's new image): no Info, properties or overlay.
            out.info = nil
            out.properties = [:]
            out.encodedOverlay = []
        }
        return out
    }
}
