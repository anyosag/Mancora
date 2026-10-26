/// MD5 (RFC 1321) in pure Swift, for the macro language's `IJ.checksum`.
/// It is not used to verify anything.
public struct MD5: Sendable {
    private var state: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    /// floor(|sin(i + 1)| × 2³²).
    private static let k: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee, 0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be, 0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa, 0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed, 0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c, 0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05, 0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039, 0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1, 0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        length &+= UInt64(bytes.count)
        var i = 0
        while buffer.count - i >= 64 {
            compress(buffer[i..<(i + 64)])
            i += 64
        }
        buffer.removeFirst(i)
    }

    public consuming func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var i = 0
        while i < tail.count {
            compress(tail[i..<(i + 64)])
            i += 64
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(8 * $0)) } }
    }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h = MD5()
        h.update(bytes)
        return h.finalize()
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var m = [UInt32](repeating: 0, count: 16)
        let base = block.startIndex
        for j in 0..<16 {
            m[j] = UInt32(block[base + 4 * j]) | UInt32(block[base + 4 * j + 1]) << 8
                | UInt32(block[base + 4 * j + 2]) << 16 | UInt32(block[base + 4 * j + 3]) << 24
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }
            f = f &+ a &+ Self.k[i] &+ m[g]
            a = d
            d = c
            c = b
            let s = Self.shifts[i]
            b = b &+ ((f << s) | (f >> (32 - s)))
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
    }
}
