/// `java.util.Random`: the same sequence for the same seed, as ImageJ's
/// macro `random()` and its noise filters (`ImageProcessor.rnd`) draw it.
public struct JavaRandom: Sendable, Hashable {
    private var seed: Int64
    private var nextNextGaussian = 0.0
    private var haveNextNextGaussian = false
    private static let multiplier: Int64 = 0x5_DEEC_E66D
    private static let mask: Int64 = (1 << 48) - 1

    /// `new Random(seed)`.
    public init(seed: Int64) { self.seed = (seed ^ Self.multiplier) & Self.mask }

    /// `new Random()`: an unpredictable seed.
    public init() {
        self.init(seed: Int64.random(in: Int64.min...Int64.max))
    }

    /// `setSeed(seed)`, which also forgets a pending Gaussian.
    public mutating func setSeed(_ seed: Int64) {
        self = JavaRandom(seed: seed)
    }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* Self.multiplier &+ 0xB) & Self.mask
        return Int32(truncatingIfNeeded: seed >> (48 - bits))
    }

    /// `nextDouble()`: uniform in 0..<1.
    public mutating func nextDouble() -> Double {
        let high = Int64(next(26)) << 27
        let low = Int64(next(27))
        return Double(high + low) * 0x1.0p-53
    }

    /// `nextInt(bound)`: uniform in 0..<bound, for a positive bound.
    public mutating func nextInt(_ bound: Int32) -> Int32 {
        precondition(bound > 0, "bound must be positive")
        var r = next(31)
        let m = bound - 1
        if bound & m == 0 {  // a power of 2
            return Int32(truncatingIfNeeded: (Int64(bound) * Int64(r)) >> 31)
        }
        var u = r
        while true {
            r = u % bound
            if u &- r &+ m >= 0 { return r }
            u = next(31)
        }
    }

    /// `nextGaussian()`: Marsaglia's polar method, with `StrictMath.log`.
    public mutating func nextGaussian() -> Double {
        if haveNextNextGaussian {
            haveNextNextGaussian = false
            return nextNextGaussian
        }
        var v1 = 0.0, v2 = 0.0, s = 0.0
        repeat {
            v1 = 2 * nextDouble() - 1
            v2 = 2 * nextDouble() - 1
            s = v1 * v1 + v2 * v2
        } while s >= 1 || s == 0
        let multiplier = (-2 * StrictMath.log(s) / s).squareRoot()
        nextNextGaussian = v2 * multiplier
        haveNextNextGaussian = true
        return v1 * multiplier
    }
}
