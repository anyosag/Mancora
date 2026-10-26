import MancoraCore
import Testing

@testable import MancoraProcess

/// Profiles and histograms of images small enough to check by hand.
/// (MancoraParityTests compares `getProfile` and `getHistogram` with ImageJ.)
@Suite("Profiles and histograms")
struct ProfileHistogramTests {
    /// 10×5, each pixel x + 10y: a plane bilinear interpolation reproduces exactly.
    static let ramp = Plane.gray16((0..<50).map { UInt16($0 % 10 + 10 * ($0 / 10)) })

    static func profile(_ roi: Roi, _ calibration: Calibration = Calibration(), _ options: ProfilePlot.Options = .init()) throws
        -> ProfileData
    {
        try ProfilePlot.profile(of: ramp, width: 10, roi: roi, calibration: calibration, options: options)
    }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, width: Float = 0) -> Roi {
        Roi(.line(Roi.Line(x1: x1, y1: y1, x2: x2, y2: y2)), strokeWidth: width)
    }

    static func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 1e-9) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // MARK: Profiles

    @Test func straightLinesSampleEveryPixel() throws {
        let data = try Self.profile(Self.line(1, 2, 8, 2))
        #expect(data.yValues == [21, 22, 23, 24, 25, 26, 27, 28])
        #expect(data.xValues == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(data.xLabel == "Distance (pixels)")
        #expect(data.yLabel == "Gray Value")
        // A 3-4-5 diagonal: round(length) + 1 samples, interpolated or nearest.
        let diagonal = try Self.profile(Self.line(0, 0, 3, 4))
        #expect(Self.close(diagonal.yValues, [0, 8.6, 17.2, 25.8, 34.4, 43]))
        let nearest = try Self.profile(Self.line(0, 0, 3, 4), Calibration(), .init(interpolate: false))
        #expect(nearest.yValues == [0, 11, 21, 22, 32, 43])
    }

    @Test func distancesAreCalibrated() throws {
        var calibration = Calibration()
        calibration.pixelWidth = 0.5
        calibration.pixelHeight = 0.5
        calibration.unit = "micron"
        calibration.valueUnit = "OD"
        let data = try Self.profile(Self.line(1, 2, 4, 2), calibration)
        #expect(data.xValues == [0, 0.5, 1, 1.5])
        #expect(data.xLabel == "Distance (microns)")
        #expect(data.yLabel == "OD")
        // Non-square pixels: the calibrated length over the samples.
        calibration.pixelHeight = 0.25
        let diagonal = try Self.profile(Self.line(0, 0, 3, 4), calibration)
        let step = (1.5 * 1.5 + 1.0 * 1.0).squareRoot() / 5
        #expect(diagonal.xValues[1] == Double(Float(step)))
        #expect(diagonal.xValues[5] == Double(Float(5 * step)))
    }

    @Test func valueCalibrationAndRGB() throws {
        var calibration = Calibration()
        calibration.valueFunction = .straightLine(intercept: 1, slope: 0.5)
        let data = try Self.profile(Self.line(1, 2, 3, 2), calibration)
        #expect(data.yValues == [11.5, 12, 12.5])
        // RGB pixels are their luminance (r + g + b) / 3, as a float.
        let rgb = Plane.rgb8([0xFF30_6090, 0xFF00_0002, 0xFF01_0000, 0xFFFF_FFFF])
        let values = try ProfilePlot.profile(of: rgb, width: 4, roi: Self.line(0, 0, 3, 0), calibration: calibration).yValues
        #expect(values == [96, Double(Float(2.0 / 3.0)), Double(Float(1.0 / 3.0)), 255])
    }

    @Test func rectanglesAverageColumnsOrRows() throws {
        let rect = Roi(.rectangle(.integer(x: 1, y: 1, width: 3, height: 2)))
        #expect(try Self.profile(rect).yValues == [16, 17, 18])
        var calibration = Calibration()
        calibration.pixelHeight = 2
        let rows = try Self.profile(rect, calibration, .init(vertical: true))
        #expect(rows.yValues == [12, 22])
        #expect(rows.xValues == [0, 2])
        // Columns outside the image have no pixels to average.
        let edge = try Self.profile(Roi(.rectangle(.integer(x: 8, y: 3, width: 4, height: 4))))
        #expect(edge.yValues.count == 4)
        #expect(edge.yValues[0] == 43 && edge.yValues[1] == 44)
        #expect(edge.yValues[2].isNaN && edge.yValues[3].isNaN)
        // Angles use their bounds.
        let angle = Roi(.polygon(.init(.angle, .integer([.init(x: 1, y: 2), .init(x: 3, y: 1), .init(x: 5, y: 2)]))))
        #expect(try Self.profile(angle).yValues == [16, 17, 18, 19, 20])
    }

    @Test func wideLinesAverageAcrossTheLine() throws {
        // Across a horizontal line the ramp is linear, so the mean is the center value.
        let wide = try Self.profile(Self.line(2, 2, 7, 2, width: 3))
        #expect(Self.close(wide.yValues, [22, 23, 24, 25, 26, 27], 1e-4))
        let uniform = Plane.gray8([UInt8](repeating: 7, count: 100))
        let values = try ProfilePlot.profile(
            of: uniform, width: 10, roi: Self.line(1, 1, 8, 7, width: 4), calibration: Calibration()
        ).yValues
        #expect(values.count == Int((49.0 + 36).squareRoot().rounded()) + 1)
        #expect(values.allSatisfy { abs($0 - 7) < 1e-6 })
        // A rotated rectangle is the wide line along its axis.
        let rotated = Roi(.polygon(.rotatedRectangle(x1: 2, y1: 2, x2: 7, y2: 2, width: 3)))
        #expect(Self.close(try Self.profile(rotated).yValues, wide.yValues, 1e-4))
    }

    @Test func polylinesStepAlongTheirSegments() throws {
        let points: [Roi.IntPoint] = [.init(x: 1, y: 1), .init(x: 5, y: 1), .init(x: 5, y: 4)]
        let polyline = Roi(.polygon(.init(.polyline, .integer(points))))
        // A value about every pixel, the last vertex not included.
        #expect(Self.close(try Self.profile(polyline).yValues, [11, 12, 13, 14, 15, 25, 35], 1e-6))
        var wide = polyline
        wide.strokeWidth = 3
        let values = try Self.profile(wide).yValues
        // A spline through the vertices, in one-pixel steps: it cuts the corner.
        #expect((6...8).contains(values.count))
        #expect(abs(values[0] - 11) < 1e-3)
    }

    @Test func otherSelectionsHaveNoProfile() throws {
        #expect(throws: ProfileError.lineOrRectangleRequired) {
            try Self.profile(Roi(.oval(.integer(x: 1, y: 1, width: 4, height: 3))))
        }
        #expect(throws: ProfileError.lineOrRectangleRequired) {
            try Self.profile(Roi(.points(.init(.integer([.init(x: 1, y: 1)])))))
        }
        let vertices = Roi.Vertices.integer([.init(x: 1, y: 1), .init(x: 5, y: 3), .init(x: 8, y: 1)])
        let spline = Roi(.polygon(.init(.polyline, vertices, splineFit: true)))
        #expect(throws: ProfileError.splineFit) { try Self.profile(spline) }
    }

    // MARK: Histograms

    @Test func eightBitHistogramsHaveABinPerValue() {
        let data = HistogramData(plane: .gray8([0, 1, 2, 3, 4, 5, 6, 7]), width: 4)
        #expect(data.bins == 256 && data.counts.count == 256 && data.binWidth == 1)
        #expect(data.counts[0..<8].allSatisfy { $0 == 1 } && data.counts[8...].allSatisfy { $0 == 0 })
        #expect(data.count == 8 && data.mean == 3.5)
        #expect(abs(data.stdDev - 2.449489742783178) < 1e-12)
        #expect(data.min == 0 && data.max == 7)
        #expect(data.mode == 0 && data.modeCount == 1 && data.isMultimodal)
        #expect(data.histMin == 0 && data.histMax == 255 && data.binStart == 0 && data.binEnd == 255)
        #expect(data.binStarts[5] == 5)
        #expect(!data.showsBins)
    }

    @Test func rgbHistogramsRoundTheLuminance() {
        let data = HistogramData(plane: .rgb8([0xFF00_0002, 0xFF00_0102, 0xFF30_6090]), width: 3)
        #expect(data.counts[1] == 2)  // 2/3 and 3/3 both round to 1
        #expect(data.counts[96] == 1)
    }

    @Test func sixteenBitBinsSpanTheRange() {
        let plane = Plane.gray16([100, 101, 102, 110])
        let data = HistogramData(plane: plane, width: 4, bins: 4)
        #expect(data.histMin == 100 && data.histMax == 110 && data.binWidth == 2.75)  // (110 - 100 + 1) / 4
        #expect(data.counts == [3, 0, 0, 1])
        #expect(data.mean == 103.25 && data.min == 100 && data.max == 110)
        #expect(data.mode == 100 && data.modeCount == 3)  // the commonest value, the fullest bin's count
        #expect(data.showsBins)
        // Only values in the range count, but min and max are every pixel's.
        let ranged = HistogramData(plane: plane, width: 4, bins: 4, histMin: 101, histMax: 105)
        #expect(ranged.count == 2 && ranged.mean == 101.5 && ranged.binWidth == 1.25)
        #expect(ranged.counts == [2, 0, 0, 0])  // bins 1.25 wide from 101
        #expect(ranged.min == 100 && ranged.max == 110)
        // A range that runs backwards is ignored.
        #expect(HistogramData(plane: plane, width: 4, bins: 4, histMin: 105, histMax: 101) == data)
    }

    @Test func calibratedHistograms() {
        var calibration = Calibration()
        calibration.valueFunction = .straightLine(intercept: 10, slope: 2)
        let data = HistogramData(plane: .gray16([0, 1, 2, 3]), width: 4, calibration: calibration)
        #expect(data.mean == 13 && data.min == 10 && data.max == 16 && data.mode == 10)
        #expect(data.binStart == 10 && data.binEnd == 16 && data.binStarts[0] == 10)
        // A 16-bit range is in calibrated values.
        let ranged = HistogramData(
            plane: .gray16([0, 1, 2, 3]), width: 4, calibration: calibration, bins: 2, histMin: 12, histMax: 14)
        #expect(ranged.histMin == 1 && ranged.histMax == 2 && ranged.count == 2)
    }

    @Test func floatBinsAndClippedRange() {
        let plane = Plane.gray32Float([-1, 0.5, .nan, 2])
        let data = HistogramData(plane: plane, width: 2, bins: 3)
        #expect(data.histMin == -1 && data.histMax == 2 && data.binWidth == 1)
        #expect(data.counts == [1, 1, 1] && data.count == 3 && data.mean == 0.5)
        #expect(data.mode == -1 && data.modeCount == 1)  // a bin's start when bins are one wide
        let ranged = HistogramData(plane: plane, width: 2, bins: 4, histMin: 0, histMax: 1)
        #expect(ranged.counts == [0, 0, 1, 0] && ranged.count == 1)
        #expect(ranged.min == 0 && ranged.max == 1)  // clipped to the range
        #expect(ranged.mode == 0.625)  // the middle of the fullest bin
    }

    @Test func defaultHistogramsMatchMeasurements() {
        var random = UInt64(12345)
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random >> 33
        }
        let planes: [Plane] = [
            .gray8((0..<400).map { _ in UInt8(next() % 200) }),
            .gray16((0..<400).map { _ in UInt16(1000 + next() % 3000) }),
            .gray32Float((0..<400).map { _ in Float(next() % 10000) / 997 - 3 }),
            .rgb8((0..<400).map { _ in 0xFF00_0000 | UInt32(next() & 0xFF_FFFF) }),
        ]
        let region = MeasurementRegion(x: 2, y: 3, width: 11, height: 9)
        for plane in planes {
            let data = HistogramData(plane: plane, width: 20, region: region)
            let stats = MeasurementStatistics(
                plane: plane, width: 20, region: region, options: [.area, .mean, .standardDeviation, .minMax, .mode])
            #expect(data.count == stats.pixelCount)
            #expect(data.mean == stats.mean && data.stdDev == stats.standardDeviation)
            #expect(data.min == stats.min && data.max == stats.max)
            if case .gray32Float = plane { #expect(data.mode == stats.mode) }
        }
    }
}
