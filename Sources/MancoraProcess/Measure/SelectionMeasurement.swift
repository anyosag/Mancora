import Foundation
public import MancoraCore

/// Analyze ▸ Measure on line, point and angle selections: ports of
/// `Analyzer.measureLength`, `measurePoint` and `measureAngle`.
extension Analyzer {
    /// Why a selection can't be measured natively.
    public enum SelectionError: Error, Sendable, Equatable {
        /// Lines wider than one pixel (measured as an area), spline-fitted
        /// lines, value-calibrated images, and points outside the image.
        case unsupported
    }

    /// `measureLength`: a straight line, polyline or freeline. Without
    /// pixel measurements only its Length (and Angle) are recorded;
    /// otherwise the statistics of its profile (`getProfile()`, one value
    /// per pixel length), with the area of that many pixels, and for a
    /// straight line its midpoint as centroid.
    public static func measureLine(
        _ roi: Roi, in image: Hyperstack, channel: Int, slice: Int, frame: Int, options: Measurements,
        threshold: ClosedRange<Double>?, label: String?, into table: inout ResultsTable
    ) throws(SelectionError) {
        let cal = image.calibration
        guard cal.valueFunction == nil else { throw .unsupported }
        if table.count > 0 {
            // A table without Length (or a straight line's Angle) gets the columns the measurements make.
            var missing = !table.columnExists("Length")
            if case .line = roi.shape, !table.columnExists("Angle") { missing = true }
            if missing {
                clearSummary(&table)
                update(&table, options: options, image: image, channel: channel, slice: slice, frame: frame, roi: roi)
            }
        }
        let pixelMeasurements: Measurements = [.area, .mean, .standardDeviation, .mode, .minMax, .centroid, .median]
        if options.isDisjoint(with: pixelMeasurements) {
            let row = table.addRow(label: options.contains(.labels) ? label : nil)
            table.set("Length", row: row, roi.length(pixelWidth: cal.pixelWidth, pixelHeight: cal.pixelHeight))
            if case .line(let line) = roi.shape {
                table.set("Angle", row: row, floatAngle(line.x1, line.y1, line.x2, line.y2, cal.pixelWidth, cal.pixelHeight))
            }
            return
        }
        let plane = image.plane(channel: channel, slice: slice, frame: frame)
        let limit = options.contains(.limitToThreshold)
        var statsOptions: Measurements = [.area, .mean, .standardDeviation, .mode, .minMax, .median]
        if limit { statsOptions.insert(.limitToThreshold) }
        var stats: MeasurementStatistics
        if JavaNumerics.round(Double(roi.strokeWidth)) > 1 {
            // A wide straight line is measured as its rotated rectangle (`convertLineToArea`).
            guard case .line(let line) = roi.shape else { throw .unsupported }
            let area = Roi(.polygon(.rotatedRectangle(
                x1: Double(Float(line.x1)), y1: Double(Float(line.y1)), x2: Double(Float(line.x2)), y2: Double(Float(line.y2)),
                width: max(Double(roi.strokeWidth), 1))))
            guard let region = try? area.measurementRegion(width: image.width, height: image.height) else { throw .unsupported }
            stats = MeasurementStatistics(
                plane: plane, width: image.width, region: region, options: statsOptions, calibration: cal,
                threshold: limit ? threshold : nil)
        } else {
            stats = try profileStatistics(roi, plane, image, statsOptions, limit ? threshold : nil)
        }
        if case .line(let line) = roi.shape, options.contains(.centroid) {
            let x1 = Double(Float(line.x1)), x2 = Double(Float(line.x2))
            let y1 = Double(Float(line.y1)), y2 = Double(Float(line.y2))
            stats.xCentroid = cal.x(x1 + (x2 - x1) / 2.0)
            stats.yCentroid = cal.y(y1 + (y2 - y1) / 2.0, height: image.height, invertY: options.contains(.invertY))
        }
        saveResults(
            stats, image: image, channel: channel, slice: slice, frame: frame, roi: roi, options: options, label: label,
            into: &table)
    }

