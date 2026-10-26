import MancoraCore
import MancoraProcess
import Testing

/// API behavior that the ImageJ golden data doesn't pin down.
@Suite("Filter behavior")
struct FilterBehaviorTests {
    static let width = 37, height = 23

    static func input(_ name: String) -> Plane {
        FilterInputs.plane(named: "\(name)-\(width)x\(height)")!.plane
    }

    @Test func gaussianDefaultAccuracyDependsOnType() {
        let gray8 = Self.input("gray8"), gray16 = Self.input("gray16"), rgb = Self.input("rgb")
        #expect(gray8.gaussianBlurred(sigma: 3, width: Self.width) == gray8.gaussianBlurred(sigma: 3, accuracy: 0.002, width: Self.width))
        #expect(rgb.gaussianBlurred(sigma: 3, width: Self.width) == rgb.gaussianBlurred(sigma: 3, accuracy: 0.002, width: Self.width))
        #expect(gray16.gaussianBlurred(sigma: 3, width: Self.width) == gray16.gaussianBlurred(sigma: 3, accuracy: 0.0002, width: Self.width))
        #expect(gray16.gaussianBlurred(sigma: 3, width: Self.width) != gray16.gaussianBlurred(sigma: 3, accuracy: 0.002, width: Self.width))
    }

    @Test func zeroSigmaLeavesThePlaneAlone() {
        let plane = Self.input("float")
        #expect(plane.gaussianBlurred(sigma: 0, width: Self.width) == plane)
        #expect(plane.gaussianBlurred(sigmaX: -1, sigmaY: 0, width: Self.width) == plane)
    }

    @Test func despeckleIsMedianOfRadiusOne() {
        let plane = Self.input("gray16")
        #expect(plane.despeckled(width: Self.width) == plane.rankFiltered(.median, radius: 1, width: Self.width))
    }

    @Test func removeNaNsKeepsIntegerPlanes() {
        for name in ["gray8", "gray16", "rgb"] {
            let plane = Self.input(name)
            #expect(plane.rankFiltered(.removeNaNs, radius: 2, width: Self.width) == plane)
        }
    }

