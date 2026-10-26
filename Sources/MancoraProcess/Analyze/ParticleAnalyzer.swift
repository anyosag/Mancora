public import MancoraCore

/// Analyze ▸ Analyze Particles (`ij.plugin.filter.ParticleAnalyzer`):
/// traces each connected area of thresholded pixels with the wand,
/// measures it, and optionally draws it into a mask.
public enum ParticleAnalyzer {
    public struct Options: Sendable, Hashable {
        /// Area limits in pixels.
        public var minSize = 0.0
        public var maxSize = Double.infinity
        public var minCircularity = 0.0
        public var maxCircularity = 1.0
        public var excludeEdges = false
        /// Measure whole outlines, holes included; otherwise only the particle's pixels.
        public var includeHoles = false
        public var fourConnected = false
        /// Add XStart and YStart, a pixel of each particle.
        public var recordStarts = false
        /// Draw the particles into a mask (Show: Masks).
        public var masks = false
        /// Black background: which value of an unthresholded binary image is
        /// the particles (255, or 0 for white backgrounds unless the LUT is inverted).
        public var blackBackground = true

        public init() {}
    }

    public enum Failure: Error, Equatable, Sendable {
        /// No threshold is set and the image isn't binary.
        case noThreshold
        case unsupported(String)
    }

    /// What one plane gave.
    public struct Result: Sendable {
        public var count: Int
        /// The particles as 255 on 0, with Show: Masks.
        public var mask: Plane?
        /// The total area of the analyzed region, calibrated (for Summarize).
        public var totalArea: Double
    }