    /// The statistics of a one-pixel-wide line's profile: one value per
    /// pixel of length, as an n×1 float image (or, limited to the
    /// threshold, converted back to the image's 8 or 16 bits).
    static func profileStatistics(
        _ roi: Roi, _ plane: Plane, _ image: Hyperstack, _ statsOptions: Measurements, _ threshold: ClosedRange<Double>?
    ) throws(SelectionError) -> MeasurementStatistics {
        guard let profile = roi.lineProfile(of: plane, width: image.width) else { throw .unsupported }
        let cal = image.calibration
        let limit = statsOptions.contains(.limitToThreshold)
        var values: Plane = .gray32Float(profile.map { Float($0) })
        if limit {
            // convertToOriginalDepth: the (float) profile as 8- or 16-bit, unscaled.
            switch image.pixelType {
            case .gray8:
                values = .gray8(profile.map { v in
                    var f = Float(v) + 0.5
                    if f < 0 { f = 0 }
                    if f > 255 { f = 255 }
                    return UInt8(truncatingIfNeeded: JavaNumerics.int32(f))
                })
            case .gray16:
                values = .gray16(profile.map { v in
                    var d = Double(Float(v))
                    if d < 0 { d = 0 }
                    if d > 65535 { d = 65535 }
                    return UInt16(truncatingIfNeeded: JavaNumerics.int32(d + 0.5))
                })
            default: break
            }
        }
        var statsCalibration = Calibration()
        statsCalibration.pixelWidth = cal.pixelWidth
        statsCalibration.pixelHeight = cal.pixelHeight
        return MeasurementStatistics(
            plane: values, width: profile.count, options: statsOptions, calibration: statsCalibration, threshold: threshold)
    }

    /// `measurePoint`: a row per point, measuring the pixel it rounds to
    /// (on its own plane, for a point with a stack position), with its
    /// coordinates as center of mass.
    public static func measurePoints(
        _ roi: Roi, in image: Hyperstack, channel: Int, slice: Int, frame: Int, options: Measurements,
        threshold: ClosedRange<Double>?, label: String?, into table: inout ResultsTable
    ) throws(SelectionError) {
        guard case .points(let points) = roi.shape else { throw .unsupported }
        if table.count > 0, !table.columnExists("X"), table.lastColumn < ResultsTable.standardHeadings.count - 1 {
            clearSummary(&table)
            update(&table, options: options, image: image, channel: channel, slice: slice, frame: frame, roi: roi)
        }
        let cal = image.calibration
        let p = points.state.floatPolygon
        let current = image.dimensions.planeIndex(channel: channel, slice: slice, frame: frame)
        for i in 0..<p.xs.count {
            var position = 0
            if p.xs.count > 1, let positions = points.positions, i < positions.count { position = Int(positions[i]) }
            let onOwnPlane = image.stack.count > 1 && position > 0 && position <= image.stack.count
            let plane = onOwnPlane ? image.stack[position - 1] : image.stack[current]
            let x = Int(RoiJava.round(Double(p.xs[i]))), y = Int(RoiJava.round(Double(p.ys[i])))
            guard x >= 0, y >= 0, x < image.width, y < image.height else { throw .unsupported }
            var stats = MeasurementStatistics(
                plane: plane, width: image.width, region: MeasurementRegion(x: x, y: y, width: 1, height: 1),
                options: options, calibration: cal, threshold: onOwnPlane ? nil : threshold)
            stats.xCenterOfMass = Double(p.xs[i])
            stats.yCenterOfMass = Double(p.ys[i])
            var single = Roi.Points(.subpixel([Roi.FloatPoint(x: p.xs[i], y: p.ys[i])]))
            single.positions = position > 0 ? [Int32(position)] : nil
            saveResults(
                stats, image: image, channel: channel, slice: slice, frame: frame, roi: Roi(.points(single)),
                options: options, label: label, into: &table)
        }
    }

    /// `measureAngle`: empty statistics, with the selection's Angle.
    public static func measureAngle(
        _ roi: Roi, in image: Hyperstack, channel: Int, slice: Int, frame: Int, options: Measurements, label: String?,
        into table: inout ResultsTable
    ) {
        if table.count > 0, !table.columnExists("Angle") {
            clearSummary(&table)
            update(&table, options: options, image: image, channel: channel, slice: slice, frame: frame, roi: roi)
        }
        saveResults(
            MeasurementStatistics(), image: image, channel: channel, slice: slice, frame: frame, roi: roi, options: options,
            label: label, into: &table)
    }

