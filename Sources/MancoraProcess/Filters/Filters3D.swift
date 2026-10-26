public import MancoraCore

/// Process ▸ Filters ▸ Median 3D, Mean 3D, Minimum 3D, Maximum 3D and
/// Variance 3D: a port of ImageJ 1.54p's `ij.plugin.Filters3D` and
/// `StackProcessor.filter3D`.
public enum Filters3D {
    /// The statistic each voxel's ellipsoidal neighborhood gives.
    public enum Filter: Sendable, Hashable {
        case mean, median, minimum, maximum, variance
    }

    /// Filters one volume (`planes`, all of one type) with an ellipsoid of
    /// radii `x`, `y` and `z` voxels. The neighborhood holds the voxels
    /// within the image whose offset `(i, j, k)` has
    /// `i²/x² + j²/y² + k²/z² ≤ 1` (a zero radius counts 0), read as
    /// `float`s. Mean and variance sum them in `double` (the squares in
    /// `float`); the median of an even count is the mean of the middle two,
    /// in `float`. Results are stored as `ImageStack.setVoxel` stores them:
    /// clipped and rounded for 8- and 16-bit data. Variance gives a 32-bit
    /// volume. RGB volumes are filtered per channel (`filterRGB`), except
    /// by variance, whose float channels ImageJ merges by scaling.
    public static func filter(_ planes: [Plane], width: Int, filter: Filter, x: Float, y: Float, z: Float) -> [Plane] {
        guard let first = planes.first else { return [] }
        if case .rgb8 = first {
            precondition(filter != .variance, "RGB variance isn't ported")
            let channels = [UInt32(16), 8, 0].map { shift in
                Self.filter(
                    planes.map { plane -> Plane in
                        guard case .rgb8(let p) = plane else { return plane }
                        return .gray8(p.map { UInt8(truncatingIfNeeded: $0 >> shift) })
                    }, width: width, filter: filter, x: x, y: y, z: z)
            }
            return planes.indices.map { k in
                guard case .gray8(let r) = channels[0][k], case .gray8(let g) = channels[1][k],
                    case .gray8(let b) = channels[2][k]
                else { return planes[k] }
                return .rgb8(r.indices.map { i in 0xFF00_0000 | UInt32(r[i]) << 16 | UInt32(g[i]) << 8 | UInt32(b[i]) })
            }
        }
        let height = first.count / width
        let depth = planes.count
        let volume = planes.map(\.floatValues)
        let offsets = kernel(x: x, y: y, z: z)
        var values = [Float](repeating: 0, count: offsets.count)
        var out = [[Double]](repeating: [Double](repeating: 0, count: width * height), count: depth)
        for zz in 0..<depth {
            for yy in 0..<height {
                for xx in 0..<width {
                    // getNeighborhood: the kernel's voxels inside the image, in order.
                    var n = 0
                    for (dx, dy, dz) in offsets {
                        let i = xx + dx, j = yy + dy, k = zz + dz
                        if i >= 0 && j >= 0 && k >= 0 && i < width && j < height && k < depth {
                            values[n] = volume[k][j * width + i]
                            n += 1
                        }
                    }
                    out[zz][yy * width + xx] = statistic(filter, &values, count: n)
                }
            }
        }
        return out.map { voxels in
            switch (filter, first) {
            case (.variance, _), (_, .gray32Float):
                return .gray32Float(voxels.map { Float($0) })
            case (_, .gray16):
                return .gray16(voxels.map { v in UInt16(truncatingIfNeeded: JavaNumerics.int32(min(max(v, 0), 65535) + 0.5)) })
            default:
                return .gray8(voxels.map { v in UInt8(truncatingIfNeeded: JavaNumerics.int32(min(max(v, 0), 255) + 0.5)) })
            }
        }
    }

    /// `createKernelEllipsoid`: the offsets inside the ellipsoid, z then y
    /// then x, as ImageJ visits them.
    static func kernel(x: Float, y: Float, z: Float) -> [(Int, Int, Int)] {
        func extent(_ r: Float) -> Int { Int(JavaNumerics.int32(Double(r).rounded(.up))) }
        func inverseSquare(_ r: Float) -> Double {
            let r2 = Double(r) * Double(r)
            return r2 != 0 ? 1.0 / r2 : 0
        }
        let vx = extent(x), vy = extent(y), vz = extent(z)
        let rx2 = inverseSquare(x), ry2 = inverseSquare(y), rz2 = inverseSquare(z)
        var offsets: [(Int, Int, Int)] = []
        guard vz >= 0, vy >= 0, vx >= 0 else { return offsets }
        for k in -vz...vz {
            for j in -vy...vy {
                for i in -vx...vx where Double(i * i) * rx2 + Double(j * j) * ry2 + Double(k * k) * rz2 <= 1.0 {
                    offsets.append((i, j, k))
                }
            }
        }
        return offsets
    }

    /// `ArrayUtil`'s `getMean`, `medianSort`, `getMinimum`, `getMaximum`
    /// and `getVariance` over the first `count` values (which it reorders).
    static func statistic(_ filter: Filter, _ values: inout [Float], count n: Int) -> Double {
        guard n > 0 else { return .nan }  // the kernel always holds its center
        switch filter {
        case .mean:
            var total = 0.0
            for i in 0..<n { total += Double(values[i]) }
            return total / Double(n)
        case .median:
            values[0..<n].sort(by: javaFloatOrder)
            if n % 2 == 1 { return Double(values[n / 2]) }
            return Double(0.5 * (values[n / 2 - 1] + values[n / 2]))
        case .minimum:
            var lowest = Double(values[0])
            for i in 1..<n where Double(values[i]) < lowest { lowest = Double(values[i]) }
            return lowest
        case .maximum:
            var highest = Double(values[0])
            for i in 1..<n where Double(values[i]) > highest { highest = Double(values[i]) }
            return highest
        case .variance:
            if n == 1 { return 0 }
            var total = 0.0, total2 = 0.0
            for i in 0..<n {
                total += Double(values[i])
                total2 += Double(values[i] * values[i])
            }
            return (total2 - total * total / Double(n)) / Double(n - 1)
        }
    }

    /// `Arrays.sort(float[])`: -0 before 0, NaN last.
    static func javaFloatOrder(_ a: Float, _ b: Float) -> Bool {
        if a.isNaN { return false }
        if b.isNaN { return true }
        if a == b { return a.sign == .minus && b.sign == .plus }
        return a < b
    }
}

extension Plane {
    /// The pixel values as floats (`(float)getVoxel`).
    var floatValues: [Float] {
        switch self {
        case .gray8(let p): p.map { Float($0) }
        case .gray16(let p): p.map { Float($0) }
        case .gray32Float(let p): p
        case .rgb8(let p): p.map { Float($0) }
        }
    }
}
