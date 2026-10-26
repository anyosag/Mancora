/// A 256-entry color lookup table, as ImageJ uses for every non-RGB image.
public struct LUT: Sendable, Hashable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case wrongLength(Int)
        case invalidColorCount(Int)
    }

    public let reds: [UInt8]
    public let greens: [UInt8]
    public let blues: [UInt8]
    /// A display name, e.g. `"Fire"` or a file name without its extension.
    public var name: String

    public init(name: String, reds: [UInt8], greens: [UInt8], blues: [UInt8]) throws(Error) {
        for channel in [reds, greens, blues] where channel.count != 256 {
            throw .wrongLength(channel.count)
        }
        self.name = name
        self.reds = reds
        self.greens = greens
        self.blues = blues
    }

    /// Builds a LUT from the first `colorCount` entries of each channel,
    /// stretched to 256 entries with ImageJ's `LutLoader.interpolate`.
    public init(
        name: String,
        interpolating reds: [UInt8],
        _ greens: [UInt8],
        _ blues: [UInt8],
        colorCount: Int
    ) throws(Error) {
        guard (1...256).contains(colorCount),
            reds.count >= colorCount, greens.count >= colorCount, blues.count >= colorCount
        else { throw .invalidColorCount(colorCount) }
        if colorCount == 256 {
            try self.init(name: name, reds: Array(reds.prefix(256)), greens: Array(greens.prefix(256)), blues: Array(blues.prefix(256)))
            return
        }
        func stretch(_ c: [UInt8]) -> [UInt8] {
            let scale = Double(colorCount) / 256.0
            return (0..<256).map { i in
                let i1 = Int(JavaNumerics.int32(Double(i) * scale))
                let i2 = min(i1 + 1, colorCount - 1)
                let fraction = Double(i) * scale - Double(i1)
                return JavaNumerics.byte((1.0 - fraction) * Double(c[i1]) + fraction * Double(c[i2]))
            }
        }
        try self.init(name: name, reds: stretch(reds), greens: stretch(greens), blues: stretch(blues))
    }

    /// The color of entry `index` packed as `0xFFRRGGBB`.
    @inline(__always)
    public func argb(_ index: Int) -> UInt32 {
        0xFF00_0000 | UInt32(reds[index]) << 16 | UInt32(greens[index]) << 8 | UInt32(blues[index])
    }

    /// The same colors in reverse order (ImageJ's "Invert LUT").
    /// Whether both LUTs map every index to the same color, whatever their names.
    public func hasSameColors(as other: LUT) -> Bool {
        reds == other.reds && greens == other.greens && blues == other.blues
    }

    public func inverted() -> LUT {
        // Lengths are already valid, so this cannot throw.
        try! LUT(name: name, reds: reds.reversed(), greens: greens.reversed(), blues: blues.reversed())
    }

    /// Whether entry 0 is brighter than entry 255, which ImageJ treats as
    /// an inverting LUT.
    /// Every entry is a shade of gray (ImageJ's `!isColorLut()`); an
    /// inverted gray LUT counts.
    public var isGray: Bool { reds == greens && greens == blues }

    public var isInverted: Bool {
        Int(reds[0]) + Int(greens[0]) + Int(blues[0]) > Int(reds[255]) + Int(greens[255]) + Int(blues[255])
    }
}

// MARK: - Built-in LUTs (ports of ImageJ's LutLoader, public domain)

extension LUT {
    /// The LUTs ImageJ generates in code, in Image ▸ Lookup Tables order.
    public static let builtIn: [LUT] = [
        .fire, .grays, .ice, .spectrum, .rgb332, .red, .green, .blue, .cyan, .magenta, .yellow, .redGreen,
    ]

    /// Looks up a built-in LUT by name, ignoring case (`"fire"`, `"3-3-2 RGB"`,
    /// `"red/green"`, …).
    public static func builtIn(named name: String) -> LUT? {
        let key = name.lowercased()
        let alias = key == "redgreen" ? "red/green" : key
        return builtIn.first { $0.name.lowercased() == alias }
    }

    public static let grays = ramp(name: "Grays", red: true, green: true, blue: true)
    public static let red = ramp(name: "Red", red: true, green: false, blue: false)
    public static let green = ramp(name: "Green", red: false, green: true, blue: false)
    public static let blue = ramp(name: "Blue", red: false, green: false, blue: true)
    public static let cyan = ramp(name: "Cyan", red: false, green: true, blue: true)
    public static let magenta = ramp(name: "Magenta", red: true, green: false, blue: true)
    public static let yellow = ramp(name: "Yellow", red: true, green: true, blue: false)

