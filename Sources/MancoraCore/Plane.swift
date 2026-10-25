/// One 2D plane of pixels, stored row-major with no padding.
///
/// Swift arrays are copy-on-write, so planes are cheap to copy and safe to
/// hand to background work; a write after a copy duplicates the storage.
public enum Plane: Sendable, Equatable {
    case gray8([UInt8])
    case gray16([UInt16])
    case gray32Float([Float])
    /// Packed `0xAARRGGBB`; alpha is always `0xFF` after import.
    case rgb8([UInt32])

    /// A zero-filled plane of `count` pixels.
    public init(zeroed type: PixelType, count: Int) {
        switch type {
        case .gray8: self = .gray8(Array(repeating: 0, count: count))
        case .gray16: self = .gray16(Array(repeating: 0, count: count))
        case .gray32Float: self = .gray32Float(Array(repeating: 0, count: count))
        case .rgb8: self = .rgb8(Array(repeating: 0xFF00_0000, count: count))
        }
    }

    public var pixelType: PixelType {
        switch self {
        case .gray8: .gray8
        case .gray16: .gray16
        case .gray32Float: .gray32Float
        case .rgb8: .rgb8
        }
    }

    public var count: Int {
        switch self {
        case .gray8(let p): p.count
        case .gray16(let p): p.count
        case .gray32Float(let p): p.count
        case .rgb8(let p): p.count
        }
    }

    /// The pixel value as a `Double`; for RGB, the luminance ImageJ uses
    /// by default (unweighted mean of R, G and B).
    public func value(at index: Int) -> Double {
        switch self {
        case .gray8(let p): return Double(p[index])
        case .gray16(let p): return Double(p[index])
        case .gray32Float(let p): return Double(p[index])
        case .rgb8(let p):
            let c = p[index]
            let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
            return (r + g + b) / 3
        }
    }

    /// Smallest and largest finite value, or `nil` for an empty plane or a
    /// float plane with no finite values. RGB planes report `0...255`.
    public func valueRange() -> ClosedRange<Double>? {
        switch self {
        case .gray8(let p): return Self.range(p)
        case .gray16(let p): return Self.range(p)
        case .gray32Float(let p):
            var lo = Float.infinity, hi = -Float.infinity
            for v in p where v.isFinite {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            return lo <= hi ? Double(lo)...Double(hi) : nil
        case .rgb8(let p): return p.isEmpty ? nil : 0...255
        }
    }

    private static func range<T: FixedWidthInteger>(_ p: [T]) -> ClosedRange<Double>? {
        guard var lo = p.first else { return nil }
        var hi = lo
        for v in p {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return Double(lo)...Double(hi)
    }
}
