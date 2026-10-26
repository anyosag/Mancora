import Foundation
import MancoraCore
import Testing

/// Golden data that ImageJ 1.54p computed (`Tools/fixtures/ConvertFixtures.java`):
/// each case describes its input images as formulas, the operation and its
/// parameters, and every output's pixel hash, type, dimensions, display
/// ranges, LUTs, calibration, labels and a few sample pixels.
enum ProcessGolden {
    struct File: Decodable {
        let imagej: String
        let cases: [Case]
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let op: String
        let inputs: [Input]
        let params: Params
        let outputs: [Output]?
        let error: Bool?

        var testDescription: String { id }
    }

    struct Input: Decodable, Sendable {
        let pattern: String
        let width: Int?
        let height: Int?
        let channels: Int?
        let slices: Int?
        let frames: Int?
        let offset: Int?
        let display: [[Double]]
        let luts: [String]
        let mode: String?
        let active: String?
        let calibration: String?
        let function: [Double]?
        let valueUnit: String?
    }

    struct Params: Decodable, Sendable {
        let to: String?
        let scale: Bool?
        let weighted: Bool?
        let method: String?
        let start: Int?
        let stop: Int?
        let allFrames: Bool?
        let frame: Int?
        let operation: String?
        let value: Double?
        let binary: String?
        let lower: Double?
        let upper: Double?
        let float: Bool?
        let slots: [Int]?
        let ignoreLUTs: Bool?
        let composite: Bool?
        let slices: String?
        let channelList: String?
        let sliceList: String?
        let frameList: String?
        let keepChannels: Bool?
        let keepSlices: Bool?
        let keepFrames: Bool?
        let channel: Int?
        let slice: Int?
        let order: [Int]?
    }

    struct Output: Decodable, Sendable {
        let type: String
        let width: Int?
        let height: Int?
        let channels: Int?
        let slices: Int?
        let frames: Int?
        let sha256: String
        let display: [[Double]]
        let luts: [String]?
        let mode: String?
        let active: String?
        let function: [Double]?
        let valueUnit: String?
        let pixelWidth: Double?
        let unit: String?
        let labels: [String?]?
        let samples: [[Double]]
    }

    static func load(_ name: String) -> File? {
        guard let data = try? ProcessFixtures.data("Tests/Fixtures/process/\(name).json") else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try? decoder.decode(File.self, from: data)
    }

    static let convert = load("convert")
    static let zproject = load("zproject")
    static let math = load("math")
    static let hyperstack = load("hyperstack")

    static func cases(_ file: File?, op: String? = nil) -> [Case] {
        (file?.cases ?? []).filter { op == nil || $0.op == op }
    }

    // MARK: Inputs (the formulas in ConvertFixtures.java)

    static let defaultWidth = 37, defaultHeight = 23

