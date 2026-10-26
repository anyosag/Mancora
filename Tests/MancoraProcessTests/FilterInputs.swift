import MancoraCore

/// The test images of `Tools/fixtures/FilterFixtures.java`, rebuilt from the
/// same formulas. A golden test checks that every input hashes to the value
/// ImageJ recorded, so the two definitions can't drift apart.
enum FilterInputs {
    /// A 31-bit hash of a pixel position, in Java's wrapping int arithmetic.
    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: x) &* 0x27d4_eb2d
        h = h &+ UInt32(truncatingIfNeeded: y) &* 0x1656_67b1
        h = h &+ UInt32(truncatingIfNeeded: seed) &* 0x9e37_79b9
        h ^= h >> 15
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        return Int(h & 0x7fff_ffff)
    }

    static func disc(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let dx = x - w / 2, dy = y - h / 2, r = h / 4
        return dx * dx + dy * dy <= r * r
    }

    /// A constant band, a 0/255 checkerboard, a bright disc and a noisy gradient.
    static func gray8(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Int {
        if y < h / 6 { return 100 }
        if x >= w - w / 6 { return (x + y) & 1 == 0 ? 0 : 255 }
        if disc(x, y, w, h) { return 230 }
        return min(255, x * 4 + y * 3 + (hash(x, y, 1) & 63))
    }

    static func gray16(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Int {
        if y < h / 6 { return 1000 }
        if x >= w - w / 6 { return (x + y) & 1 == 0 ? 0 : 65535 }
        if disc(x, y, w, h) { return 50000 }
        return min(65535, x * 1500 + y * 700 + (hash(x, y, 2) & 4095))
    }

    static func gray32(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Float {
        if y < h / 6 { return 12.5 }
        if x >= w - w / 6 { return (x + y) & 1 == 0 ? -2.5e4 : 1.0e5 }
        if disc(x, y, w, h) { return -7.25 }
        return Float(hash(x, y, 3) & 0xffff) / 256 - 100 + Float(x) * 0.37
    }

    static func floatSpecial(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Float {
        switch hash(x, y, 4) % 97 {
        case 0: return .nan
        case 1: return .infinity
        case 2: return -.infinity
        case 3: return -0.0
        case 4: return 3.0e38
        case 5: return -3.0e38
        case 6: return subnormal
        default: return gray32(x, y, w, h)
        }
    }

    /// Java's `1.0e-40f`; a literal that small is an error in Swift.
    static let subnormal = Float("1.0e-40")!

    static func rgb(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UInt32 {
        0xFF00_0000 | UInt32(gray8(x, y, w, h)) << 16 | UInt32(gray8(w - 1 - x, h - 1 - y, w, h)) << 8
            | UInt32(hash(x, y, 5) & 255)
    }

    static func binary(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UInt8 {
        let dx = x - w / 3, dy = y - h / 2, d2 = dx * dx + dy * dy
        let ring = d2 >= 9 && d2 < 30
        let block = x >= w / 2 + 2 && x < w / 2 + 11 && y >= 2 && y < 10
            && !(x >= w / 2 + 5 && x < w / 2 + 8 && y >= 5 && y < 7)
        let bar = x < 4 && y > h / 2 && y < h - 3
        let corner = x >= w - 5 && y >= h - 4
        let line = x - y == w / 2 && x > w / 2
        let speck = hash(x, y, 7) % 23 == 0
        return ring || block || bar || corner || line || speck ? 255 : 0
    }

    /// The plane for an input name such as `"gray16-37x23"`.
    static func plane(named name: String) -> (plane: Plane, width: Int, height: Int)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2 else { return nil }
        let size = parts[1].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { return nil }
        let (w, h) = (size[0], size[1])
        func grid<T>(_ f: (Int, Int, Int, Int) -> T) -> [T] {
            var out: [T] = []
            out.reserveCapacity(w * h)
            for y in 0..<h { for x in 0..<w { out.append(f(x, y, w, h)) } }
            return out
        }
        let plane: Plane
        switch parts[0] {
        case "gray8": plane = .gray8(grid { UInt8(gray8($0, $1, $2, $3)) })
        case "gray16": plane = .gray16(grid { UInt16(gray16($0, $1, $2, $3)) })
        case "float": plane = .gray32Float(grid(gray32))
        case "floatSpecial": plane = .gray32Float(grid(floatSpecial))
        case "rgb": plane = .rgb8(grid(rgb))
        case "binary": plane = .gray8(grid(binary))
        default: return nil
        }
        return (plane, w, h)
    }

    /// The bytes the fixtures hash: 8-bit as is, 16-bit and float
    /// little-endian (every NaN as `0x7FC00000`), RGB as R, G, B.
    static func bytes(_ plane: Plane) -> [UInt8] {
        var out: [UInt8] = []
        switch plane {
        case .gray8(let p): out = p
        case .gray16(let p):
            out.reserveCapacity(2 * p.count)
            for v in p { out += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        case .gray32Float(let p):
            out.reserveCapacity(4 * p.count)
            for v in p {
                let bits = v.isNaN ? 0x7FC0_0000 : v.bitPattern
                for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: bits >> UInt32(8 * k))) }
            }
        case .rgb8(let p):
            out.reserveCapacity(3 * p.count)
            for v in p {
                out += [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
            }
        }
        return out
    }

    static func sha256(_ plane: Plane) -> String {
        TestSHA256.hex(bytes(plane))
    }

    /// A pixel as the fixtures write it: decimal, Java's `Float.toString`
    /// value, or `rrggbb`.
    static func sample(_ plane: Plane, _ i: Int) -> String {
        switch plane {
        case .gray8(let p): return String(p[i])
        case .gray16(let p): return String(p[i])
        case .gray32Float(let p): return String(p[i])
        case .rgb8(let p):
            let hex = String(p[i] & 0xFF_FFFF, radix: 16)
            return String(repeating: "0", count: 6 - hex.count) + hex
        }
    }

    /// Whether a sample written by the fixtures equals `value`, comparing
    /// floats by value (NaN equals NaN).
    static func sampleMatches(_ expected: String, _ plane: Plane, _ i: Int) -> Bool {
        guard case .gray32Float(let p) = plane else { return expected == sample(plane, i) }
        let actual = p[i]
        switch expected {
        case "NaN": return actual.isNaN
        case "Infinity": return actual == .infinity
        case "-Infinity": return actual == -.infinity
        default:
            guard let value = Float(expected) else { return false }
            return value.bitPattern == actual.bitPattern
        }
    }
}

/// SHA-256 (FIPS 180-4), small and slow, for checking fixture hashes.
enum TestSHA256 {
    static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bits = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + 4 * i
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let t1 = hh &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.map { word in
            let s = String(word, radix: 16)
            return String(repeating: "0", count: 8 - s.count) + s
        }.joined()
    }

    static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
}
