import Foundation
public import MancoraCore

/// Analyze ▸ Measure (`ij.plugin.filter.Analyzer`): measures a plane of an
/// image and adds a row to a results table, with ImageJ's columns.
public enum Analyzer {
    /// Measures the plane at (`channel`, `slice`, `frame`): the pixels of
    /// the area selection `roi`, or the whole plane.
    public static func measure(
        _ image: Hyperstack, channel: Int = 0, slice: Int = 0, frame: Int = 0, roi: Roi? = nil,
        options: Measurements, threshold: ClosedRange<Double>? = nil, into table: inout ResultsTable
    ) throws(RoiMaskError) {
        let plane = image.plane(channel: channel, slice: slice, frame: frame)
        let region = try roi.map { roi throws(RoiMaskError) in try roi.measurementRegion(width: image.width, height: image.height) }
        let stats = MeasurementStatistics(
            plane: plane, width: image.width, region: region, options: options, calibration: image.calibration,
            threshold: threshold)
        prepareForMeasure(&table)
        saveResults(stats, image: image, channel: channel, slice: slice, frame: frame, roi: roi, options: options, into: &table)
    }

    /// `Analyzer.saveResults`: a row for the whole image or a selection. A
    /// line adds its Length (and a straight line its Angle), an angle its
    /// Angle, and a point its coordinates and position (`savePoints`).
    /// `label` replaces the label made from the image and `roi`'s name.
    public static func saveResults(
        _ stats: MeasurementStatistics, image: Hyperstack, channel: Int, slice: Int, frame: Int, roi: Roi? = nil,
        options: Measurements, label explicitLabel: String? = nil, into table: inout ResultsTable
    ) {
        let dims = image.dimensions
        let stackIndex = dims.planeIndex(channel: channel, slice: slice, frame: frame)
        let pw = image.calibration.pixelWidth, ph = image.calibration.pixelHeight
        if table.lastHeading == nil { reset(&table) }
        clearSummary(&table)
        let row = table.addRow(
            label: options.contains(.labels)
                ? explicitLabel ?? label(image, stackIndex: stackIndex, roiName: roi?.name) : nil)
        // ImageJ adds most columns by their fixed index, and these few by name.
        func add(_ column: String, _ value: Double) { table.setStandard(column, row: row, value) }
        func addNamed(_ column: String, _ value: Double) { table.set(column, row: row, value) }

        if options.contains(.area) { add("Area", stats.area) }
        if options.contains(.mean) { add("Mean", stats.mean) }
        if options.contains(.standardDeviation) { add("StdDev", stats.standardDeviation) }
        if options.contains(.mode) { add("Mode", stats.mode) }
        if options.contains(.minMax) {
            add("Min", stats.min)
            add("Max", stats.max)
        }
        if options.contains(.centroid) {
            add("X", stats.xCentroid)
            add("Y", stats.yCentroid)
        }
        if options.contains(.centerOfMass) {
            add("XM", stats.xCenterOfMass)
            add("YM", stats.yCenterOfMass)
        }
        if !options.isDisjoint(with: [.perimeter, .shapeDescriptors]) {
            // Without a selection ImageJ uses the image's outline, in pixels.
            let perimeter = roi?.length(pixelWidth: pw, pixelHeight: ph) ?? Double(image.width * 2 + image.height * 2)
            if options.contains(.perimeter) { add("Perim.", perimeter) }
            if options.contains(.shapeDescriptors) {
                var circularity = perimeter == 0 ? 0 : 4.0 * Double.pi * (stats.area / (perimeter * perimeter))
                if circularity > 1 { circularity = 1 }
                add("Circ.", circularity)
                let isArea = roi?.isArea ?? true
                let convexArea = roi.map { $0.outline()?.convexHull().roundedArea ?? .nan } ?? Double(stats.pixelCount)
                add("AR", isArea ? stats.major / stats.minor : 0)
                add("Round", isArea ? 4.0 * stats.area / (Double.pi * stats.major * stats.major) : 0)
                add("Solidity", isArea ? Double(stats.pixelCount) / convexArea : .nan)
                if table.count == 1 { ["Circ.", "AR", "Round", "Solidity"].forEach { table.setDecimal($0) } }
            }
        }
        if options.contains(.boundingRectangle) {
            if let roi, roi.isLine {
                // A line's bounds, calibrated.
                let b = roi.bounds
                let cal = image.calibration
                add("BX", cal.x(Double(b.x)))
                add("BY", cal.y(Double(b.y), height: image.height, invertY: options.contains(.invertY)))
                add("Width", Double(b.width) * pw)
                add("Height", Double(b.height) * ph)
            } else {
                add("BX", stats.roiX)
                add("BY", stats.roiY)
                add("Width", stats.roiWidth)
                add("Height", stats.roiHeight)
            }
        }
        if options.contains(.ellipse) {
            add("Major", stats.major)
            add("Minor", stats.minor)
            add("Angle", stats.angle)
        }
        if options.contains(.feret) {
            // A whole-image Roi isn't attached to the image, so it's uncalibrated.
            let feret = roi.map { $0.feretValues(pixelWidth: pw, pixelHeight: ph) }
                ?? FeretValues(polygon: FloatPolygon(rectangleX: 0, y: 0, width: image.width, height: image.height))
            add("Feret", feret?.diameter ?? .nan)
            add("FeretX", feret?.startX ?? .nan)
            add("FeretY", feret?.startY ?? .nan)
            add("FeretAngle", feret?.angle ?? .nan)
            add("MinFeret", feret?.minimum ?? .nan)
        }
        if options.contains(.integratedDensity) {
            add("IntDen", stats.area * stats.mean)
            add("RawIntDen", Double(stats.pixelCount) * stats.rawMean)
        }
        if options.contains(.median) { add("Median", stats.median) }
        if options.contains(.skewness) { add("Skew", stats.skewness) }
        if options.contains(.kurtosis) { add("Kurt", stats.kurtosis) }
        if options.contains(.areaFraction) { add("%Area", stats.areaFraction) }
        if options.contains(.stackPosition) {
            if dims.channels > 1 || (dims.slices > 1 && dims.frames > 1) {
                if dims.channels > 1 { addNamed("Ch", Double(channel + 1)) }
                if dims.slices > 1 { addNamed("Slice", Double(slice + 1)) }
                if dims.frames > 1 { addNamed("Frame", Double(frame + 1)) }
            } else {
                addNamed("Slice", Double(stackIndex + 1))
            }
        }
        if let roi {
            switch roi.shape {
            case .polygon(let polygon) where polygon.kind == .angle:
                addNamed("Angle", roi.polylineAngle)
            case .line(let line):
                addNamed("Length", roi.length(pixelWidth: pw, pixelHeight: ph))
                addNamed("Angle", floatAngle(line.x1, line.y1, line.x2, line.y2, pw, ph))
            case .polygon(let polygon) where polygon.kind.isLine:
                addNamed("Length", roi.length(pixelWidth: pw, pixelHeight: ph))
            case .points(let points):
                savePoints(points, roi: roi, image: image, channel: channel, slice: slice, frame: frame, options: options, row: row, into: &table)
            default:
                break
            }
        }
        if options.contains(.limitToThreshold), image.pixelType != .rgb8 {
            add("MinThr", stats.lowerThreshold)
            add("MaxThr", stats.upperThreshold)
        }
    }