    static func plane(_ pattern: String, k: Int, width w: Int, height h: Int) -> Plane {
        let n = w * h
        switch pattern {
        case "gray8":
            var p = [UInt8](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    p[i] = i == 0 ? 0 : i == 1 ? 255 : UInt8((x * 7 + y * 13 + k * 29) & 255)
                }
            }
            return .gray8(p)
        case "gray16", "gray16n":
            var p = [UInt16](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let v: Int
                    if pattern == "gray16n" {
                        v = 100 + (x * 37 + y * 101 + k * 211) % 3000
                    } else {
                        switch i {
                        case 0: v = 0
                        case 1: v = 65535
                        case 2: v = 1
                        case 3: v = 32768
                        default: v = (x * 1789 + y * 2903 + k * 4099 + 17) & 0xFFFF
                        }
                    }
                    p[i] = UInt16(v)
                }
            }
            return .gray16(p)
        case "gray32", "gray32s":
            let specials: [Float] = [
                .nan, .infinity, -.infinity, -0.0, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                .leastNonzeroMagnitude, 0.5, 1.5, 2.5, -0.5, -1.5, 255.5, 65535.5, 1e10, -1e10, 254.5, 65534.5, 256,
                -256,
            ]
            var p = [Float](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    var v = Float((x * 37 + y * 101 + k * 211) % 2000 - 700) * Float(0.37)
                    if pattern == "gray32s" {
                        if i < specials.count { v = specials[i] } else if i == 20 + k % 10 { v = .nan }
                    }
                    p[i] = v
                }
            }
            return .gray32Float(p)
        case "rgb":
            var p = [UInt32](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let r = UInt32((x * 8 + k * 20) & 255), g = UInt32((y * 11 + k * 7) & 255)
                    let b = UInt32((x * 3 + y * 5 + k * 13) & 255)
                    p[i] = i == 0 ? 0xFF00_0000 : i == 1 ? 0xFFFF_FFFF : 0xFF00_0000 | r << 16 | g << 8 | b
                }
            }
            return .rgb8(p)
        default:
            preconditionFailure("unknown pattern \(pattern)")
        }
    }

    static let stripes: LUT = {
        let r = (0..<256).map { UInt8(truncatingIfNeeded: $0 * 67) }
        let g = (0..<256).map { UInt8(truncatingIfNeeded: $0 * 151) }
        let b = (0..<256).map { UInt8(truncatingIfNeeded: $0 * 37) }
        return try! LUT(name: "Stripes", reds: r, greens: g, blues: b)
    }()

    static func lut(_ name: String) -> LUT {
        let inverted = name.hasSuffix("-inv")
        let base = inverted ? String(name.dropLast(4)) : name
        let lut = base == "Stripes" ? stripes : LUT.builtIn(named: base)!
        return inverted ? lut.inverted() : lut
    }

    static func image(_ spec: Input) throws -> Hyperstack {
        let w = spec.width ?? defaultWidth, h = spec.height ?? defaultHeight
        let dims = HyperstackDimensions(channels: spec.channels ?? 1, slices: spec.slices ?? 1, frames: spec.frames ?? 1)
        let n = dims.planeCount!
        let planes = (0..<n).map { plane(spec.pattern, k: $0 + (spec.offset ?? 0), width: w, height: h) }
        let stack = try ImageStack(width: w, height: h, planes: planes, labels: (0..<n).map { "p\($0)" })
        var cal = Calibration()
        cal.pixelWidth = 0.5
        cal.pixelHeight = 0.75
        cal.pixelDepth = 2
        cal.unit = "µm"
        cal.frameInterval = 3
        switch spec.calibration {
        case "signed":
            cal.valueFunction = .straightLine(intercept: -32768, slope: 1)
        case "function":
            cal.valueFunction = .straightLine(intercept: spec.function![0], slope: spec.function![1])
            cal.valueUnit = spec.valueUnit ?? "Gray Value"
        default:
            break
        }
        let active = spec.active.map { Array($0) }
        let channels = (0..<dims.channels).map { c in
            ChannelDisplay(
                lut: lut(spec.luts[c]), displayRange: spec.display[c][0]...spec.display[c][1],
                isVisible: active.map { c < $0.count && $0[c] == "1" } ?? true)
        }
        let mode = spec.mode.flatMap(CompositeMode.init(rawValue:)) ?? .color
        return try Hyperstack(
            title: "in", stack: stack, dimensions: dims, calibration: cal, channels: channels, compositeMode: mode)
    }

    // MARK: Hashes

    /// The pixel bytes ConvertFixtures.java hashes: 8-bit as is, 16-bit
    /// little-endian, 32-bit IEEE bits little-endian with NaN as 0x7fc00000,
    /// RGB as R, G, B.
    static func pixelBytes(_ stack: ImageStack) -> [UInt8] {
        var out: [UInt8] = []
        for plane in stack.planes {
            switch plane {
            case .gray8(let p):
                out.append(contentsOf: p)
            case .gray16(let p):
                for v in p {
                    out.append(UInt8(v & 0xFF))
                    out.append(UInt8(v >> 8))
                }
            case .gray32Float(let p):
                for v in p {
                    let bits = v.isNaN ? 0x7FC0_0000 : v.bitPattern
                    for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: bits >> (8 * k))) }
                }
            case .rgb8(let p):
                for c in p {
                    out.append(UInt8(truncatingIfNeeded: c >> 16))
                    out.append(UInt8(truncatingIfNeeded: c >> 8))
                    out.append(UInt8(truncatingIfNeeded: c))
                }
            }
        }
        return out
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] })
    }

    static func lutHash(_ lut: LUT) -> String {
        String(hex(SHA256.hash(lut.reds + lut.greens + lut.blues)).prefix(16))
    }

    /// One-shot SHA-256 (FIPS 180-4), so the tests need nothing outside the
    /// standard library and Foundation.
    enum SHA256 {
        static func hash(_ message: [UInt8]) -> [UInt8] {
            var h: [UInt32] = [
                0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
            ]
            var data = message
            data.append(0x80)
            while data.count % 64 != 56 { data.append(0) }
            let bits = UInt64(message.count) &* 8
            for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(s))) }
            var w = [UInt32](repeating: 0, count: 64)
            for block in stride(from: 0, to: data.count, by: 64) {
                for t in 0..<16 {
                    let j = block + 4 * t
                    w[t] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
                }
                for t in 16..<64 {
                    let s0 = w[t - 15].rotr(7) ^ w[t - 15].rotr(18) ^ (w[t - 15] >> 3)
                    let s1 = w[t - 2].rotr(17) ^ w[t - 2].rotr(19) ^ (w[t - 2] >> 10)
                    w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                }
                var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
                for t in 0..<64 {
                    let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                    let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
                }
                for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
            }
            return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) } }
        }

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
    }

    // MARK: Comparison

    static func value(_ stack: ImageStack, flat: Int) -> Double {
        let n = stack[0].count
        let plane = stack[flat / n], i = flat % n
        switch plane {
        case .gray8(let p): return Double(p[i])
        case .gray16(let p): return Double(p[i])
        case .gray32Float(let p): return Double(p[i])
        case .rgb8(let p): return Double(p[i] & 0xFF_FFFF)
        }
    }

    static func same(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }

    /// Checks `image` against what ImageJ produced, recording every difference.
    static func check(_ image: Hyperstack, _ expected: Output, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let dims = image.dimensions
        #expect(image.pixelType.rawValue == expected.type, "type", sourceLocation: sourceLocation)
        #expect(image.width == expected.width ?? defaultWidth, sourceLocation: sourceLocation)
        #expect(image.height == expected.height ?? defaultHeight, sourceLocation: sourceLocation)
        #expect(
            [dims.channels, dims.slices, dims.frames] == [expected.channels ?? 1, expected.slices ?? 1, expected.frames ?? 1],
            "dimensions", sourceLocation: sourceLocation)
        guard image.pixelType.rawValue == expected.type, dims.planeCount == image.stack.count else { return }

        let hash = hex(SHA256.hash(pixelBytes(image.stack)))
        if hash != expected.sha256 {
            let total = image.stack.count * image.stack[0].count
            let samples = expected.samples.filter { Int($0[0]) < total }.map { s in
                let actual = value(image.stack, flat: Int(s[0]))
                return "[\(Int(s[0]))] imagej \(s[1]) mancora \(actual)\(same(actual, s[1]) ? "" : " ✗")"
            }
            Issue.record("pixels differ from ImageJ:\n\(samples.joined(separator: "\n"))", sourceLocation: sourceLocation)
        }

        let ranges = image.channels.map { [$0.displayRange.lowerBound, $0.displayRange.upperBound] }
        let expectedRanges = expected.display
        #expect(
            ranges.count == expectedRanges.count && zip(ranges, expectedRanges).allSatisfy { a, b in
                same(a[0], b[0]) && same(a[1], b[1])
            }, "display ranges \(ranges) vs ImageJ \(expectedRanges)", sourceLocation: sourceLocation)
        if let luts = expected.luts {
            #expect(image.channels.map { lutHash($0.lut) } == luts, "LUTs", sourceLocation: sourceLocation)
        }
        if dims.channels > 1, let mode = expected.mode {
            #expect(image.compositeMode.rawValue == mode, "composite mode", sourceLocation: sourceLocation)
            if mode == "composite", let active = expected.active {
                #expect(String(image.channels.map { $0.isVisible ? "1" : "0" }) == active, "active channels", sourceLocation: sourceLocation)
            }
        }
        let function: [Double]? = image.calibration.valueFunction.map {
            switch $0 { case .straightLine(let a, let b): [a, b] }
        }
        #expect(function == expected.function, "value function", sourceLocation: sourceLocation)
        #expect(image.calibration.valueUnit == expected.valueUnit ?? "Gray Value", "value unit", sourceLocation: sourceLocation)
        #expect(image.calibration.pixelWidth == expected.pixelWidth ?? 0.5, "pixel width", sourceLocation: sourceLocation)
        #expect(image.calibration.unit == expected.unit ?? "µm", "unit", sourceLocation: sourceLocation)
        // ImageJ drops the label of a single image when it replaces its processor.
        if image.stack.count > 1 {
            let labels = expected.labels ?? (0..<image.stack.count).map { "p\($0)" }
            #expect(image.stack.labels == labels, "slice labels", sourceLocation: sourceLocation)
        }
    }
}

extension UInt32 {
    fileprivate func rotr(_ n: UInt32) -> UInt32 { self >> n | self << (32 - n) }
}
