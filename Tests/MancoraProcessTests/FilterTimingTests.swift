import Foundation
import MancoraCore
import MancoraProcess
import Testing

/// Timings on a 2048×2048 image, for release builds:
///
///     MANCORA_TIMINGS=1 swift test -c release --filter FilterTimings
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MANCORA_TIMINGS"] != nil))
struct FilterTimings {
    static let size = 2048

    static let gray16: Plane = {
        let n = size
        return .gray16((0..<(n * n)).map { i in UInt16(FilterInputs.gray16(i % n, i / n, n, n)) })
    }()

    static let float: Plane = {
        let n = size
        return .gray32Float((0..<(n * n)).map { i in FilterInputs.gray32(i % n, i / n, n, n) })
    }()

    static let rgb: Plane = {
        let n = size
        return .rgb8((0..<(n * n)).map { i in FilterInputs.rgb(i % n, i / n, n, n) })
    }()

    static let kernel5x5 = try! ConvolutionKernel(width: 5, height: 5, values: (0..<25).map { Float($0 % 7) - 2 })

    static let operations: [(String, @Sendable () -> Plane)] = [
        ("16-bit median r=2", { gray16.rankFiltered(.median, radius: 2, width: size) }),
        ("16-bit median r=5", { gray16.rankFiltered(.median, radius: 5, width: size) }),
        ("16-bit mean r=10", { gray16.rankFiltered(.mean, radius: 10, width: size) }),
        ("16-bit maximum r=10", { gray16.rankFiltered(.maximum, radius: 10, width: size) }),
        ("float variance r=3", { float.rankFiltered(.variance, radius: 3, width: size) }),
        ("16-bit Gaussian σ=2", { gray16.gaussianBlurred(sigma: 2, width: size) }),
        ("float Gaussian σ=8", { float.gaussianBlurred(sigma: 8, width: size) }),
        ("float Gaussian σ=30", { float.gaussianBlurred(sigma: 30, width: size) }),
        ("RGB Gaussian σ=2", { rgb.gaussianBlurred(sigma: 2, width: size) }),
        ("16-bit smooth", { gray16.smoothed(width: size) }),
        ("float find edges", { float.findingEdges(width: size) }),
        ("16-bit convolve 5×5", { gray16.convolved(with: kernel5x5, width: size) }),
        ("16-bit resize bilinear 0.6×", { geometry(gray16, .bilinear).resized(width: 1229, height: 1229).plane }),
        ("16-bit resize bicubic averaged 0.37×", {
            geometry(gray16, .bicubic).resized(width: 758, height: 758, averaging: true).plane
        }),
        ("float resize bicubic 1.5×", { geometry(float, .bicubic).resized(width: 3072, height: 3072).plane }),
        ("float rotate bicubic 15°", {
            var ip = geometry(float, .bicubic)
            ip.rotate(degrees: 15)
            return ip.plane
        }),
        ("RGB rotate bilinear 15°", {
            var ip = geometry(rgb, .bilinear)
            ip.rotate(degrees: 15)
            return ip.plane
        }),
        ("16-bit scale bilinear 0.7×", {
            var ip = geometry(gray16, .bilinear)
            ip.scale(x: 0.7, y: 0.7)
            return ip.plane
        }),
        ("16-bit translate bicubic", {
            var ip = geometry(gray16, .bicubic)
            ip.translate(x: 2.5, y: -1.25)
            return ip.plane
        }),
    ]

    static func geometry(_ plane: Plane, _ method: InterpolationMethod) -> GeometryProcessor {
        var ip = GeometryProcessor(plane, width: size)
        ip.interpolation = method
        return ip
    }

    @Test(arguments: operations.indices)
    func timing(_ index: Int) {
        let (name, operation) = Self.operations[index]
        _ = operation()  // warm up, and build the inputs
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        for _ in 0..<3 {
            let start = clock.now
            let result = operation()
            best = min(best, clock.now - start)
            #expect(result.count == Self.size * Self.size)
        }
        print("TIMING \(name): \(best)")
    }
}