    /// Analyzes the plane at stack `index` of `image` within `roi` (an area
    /// selection, or the whole plane), adding a row per particle to `table`.
    public static func analyze(
        _ image: Hyperstack, channel: Int, slice: Int, frame: Int, roi: Roi?, threshold: ClosedRange<Double>?,
        measurements: Measurements, options: Options, into table: inout ResultsTable
    ) throws(Failure) -> Result {
        let width = image.width, height = image.height
        let index = image.dimensions.planeIndex(channel: channel, slice: slice, frame: frame)
        let plane = image.stack[index]
        guard plane.pixelType != .rgb8 else { throw .unsupported("RGB images are thresholded with Color Threshold") }
        let isFloat = plane.pixelType == .gray32Float
        var work = (0..<plane.count).map { Float(plane.value(at: $0)) }

        // setThresholdLevels
        let level1: Double, level2: Double, fillColor: Float
        if let threshold {
            (level1, level2) = (threshold.lowerBound, threshold.upperBound)
            switch plane.pixelType {
            case .gray8: fillColor = level1 > 0 ? 0 : level2 < 255 ? 255 : 0
            case .gray16: fillColor = level1 > 0 ? 0 : level2 < 65535 ? 65535 : 0
            default: fillColor = -Float.greatestFiniteMagnitude
            }
        } else {
            guard plane.pixelType == .gray8, work.allSatisfy({ $0 == 0 || $0 == 255 }) else { throw .noThreshold }
            let inverted = image.channels[min(channel, image.channels.count - 1)].lut.isInverted
            if !options.blackBackground && !inverted {
                (level1, level2, fillColor) = (0, 0, 192)
            } else {
                (level1, level2, fillColor) = (255, 255, 64)
            }
        }

        // The analyzed rectangle, and everything outside the selection erased.
        var region = MeasurementRegion(x: 0, y: 0, width: width, height: height)
        if let roi {
            guard roi.isArea else { throw .unsupported("line and point selections") }
            do { region = try roi.measurementRegion(width: width, height: height) } catch {
                throw .unsupported("\(error)")
            }
            if options.excludeEdges, region.mask != nil { throw .unsupported("excluding edges of a non-rectangular selection") }
            for y in 0..<height {
                for x in 0..<width {
                    let inRect = x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
                    if !inRect || !region.contains(x, y) { work[y * width + x] = fillColor }
                }
            }
        }
        let cal = image.calibration
        let totalArea: Double
        if region.mask != nil {
            totalArea = MeasurementStatistics(plane: plane, width: width, region: region, options: .area, calibration: cal).area
        } else {
            totalArea = Double(region.width) * cal.pixelWidth * Double(region.height) * cal.pixelHeight
        }

        var floodValues = options.includeHoles ? [] : work
        var maskPixels: [UInt8]? = options.masks ? Array(repeating: 0, count: plane.count) : nil
        var count = 0
        var done = false
        func inLevels(_ v: Float) -> Bool { Double(v) >= level1 && Double(v) <= level2 }
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) where !done && inLevels(work[y * width + x]) {
                // analyzeParticle
                let outline = Wand.outline(
                    values: work, width: width, x: x, y: y, lower: level1, upper: level2,
                    mode: options.fourConnected ? .fourConnected : .legacy)
                guard !outline.xs.isEmpty else { continue }
                let points = zip(outline.xs, outline.ys).map { Roi.IntPoint(x: $0, y: $1) }
                let particle = Roi(.polygon(.init(.traced, .integer(points))))
                let b = particle.bounds
                var mask: [Bool]?
                if b.width > 1 && b.height > 1 {
                    mask = try? particle.mask().pixels
                    if !options.includeHoles, mask != nil {
                        mask = floodFill(
                            &floodValues, x: x, y: y, width: width, height: height, bounds: b, fill: fillColor,
                            isFloat: isFloat, inside: inLevels)
                    }
                }
                let particleRegion = MeasurementRegion(x: b.x, y: b.y, width: b.width, height: b.height, mask: mask)
                let stats = MeasurementStatistics(
                    plane: plane, width: width, region: particleRegion, options: measurements, calibration: cal,
                    threshold: threshold)
                var include = true
                if options.excludeEdges {
                    if b.x == region.x || b.y == region.y || b.x + b.width == region.x + region.width
                        || b.y + b.height == region.y + region.height
                    {
                        include = false
                    }
                }
                if options.minCircularity > 0 || options.maxCircularity != 1 {
                    let perimeter = particle.length()
                    var circularity = perimeter == 0 ? 0 : 4.0 * Double.pi * (Double(stats.pixelCount) / (perimeter * perimeter))
                    if circularity > 1, options.maxCircularity <= 1 { circularity = 1 }
                    if circularity < options.minCircularity || circularity > options.maxCircularity { include = false }
                }
                if Double(stats.pixelCount) >= options.minSize && Double(stats.pixelCount) <= options.maxSize && include {
                    count += 1
                    Analyzer.saveResults(
                        stats, image: image, channel: channel, slice: slice, frame: frame, roi: particle,
                        options: measurements, into: &table)
                    let row = table.count - 1
                    if options.maxCircularity > 1, table.columns.contains("Circ."), table.number("Circ.", row: row) == 1 {
                        let perimeter = particle.length(pixelWidth: cal.pixelWidth, pixelHeight: cal.pixelHeight)
                        table.set("Circ.", row: row, perimeter == 0 ? 0 : 4.0 * Double.pi * (Double(stats.pixelCount) / (perimeter * perimeter)))
                    }
                    if options.recordStarts {
                        table.set("XStart", row: row, Double(x))
                        table.set("YStart", row: row, Double(y))
                    }
                    if maskPixels != nil {
                        fill(b, mask, width: width) { maskPixels![$0] = 255 }
                    }
                }
                // The particle is done: fill it so it isn't traced again.
                fill(b, mask, width: width) { work[$0] = fillColor }
                done = level1 == 0 && level2 == 255 && plane.pixelType == .gray8
            }
        }
        return Result(count: count, mask: maskPixels.map { .gray8($0) }, totalArea: totalArea)
    }

    /// `updateSliceSummary`: a row of Summarize's table for the `count`
    /// particles just added to `results`.
    public static func summarize(
        label: String, count: Int, totalArea: Double, measurements: Measurements, results: ResultsTable,
        into summary: inout ResultsTable
    ) {
        let row = summary.addRow()
        summary.set("Slice", row: row, .text(label))
        let start = results.count - count
        // ResultsTable.getColumn gives floats.
        func column(_ name: String) -> [Float] { (start..<results.count).map { Float(results.number(name, row: $0)) } }
        var sum = 0.0
        for area in column("Area") { sum += Double(area) }
        summary.set("Count", row: row, Double(count))
        summary.set("Total Area", row: row, sum)
        summary.set("Average Size", row: row, sum / Double(count))
        summary.set("%Area", row: row, sum * 100.0 / totalArea)
        func mean(_ name: String) {
            guard count > 0, results.columns.contains(name) else {
                summary.set(name, row: row, .nan)
                return
            }
            let stats = MeasurementStatistics(plane: .gray32Float(column(name)), width: count, options: .mean)
            summary.set(name, row: row, stats.mean)
        }
        if measurements.contains(.mean) { mean("Mean") }
        if measurements.contains(.mode) { mean("Mode") }
        if measurements.contains(.perimeter) { mean("Perim.") }
        if measurements.contains(.ellipse) { ["Major", "Minor", "Angle"].forEach(mean) }
        if measurements.contains(.shapeDescriptors) { ["Circ.", "Solidity"].forEach(mean) }
        if measurements.contains(.feret) { ["Feret", "FeretX", "FeretY", "FeretAngle", "MinFeret"].forEach(mean) }
        if measurements.contains(.integratedDensity) { mean("IntDen") }
        if measurements.contains(.median) { mean("Median") }
        if measurements.contains(.skewness) { mean("Skew") }
        if measurements.contains(.kurtosis) { mean("Kurt") }
    }

    /// Calls `body` with the index of each pixel of `bounds` in `mask` (all of them without one).
    static func fill(_ bounds: RoiBounds, _ mask: [Bool]?, width: Int, _ body: (Int) -> Void) {
        for y in 0..<bounds.height {
            for x in 0..<bounds.width where mask?[y * bounds.width + x] ?? true {
                body((bounds.y + y) * width + bounds.x + x)
            }
        }
    }

    /// `FloodFiller.particleAnalyzerFill`: the 8-connected area of in-level
    /// pixels from (x, y), as a mask over `bounds`; it is also filled with
    /// `fill` in `values` so it isn't found again.
    static func floodFill(
        _ values: inout [Float], x: Int, y: Int, width: Int, height: Int, bounds: RoiBounds, fill: Float, isFloat: Bool,
        inside: (Float) -> Bool
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: bounds.width * bounds.height)
        func inParticle(_ x: Int, _ y: Int) -> Bool {
            // ImageProcessor.getPixel is 0 (getPixelValue NaN) outside the image.
            guard x >= 0, x < width, y >= 0, y < height else { return !isFloat && inside(0) }
            return inside(values[y * width + x])
        }
        func fillLine(_ x1: Int, _ x2: Int, _ y: Int) {
            for x in min(x1, x2)...max(x1, x2) {
                let mx = x - bounds.x, my = y - bounds.y
                if mx >= 0, mx < bounds.width, my >= 0, my < bounds.height { mask[my * bounds.width + mx] = true }
                if x >= 0, x < width, y >= 0, y < height { values[y * width + x] = fill }
            }
        }
        var stack = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            guard inParticle(sx, sy) else { continue }
            var x1 = sx, x2 = sx
            while inParticle(x1, sy) && x1 >= 0 { x1 -= 1 }
            x1 += 1
            while inParticle(x2, sy) && x2 < width { x2 += 1 }
            x2 -= 1
            fillLine(x1, x2, sy)
            if x1 > 0 { x1 -= 1 }
            if x2 < width - 1 { x2 += 1 }
            var inScanLine = false
            for i in x1...x2 {
                if !inScanLine && sy > 0 && inParticle(i, sy - 1) {
                    stack.append((i, sy - 1))
                    inScanLine = true
                } else if inScanLine && sy > 0 && !inParticle(i, sy - 1) {
                    inScanLine = false
                }
            }
            inScanLine = false
            for i in x1...x2 {
                if !inScanLine && sy < height - 1 && inParticle(i, sy + 1) {
                    stack.append((i, sy + 1))
                    inScanLine = true
                } else if inScanLine && sy < height - 1 && !inParticle(i, sy + 1) {
                    inScanLine = false
                }
            }
        }
        return mask
    }
}
