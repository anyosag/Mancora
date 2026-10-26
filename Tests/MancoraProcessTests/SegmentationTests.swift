import Foundation
import MancoraCore
import MancoraProcess
import Testing

/// Background subtraction, maxima and distance maps on images whose answer
/// is known (ImageJ parity is checked by MancoraParityTests).
@Suite("Background, maxima and EDM")
struct SegmentationTests {
    /// Two Gaussian peaks, 100 and 60 high, over a saddle about 30 high.
    static func twoPeaks(width: Int = 40, height: Int = 20) -> [Float] {
        (0..<(width * height)).map { i in
            let x = Double(i % width), y = Double(i / width)
            func peak(_ cx: Double, _ h: Double) -> Double { h * exp(-((x - cx) * (x - cx) + (y - 10) * (y - 10)) / 30) }
            return Float(peak(12, 100) + peak(28, 60))
        }
    }

    @Test func flatImagesHaveThemselvesAsBackground() throws {
        let flat = Plane.gray8([UInt8](repeating: 77, count: 30 * 20))
        for paraboloid in [false, true] {
            var options = BackgroundOptions(radius: 10, useParaboloid: paraboloid)
            #expect(try flat.subtractingBackground(options, width: 30, invertedLUT: false) == .gray8([UInt8](repeating: 0, count: 600)))
            options.createBackground = true
            #expect(try flat.subtractingBackground(options, width: 30, invertedLUT: false) == flat)
        }
        // A light background is subtracted from the maximum.
        let light = BackgroundOptions(radius: 10, lightBackground: true)
        #expect(try flat.subtractingBackground(light, width: 30, invertedLUT: false) == .gray8([UInt8](repeating: 255, count: 600)))
        #expect(try flat.subtractingBackground(light, width: 30, invertedLUT: true) == .gray8([UInt8](repeating: 0, count: 600)))
    }

    @Test func backgroundIsBelowTheData() throws {
        let values = Self.twoPeaks().map { $0 + 20 }
        let plane = Plane.gray32Float(values)
        let options = BackgroundOptions(radius: 5, createBackground: true, presmooth: false)
        guard case .gray32Float(let background) = try plane.subtractingBackground(options, width: 40, invertedLUT: false) else {
            Issue.record("not float")
            return
        }
        #expect(zip(values, background).allSatisfy { $1 <= $0 + 1e-4 })
        #expect(background.min()! >= 19.9)
        // The peaks are higher than the ball, so they aren't background.
        #expect(background[10 * 40 + 12] < values[10 * 40 + 12] - 20)
    }

