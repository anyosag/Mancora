/// SHA-256 and SHA-1 digests in pure Swift, so checksum verification works
/// the same on every platform without CryptoKit or OpenSSL.
///
/// SHA-256 verifies Mancora's own downloads (`SHA256SUMS.txt`); SHA-1 is what
/// Fiji update sites record for each file.
public struct SHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        var i = 0
        // Top up a partial block, then hash whole blocks straight from the input.
        while !buffer.isEmpty, i < bytes.count {
            buffer.append(bytes[i])
            i += 1
            if buffer.count == 64 {
                compress(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - i >= 64 {
            compress(bytes[i..<(i + 64)])
            i += 64
        }
        buffer.append(contentsOf: bytes[i...])
        length &+= UInt64(bytes.count)
    }

    public consuming func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var i = 0
        while i < tail.count {
            compress(tail[i..<(i + 64)])
            i += 64
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) } }
    }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h = SHA256()
        h.update(bytes)
        return h.finalize()
    }

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    private mutating func compress<Block: RandomAccessCollection>(_ block: Block) where Block.Element == UInt8, Block.Index == Int {
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for t in 0..<16 {
            let j = base + 4 * t
            w[t] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for t in 16..<64 {
            let s0 = w[t - 15].rotatedRight(7) ^ w[t - 15].rotatedRight(18) ^ (w[t - 15] >> 3)
            let s1 = w[t - 2].rotatedRight(17) ^ w[t - 2].rotatedRight(19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for t in 0..<64 {
            let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[t] &+ w[t]
            let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

public struct SHA1: Sendable {
    private var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        var i = 0
        while !buffer.isEmpty, i < bytes.count {
            buffer.append(bytes[i])
            i += 1
            if buffer.count == 64 {
                compress(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - i >= 64 {
            compress(bytes[i..<(i + 64)])
            i += 64
        }
        buffer.append(contentsOf: bytes[i...])
        length &+= UInt64(bytes.count)
    }

    public consuming func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var i = 0
        while i < tail.count {
            compress(tail[i..<(i + 64)])
            i += 64
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) } }
    }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h = SHA1()
        h.update(bytes)
        return h.finalize()
    }

    private mutating func compress<Block: RandomAccessCollection>(_ block: Block) where Block.Element == UInt8, Block.Index == Int {
        var w = [UInt32](repeating: 0, count: 80)
        let base = block.startIndex
        for t in 0..<16 {
            let j = base + 4 * t
            w[t] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for t in 16..<80 { w[t] = (w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]).rotatedLeft(1) }
        var (a, b, c, d, e) = (state[0], state[1], state[2], state[3], state[4])
        for t in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch t {
            case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
            case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
            case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
            default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
            }
            let temp = a.rotatedLeft(5) &+ f &+ e &+ k &+ w[t]
            (e, d, c, b, a) = (d, c, b.rotatedLeft(30), a, temp)
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e
    }
}

/// Lowercase hexadecimal, as `sha256sum` and Fiji's `db.xml.gz` print digests.
public func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var s = ""
    s.reserveCapacity(bytes.count * 2)
    for b in bytes {
        s.append(digits[Int(b >> 4)])
        s.append(digits[Int(b & 0x0F)])
    }
    return s
}

extension UInt32 {
    @inline(__always) fileprivate func rotatedRight(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
    @inline(__always) fileprivate func rotatedLeft(_ n: UInt32) -> UInt32 { (self << n) | (self >> (32 - n)) }
}