    /// `ResultsTable.update(measurements, imp, roi)`: the columns a
    /// measurement of `roi` on `image` (or with no image) would add are
    /// created, empty, in their slots, and columns it wouldn't add go
    /// unless they were set by name; without labels, the Label column goes.
    public static func update(
        _ table: inout ResultsTable, options: Measurements, image: Hyperstack?, channel: Int = 0, slice: Int = 0,
        frame: Int = 0, roi: Roi?
    ) {
        var scratch = ResultsTable()
        var options = options
        let target: Hyperstack
        if let image {
            target = image
        } else {
            // No image: no threshold columns, and an image's columns otherwise.
            options.remove(.limitToThreshold)
            guard let blank = try? Hyperstack(title: "", stack: ImageStack(width: 1, height: 1, planes: [.gray8([0])])) else { return }
            target = blank
        }
        saveResults(
            MeasurementStatistics(plane: .gray8([0]), width: 1, options: options), image: target, channel: channel,
            slice: slice, frame: frame, roi: roi, options: options, into: &scratch)
        let wanted = Dictionary(scratch.columnSlots.map { ($0.slot, $0.heading) }, uniquingKeysWith: { a, _ in a })
        for (slot, heading) in wanted.sorted(by: { $0.key < $1.key }) { table.addColumn(heading, slot: slot) }
        for column in table.columnSlots where wanted[column.slot] == nil && !column.kept {
            table.removeColumn(slot: column.slot)
        }
        if !options.contains(.labels) { table.removeLabels() }
    }

    /// `getFileName()`: the title (of the redirect image, if any), the
    /// selection's name, then the current slice's label or number.
    public static func label(title: String, image: Hyperstack, stackIndex: Int, roiName: String?) -> String {
        var titled = image
        titled.title = title
        return label(titled, stackIndex: stackIndex, roiName: roiName)
    }
}

extension MeasurementStatistics {
    /// A `new ImageStatistics()`: every value 0, thresholds NaN.
    init() {}
}

extension Roi {
    /// `Roi.isLine()`: straight lines, polylines, freelines and angles.
    public var isLine: Bool {
        switch shape {
        case .line: true
        case .polygon(let p): p.kind.isLine
        default: false
        }
    }

    /// `PolygonRoi.getAngle()` of an angle selection, as its constructor
    /// computes it (uncalibrated): the angle between its two segments, or
    /// NaN for anything but three vertices.
    public var polylineAngle: Double {
        guard case .polygon(let polygon) = shape, polygon.kind == .angle else { return .nan }
        let s = polygon.state
        let xs: [Double], ys: [Double]
        if let xpf = s.xpf, let ypf = s.ypf {
            (xs, ys) = (xpf.map(Double.init), ypf.map(Double.init))
        } else if let xp = s.xp, let yp = s.yp {
            (xs, ys) = (xp.map(Double.init), yp.map(Double.init))
        } else {
            return .nan
        }
        guard xs.count == 3 else { return .nan }
        let angle1 = Analyzer.floatAngle(xs[0], ys[0], xs[1], ys[1], 1, 1)
        let angle2 = Analyzer.floatAngle(xs[1], ys[1], xs[2], ys[2], 1, 1)
        var degrees = abs(180 - abs(angle1 - angle2))
        if degrees > 180.0 { degrees = 360.0 - degrees }
        return degrees
    }
}

extension Calibration {
    /// `getX(x)`.
    func x(_ x: Double) -> Double { (x - xOrigin) * pixelWidth }

    /// `getY(y, imageHeight)`, with Invert Y from the image or the measurements.
    func y(_ y: Double, height: Int, invertY measurementsInvertY: Bool) -> Double {
        if invertY || measurementsInvertY {
            return yOrigin != 0 ? (yOrigin - y) * pixelHeight : (Double(height) - y - 1) * pixelHeight
        }
        return (y - yOrigin) * pixelHeight
    }
}
