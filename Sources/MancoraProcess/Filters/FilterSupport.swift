public import MancoraCore

/// Why a filter couldn't run.
public enum FilterError: Error, Sendable, Equatable {
    /// A convolution kernel needs odd width and height and one value per
    /// element (ImageJ's `Convolver` rejects even sizes too).
    case invalidKernel(width: Int, height: Int, valueCount: Int)
    /// The operation is only defined for this pixel type (ImageJ's binary
    /// commands take 8-bit images only).
    case unsupportedPixelType(PixelType, expected: PixelType)
}

extension Plane {
    /// The plane's height for a given width, checking that the two agree.
    func filterHeight(width: Int) -> Int {
        precondition(width > 0 && count % width == 0, "plane of \(count) pixels can't be \(width) pixels wide")
        return count / width
    }
}

extension ImageStack {
    /// Applies `transform` to every plane, keeping size, labels and order.
    func mapPlanes(_ transform: (Plane) -> Plane) -> ImageStack {
        var out = self
        for i in 0..<count {
            do {
                try out.setPlane(transform(planes[i]), at: i)
            } catch {
                preconditionFailure("filter changed the plane's size or type: \(error)")
            }
        }
        return out
    }
}

/// Conversions between planes and the float channels ImageJ's filters work
/// on (`ImageProcessor.toFloat` and `setPixels(channel, fp)`).
enum FloatChannels {
    /// One float array per channel: one for grayscale, red/green/blue for RGB.
    static func split(_ plane: Plane) -> [[Float]] {
        switch plane {
        case .gray8(let p): return [p.map { Float($0) }]
        case .gray16(let p): return [p.map { Float($0) }]
        case .gray32Float(let p): return [p]
        case .rgb8(let p):
            return [16, 8, 0].map { shift in p.map { Float(($0 >> UInt32(shift)) & 0xFF) } }
        }
    }

    /// Rebuilds a plane of `type` from float channels the way ImageJ's
    /// `setPixels(channel, fp)` does: add 0.5, clamp to the type's range,
    /// truncate. Float data is kept as is.
    static func merge(_ channels: [[Float]], as type: PixelType) -> Plane {
        switch type {
        case .gray8: return .gray8(channels[0].map { UInt8(truncatingIfNeeded: roundClamped($0, max: 255)) })
        case .gray16: return .gray16(channels[0].map { UInt16(truncatingIfNeeded: roundClamped($0, max: 65535)) })
        case .gray32Float: return .gray32Float(channels[0])
        case .rgb8:
            let r = channels[0], g = channels[1], b = channels[2]
            var out = [UInt32](repeating: 0, count: r.count)
            for i in out.indices {
                out[i] = 0xFF00_0000 | UInt32(roundClamped(r[i], max: 255)) << 16
                    | UInt32(roundClamped(g[i], max: 255)) << 8 | UInt32(roundClamped(b[i], max: 255))
            }
            return .rgb8(out)
        }
    }

    /// `value = f + 0.5f; clamp to [0, max]; (int)value`, with NaN giving 0.
    @inline(__always)
    static func roundClamped(_ f: Float, max: Float) -> Int32 {
        var value = f + 0.5
        if value < 0 { value = 0 }
        if value > max { value = max }
        return JavaNumerics.int32(value)
    }
}

extension Plane {
    /// The values of the pixels in `region` (its bounds and mask), row by
    /// row: what ImageJ's statistics count for a selection.
    public func values(in region: MeasurementRegion, width: Int) -> Plane {
        let height = filterHeight(width: width)
        var indices: [Int] = []
        let x0 = max(region.x, 0), x1 = min(region.x + region.width, width)
        let y0 = max(region.y, 0), y1 = min(region.y + region.height, height)
        if x0 < x1, y0 < y1 {
            for y in y0..<y1 {
                for x in x0..<x1 where region.contains(x, y) { indices.append(y * width + x) }
            }
        }
        switch self {
        case .gray8(let p): return .gray8(indices.map { p[$0] })
        case .gray16(let p): return .gray16(indices.map { p[$0] })
        case .gray32Float(let p): return .gray32Float(indices.map { p[$0] })
        case .rgb8(let p): return .rgb8(indices.map { p[$0] })
        }
    }
}
