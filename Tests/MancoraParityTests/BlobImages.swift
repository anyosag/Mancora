import Foundation
import MancoraCore
import MancoraIO

/// Synthetic images like ImageJ's "blobs" sample, built from a fixed seed:
/// soft-edged elliptical blobs of different sizes and brightness on an
/// unevenly lit, noisy background, some touching each other or the edge.
/// Their masks have touching pairs for Watershed to cut.
enum BlobImages {
    static let width = 90, height = 72

    struct Blob {
        var x: Double, y: Double, rx: Double, ry: Double, angle: Double, amplitude: Double
        /// For RGB: how much of each channel the blob adds.
        var color: (Double, Double, Double)
    }

    /// The blobs of one image: random ones, a pair that overlaps (a neck for
    /// Watershed), one cut by the left edge and one in a corner.
    static func blobs(seed: UInt64) -> [Blob] {
        var random = SeededRandom(seed: seed)
        func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * random.unit() }
        var out: [Blob] = []
        func color() -> (Double, Double, Double) { (uniform(0.3, 1), uniform(0.2, 1), uniform(0.1, 0.9)) }
        for _ in 0..<11 {
            let r = uniform(3, 7.5)
            out.append(
                Blob(
                    x: uniform(4, Double(width) - 4), y: uniform(4, Double(height) - 4), rx: r, ry: r * uniform(0.6, 1.2),
                    angle: uniform(0, .pi), amplitude: uniform(0.45, 1), color: color()))
        }
        let cx = uniform(25, 60), cy = uniform(20, 50), r = uniform(5, 7)
        out.append(Blob(x: cx, y: cy, rx: r, ry: r, angle: 0, amplitude: 0.85, color: color()))
        out.append(Blob(x: cx + 1.55 * r, y: cy + 0.6 * r, rx: r * 0.9, ry: r * 0.9, angle: 0, amplitude: 0.8, color: color()))
        out.append(Blob(x: 1.5, y: uniform(20, 50), rx: 5, ry: 7, angle: 0.3, amplitude: 0.9, color: color()))
        out.append(Blob(x: Double(width) - 2, y: Double(height) - 3, rx: 6, ry: 5, angle: 0, amplitude: 0.7, color: color()))
        return out
    }

    /// How much of a blob covers a pixel: 1 inside, falling off smoothly
    /// over about a pixel at the edge.
    static func coverage(_ b: Blob, _ x: Double, _ y: Double) -> Double {
        let dx = x - b.x, dy = y - b.y
        let u = dx * cos(b.angle) + dy * sin(b.angle), v = -dx * sin(b.angle) + dy * cos(b.angle)
        let r = ((u / b.rx) * (u / b.rx) + (v / b.ry) * (v / b.ry)).squareRoot()
        return 1 / (1 + exp((r - 1) * 2.2 * min(b.rx, b.ry)))
    }

    /// Background, blobs and noise, about 0 to 1.2. `channel` picks a blob
    /// color component for RGB, or gray when `nil`.
    static func field(seed: UInt64, channel: Int? = nil) -> [Double] {
        let blobs = blobs(seed: seed)
        var noise = SeededRandom(seed: seed &* 7 &+ UInt64(channel ?? 3))
        return (0..<(width * height)).map { i in
            let x = Double(i % width), y = Double(i / width)
            var v = 0.06 + 0.22 * x / Double(width) + 0.1 * sin(y / Double(height) * .pi)
            for b in blobs {
                let weight: Double
                switch channel {
                case 0?: weight = b.color.0
                case 1?: weight = b.color.1
                case 2?: weight = b.color.2
                default: weight = 1
                }
                v += b.amplitude * weight * coverage(b, x, y)
            }
            return v + 0.04 * noise.unit()
        }
    }

    /// The blobs alone, as a 0/255 mask (255 where they cover half a pixel).
    static func mask(seed: UInt64) -> [UInt8] {
        let blobs = blobs(seed: seed)
        return (0..<(width * height)).map { i in
            let x = Double(i % width), y = Double(i / width)
            return blobs.contains { coverage($0, x, y) > 0.5 } ? 255 : 0
        }
    }

    static func gray8(_ f: [Double]) -> Plane { .gray8(f.map { UInt8(clamping: Int($0 * 200 + 8)) }) }
    static func gray16(_ f: [Double]) -> Plane { .gray16(f.map { UInt16(clamping: Int(400 + $0 * 9000)) }) }
    static func gray32(_ f: [Double]) -> Plane { .gray32Float(f.map { Float($0 * 3 - 0.4) }) }

    static func image(for input: ParityInput) throws -> Hyperstack {
        let seed = UInt64(input.rawValue.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) })
        let title = input.rawValue + ".tif"
        var planes: [Plane]
        var lut = LUT.grays
        var calibration = Calibration()
        var labels: [String?]?
        var roi: Roi?
        switch input {
        case .blobs8: planes = [gray8(field(seed: seed))]
        case .blobs16:
            planes = [gray16(field(seed: seed))]
            calibration.pixelWidth = 0.5
            calibration.pixelHeight = 0.5
            calibration.unit = "µm"
        case .blobs32: planes = [gray32(field(seed: seed))]
        case .blobsRGB:
            let channels = (0..<3).map { field(seed: seed, channel: $0) }
            planes = [
                .rgb8((0..<(width * height)).map { i in
                    let c = channels.map { UInt32(clamping: Int($0[i] * 190 + 10)) }
                    return 0xFF00_0000 | c[0] << 16 | c[1] << 8 | c[2]
                })
            ]
        case .blobsLight: planes = [.gray8(field(seed: seed).map { UInt8(clamping: 250 - Int($0 * 200)) })]
        case .blobsInverted:
            // Like blobs.gif: bright blobs in the data, shown dark on light.
            planes = [gray8(field(seed: seed))]
            lut = LUT.grays.inverted()
        case .blobsStack8: planes = (0..<3).map { gray8(field(seed: seed &+ UInt64($0))) }
        case .blobsStack16: planes = (0..<3).map { gray16(field(seed: seed &+ UInt64($0))) }
        case .blobsStack32:
            planes = (0..<3).map { gray32(field(seed: seed &+ UInt64($0))) }
            labels = ["first", nil, "third"]
        case .blobsROI:
            planes = [gray8(field(seed: seed))]
            roi = Roi(.rectangle(.integer(x: 12, y: 9, width: 50, height: 41)))
        case .blobsOvalROI:
            planes = [gray16(field(seed: seed))]
            roi = Roi(.oval(.integer(x: 10, y: 6, width: 62, height: 55)))
        case .blobsMask: planes = [.gray8(mask(seed: seed))]
        case .blobsMaskInverted:
            planes = [.gray8(mask(seed: seed))]
            lut = LUT.grays.inverted()
        case .blobsMaskStack: planes = (0..<3).map { .gray8(mask(seed: seed &+ UInt64($0))) }
        default: preconditionFailure("\(input) isn't a blobs image")
        }
        let stack = try ImageStack(width: width, height: height, planes: planes, labels: labels)
        var channels = Hyperstack.defaultChannels(for: stack, dimensions: HyperstackDimensions(slices: planes.count))
        channels[0].lut = lut
        var image = try Hyperstack(title: title, stack: stack, calibration: calibration, channels: channels)
        image.encodedROI = roi.map(RoiCodec.encode)
        return image
    }
}
