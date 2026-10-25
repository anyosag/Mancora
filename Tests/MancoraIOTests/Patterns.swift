import MancoraCore

/// The pixel patterns the fixture generators write. These formulas must match
/// `Tools/fixtures/make_tiffs.py` and `Tools/fixtures/ImageJFixtures.java`.
enum Patterns {
    static func p8(_ x: Int, _ y: Int, _ k: Int = 0) -> UInt8 { UInt8((x * 7 + y * 13 + k * 50) & 255) }
    static func p16(_ x: Int, _ y: Int, _ k: Int = 0) -> UInt16 { UInt16((x * 311 + y * 1009 + k * 5003) & 0xFFFF) }
    static func f32(_ x: Int, _ y: Int, _ k: Int = 0) -> Float { Float(x) * 0.25 - Float(y) * 0.5 + Float(k) * 100 }
    static func u32(_ x: Int, _ y: Int, _ k: Int = 0) -> Float { Float(x * 100003 + y * 7 + k) }
    static func rgb(_ x: Int, _ y: Int, _ k: Int = 0) -> UInt32 {
        let r = UInt32((x * 8 + k * 20) & 255), g = UInt32((y * 10) & 255), b = UInt32((x * 3 + y * 5) & 255)
        return 0xFF00_0000 | r << 16 | g << 8 | b
    }
    static func bits(_ x: Int, _ y: Int) -> Bool { (x + y) % 3 == 0 }

    /// ImageJFixtures.hyper: plane k of the c=2, z=3, t=4 hyperstack.
    static func hyperstack(_ k: Int, _ x: Int, _ y: Int) -> UInt16 {
        let c = k % 2, z = (k / 2) % 3, t = k / 6
        return UInt16(c * 1000 + z * 100 + t * 10 + x + y * 7)
    }

    /// The expected plane `k` for a manifest pattern name.
    static func plane(_ name: String, width: Int, height: Int, k: Int, inverted: Bool = false) -> Plane? {
        let coords = (0..<height).flatMap { y in (0..<width).map { x in (x, y) } }
        switch name {
        case "p8": return .gray8(coords.map { p8($0.0, $0.1, k) })
        case "p16": return .gray16(coords.map { p16($0.0, $0.1, k) })
        case "f32": return .gray32Float(coords.map { f32($0.0, $0.1, k) })
        case "u32": return .gray32Float(coords.map { u32($0.0, $0.1, k) })
        case "rgb": return .rgb8(coords.map { rgb($0.0, $0.1, k) })
        case "bits": return .gray8(coords.map { bits($0.0, $0.1) != inverted ? 255 : 0 })
        default: return nil
        }
    }
}