    @Test func shrinkingNeedsTwoPixels() throws {
        // Radius 50 shrinks by 4: a 4×4 image would become 1×1, a 6×6 one 2×2.
        let tiny = Plane.gray8([UInt8](repeating: 9, count: 4 * 4))
        #expect(throws: BackgroundError.imageTooSmall) {
            try tiny.subtractingBackground(BackgroundOptions(radius: 50), width: 4, invertedLUT: false)
        }
        let small = Plane.gray8([UInt8](repeating: 9, count: 6 * 6))
        #expect(try small.subtractingBackground(BackgroundOptions(radius: 50), width: 6, invertedLUT: false) == .gray8([UInt8](repeating: 0, count: 36)))
    }

    @Test func prominenceDecidesWhichPeaksCount() {
        let values = Self.twoPeaks()
        func count(_ tolerance: Double, strict: Bool = false) -> Int {
            MaximumFinder.find(
                values: values, width: 40, height: 20, isFloat: true, tolerance: tolerance, strict: strict, threshold: nil,
                output: .count, excludeOnEdges: false, isEDM: false
            ).points.count
        }
        #expect(count(10) == 2)
        #expect(count(50) == 1)
        // Strict needs the highest peak to stand out by more than the prominence too.
        #expect(count(150) == 1)
        #expect(count(150, strict: true) == 0)
        let points = MaximumFinder.find(
            values: values, width: 40, height: 20, isFloat: true, tolerance: 10, strict: false, threshold: nil,
            output: .list, excludeOnEdges: false, isEDM: false
        ).points
        #expect(points == [MaximumFinder.Point(x: 12, y: 10), MaximumFinder.Point(x: 28, y: 10)])
    }

    @Test func singlePointsAndSegmentation() throws {
        let values = Self.twoPeaks()
        let single = try #require(
            MaximumFinder.find(
                values: values, width: 40, height: 20, isFloat: true, tolerance: 10, strict: false, threshold: nil,
                output: .singlePoints, excludeOnEdges: false, isEDM: false
            ).image)
        #expect(single.filter { $0 == 255 }.count == 2)
        #expect(single[10 * 40 + 12] == 255 && single[10 * 40 + 28] == 255)
        let segmented = try #require(
            MaximumFinder.find(
                values: values, width: 40, height: 20, isFloat: true, tolerance: 10, strict: false, threshold: nil,
                output: .segmented, excludeOnEdges: false, isEDM: false
            ).image)
        // A line between the two peaks separates their particles.
        #expect(segmented[10 * 40 + 12] == 255 && segmented[10 * 40 + 28] == 255)
        #expect((0..<20).allSatisfy { y in (14..<26).contains { x in segmented[y * 40 + x] == 0 } })
    }

    @Test func distanceMapOfASquare() {
        // A 7×7 square in an 11×11 image.
        let pixels = (0..<121).map { i -> UInt8 in (2...8).contains(i % 11) && (2...8).contains(i / 11) ? 255 : 0 }
        let edm = EDM.floatEDM(pixels, width: 11, height: 11, backgroundValue: 0)
        #expect(edm[5 * 11 + 5] == 4)
        #expect(edm[2 * 11 + 5] == 1)
        #expect(edm[3 * 11 + 3] == 2)
        #expect(edm[0] == 0)
        let result = EDM.run(.distanceMap, on: pixels, width: 11, background255: false, output: .overwrite)
        #expect(result.overwritten?[5 * 11 + 5] == 4)
        #expect(result.displayRange == 0...4)
        let uep = EDM.run(.ultimatePoints, on: pixels, width: 11, background255: false, output: .float)
        guard case .gray32Float(let points)? = uep.output else {
            Issue.record("no float output")
            return
        }
        #expect(points.filter { $0 > 0 } == [4])
    }

    static func inDisc(_ x: Double, _ y: Double, _ cx: Double) -> Bool {
        let dx = x - cx, dy = y - 12
        return dx * dx + dy * dy <= 64
    }

    @Test func watershedCutsTouchingDiscs() throws {
        let width = 40, height = 24
        let pixels = (0..<(width * height)).map { i -> UInt8 in
            let x = Double(i % width), y = Double(i / width)
            return Self.inDisc(x, y, 13) || Self.inDisc(x, y, 26) ? 255 : 0
        }
        let cut = try #require(EDM.run(.watershed, on: pixels, width: width, background255: false, output: .overwrite).overwritten)
        #expect(cut.filter { $0 == 255 }.count < pixels.filter { $0 == 255 }.count)
        #expect(cut[12 * width + 19] == 0 || cut[12 * width + 20] == 0)
        #expect(cut[12 * width + 13] == 255 && cut[12 * width + 26] == 255)
        // With a white background the result is inverted back.
        let inverted = pixels.map { 255 - $0 }
        let white = try #require(EDM.run(.watershed, on: inverted, width: width, background255: true, output: .overwrite).overwritten)
        #expect(white == cut.map { 255 - $0 })
    }

    @Test func selectionsContainPixelsAsImageJTestsThem() {
        let rect = Roi(.rectangle(.integer(x: 2, y: 3, width: 4, height: 2)))
        #expect(rect.containsPixel(x: 2, y: 3) == true)
        #expect(rect.containsPixel(x: 6, y: 3) == false)
        let oval = Roi(.oval(.integer(x: 0, y: 0, width: 10, height: 10)))
        #expect(oval.containsPixel(x: 5, y: 5) == true)
        #expect(oval.containsPixel(x: 0, y: 0) == false)
        let triangle = Roi(.polygon(.init(.polygon, .integer([.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 10)]))))
        #expect(triangle.containsPixel(x: 1, y: 1) == true)
        #expect(triangle.containsPixel(x: 8, y: 8) == false)
        let rounded = Roi(.rectangle(.integer(x: 0, y: 0, width: 10, height: 10), cornerDiameter: 8))
        #expect(rounded.containsPixel(x: 0, y: 0) == false)
        #expect(rounded.containsPixel(x: 5, y: 0) == true)
        let subpixel = Roi(.oval(.subpixel(x: 0.5, y: 0.5, width: 9, height: 9)))
        #expect(subpixel.containsPixel(x: 5, y: 5) == nil)
    }
}
