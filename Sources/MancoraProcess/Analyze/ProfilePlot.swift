public import MancoraCore

/// A line or rectangle profile, as Analyze ▸ Plot Profile plots it: the
/// values along the selection against the distance from its start.
public struct ProfileData: Sendable, Hashable {
    /// The distance of each value from the start, in calibrated units:
    /// `(float)(i * xInc)`, as ImageJ's plot has them.
    public var xValues: [Double]
    /// The profile: what the macro function `getProfile()` returns.
    public var yValues: [Double]
    /// "Distance (pixels)", "Distance (microns)"…
    public var xLabel: String
    /// The value unit, "Gray Value" unless the image has a value calibration.
    public var yLabel: String

    public init(xValues: [Double], yValues: [Double], xLabel: String, yLabel: String) {
        self.xValues = xValues
        self.yValues = yValues
        self.xLabel = xLabel
        self.yLabel = yLabel
    }
}

/// Why a selection has no profile.
public enum ProfileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// ImageJ's "Line or rectangular selection required." (ovals,
    /// polygons, points and composite selections have no profile).
    case lineOrRectangleRequired
    /// Spline-fitted polylines and freelines, whose spline Mancora doesn't
    /// compute yet.
    case splineFit

    public var description: String {
        switch self {
        case .lineOrRectangleRequired: "Line or rectangular selection required."
        case .splineFit: "Profiles of spline-fitted lines are not available in Mancora yet."
        }
    }
}

/// ImageJ's `ProfilePlot`: the profile of a line or rectangular selection
/// on one plane, computed as ImageJ 1.54p does.
///
/// - Straight lines one pixel wide sample `round(length) + 1` points, one
///   pixel apart, from the first end point to the second (pixel centers are
///   at integer coordinates), interpolated or from the nearest pixel.
/// - Wider straight lines, polylines and freelines are straightened
///   (`Straightener`): a spline through the vertices resampled at one-pixel
///   steps, `width` interpolated values across the line at each step, and
///   the profile is the mean across the line. Lines narrower than 2 pixels
///   keep their own sampling.
/// - Thin polylines and freelines step along each segment in 0.01-pixel
///   steps and take a value whenever the last one is at least 0.995 pixels
///   away.
/// - Rectangles (and angle selections, through their bounds) average each
///   column of the bounding rectangle, or each row for a vertical profile.
///
/// 8- and 16-bit values go through the value calibration; RGB pixels are
/// their luminance.
public enum ProfilePlot {
    /// The settings that change a profile (Edit ▸ Options ▸ Plots).
    public struct Options: Sendable, Hashable {
        /// "Interpolate line profiles" (`PlotWindow.interpolate`, the macro's
        /// `setOption("InterpolateLines", …)`): bilinear values along thin
        /// straight lines and polylines instead of the nearest pixel's.
        public var interpolate: Bool
        /// Row averages of rectangles ("Vertical profile", or the Alt key).
        public var vertical: Bool
        /// The RGB-to-gray weights (Edit ▸ Options ▸ Conversions).
        public var rgbWeights: RGBWeights

        public init(interpolate: Bool = true, vertical: Bool = false, rgbWeights: RGBWeights = .unweighted) {
            self.interpolate = interpolate
            self.vertical = vertical
            self.rgbWeights = rgbWeights
        }
    }

    /// The profile of `roi` on `plane` (`width` pixels wide), with x values
    /// in `calibration`'s units.
    public static func profile(
        of plane: Plane, width: Int, roi: Roi, calibration: Calibration, options: Options = Options()
    ) throws(ProfileError) -> ProfileData {
        let values = PixelValues(
            plane, width: width, calibration: valueCalibration(calibration, plane), rgbWeights: options.rgbWeights)
        var xInc = calibration.pixelWidth
        let profile: [Double]
        switch roi.shape {
        case .line(let line):
            profile = straightLine(line, strokeWidth: roi.strokeWidth, values, options, calibration, &xInc)
        case .polygon(let p):
            if case .rotatedRectangle(let rectWidth) = p.parametric {
                // ProfilePlot turns a rotated rectangle into a wide line along its axis.
                let s = p.state
                guard let xpf = s.xpf, let ypf = s.ypf, xpf.count == 4 else { throw .lineOrRectangleRequired }
                let x = Float(s.x), y = Float(s.y)
                func mid(_ v: [Float], _ i: Int, _ base: Float) -> Double { Double(v[i] + (v[(i + 1) % 4] - v[i]) / 2 + base) }
                let axis = Roi.Line(x1: mid(xpf, 3, x), y1: mid(ypf, 3, y), x2: mid(xpf, 1, x), y2: mid(ypf, 1, y))
                profile = straightLine(axis, strokeWidth: Float(rectWidth), values, options, calibration, &xInc)
            } else if p.kind == .polyline || p.kind == .freeline {
                if p.isSplineFit { throw .splineFit }
                let lineWidth = Int(JavaNumerics.round(Double(roi.strokeWidth)))
                if lineWidth <= 1 {
                    let points = p.state.floatPolygon
                    profile = irregular(points.xs, points.ys, values, interpolate: options.interpolate)
                } else if let straight = Straightener.straighten(
                    p.state, isFreeline: p.kind == .freeline, width: lineWidth, from: values)
                {
                    profile = straight.columnAverage(x: 0, y: 0, width: straight.width, height: straight.height)
                } else {
                    profile = []
                }
            } else if p.kind == .angle {
                profile = average(roi.bounds, values, options.vertical, calibration, &xInc)
            } else {
                throw .lineOrRectangleRequired
            }
        default:
            guard roi.kind == .rectangle else { throw .lineOrRectangleRequired }
            profile = average(roi.bounds, values, options.vertical, calibration, &xInc)
        }
        let xValues = profile.indices.map { Double(Float(Double($0) * xInc)) }
        return ProfileData(
            xValues: xValues, yValues: profile, xLabel: "Distance (\(pluralUnits(calibration.unit)))",
            yLabel: valueCalibration(calibration, plane).valueUnit)
    }