    /// `Analyzer.savePoints` for one point: Area 0, its calibrated X and Y,
    /// and its stack position (its own, or the current one).
    static func savePoints(
        _ points: Roi.Points, roi: Roi, image: Hyperstack, channel: Int, slice: Int, frame: Int, options: Measurements,
        row: Int, into table: inout ResultsTable
    ) {
        func add(_ column: String, _ value: Double) { table.set(column, row: row, value) }
        if options.contains(.area) { table.setStandard("Area", row: row, 0) }
        let p = points.vertices.floatPoints.first ?? Roi.FloatPoint(x: 0, y: 0)
        let cal = image.calibration
        add("X", cal.x(Double(p.x)))
        add("Y", cal.y(Double(p.y), height: image.height, invertY: options.contains(.invertY)))
        let dims = image.dimensions
        let position = Int(points.positions?.first ?? 0)
        if dims.channels > 1 || (dims.slices > 1 && dims.frames > 1) {
            var (c, z, t) = (channel + 1, slice + 1, frame + 1)
            if position > 0 {
                let at = dims.position(ofPlane: position - 1)
                (c, z, t) = (at.channel + 1, at.slice + 1, at.frame + 1)
            }
            if dims.channels > 1 { add("Ch", Double(c)) }
            if dims.slices > 1 { add("Slice", Double(z)) }
            if dims.frames > 1 { add("Frame", Double(t)) }
        } else if image.stack.count > 1 {
            add("Slice", Double(position > 0 ? position : dims.planeIndex(channel: channel, slice: slice, frame: frame) + 1))
        }
        // On an "FFT of" image: the period (R) and direction the point stands for.
        if image.frequencyDomain != nil {
            let center = Double(image.width) / 2.0
            let x = Double(p.x)
            let y = Double(image.height) - Double(p.y) - 1
            var r = ((x - center) * (x - center) + (y - center) * (y - center)).squareRoot()
            if r < 1.0 { r = 1.0 }
            var theta = atan2(y - center, x - center) * 180.0 / Double.pi
            if theta < 0 { theta = 360.0 + theta }
            add("R", (Double(image.width) / r) * cal.pixelWidth)
            add("Theta", theta)
        }
    }

