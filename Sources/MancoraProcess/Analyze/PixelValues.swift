import MancoraCore

/// A plane as an `ImageProcessor` reads it for profiles: `getPixelValue`
/// (8- and 16-bit values through the calibration table, the luminance of
/// RGB pixels, NaN outside the image), `getInterpolatedValue` and
/// `getLine`.
struct PixelValues {
    let width: Int
    let height: Int
    /// `getPixelValue` of every pixel, row by row.
    let pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The values `getPixelValue` returns for `plane`: ImageJ applies a
    /// value calibration (as a `float` table) to 8- and 16-bit images only,
    /// and turns RGB into `(float)(r*wr + g*wg + b*wb)`.
    init(_ plane: Plane, width: Int, calibration: Calibration, rgbWeights: RGBWeights) {
        self.width = width
        height = width > 0 ? plane.count / width : 0
        switch plane {
        case .gray8(let p):
            if let table = MeasurementStatistics.cTable(calibration, count: 256) {
                pixels = p.map { table[Int($0)] }
            } else {
                pixels = p.map { Float($0) }
            }
        case .gray16(let p):
            if let table = MeasurementStatistics.cTable(calibration, count: 65536) {
                pixels = p.map { table[Int($0)] }
            } else {
                pixels = p.map { Float($0) }
            }
        case .gray32Float(let p):
            pixels = p
        case .rgb8(let p):
            let w = rgbWeights
            pixels = p.map { c in
                Float(Double((c >> 16) & 0xFF) * w.red + Double((c >> 8) & 0xFF) * w.green + Double(c & 0xFF) * w.blue)
            }
        }
    }

    /// `getPixelValue(x, y)`: NaN outside the image.
    @inline(__always)
    func value(_ x: Int, _ y: Int) -> Double {
        x >= 0 && x < width && y >= 0 && y < height ? Double(pixels[y * width + x]) : .nan
    }

    /// `getInterpolatedValue(x, y)`: bilinear; within a pixel of the image
    /// the edge pixels repeat, and farther out the value is 0.
    func interpolated(_ x: Double, _ y: Double) -> Double {
        let w = Double(width), h = Double(height)
        if x < 0 || x >= w - 1 || y < 0 || y >= h - 1 {
            if x < -1 || x >= w || y < -1 || y >= h { return 0 }
            return bilinear(x, y, edgeValue)
        }
        return bilinear(x, y, value)
    }

    /// `getEdgeValue`: the nearest pixel inside the image.
    private func edgeValue(_ xIn: Int, _ yIn: Int) -> Double {
        var x = xIn, y = yIn
        if x <= 0 { x = 0 }
        if x >= width { x = width - 1 }
        if y <= 0 { y = 0 }
        if y >= height { y = height - 1 }
        return value(x, y)
    }

    @inline(__always)
    private func bilinear(_ x: Double, _ y: Double, _ pixel: (Int, Int) -> Double) -> Double {
        let xbase = Int(JavaNumerics.int32(x)), ybase = Int(JavaNumerics.int32(y))
        var xFraction = x - Double(xbase), yFraction = y - Double(ybase)
        if xFraction < 0 { xFraction = 0 }
        if yFraction < 0 { yFraction = 0 }
        let lowerLeft = pixel(xbase, ybase), lowerRight = pixel(xbase + 1, ybase)
        let upperRight = pixel(xbase + 1, ybase + 1), upperLeft = pixel(xbase, ybase + 1)
        let upperAverage = upperLeft + xFraction * (upperRight - upperLeft)
        let lowerAverage = lowerLeft + xFraction * (lowerRight - lowerLeft)
        return lowerAverage + yFraction * (upperAverage - lowerAverage)
    }

    /// `ImageProcessor.getLine(x1, y1, x2, y2)`: `round(length) + 1`
    /// values one (rounded) pixel apart, interpolated or from the nearest
    /// pixel.
    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, interpolate: Bool) -> [Double] {
        let dx = x2 - x1, dy = y2 - y1
        let n = max(Int(JavaNumerics.roundToInt32((dx * dx + dy * dy).squareRoot())), 0)
        let xinc = n > 0 ? dx / Double(n) : 0
        let yinc = n > 0 ? dy / Double(n) : 0
        var data = [Double](repeating: 0, count: n + 1)
        var rx = x1, ry = y1
        for i in 0...n {
            if interpolate {
                data[i] = interpolated(rx, ry)
            } else {
                data[i] = value(Int(JavaNumerics.roundToInt32(rx)), Int(JavaNumerics.roundToInt32(ry)))
            }
            rx += xinc
            ry += yinc
        }
        return data
    }

    /// `ProfilePlot.getColumnAverageProfile`: the mean of each column of
    /// the rectangle, skipping pixels outside the image (and NaNs).
    func columnAverage(x: Int, y: Int, width w: Int, height h: Int) -> [Double] {
        var profile = [Double](repeating: 0, count: w)
        var counts = [Int](repeating: 0, count: w)
        for row in stride(from: y, to: y + h, by: 1) {
            let aLine = line(Double(x), Double(row), Double(x + w - 1), Double(row), interpolate: false)
            for (i, v) in aLine.enumerated() where i < w && !v.isNaN {
                profile[i] += v
                counts[i] += 1
            }
        }
        for i in 0..<w { profile[i] /= Double(counts[i]) }
        return profile
    }

    /// `ProfilePlot.getRowAverageProfile`: the mean of each row of the
    /// rectangle, skipping pixels outside the image (and NaNs).
    func rowAverage(x: Int, y: Int, width w: Int, height h: Int) -> [Double] {
        var profile = [Double](repeating: 0, count: h)
        var counts = [Int](repeating: 0, count: h)
        for column in stride(from: x, to: x + w, by: 1) {
            let aLine = line(Double(column), Double(y), Double(column), Double(y + h - 1), interpolate: false)
            for i in 0..<min(h, aLine.count) where !aLine[i].isNaN {
                profile[i] += aLine[i]
                counts[i] += 1
            }
        }
        for i in 0..<h { profile[i] /= Double(counts[i]) }
        return profile
    }
}
