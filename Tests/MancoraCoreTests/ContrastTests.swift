import Testing

@testable import MancoraCore

/// Bit-for-bit equality, with any NaN equal to any NaN.
private func same(_ a: Double, _ b: Double) -> Bool {
    a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN)
}

/// ImageJ records "no range" as NaN to NaN; Mancora as `nil`.
private func same(_ range: ClosedRange<Double>?, min: Double, max: Double) -> Bool {
    guard let range else { return min.isNaN && max.isNaN }
    return same(range.lowerBound, min) && same(range.upperBound, max)
}

private func describe(_ range: ClosedRange<Double>?) -> String {
    range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"
}

private func check(
    _ stats: ImageStatistics,
    _ golden: ContrastGolden.Statistics,
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(stats.nBins == golden.nBins, "\(label) nBins", sourceLocation: sourceLocation)
    #expect(same(stats.histMin, golden.histMin.value), "\(label) histMin \(stats.histMin)", sourceLocation: sourceLocation)
    #expect(same(stats.histMax, golden.histMax.value), "\(label) histMax \(stats.histMax)", sourceLocation: sourceLocation)
    #expect(same(stats.binSize, golden.binSize.value), "\(label) binSize \(stats.binSize)", sourceLocation: sourceLocation)
    #expect(stats.pixelCount == golden.pixelCount, "\(label) pixelCount", sourceLocation: sourceLocation)
    #expect(same(stats.min, golden.min.value), "\(label) min \(stats.min)", sourceLocation: sourceLocation)
    #expect(same(stats.max, golden.max.value), "\(label) max \(stats.max)", sourceLocation: sourceLocation)
    #expect(same(stats.mean, golden.mean.value), "\(label) mean \(stats.mean)", sourceLocation: sourceLocation)
    #expect(stats.histogram == golden.histogram, "\(label) histogram", sourceLocation: sourceLocation)
    #expect(
        stats.histogram16.map(ContrastGolden.histogram16Hash) == golden.histogram16Hash,
        "\(label) histogram16",
        sourceLocation: sourceLocation
    )
}

@Suite("Automatic contrast matches ImageJ 1.54p")
struct ContrastGoldenTests {
    @Test func goldenPresent() throws {
        let file = try #require(ContrastGolden.file, "Tests/Fixtures/contrast-golden.json is missing or unreadable")
        #expect(file.imagej == "1.54p")
        #expect(file.saturated.value == ContrastEnhancer.defaultSaturated)
        #expect(file.cases.count >= 39)
        for c in file.cases {
            #expect(c.planeResults.count == c.planes, "\(c.name)")
            #expect(c.planeResults.allSatisfy { $0.auto.count == file.presses }, "\(c.name)")
            #expect((c.stack != nil) == (c.planes > 1), "\(c.name)")
        }
    }

    @Test("Generated pixels match ImageJ's", arguments: ContrastGolden.cases)
    func pixels(_ c: ContrastGolden.Case) {
        #expect(ContrastGolden.pixelHash(ContrastGolden.planes(c)) == c.pixelHash)
    }

    @Test("ImageStatistics matches ImageJ", arguments: ContrastGolden.cases)
    func statistics(_ c: ContrastGolden.Case) throws {
        let stack = try ContrastGolden.stack(c)
        for (k, golden) in c.planeResults.enumerated() {
            check(try ImageStatistics(stack[k]), golden.statistics, "plane \(k)")
        }
        if let golden = c.stack {
            check(try ImageStatistics(stack: stack), golden.statistics, "stack")
        }
    }

    @Test("Enhance Contrast matches ImageJ", arguments: ContrastGolden.cases)
    func enhanceContrast(_ c: ContrastGolden.Case) throws {
        let stack = try ContrastGolden.stack(c)
        for (k, golden) in c.planeResults.enumerated() {
            let range = try ContrastEnhancer.displayRange(for: stack[k])
            if let expected = golden.enhance {
                #expect(same(range, min: expected.min.value, max: expected.max.value), "plane \(k): \(describe(range))")
            } else {
                #expect(range == nil, "plane \(k): ImageJ leaves the range unchanged")
            }
        }
        if let golden = c.stack {
            let range = try ContrastEnhancer.displayRange(forStack: stack)
            // ImageJ applies the stack range to whichever plane is current.
            for (k, expected) in golden.enhance.enumerated() {
                if let expected {
                    #expect(same(range, min: expected.min.value, max: expected.max.value), "plane \(k): \(describe(range))")
                } else {
                    #expect(range == nil, "plane \(k): ImageJ leaves the range unchanged")
                }
            }
        }
    }