    /// `Roi.getFloatAngle(x1, y1, x2, y2)`: degrees from the x axis, y up, calibrated.
    static func floatAngle(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ pw: Double, _ ph: Double) -> Double {
        var dx = x2 - x1
        var dy = y1 - y2
        dx *= pw
        dy *= ph
        return (180.0 / Double.pi) * atan2(dy, dx)
    }

    /// `Analyzer.reset()`: a table with rows is cleared, and one without
    /// the default headings gets them.
    public static func reset(_ table: inout ResultsTable) {
        if table.count > 0 { table.reset() }
        if table.lastHeading == nil { table.setDefaultHeadings() }
    }

    /// The start of `Analyzer.measure()`: a table whose last standard slot
    /// isn't headed as ImageJ's ("M…") is reset first.
    public static func prepareForMeasure(_ table: inout ResultsTable) {
        if table.lastHeading?.first != "M" { reset(&table) }
    }

    /// `clearSummary`: Summarize's Mean, SD, Min and Max rows go before a new row.
    public static func clearSummary(_ table: inout ResultsTable) {
        if table.count >= 4, table.labels[table.count - 1] == "Max" { table.removeLastRows(4) }
    }

    /// `Analyzer.getFileName`: the title, the selection's name (unless it
    /// has a dot; at most 30 characters), then the slice's label or number.
    static func label(_ image: Hyperstack, stackIndex: Int, roiName: String? = nil) -> String {
        var label = image.title
        if let name = roiName, !name.contains(".") {
            let utf16 = Array(name.utf16)
            label += ":" + (utf16.count > 30 ? String(decoding: utf16[..<27], as: UTF16.self) + "..." : name)
        }
        guard image.stack.count > 1 else { return label }
        let colon = label.isEmpty ? "" : ":"
        if let short = shortSliceLabel(image.stack.labels[stackIndex]), !short.isEmpty {
            label += colon + short
        } else {
            label += colon + String(stackIndex + 1)
        }
        return label
    }

    /// `ImageStack.getShortSliceLabel(n, 60)`: the first line, without a
    /// file extension, at most 60 characters.
    public static func shortSliceLabel(_ label: String?) -> String? {
        guard var short = label else { return nil }
        if let newline = short.firstIndex(of: "\n") {
            if newline == short.startIndex { return nil }
            short = String(short[..<newline])
        }
        let chars = Array(short.utf16)
        if chars.count > 4, chars[chars.count - 4] == UInt16(UInt8(ascii: ".")),
            UnicodeScalar(chars[chars.count - 1])?.properties.generalCategory != .decimalNumber
        {
            short = String(decoding: chars[..<(chars.count - 4)], as: UTF16.self)
        }
        let trimmed = Array(short.utf16)
        if trimmed.count > 60 { short = String(decoding: trimmed[..<60], as: UTF16.self) }
        return short
    }
}
