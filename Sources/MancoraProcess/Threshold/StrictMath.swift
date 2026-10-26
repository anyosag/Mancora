import MancoraCore

/// Java's `StrictMath.log`, `log10` and `exp`: ports of fdlibm 5.3
/// (`e_log.c`, `e_log10.c`, `e_exp.c`), which the Java specification
/// requires `StrictMath` to reproduce bit for bit.
///
/// ImageJ calls `Math.log`, which the JVM may replace with a faster
/// intrinsic that differs from fdlibm in the last bit for a few percent of
/// arguments. Mancora uses fdlibm everywhere instead of the platform's
/// `libm`, so results are identical on macOS, Linux and Windows. A last-bit
/// difference only changes an ImageJ result when two candidates tie to
/// within rounding error.
enum StrictMath {
    private static let two54 = Double(bitPattern: 0x4350_0000_0000_0000)
    private static let ln2Hi = Double(bitPattern: 0x3FE6_2E42_FEE0_0000)
    private static let ln2Lo = Double(bitPattern: 0x3DEA_39EF_3579_3C76)

    private static func high(_ x: Double) -> Int32 { Int32(truncatingIfNeeded: x.bitPattern >> 32) }
    private static func low(_ x: Double) -> UInt32 { UInt32(truncatingIfNeeded: x.bitPattern) }
    private static func withHigh(_ x: Double, _ hi: Int32) -> Double {
        Double(bitPattern: UInt64(UInt32(bitPattern: hi)) << 32 | (x.bitPattern & 0xFFFF_FFFF))
    }

    // MARK: log (e_log.c)

    private static let lg1 = Double(bitPattern: 0x3FE5_5555_5555_5593)
    private static let lg2 = Double(bitPattern: 0x3FD9_9999_9997_FA04)
    private static let lg3 = Double(bitPattern: 0x3FD2_4924_9422_9359)
    private static let lg4 = Double(bitPattern: 0x3FCC_71C5_1D8E_78AF)
    private static let lg5 = Double(bitPattern: 0x3FC7_4664_96CB_03DE)
    private static let lg6 = Double(bitPattern: 0x3FC3_9A09_D078_C69F)
    private static let lg7 = Double(bitPattern: 0x3FC2_F112_DF3E_5244)

    /// `StrictMath.log(x)`, the natural logarithm.
    static func log(_ value: Double) -> Double {
        var x = value
        var hx = high(x)
        let lx = low(x)
        var k: Int32 = 0
        if hx < 0x0010_0000 {  // x < 2^-1022
            if (hx & 0x7FFF_FFFF) | Int32(bitPattern: lx) == 0 { return -.infinity }  // log(±0)
            if hx < 0 { return .nan }  // log(negative)
            k -= 54  // subnormal: scale up
            x *= two54
            hx = high(x)
        }
        if hx >= 0x7FF0_0000 { return x + x }
        k += (hx >> 20) - 1023
        hx &= 0x000F_FFFF
        let i = (hx &+ 0x95F64) & 0x10_0000
        x = withHigh(x, hx | (i ^ 0x3FF0_0000))  // normalize x or x/2
        k += i >> 20
        let f = x - 1.0
        if (0x000F_FFFF & (2 &+ hx)) < 3 {  // |f| < 2^-20
            if f == 0 {
                if k == 0 { return 0 }
                let dk = Double(k)
                return dk * ln2Hi + dk * ln2Lo
            }
            let r = f * f * (0.5 - 0.33333333333333333 * f)
            if k == 0 { return f - r }
            let dk = Double(k)
            return dk * ln2Hi - ((r - dk * ln2Lo) - f)
        }
        let s = f / (2.0 + f)
        let dk = Double(k)
        let z = s * s
        var j = hx &- 0x6147A
        let w = z * z
        let j2 = 0x6B851 &- hx
        let t1 = w * (lg2 + w * (lg4 + w * lg6))
        let t2 = z * (lg1 + w * (lg3 + w * (lg5 + w * lg7)))
        j |= j2
        let r = t2 + t1
        if j > 0 {
            let hfsq = 0.5 * f * f
            if k == 0 { return f - (hfsq - s * (hfsq + r)) }
            return dk * ln2Hi - ((hfsq - (s * (hfsq + r) + dk * ln2Lo)) - f)
        }
        if k == 0 { return f - s * (f - r) }
        return dk * ln2Hi - ((s * (f - r) - dk * ln2Lo) - f)
    }