    @Test("B&C Auto presses match ImageJ", arguments: ContrastGolden.cases)
    func autoPresses(_ c: ContrastGolden.Case) throws {
        let stack = try ContrastGolden.stack(c)
        for (k, golden) in c.planeResults.enumerated() {
            var state = BrightnessContrast.AutoState()
            for (p, expected) in golden.auto.enumerated() {
                let result = try state.press(stack[k])
                let label = "plane \(k) press \(p + 1)"
                #expect(
                    same(result.displayRange, min: expected.min.value, max: expected.max.value),
                    "\(label): \(describe(result.displayRange))"
                )
                #expect(state.autoThreshold == expected.autoThreshold, "\(label) autoThreshold")
                // ImageJ's reset is the only path that sets autoThreshold to 0.
                #expect(result.didReset == (expected.autoThreshold == 0), "\(label) didReset")
            }
        }
    }
}

@Suite("Automatic contrast rules")
struct ContrastRuleTests {
    /// 1000 pixels, five of each value 0–199: every press finds a range.
    let ramp = Plane.gray8((0..<1000).map { UInt8($0 % 200) })

    @Test func pressCountCyclesAndResets() throws {
        // Twelve values with 1000 pixels each: within the limit (a tenth of
        // all pixels) and above every threshold down to 12000 / 19.
        let plane = Plane.gray8((0..<12000).map { UInt8(($0 % 12) * 20) })
        var state = BrightnessContrast.AutoState()
        #expect(state.autoThreshold == 0)
        var divisors: [Int] = []
        var resets: [Bool] = []
        for _ in 0..<11 {
            let result = try state.press(plane)
            divisors.append(state.autoThreshold)
            resets.append(result.didReset)
            #expect(result.displayRange == (result.didReset ? 0...255 : 0...220))
        }
        // Divisor 9 needs a bin with more than a ninth of the pixels but at
        // most a tenth, so the tenth press always resets.
        #expect(divisors == [5000, 2500, 1250, 625, 312, 156, 78, 39, 19, 0, 5000])
        #expect(resets == (0..<11).map { $0 == 9 })
        state.reset()
        #expect(state == BrightnessContrast.AutoState())
    }

    @Test func constantPlanesReset() throws {
        var state = BrightnessContrast.AutoState()
        #expect(try state.press(ramp) == BrightnessContrast.AutoResult(displayRange: 0...199, didReset: false))
        let result = try state.press(.gray8(Array(repeating: 9, count: 100)))
        #expect(result == BrightnessContrast.AutoResult(displayRange: 0...255, didReset: true))
        #expect(state.autoThreshold == 0)
        #expect(try state.press(.gray16(Array(repeating: 700, count: 100))).displayRange == 700...700)
        #expect(try ContrastEnhancer.displayRange(for: .gray16(Array(repeating: 700, count: 100))) == nil)
    }

    @Test func resetRangeIncludesInfinityButNotNaN() {
        #expect(BrightnessContrast.resetRange(for: .gray8([5, 6])) == 0...255)
        #expect(BrightnessContrast.resetRange(for: .gray16([5, 900, 6])) == 5...900)
        #expect(BrightnessContrast.resetRange(for: .gray32Float([.nan, 2, -.infinity, .nan, 1])) == -.infinity...2)
        #expect(BrightnessContrast.resetRange(for: .gray32Float([.nan, .nan])) == nil)
    }