    /// `ProfilePlot.getStraightLineProfile`: `Line.getPixels()`, and the
    /// distance between samples along the line when pixels aren't square.
    private static func straightLine(
        _ line: Roi.Line, strokeWidth: Float, _ values: PixelValues, _ options: Options, _ calibration: Calibration,
        _ xInc: inout Double
    ) -> [Double] {
        let profile: [Double]
        if strokeWidth <= 1 {
            profile = values.line(line.x1, line.y1, line.x2, line.y2, interpolate: options.interpolate)
        } else {
            // Straightener.straightenLine(imp, line, 0): a two-point polyline,
            // as wide as the line's width truncated.
            let points = [
                Roi.FloatPoint(x: Float(line.x1), y: Float(line.y1)), Roi.FloatPoint(x: Float(line.x2), y: Float(line.y2)),
            ]
            let polygon = PolygonState(subpixel: points, isLine: true)
            let width = Int(JavaNumerics.int32(strokeWidth))
            if let straight = Straightener.straighten(polygon, isFreeline: false, width: width, from: values) {
                profile = straight.columnAverage(x: 0, y: 0, width: straight.width, height: straight.height)
            } else {
                profile = []
            }
        }
        if calibration.pixelWidth != calibration.pixelHeight {
            var dx = Double(Float(line.x2) - Float(line.x1))
            var dy = Double(Float(line.y2) - Float(line.y1))
            let pixelLength = (dx * dx + dy * dy).squareRoot()
            dx = calibration.pixelWidth * dx
            dy = calibration.pixelHeight * dy
            let calibratedLength = (dx * dx + dy * dy).squareRoot()
            xInc = calibratedLength * 1.0 / pixelLength
        }
        return profile
    }

    /// `getColumnAverageProfile` of the bounds, or `getRowAverageProfile`
    /// (whose samples are a pixel height apart).
    private static func average(
        _ b: RoiBounds, _ values: PixelValues, _ vertical: Bool, _ calibration: Calibration, _ xInc: inout Double
    ) -> [Double] {
        if vertical {
            xInc = calibration.pixelHeight
            return values.rowAverage(x: b.x, y: b.y, width: b.width, height: b.height)
        }
        return values.columnAverage(x: b.x, y: b.y, width: b.width, height: b.height)
    }

    /// `ProfilePlot.getIrregularProfile`: a polyline one pixel wide, walked
    /// in 0.01-pixel steps, taking a value whenever the previous one is at
    /// least 0.995 pixels away. The walk starts as if a value had been taken
    /// at (0, 0).
    static func irregular(_ xs: [Float], _ ys: [Float], _ values: PixelValues, interpolate: Bool) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out: [Double] = []
        let inc = 0.01
        var lastx = 0.0, lasty = 0.0
        var x2 = Double(xs[0]), y2 = Double(ys[0])
        for i in stride(from: 1, to: n, by: 1) {
            let x1 = x2, y1 = y2
            var x = x1, y = y1
            x2 = Double(xs[i])
            y2 = Double(ys[i])
            var dx = x2 - x1
            var dy = y2 - y1
            let distance = (dx * dx + dy * dy).squareRoot()
            let xinc = dx * inc / distance
            let yinc = dy * inc / distance
            var n2 = Int(JavaNumerics.int32(distance / inc))
            if n == 2 { n2 += 1 }
            repeat {
                dx = x - lastx
                dy = y - lasty
                let distance2 = (dx * dx + dy * dy).squareRoot()
                if distance2 >= 1.0 - inc / 2.0 {
                    if interpolate {
                        out.append(values.interpolated(x, y))
                    } else {
                        out.append(values.value(Int(JavaNumerics.roundToInt32(x)), Int(JavaNumerics.roundToInt32(y))))
                    }
                    lastx = x
                    lasty = y
                }
                x += xinc
                y += yinc
                n2 -= 1
            } while n2 > 0
        }
        return out
    }

    /// The calibration ImageJ keeps for the plane's type: 32-bit and RGB
    /// images have no value calibration, and RGB's value unit is the default.
    static func valueCalibration(_ calibration: Calibration, _ plane: Plane) -> Calibration {
        var c = calibration
        switch plane {
        case .gray8, .gray16: break
        case .gray32Float: c.valueFunction = nil
        case .rgb8:
            c.valueFunction = nil
            c.valueUnit = "Gray Value"
        }
        return c
    }

    /// `Calibration.getUnits()`: "pixels", "microns" and "inches" for their singulars.
    static func pluralUnits(_ unit: String) -> String {
        switch unit {
        case "pixel": "pixels"
        case "micron": "microns"
        case "inch": "inches"
        default: unit
        }
    }
}
