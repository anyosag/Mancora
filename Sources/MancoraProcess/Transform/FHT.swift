import MancoraCore

/// A port of ImageJ's `FHT`, Arlo Reeves' Fast Hartley Transform from NIH
/// Image, in `float` as ImageJ computes it: the 2D transform of a square
/// image whose side is a power of 2, and its 8-bit power spectrum.
public struct FHT: Sendable {
    public let size: Int
    private let log2Size: Int
    private let cosines: [Float]
    private let sines: [Float]
    private let bitReversed: [Int]

    /// `initializeTables(maxN)`: `float` sines and cosines of `theta`,
    /// which grows by `2π/maxN` a step, and the bit-reversal table.
    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "the FHT's size must be a power of 2")
        self.size = size
        var c: [Float] = [], s: [Float] = []
        var theta = 0.0
        let dTheta = 2.0 * Double.pi / Double(size)
        for _ in 0..<(size / 4) {
            c.append(Float(GeometryMath.cosine(theta)))
            s.append(Float(GeometryMath.sine(theta)))
            theta += dTheta
        }
        cosines = c
        sines = s
        let bits = Int.bitWidth - 1 - size.leadingZeroBitCount
        log2Size = bits
        bitReversed = (0..<size).map { x in
            var reversed = 0
            for i in 0..<bits where x & (1 << i) != 0 { reversed |= 1 << (bits - i - 1) }
            return reversed
        }
    }

    /// `rc2DFHT(x, inverse, maxN)`: the rows' 1D transforms, then the
    /// columns', then Bracewell's step to the 2D Hartley transform.
    public func transform(_ pixels: inout [Float], inverse: Bool) {
        precondition(pixels.count == size * size, "the FHT's image must be size × size")
        let n = size
        var temp = [Float](repeating: 0, count: n)
        pixels.withUnsafeMutableBufferPointer { x in
            temp.withUnsafeMutableBufferPointer { t in
                for row in 0..<n { dfht3(x, base: row * n, inverse: inverse, temp: t) }
                transpose(x)
                for row in 0..<n { dfht3(x, base: row * n, inverse: inverse, temp: t) }
                transpose(x)
            }
            for row in 0...(n / 2) {
                for col in 0...(n / 2) {
                    let mRow = (n - row) % n
                    let mCol = (n - col) % n
                    let a = x[row * n + col]
                    let b = x[mRow * n + col]
                    let c = x[row * n + mCol]
                    let d = x[mRow * n + mCol]
                    let e = ((a + d) - (b + c)) / 2
                    x[row * n + col] = a - e
                    x[mRow * n + col] = b + e
                    x[row * n + mCol] = c + e
                    x[mRow * n + mCol] = d - e
                }
            }
        }
    }

    /// `dfht3`: the 1D transform of `x[base..<base+size]`, radix-4
    /// butterflies first, divided by `size` when inverse.
    private func dfht3(_ x: UnsafeMutableBufferPointer<Float>, base: Int, inverse: Bool, temp: UnsafeMutableBufferPointer<Float>) {
        let n = size
        for i in 0..<n { temp[i] = x[base + bitReversed[i]] }
        for i in 0..<n { x[base + i] = temp[i] }
        var gpSize = 2
        var numGps = n / 4
        for gpNum in 0..<numGps {
            let ad1 = base + gpNum * 4
            let ad2 = ad1 + 1
            let ad3 = ad1 + gpSize
            let ad4 = ad2 + gpSize
            let rt1 = x[ad1] + x[ad2]
            let rt2 = x[ad1] - x[ad2]
            let rt3 = x[ad3] + x[ad4]
            let rt4 = x[ad3] - x[ad4]
            x[ad1] = rt1 + rt3
            x[ad2] = rt2 + rt4
            x[ad3] = rt1 - rt3
            x[ad4] = rt2 - rt4
        }
        if log2Size > 2 {
            gpSize = 4
            var numBfs = 2
            numGps /= 2
            for _ in 2..<log2Size {
                for gpNum in 0..<numGps {
                    let ad0 = base + gpNum * gpSize * 2
                    var ad1 = ad0
                    var ad2 = ad1 + gpSize
                    var ad3 = ad1 + gpSize / 2
                    var ad4 = ad3 + gpSize
                    var rt1 = x[ad1]
                    x[ad1] = x[ad1] + x[ad2]
                    x[ad2] = rt1 - x[ad2]
                    rt1 = x[ad3]
                    x[ad3] = x[ad3] + x[ad4]
                    x[ad4] = rt1 - x[ad4]
                    for bfNum in 1..<numBfs {
                        ad1 = bfNum + ad0
                        ad2 = ad1 + gpSize
                        ad3 = gpSize - bfNum + ad0
                        ad4 = ad3 + gpSize
                        let cs = bfNum * numGps
                        let rt1 = x[ad2] * cosines[cs] + x[ad4] * sines[cs]
                        let rt2 = x[ad4] * cosines[cs] - x[ad2] * sines[cs]
                        x[ad2] = x[ad1] - rt1
                        x[ad1] = x[ad1] + rt1
                        x[ad4] = x[ad3] + rt2
                        x[ad3] = x[ad3] - rt2
                    }
                }
                gpSize *= 2
                numBfs *= 2
                numGps /= 2
            }
        }
        if inverse {
            let divisor = Float(n)
            for i in base..<(base + n) { x[i] = x[i] / divisor }
        }
    }

    /// `transposeR`.
    private func transpose(_ x: UnsafeMutableBufferPointer<Float>) {
        let n = size
        for r in 0..<n {
            for c in (r + 1)..<n { x.swapAt(r * n + c, c * n + r) }
        }
    }

    /// `getPowerSpectrum()`: `(H(u,v)² + H(-u,-v)²) / 2`, its log scaled
    /// so the largest value is 254 and the range at most e^50, as bytes
    /// from 1, with the origin in the center (``swapQuadrants(_:width:)``).
    public func powerSpectrum(_ fht: [Float]) -> [UInt8] {
        let n = size
        var fps = [Float](repeating: 0, count: n * n)
        var minimum = Float.greatestFiniteMagnitude
        var maximum = Float.leastNonzeroMagnitude
        for row in 0..<n {
            let base = row * n
            let mirror = ((n - row) % n) * n
            for c in 0..<n {
                let h = fht[base + c]
                let m = fht[mirror + (n - c) % n]
                let r = (h * h + m * m) / 2
                fps[base + c] = r
                if r < minimum { minimum = r }
                if r > maximum { maximum = r }
            }
        }
        maximum = Float(Libm.logarithm(Double(maximum)))
        minimum = Float(Libm.logarithm(Double(minimum)))
        if minimum.isNaN || maximum - minimum > 50 { minimum = maximum - 50 }
        let scale = Float(253.999 / Double(maximum - minimum))
        var ps = [UInt8](repeating: 0, count: n * n)
        for i in ps.indices {
            var r = (Float(Libm.logarithm(Double(fps[i]))) - minimum) * scale
            if r.isNaN || r < 0 { r = 0 }
            ps[i] = UInt8(truncatingIfNeeded: JavaNumerics.int32(r + 1))
        }
        Self.swapQuadrants(&ps, width: n)
        return ps
    }

    /// `FFT.swapQuadrants(ip)` on a square image: quadrants 1 and 3 and
    /// 2 and 4 trade places, so the origin moves to the center. An odd
    /// width leaves the last row and column where they are.
    public static func swapQuadrants<T>(_ pixels: inout [T], width: Int) {
        let half = width / 2
        guard half > 0 else { return }
        let source = pixels
        let side = 2 * half
        for y in 0..<side {
            let sy = (y + half) % side
            for x in 0..<side { pixels[y * width + x] = source[sy * width + (x + half) % side] }
        }
    }
}
