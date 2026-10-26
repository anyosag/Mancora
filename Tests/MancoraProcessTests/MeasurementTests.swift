import MancoraCore
import Testing

@testable import MancoraProcess

/// Measurements on images small enough to check by hand. (MancoraParityTests
/// compares every measurement with ImageJ itself.)
@Suite("Measurements")
struct MeasurementTests {
    /// 4×2: 0 1 2 3 / 4 5 6 7.
    static let ramp = Plane.gray8([0, 1, 2, 3, 4, 5, 6, 7])

    @Test func basicStatistics() {
        let stats = MeasurementStatistics(
            plane: Self.ramp, width: 4, options: [.area, .mean, .standardDeviation, .minMax, .median, .centroid])
        #expect(stats.pixelCount == 8)
        #expect(stats.area == 8)
        #expect(stats.mean == 3.5)
        #expect(abs(stats.standardDeviation - 2.449489742783178) < 1e-12)  // sample standard deviation
        #expect(stats.min == 0 && stats.max == 7)
        #expect(stats.median == 4)  // ImageJ: the first value past half the pixels
        #expect(stats.xCentroid == 2 && stats.yCentroid == 1)
    }

    @Test func regionsMasksAndCalibration() {
        var calibration = Calibration()
        calibration.pixelWidth = 0.5
        calibration.pixelHeight = 0.5
        calibration.unit = "µm"
        let region = MeasurementRegion(x: 1, y: 0, width: 2, height: 2, mask: [true, false, true, true])
        let stats = MeasurementStatistics(
            plane: Self.ramp, width: 4, region: region, options: [.area, .mean, .boundingRectangle], calibration: calibration)
        #expect(stats.pixelCount == 3)
        #expect(stats.area == 0.75)
        #expect(stats.mean == 4)  // 1, 5 and 6
        #expect(stats.roiX == 0.5 && stats.roiWidth == 1)
    }

    @Test func floatAndRGB() {
        let float = MeasurementStatistics(plane: .gray32Float([-1, 0.5, .nan, 2]), width: 2, options: [.mean, .minMax, .median])
        #expect(float.pixelCount == 3)  // NaN isn't counted
        #expect(float.mean == 0.5 && float.min == -1 && float.max == 2)
        #expect(float.median == 0.5)
        let rgb = MeasurementStatistics(plane: .rgb8([0xFF30_6090, 0xFF00_0000]), width: 2, options: [.mean])
        #expect(rgb.mean == 48)  // (0x30 + 0x60 + 0x90) / 3 = 96, and 0
    }

    @Test func resultsRowsAndColumns() throws {
        let image = try Hyperstack(title: "ramp.tif", stack: ImageStack(width: 4, height: 2, planes: [Self.ramp]))
        var table = ResultsTable()
        try Analyzer.measure(image, options: [.labels, .minMax, .area, .perimeter, .feret], into: &table)
        try Analyzer.measure(image, options: [.mean], into: &table)
        // ImageJ's column order, whatever order they were filled in.
        #expect(table.columns == ["Area", "Mean", "Min", "Max", "Perim.", "Feret", "FeretX", "FeretY", "FeretAngle", "MinFeret"])
        #expect(table.labels == ["ramp.tif", nil])
        #expect(table.number("Perim.", row: 0) == 12)
        #expect(abs(table.number("Feret", row: 0) - 20.0.squareRoot()) < 1e-12)
        #expect(table.number("MinFeret", row: 0) == 2)
        #expect(table.number("Area", row: 1) == 0)  // never set: 0, as in ImageJ
        table.emptyCellsAreNaN = true
        #expect(table.number("Area", row: 1).isNaN)
    }
}