    @Test func floatHistogramSkipsNonFiniteValues() throws {
        let stats = try ImageStatistics(.gray32Float([.nan, 1, .infinity, 3, -.infinity]))
        #expect(stats.pixelCount == 2)
        #expect(stats.min == 1 && stats.max == 3 && stats.mean == 2)
        #expect(stats.binSize == 2.0 / 256)
        #expect(stats.histogram[0] == 1 && stats.histogram[255] == 1)
    }

    @Test func sixteenBitHistogramUsesTheDataRange() throws {
        let stats = try ImageStatistics(.gray16([1000, 1001, 1255, 1256]))
        #expect(stats.histMin == 1000 && stats.histMax == 1256)
        #expect(stats.binSize == 257.0 / 256)
        #expect(stats.histogram16?.count == 65536)
        #expect(stats.histogram16?[1255] == 1)
        // (int)(255 / binSize) is 254; 256 / binSize lands in the last bin.
        #expect(stats.histogram[0] == 2 && stats.histogram[254] == 1 && stats.histogram[255] == 1)
    }

    @Test func singlePlaneStackMatchesPlane() throws {
        for plane in [Plane.gray8([3, 9, 200]), .gray16([3, 9, 60000]), .gray32Float([0.5, .nan, -7])] {
            let stack = try ImageStack(width: 3, height: 1, planes: [plane])
            #expect(try ImageStatistics(stack: stack) == ImageStatistics(plane))
        }
    }

    @Test func emptyPlanesDoNotTrap() throws {
        #expect(try ContrastEnhancer.displayRange(for: .gray8([])) == nil)
        #expect(try ContrastEnhancer.displayRange(for: .gray16([])) == nil)
        #expect(try ContrastEnhancer.displayRange(for: .gray32Float([])) == nil)
        var state = BrightnessContrast.AutoState()
        #expect(try state.press(.gray8([])) == BrightnessContrast.AutoResult(displayRange: 0...255, didReset: true))
        #expect(try state.press(.gray16([])) == BrightnessContrast.AutoResult(displayRange: nil, didReset: true))
    }

    @Test func saturatedPixelCountRoundsDown() {
        // (int)(1000 * 0.35 / 200) = 1: a single pixel in an end bin is saturated, two are not.
        var histogram = [Int](repeating: 0, count: 256)
        histogram[0] = 1
        histogram[1] = 2
        histogram[100] = 994
        histogram[254] = 2
        histogram[255] = 1
        let bins = ContrastEnhancer.saturatedBins(histogram, pixelCount: 1000, saturated: 0.35)
        #expect(bins.lower == 1 && bins.upper == 254)
        let none = ContrastEnhancer.saturatedBins(histogram, pixelCount: 1000, saturated: 0)
        #expect(none.lower == 0 && none.upper == 255)
    }

    @Test func rgbIsNotSupported() {
        let plane = Plane.rgb8([0xFF10_2030])
        #expect(throws: ImageStatistics.Error.unsupportedPixelType(.rgb8)) {
            try ContrastEnhancer.displayRange(for: plane)
        }
        var state = BrightnessContrast.AutoState()
        _ = try? state.press(ramp)
        let before = state
        #expect(before.autoThreshold == 5000)
        #expect(throws: ImageStatistics.Error.unsupportedPixelType(.rgb8)) { try state.press(plane) }
        #expect(state == before)
    }
}

@Suite("Java rounding")
struct JavaRoundTests {
    static let cases: [(Double, Int64)] = [
        (2.5, 3), (-2.5, -2), (-0.5, 0), (-0.50000000000000011, -1), (0.49999999999999994, 0),
        (-0.3, 0), (1e-300, 0), (4_503_599_627_370_497, 4_503_599_627_370_497), (-1.5, -1), (.nan, 0),
        (.infinity, .max), (-.infinity, .min), (1e19, .max), (-1e19, .min),
    ]

    @Test("Math.round", arguments: cases)
    func mathRound(_ value: Double, _ expected: Int64) {
        #expect(JavaNumerics.round(value) == expected)
    }

    @Test func intRoundKeepsLow32Bits() {
        #expect(JavaNumerics.roundToInt32(65535.5) == 65536)
        #expect(JavaNumerics.roundToInt32(4294967297) == 1)
    }
}
