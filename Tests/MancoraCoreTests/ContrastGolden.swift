import Foundation
import Testing

@testable import MancoraCore

/// Display ranges recorded by ImageJ 1.54p for Enhance Contrast and the B&C
/// dialog's Auto button; see `Tools/fixtures/ContrastFixtures.java`.
///
/// The JSON holds generator parameters rather than pixels. The generators
/// below must match the Java ones; each case's FNV-1a pixel hash checks that
/// they do.
enum ContrastGolden {
    /// A double written by Java's `Double.toString` as a JSON string, parsed
    /// with Swift's correctly rounded `Double(_:)` so the value is exact on
    /// every platform.
    struct Exact: Decodable, Sendable {
        let value: Double

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let value = Double(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a double: \(text)")
            }
            self.value = value
        }
    }

    struct File: Decodable, Sendable {
        let imagej: String
        let saturated: Exact
        let presses: Int
        let cases: [Case]
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let type: String
        let width: Int
        let height: Int
        let planes: Int
        let generator: Generator
        let pixelHash: String
        let planeResults: [PlaneResult]
        let stack: StackResult?

        var testDescription: String { name }
    }

    struct Generator: Decodable, Sendable {
        let kind: String
        let parameters: [String: Exact]
    }

    struct Statistics: Decodable, Sendable {
        let nBins: Int
        let histMin: Exact
        let histMax: Exact
        let binSize: Exact
        let pixelCount: Int
        let min: Exact
        let max: Exact
        let mean: Exact
        let histogram16Hash: String?
        let histogram: [Int]
    }

    struct Range: Decodable, Sendable {
        let min: Exact
        let max: Exact
    }

    struct Press: Decodable, Sendable {
        let min: Exact
        let max: Exact
        let autoThreshold: Int
    }

    struct PlaneResult: Decodable, Sendable {
        let statistics: Statistics
        let enhance: Range?
        let auto: [Press]
    }

    struct StackResult: Decodable, Sendable {
        let statistics: Statistics
        let enhance: [Range?]
    }

    static let file: File? = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)  // ContrastGolden.swift, MancoraCoreTests, Tests
        let path = parts.joined(separator: "/") + "/Tests/Fixtures/contrast-golden.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var cases: [Case] { file?.cases ?? [] }

    // MARK: Pixel generators (mirroring ContrastFixtures.java)

    /// SplitMix64 with Java's wrapping `long` arithmetic.
    struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ n: Int) -> Int { Int((next() >> 33) % UInt64(n)) }

        mutating func gauss() -> Int { below(65536) + below(65536) + below(65536) + below(65536) - 131070 }
    }

    /// The case's planes, generated as ContrastFixtures.makeStack does.
    static func planes(_ c: Case) -> [Plane] {
        let p = c.generator.parameters
        func int(_ key: String, _ fallback: Int = 0) -> Int { p[key].map { Int($0.value) } ?? fallback }
        func float(_ key: String, _ fallback: Float = 0) -> Float { p[key].map { Float($0.value) } ?? fallback }
        var rng = SplitMix64(state: UInt64(bitPattern: Int64(int("seed"))))
        let n = c.width * c.height

        func intValue(_ x: Int, _ y: Int, _ k: Int) -> Int {
            let dk = int("dk")
            switch c.generator.kind {
            case "linear":
                return int("offset") + x * int("dx") + y * int("dy") + k * dk
            case "noise":
                return int("center") + k * dk + rng.gauss() * int("sigma") / 37837
            case "skewed":
                let u = rng.below(int("n", 1))
                return int("offset") + u * u / int("div", 1)
            case "constant":
                return int("value") + k * dk
            case "twoValues":
                return (y * c.width + x) % int("period", 1) == 0 ? int("b") : int("a")
            case "spots":
                if rng.below(1000) < int("perMille") {
                    return int("spot") + rng.gauss() * int("spotSigma") / 37837
                }
                return int("center") + rng.gauss() * int("sigma") / 37837
            default:
                fatalError("unknown generator \(c.generator.kind)")
            }
        }

        func floatValue(_ x: Int, _ y: Int, _ k: Int) -> Float {
            let dk = float("dk")
            var v: Float
            switch c.generator.kind {
            case "flinear":
                v = Float(x) / float("divx", 1) - Float(y) / float("divy", 1) + Float(k) * dk
            case "fnoise":
                v = Float(rng.gauss()) / 37837 * float("scale", 1) + float("offset") + Float(k) * dk
            case "fskewed":
                let u = rng.below(int("n", 1))
                v = Float(u * u) / float("div", 1)
            case "fconstant":
                v = float("value") + Float(k) * dk
            case "ftwoValues":
                v = (y * c.width + x) % int("period", 1) == 0 ? float("b") : float("a")
            default:
                fatalError("unknown generator \(c.generator.kind)")
            }
            let i = y * c.width + x
            func hits(_ special: String) -> Bool {
                let period = int(special + "Period")
                return period > 0 && i % period == int(special + "Phase")
            }
            if hits("nan") { v = .nan }
            if hits("posInf") { v = .infinity }
            if hits("negInf") { v = -.infinity }
            return v
        }

        func clamped(_ v: Int, _ typeMax: Int) -> Int { max(int("lo"), min(int("hi", typeMax), v)) }

        return (0..<c.planes).map { k in
            switch c.type {
            case "gray8":
                return .gray8((0..<n).map { i in UInt8(clamped(intValue(i % c.width, i / c.width, k), 255)) })
            case "gray16":
                return .gray16((0..<n).map { i in UInt16(clamped(intValue(i % c.width, i / c.width, k), 65535)) })
            default:
                return .gray32Float((0..<n).map { i in floatValue(i % c.width, i / c.width, k) })
            }
        }
    }

    static func stack(_ c: Case) throws -> ImageStack {
        try ImageStack(width: c.width, height: c.height, planes: planes(c))
    }

    // MARK: Hashes (FNV-1a, 64-bit, little-endian values)

    static func fnv(_ hash: inout UInt64, _ value: UInt64, bytes: Int) {
        for b in 0..<bytes {
            hash ^= (value >> (8 * UInt64(b))) & 0xFF
            hash &*= 0x0000_0100_0000_01B3
        }
    }

    static func hex(_ hash: UInt64) -> String {
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    static func pixelHash(_ planes: [Plane]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for plane in planes {
            switch plane {
            case .gray8(let px): for v in px { fnv(&h, UInt64(v), bytes: 1) }
            case .gray16(let px): for v in px { fnv(&h, UInt64(v), bytes: 2) }
            case .gray32Float(let px): for v in px { fnv(&h, UInt64(v.bitPattern), bytes: 4) }
            case .rgb8(let px): for v in px { fnv(&h, UInt64(v), bytes: 4) }
            }
        }
        return hex(h)
    }

    static func histogram16Hash(_ counts: [Int]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<65536 { fnv(&h, UInt64(i < counts.count ? counts[i] : 0), bytes: 4) }
        return hex(h)
    }
}
