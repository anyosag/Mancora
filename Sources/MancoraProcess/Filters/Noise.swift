public import MancoraCore

extension Plane {
    /// Process ▸ Noise ▸ Add Noise and Add Specified Noise:
    /// `ImageProcessor.noise(standardDeviation)`, drawing from `random`
    /// pixel by pixel, row by row through `rect` (the whole plane for `nil`).
    ///
    /// 8- and 16-bit pixels add `Math.round(gaussian * sd)`, drawing again
    /// until the sum fits the type's range; 32-bit pixels add
    /// `(float)(gaussian * sd)`; RGB planes take their red, then green, then
    /// blue channel through the 8-bit rule (`filterRGB(RGB_NOISE)`).
    public func addingNoise(standardDeviation sd: Double, width: Int, rect: RoiBounds? = nil, random: inout JavaRandom) -> Plane {
        let height = filterHeight(width: width)
        let r = rect ?? .whole(width: width, height: height)
        guard !r.isEmpty else { return self }
        func integers<T: FixedWidthInteger>(_ pixels: inout [T], max: Int64) {
            for y in r.y..<(r.y + r.height) {
                for i in (y * width + r.x)..<(y * width + r.x + r.width) {
                    while true {
                        let v = Int64(pixels[i]) + Int64(Int32(truncatingIfNeeded: JavaNumerics.round(random.nextGaussian() * sd)))
                        if v >= 0 && v <= max {
                            pixels[i] = T(v)
                            break
                        }
                    }
                }
            }
        }
        switch self {
        case .gray8(var p):
            integers(&p, max: 255)
            return .gray8(p)
        case .gray16(var p):
            integers(&p, max: 65535)
            return .gray16(p)
        case .gray32Float(var p):
            for y in r.y..<(r.y + r.height) {
                for i in (y * width + r.x)..<(y * width + r.x + r.width) {
                    p[i] = p[i] + Float(random.nextGaussian() * sd)
                }
            }
            return .gray32Float(p)
        case .rgb8(let p):
            var channels = [16, 8, 0].map { (shift: UInt32) in p.map { UInt8(truncatingIfNeeded: $0 >> shift) } }
            for c in channels.indices { integers(&channels[c], max: 255) }
            return .rgb8(p.indices.map { i in
                (p[i] & 0xFF00_0000) | UInt32(channels[0][i]) << 16 | UInt32(channels[1][i]) << 8 | UInt32(channels[2][i])
            })
        }
    }

    /// Process ▸ Noise ▸ Salt and Pepper (`SaltAndPepper.add(ip, percent)`)
    /// on an 8-bit plane: `(int)(percent * area) / 2` times, a random pixel
    /// of `rect` becomes 255 and another 0. Other types are returned unchanged.
    public func addingSaltAndPepper(percent: Double = 0.05, width: Int, rect: RoiBounds? = nil, random: inout JavaRandom) -> Plane {
        guard case .gray8(var p) = self else { return self }
        let r = rect ?? .whole(width: width, height: filterHeight(width: width))
        guard !r.isEmpty else { return self }
        let n = Int(JavaNumerics.int32(percent * Double(r.width) * Double(r.height)))
        func rand(_ min: Int, _ max: Int) -> Int { min + Int(random.nextInt(Int32(max - min))) }
        for _ in 0..<(n / 2) {
            var rx = rand(r.x, r.x + r.width), ry = rand(r.y, r.y + r.height)
            p[ry * width + rx] = 255
            rx = rand(r.x, r.x + r.width)
            ry = rand(r.y, r.y + r.height)
            p[ry * width + rx] = 0
        }
        return .gray8(p)
    }
}