    // MARK: log10 (e_log10.c)

    private static let ivln10 = Double(bitPattern: 0x3FDB_CB7B_1526_E50E)
    private static let log10_2hi = Double(bitPattern: 0x3FD3_4413_509F_6000)
    private static let log10_2lo = Double(bitPattern: 0x3D59_FEF3_11F1_2B36)

    /// `StrictMath.log10(x)`, the base-10 logarithm.
    static func log10(_ value: Double) -> Double {
        var x = value
        var hx = high(x)
        let lx = low(x)
        var k: Int32 = 0
        if hx < 0x0010_0000 {  // x < 2^-1022
            if (hx & 0x7FFF_FFFF) | Int32(bitPattern: lx) == 0 { return -.infinity }
            if hx < 0 { return .nan }
            k -= 54
            x *= two54
            hx = high(x)
        }
        if hx >= 0x7FF0_0000 { return x + x }
        k += (hx >> 20) - 1023
        let i = Int32(bitPattern: (UInt32(bitPattern: k) & 0x8000_0000) >> 31)
        hx = (hx & 0x000F_FFFF) | ((0x3FF - i) << 20)
        let y = Double(k + i)
        x = withHigh(x, hx)
        let z = y * log10_2lo + ivln10 * log(x)
        return z + y * log10_2hi
    }

    // MARK: exp (e_exp.c)

    private static let huge = 1.0e+300
    private static let twom1000 = Double(bitPattern: 0x0170_0000_0000_0000)
    private static let oThreshold = Double(bitPattern: 0x4086_2E42_FEFA_39EF)
    private static let uThreshold = Double(bitPattern: 0xC087_4910_D52D_3051)
    private static let invln2 = Double(bitPattern: 0x3FF7_1547_652B_82FE)
    private static let p1 = Double(bitPattern: 0x3FC5_5555_5555_553E)
    private static let p2 = Double(bitPattern: 0xBF66_C16C_16BE_BD93)
    private static let p3 = Double(bitPattern: 0x3F11_566A_AF25_DE2C)
    private static let p4 = Double(bitPattern: 0xBEBB_BD41_C5D2_6BF1)
    private static let p5 = Double(bitPattern: 0x3E66_3769_72BE_A4D0)

    /// `StrictMath.exp(x)`.
    static func exp(_ value: Double) -> Double {
        var x = value
        var hx = UInt32(truncatingIfNeeded: x.bitPattern >> 32)
        let negative = hx >> 31 == 1
        hx &= 0x7FFF_FFFF  // high word of |x|

        // Non-finite and out-of-range arguments.
        if hx >= 0x4086_2E42 {  // |x| >= 709.78...
            if hx >= 0x7FF0_0000 {
                if (hx & 0xF_FFFF) | low(x) != 0 { return x + x }  // NaN
                return negative ? 0 : x  // exp(±inf) = inf, 0
            }
            if x > oThreshold { return huge * huge }  // overflow
            if x < uThreshold { return twom1000 * twom1000 }  // underflow
        }

        // Argument reduction.
        var hi = 0.0, lo = 0.0
        var k: Int32 = 0
        if hx > 0x3FD6_2E42 {  // |x| > 0.5 ln2
            if hx < 0x3FF0_A2B2 {  // and |x| < 1.5 ln2
                hi = negative ? x + ln2Hi : x - ln2Hi
                lo = negative ? -ln2Lo : ln2Lo
                k = negative ? -1 : 1
            } else {
                k = JavaNumerics.int32(invln2 * x + (negative ? -0.5 : 0.5))
                let t = Double(k)
                hi = x - t * ln2Hi  // t * ln2Hi is exact here
                lo = t * ln2Lo
            }
            x = hi - lo
        } else if hx < 0x3E30_0000 {  // |x| < 2^-28
            if huge + x > 1.0 { return 1.0 + x }
        }

        // x is now in the primary range.
        let t = x * x
        let c = x - t * (p1 + t * (p2 + t * (p3 + t * (p4 + t * p5))))
        if k == 0 { return 1.0 - ((x * c) / (c - 2.0) - x) }
        let y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi)
        if k >= -1021 {
            return withHigh(y, high(y) &+ (k << 20))  // add k to y's exponent
        }
        return withHigh(y, high(y) &+ ((k + 1000) << 20)) * twom1000
    }
}