    public static let fire = try! LUT(
        name: "Fire",
        interpolating: [
            0, 0, 1, 25, 49, 73, 98, 122, 146, 162, 173, 184, 195, 207, 217, 229,
            240, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        ],
        [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 14, 35, 57,
            79, 101, 117, 133, 147, 161, 175, 190, 205, 219, 234, 248, 255, 255, 255, 255,
        ],
        [
            0, 61, 96, 130, 165, 192, 220, 227, 210, 181, 151, 122, 93, 64, 35, 5,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 35, 98, 160, 223, 255,
        ],
        colorCount: 32
    )

    public static let ice = try! LUT(
        name: "Ice",
        interpolating: [
            0, 0, 0, 0, 0, 0, 19, 29, 50, 48, 79, 112, 134, 158, 186, 201,
            217, 229, 242, 250, 250, 250, 250, 251, 250, 250, 250, 250, 251, 251, 243, 230,
        ],
        [
            156, 165, 176, 184, 190, 196, 193, 184, 171, 162, 146, 125, 107, 93, 81, 87,
            92, 97, 95, 93, 93, 90, 85, 69, 64, 54, 47, 35, 19, 0, 4, 0,
        ],
        [
            140, 147, 158, 166, 170, 176, 209, 220, 234, 225, 236, 246, 250, 251, 250, 250,
            245, 230, 230, 222, 202, 180, 163, 142, 123, 114, 106, 94, 84, 64, 26, 27,
        ],
        colorCount: 32
    )

    /// Full-saturation hues, computed with `java.awt.Color.HSBtoRGB`'s
    /// single-precision arithmetic so every entry matches ImageJ.
    public static let spectrum: LUT = {
        var r = [UInt8](), g = [UInt8](), b = [UInt8]()
        for i in 0..<256 {
            let (cr, cg, cb) = hsbToRGB(hue: Float(i) / 255, saturation: 1, brightness: 1)
            r.append(cr)
            g.append(cg)
            b.append(cb)
        }
        return try! LUT(name: "Spectrum", reds: r, greens: g, blues: b)
    }()

    public static let rgb332: LUT = {
        let r = (0..<256).map { UInt8($0 & 0xE0) }
        let g = (0..<256).map { UInt8(truncatingIfNeeded: ($0 << 3) & 0xE0) }
        let b = (0..<256).map { UInt8(truncatingIfNeeded: ($0 << 6) & 0xC0) }
        return try! LUT(name: "3-3-2 RGB", reds: r, greens: g, blues: b)
    }()

    public static let redGreen: LUT = {
        let r = (0..<256).map { $0 < 128 ? UInt8($0 * 2) : 0 }
        let g = (0..<256).map { $0 < 128 ? 0 : UInt8(truncatingIfNeeded: $0 * 2) }
        return try! LUT(name: "Red/Green", reds: r, greens: g, blues: Array(repeating: 0, count: 256))
    }()

    private static func ramp(name: String, red: Bool, green: Bool, blue: Bool) -> LUT {
        let ramp = (0..<256).map { UInt8($0) }
        let zero = [UInt8](repeating: 0, count: 256)
        return try! LUT(name: name, reds: red ? ramp : zero, greens: green ? ramp : zero, blues: blue ? ramp : zero)
    }

    /// A port of `java.awt.Color.HSBtoRGB`.
    static func hsbToRGB(hue: Float, saturation: Float, brightness: Float) -> (UInt8, UInt8, UInt8) {
        func channel(_ v: Float) -> UInt8 { UInt8(truncatingIfNeeded: JavaNumerics.int32(v * 255.0 + 0.5)) }
        if saturation == 0 {
            let v = channel(brightness)
            return (v, v, v)
        }
        let h = (hue - hue.rounded(.down)) * 6.0
        let f = h - h.rounded(.down)
        let p = brightness * (1.0 - saturation)
        let q = brightness * (1.0 - saturation * f)
        let t = brightness * (1.0 - (saturation * (1.0 - f)))
        switch Int(JavaNumerics.int32(h)) {
        case 0: return (channel(brightness), channel(t), channel(p))
        case 1: return (channel(q), channel(brightness), channel(p))
        case 2: return (channel(p), channel(brightness), channel(t))
        case 3: return (channel(p), channel(q), channel(brightness))
        case 4: return (channel(t), channel(p), channel(brightness))
        case 5: return (channel(brightness), channel(p), channel(q))
        default: return (0, 0, 0)
        }
    }
}