    @Test func removeNaNsLeavesNoIsolatedNaN() throws {
        let plane = Self.input("floatSpecial")
        guard case .gray32Float(let before) = plane,
            case .gray32Float(let after) = plane.rankFiltered(.removeNaNs, radius: 2, width: Self.width)
        else { Issue.record("not float"); return }
        #expect(before.contains { $0.isNaN })
        #expect(!after.contains { $0.isNaN })
        for i in before.indices where !before[i].isNaN { #expect(after[i].bitPattern == before[i].bitPattern) }
    }

    @Test func rgbResultsAreOpaque() throws {
        let plane = Self.input("rgb")
        let kernel = try ConvolutionKernel(width: 3, height: 3, values: [1, 1, 1, 1, -7, 1, 1, 1, 1])
        let results = [
            plane.gaussianBlurred(sigma: 1.5, width: Self.width),
            plane.rankFiltered(.variance, radius: 2, width: Self.width),
            plane.smoothed(width: Self.width),
            plane.sharpened(width: Self.width),
            plane.findingEdges(width: Self.width),
            plane.convolved(with: kernel, width: Self.width),
        ]
        for case .rgb8(let pixels) in results { #expect(pixels.allSatisfy { $0 >> 24 == 0xFF }) }
    }

    @Test func threeByThreeFiltersSkipOnePixelWideImages() {
        let plane = FilterInputs.plane(named: "gray16-1x5")!.plane
        #expect(plane.smoothed(width: 1) == plane)
        #expect(plane.sharpened(width: 1) == plane)
        #expect(plane.findingEdges(width: 1) == plane)
    }

    @Test func kernelValidation() {
        #expect(throws: FilterError.invalidKernel(width: 2, height: 3, valueCount: 6)) {
            try ConvolutionKernel(width: 2, height: 3, values: Array(repeating: 1, count: 6))
        }
        #expect(throws: FilterError.invalidKernel(width: 3, height: 3, valueCount: 8)) {
            try ConvolutionKernel(width: 3, height: 3, values: Array(repeating: 1, count: 8))
        }
        #expect(throws: FilterError.invalidKernel(width: 0, height: 1, valueCount: 0)) {
            try ConvolutionKernel(width: 0, height: 1, values: [])
        }
    }

    @Test func normalizationScale() throws {
        #expect(try ConvolutionKernel(width: 3, height: 1, values: [1, 2, 1]).normalizationScale == 0.25)
        #expect(try ConvolutionKernel(width: 3, height: 1, values: [-1, 2, -1]).normalizationScale == 1)
    }

    @Test func identityKernelKeepsPixels() throws {
        let identity = try ConvolutionKernel(width: 3, height: 3, values: [0, 0, 0, 0, 1, 0, 0, 0, 0])
        for name in ["gray8", "gray16", "float", "rgb"] {
            let plane = Self.input(name)
            #expect(plane.convolved(with: identity, width: Self.width) == plane)
        }
    }

    @Test func binaryNeedsEightBitPlanes() {
        let options = BinaryOptions(blackBackground: true)
        #expect(throws: FilterError.unsupportedPixelType(.gray16, expected: .gray8)) {
            try Self.input("gray16").binary(.erode, options: options, width: Self.width)
        }
    }

    /// ImageJ's Outline throws ArrayIndexOutOfBoundsException on a
    /// one-pixel-wide image; Mancora leaves it unchanged (it has no inner
    /// pixels).
    @Test func outlineOfOnePixelWideImage() throws {
        let plane = Plane.gray8([0, 255, 255, 255, 0, 255])
        #expect(try plane.binary(.outline, options: BinaryOptions(blackBackground: true), width: 1) == plane)
    }

    @Test func blackBackgroundSwapsForegroundAndBackground() throws {
        let mask = FilterInputs.plane(named: "binary-37x23")!.plane
        guard case .gray8(let pixels) = mask else { return }
        let inverted = Plane.gray8(pixels.map { 255 - $0 })
        for op in BinaryOperation.allCases {
            let black = try mask.binary(op, options: BinaryOptions(blackBackground: true), width: Self.width)
            let white = try inverted.binary(op, options: BinaryOptions(blackBackground: false), width: Self.width)
            guard case .gray8(let b) = black, case .gray8(let w) = white else { continue }
            #expect(b == w.map { 255 - $0 }, "\(op)")
        }
    }

    @Test func zeroIterationsChangeNothing() throws {
        let mask = FilterInputs.plane(named: "binary-37x23")!.plane
        let options = BinaryOptions(blackBackground: true, iterations: 0)
        #expect(try mask.binary(.erode, options: options, width: Self.width) == mask)
    }

    @Test func fillHolesFillsEnclosedBackground() throws {
        // A 5×5 square ring on a 7×7 background.
        var pixels = [UInt8](repeating: 0, count: 49)
        for i in 1...5 { for j in [1, 5] { pixels[j * 7 + i] = 255; pixels[i * 7 + j] = 255 } }
        let filled = try Plane.gray8(pixels).binary(.fillHoles, options: BinaryOptions(blackBackground: true), width: 7)
        guard case .gray8(let out) = filled else { return }
        for y in 0..<7 {
            for x in 0..<7 { #expect(out[y * 7 + x] == ((1...5).contains(x) && (1...5).contains(y) ? 255 : 0)) }
        }
    }

    @Test func stackFiltersApplyToEveryPlane() throws {
        let planes = ["gray16-37x23", "gray16-37x23"].map { FilterInputs.plane(named: $0)!.plane }
            + [Plane.gray16(Array(repeating: 7, count: Self.width * Self.height))]
        let stack = try ImageStack(width: Self.width, height: Self.height, planes: planes, labels: ["a", nil, "c"])
        let blurred = stack.gaussianBlurred(sigmaX: 2, sigmaY: 1)
        #expect(blurred.labels == ["a", nil, "c"])
        for i in 0..<stack.count {
            #expect(blurred[i] == stack[i].gaussianBlurred(sigmaX: 2, sigmaY: 1, width: Self.width))
            #expect(stack.rankFiltered(.median, radius: 2)[i] == stack[i].rankFiltered(.median, radius: 2, width: Self.width))
            #expect(stack.smoothed()[i] == stack[i].smoothed(width: Self.width))
        }
        #expect(throws: FilterError.unsupportedPixelType(.gray16, expected: .gray8)) {
            try stack.binary(.dilate, options: BinaryOptions(blackBackground: false))
        }
    }
}
