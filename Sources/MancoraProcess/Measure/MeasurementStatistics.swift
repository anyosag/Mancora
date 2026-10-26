public import MancoraCore

/// The statistics Analyze ▸ Measure reports for one plane, computed as
/// ImageJ's `ByteStatistics`, `ShortStatistics`, `FloatStatistics` and
/// `ColorStatistics` do (same order of operations, same quirks), so the
/// numbers match ImageJ's.
public struct MeasurementStatistics: Sendable, Hashable {
    public var pixelCount = 0
    public var area = 0.0
    public var mean = 0.0
    /// The mean of the raw (uncalibrated) values.
    public var rawMean = 0.0
    public var standardDeviation = 0.0
    /// The most frequent value (ImageJ's `dmode`).
    public var mode = 0.0
    public var min = 0.0
    public var max = 0.0
    public var median = 0.0
    public var skewness = 0.0
    public var kurtosis = 0.0
    public var xCentroid = 0.0
    public var yCentroid = 0.0
    public var xCenterOfMass = 0.0
    public var yCenterOfMass = 0.0
    /// The measured rectangle, calibrated.
    public var roiX = 0.0
    public var roiY = 0.0
    public var roiWidth = 0.0
    public var roiHeight = 0.0
    /// The best-fitting ellipse: axis lengths and the major axis's angle in degrees.
    public var major = 0.0
    public var minor = 0.0
    public var angle = 0.0
    public var areaFraction = 0.0
    /// The limits used with ``Measurements/limitToThreshold``.
    public var lowerThreshold = Double.nan
    public var upperThreshold = Double.nan

    /// Measures `plane` (`width` pixels wide) within `region` (the whole
    /// plane when `nil`). `threshold` is the image's threshold, if one is
    /// set: it limits the measurement with ``Measurements/limitToThreshold``
    /// and defines the area fraction.
    public init(
        plane: Plane, width: Int, region: MeasurementRegion? = nil, options: Measurements,
        calibration: Calibration = Calibration(), threshold: ClosedRange<Double>? = nil
    ) {
        let height = width > 0 ? plane.count / width : 0
        let geometry = Geometry(
            width: width, height: height, region: region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height),
            calibration: calibration, invertY: calibration.invertY || options.contains(.invertY))
        pw = geometry.pw
        ph = geometry.ph
        roiX = geometry.x(Double(geometry.rx))
        roiY = geometry.y(Double(geometry.ry))
        roiWidth = Double(geometry.rw) * geometry.pw
        roiHeight = Double(geometry.rh) * geometry.ph
        switch plane {
        case .gray8(let p):
            byteStatistics(p, geometry, options, threshold, cTable: Self.cTable(calibration, count: 256))
        case .gray16(let p):
            shortStatistics(p, geometry, options, threshold, cTable: Self.cTable(calibration, count: 65536))
        case .gray32Float(let p):
            floatStatistics(p, geometry, options, threshold)
        case .rgb8(let p):
            colorStatistics(p, geometry, options)
        }
    }

    /// `Calibration.getCTable`: the calibrated value of every raw value.
    static func cTable(_ calibration: Calibration, count: Int) -> [Float]? {
        guard let function = calibration.valueFunction else { return nil }
        return (0..<count).map { Float(function.apply(Double($0))) }
    }

    // MARK: 8-bit

    private mutating func byteStatistics(
        _ p: [UInt8], _ g: Geometry, _ options: Measurements, _ threshold: ClosedRange<Double>?, cTable: [Float]?
    ) {
        var histogram = [Int](repeating: 0, count: 256)
        g.forEachPixel { _, _, i in histogram[Int(p[i])] += 1 }
        let limit = options.contains(.limitToThreshold)
        var minT = 0, maxT = 255
        if limit, let threshold {
            minT = Swift.max(Int(JavaNumerics.int32(threshold.lowerBound)), 0)
            maxT = Swift.min(Int(JavaNumerics.int32(threshold.upperBound)), 255)
        }
        if limit { saveThreshold(Double(minT), Double(maxT), cTable) }
        if let cTable {
            calibratedStatistics(histogram, minT, maxT, cTable)
        } else {
            rawStatistics(histogram, minT, maxT)
        }
        if options.contains(.minMax) {
            if pixelCount == 0 {
                (min, max) = (.nan, .nan)
            } else if let cTable {
                calibratedMinMax(histogram, minT, maxT, cTable, emptyIsZero: true)
            } else {
                rawMinMax(histogram, minT, maxT)
            }
        }
        let value: (Int) -> Double = { Double(p[$0]) }
        let limited = minT > 0 || maxT < 255
        centroids(g, options, threshold, value: value) { !limited || (Int(p[$0]) >= minT && Int(p[$0]) <= maxT) }
        if !options.isDisjoint(with: [.centerOfMass, .skewness, .kurtosis]) {
            moments(g) { i in
                let v = Int(p[i])
                guard v >= minT, v <= maxT else { return nil }
                return Double(cTable.map { $0[v] } ?? Float(v)) + Double.leastNonzeroMagnitude
            }
        }
        if options.contains(.median) { median = Self.histogramMedian(histogram, minT, maxT, pixelCount, cTable) }
        if options.contains(.areaFraction) { areaFraction = Self.areaFraction(histogram, threshold) }
    }

    /// `ImageStatistics.getRawStatistics`.
    private mutating func rawStatistics(_ histogram: [Int], _ minT: Int, _ maxT: Int) {
        var sum = 0.0, sum2 = 0.0
        var maxCount = 0, modeIndex = 0
        var count = 0
        for i in stride(from: minT, through: maxT, by: 1) {
            let n = histogram[i]
            count += n
            sum += Double(i) * Double(n)
            let value = Double(i)
            sum2 += (value * value) * Double(n)
            if n > maxCount {
                maxCount = n
                modeIndex = i
            }
        }
        pixelCount = count
        area = Double(count) * pw * ph
        mean = sum / Double(count)
        rawMean = mean
        mode = Double(modeIndex)
        standardDeviation = Self.standardDeviation(Double(count), sum, sum2)
    }

    /// `ByteStatistics.getCalibratedStatistics`.
    private mutating func calibratedStatistics(_ histogram: [Int], _ minT: Int, _ maxT: Int, _ cTable: [Float]) {
        var sum = 0.0, sum2 = 0.0, isum = 0.0
        var maxCount = 0, modeIndex = 0
        for i in stride(from: minT, through: maxT, by: 1) {
            let n = histogram[i]
            let value = Double(cTable[i])
            if n > 0, !value.isNaN {
                pixelCount += n
                sum += value * Double(n)
                isum += Double(i * n)
                sum2 += (value * value) * Double(n)
                if n > maxCount {
                    maxCount = n
                    modeIndex = i
                }
            }
        }
        area = Double(pixelCount) * pw * ph
        mean = sum / Double(pixelCount)
        rawMean = isum / Double(pixelCount)
        mode = Double(cTable[modeIndex])
        standardDeviation = Self.standardDeviation(Double(pixelCount), sum, sum2)
    }

    /// `ImageStatistics.getRawMinAndMax`.
    private mutating func rawMinMax(_ histogram: [Int], _ minT: Int, _ maxT: Int) {
        var low = minT
        while histogram[low] == 0, low < 255 { low += 1 }
        var high = maxT
        while histogram[high] == 0, high > 0 { high -= 1 }
        (min, max) = (Double(low), Double(high))
    }

    private mutating func calibratedMinMax(_ histogram: [Int], _ first: Int, _ last: Int, _ cTable: [Float], emptyIsZero: Bool) {
        if emptyIsZero, pixelCount == 0 {
            (min, max) = (0, 0)
            return
        }
        min = Double.greatestFiniteMagnitude
        max = -Double.greatestFiniteMagnitude
        for i in stride(from: first, through: last, by: 1) where histogram[i] > 0 {
            let v = Double(cTable[i])
            if v < min { min = v }
            if v > max { max = v }
        }
    }

    // MARK: 16-bit

    private mutating func shortStatistics(
        _ p: [UInt16], _ g: Geometry, _ options: Measurements, _ threshold: ClosedRange<Double>?, cTable: [Float]?
    ) {
        let limit = options.contains(.limitToThreshold)
        var minT = 0, maxT = 65535
        if limit, let threshold {
            minT = Swift.max(Int(JavaNumerics.int32(threshold.lowerBound)), 0)
            maxT = Int(JavaNumerics.int32(threshold.upperBound))
        }
        if limit { saveThreshold(Double(minT), Double(maxT), cTable) }
        var histogram = [Int](repeating: 0, count: 65536)
        g.forEachPixel { _, _, i in histogram[Int(p[i])] += 1 }
        maxT = Swift.max(Swift.min(maxT, 65535), 0)
        // getRawMinAndMax(hist, minThreshold, maxThreshold)
        var low = minT
        if low < 65536 {
            while histogram[low] == 0, low < 65535 { low += 1 }
        }
        var high = maxT
        while histogram[high] == 0, high > 0 { high -= 1 }
        (min, max) = (Double(low), Double(high))
        // getStatistics(ip, hist, min, max, cTable)
        var sum = 0.0, sum2 = 0.0
        var maxCount = 0
        var modeValue = 0.0
        for i in stride(from: low, through: high, by: 1) {
            let n = histogram[i]
            if n > maxCount {
                maxCount = n
                modeValue = Double(i)
            }
            pixelCount += n
            let value = Double(cTable.map { $0[i] } ?? Float(i))
            sum += value * Double(n)
            sum2 += (value * value) * Double(n)
        }
        area = Double(pixelCount) * pw * ph
        mean = sum / Double(pixelCount)
        rawMean = mean
        standardDeviation = Self.standardDeviation(Double(pixelCount), sum, sum2)
        mode = cTable.map { Double($0[Int(modeValue)]) } ?? modeValue
        let limited = minT > 0 || maxT < 65535
        centroids(g, options, threshold, value: { Double(p[$0]) }) { !limited || (Int(p[$0]) >= minT && Int(p[$0]) <= maxT) }
        if !options.isDisjoint(with: [.centerOfMass, .skewness, .kurtosis]) {
            moments(g) { i in
                let v = Int(p[i])
                guard v >= minT, v <= maxT else { return nil }
                return Double(cTable.map { $0[v] } ?? Float(v))
            }
        }
        if options.contains(.minMax), let cTable { calibratedMinMax(histogram, low, high, cTable, emptyIsZero: false) }
        if options.contains(.median) {
            median = pixelCount > 0 ? Self.histogramMedian(histogram, minT, maxT, pixelCount, cTable) : .nan
        }
        if options.contains(.areaFraction) { areaFraction = Self.areaFraction(histogram, threshold) }
    }

    // MARK: 32-bit

    private mutating func floatStatistics(
        _ p: [Float], _ g: Geometry, _ options: Measurements, _ threshold: ClosedRange<Double>?
    ) {
        let limit = options.contains(.limitToThreshold)
        var minT = -Double(Float.greatestFiniteMagnitude), maxT = Double(Float.greatestFiniteMagnitude)
        if limit, let threshold { (minT, maxT) = (threshold.lowerBound, threshold.upperBound) }
        if limit { saveThreshold(minT, maxT, nil) }
        // getStatistics: min and max, then a 256-bin histogram between them.
        var roiMin = Double.greatestFiniteMagnitude, roiMax = -Double.greatestFiniteMagnitude
        g.forEachPixel { _, _, i in
            let v = Double(p[i])
            if v >= minT, v <= maxT {
                if v < roiMin { roiMin = v }
                if v > roiMax { roiMax = v }
            }
        }
        (min, max) = (roiMin, roiMax)
        let histMin = roiMin, histMax = roiMax
        let nBins = 256
        let binSize = (histMax - histMin) / Double(nBins)
        let scale = Double(nBins) / (histMax - histMin)
        var histogram = [Int](repeating: 0, count: nBins)
        var sum = 0.0, sum2 = 0.0
        var count = 0
        g.forEachPixel { _, _, i in
            let v = Double(p[i])
            if v >= minT, v <= maxT, v >= histMin, v <= histMax {
                count += 1
                sum += v
                sum2 += v * v
                let index = Swift.min(Int(JavaNumerics.int32(scale * (v - histMin))), nBins - 1)
                histogram[index] += 1
            }
        }
        pixelCount = count
        area = Double(count) * pw * ph
        mean = sum / Double(count)
        rawMean = mean
        standardDeviation = Self.standardDeviation(Double(count), sum, sum2)
        if options.contains(.mode) {
            var maxCount = 0, modeIndex = 0
            for (i, n) in histogram.enumerated() where n > maxCount {
                maxCount = n
                modeIndex = i
            }
            mode = histMin + Double(modeIndex) * binSize
            if binSize != 1 { mode += binSize / 2 }
        }
        centroids(g, options, threshold, value: { Double(p[$0]) }) { Double(p[$0]) >= minT && Double(p[$0]) <= maxT }
        if !options.isDisjoint(with: [.centerOfMass, .skewness, .kurtosis]) {
            moments(g) { i in
                let v = Double(p[i]) + Double.leastNonzeroMagnitude
                return v >= minT && v <= maxT ? v : nil
            }
        }
        if options.contains(.median) { median = Self.floatMedian(p, g, minT, maxT, pixelCount) }
        if options.contains(.areaFraction) {
            // FloatStatistics.calculateAreaFraction compares in float.
            var inside = 0, total = 0
            let t1 = threshold.map { Float($0.lowerBound) }, t2 = threshold.map { Float($0.upperBound) }
            g.forEachPixel { _, _, i in
                total += 1
                if let t1, let t2 {
                    if p[i] >= t1 && p[i] <= t2 { inside += 1 }
                } else if p[i] != 0 {
                    inside += 1
                }
            }
            areaFraction = Double(inside) * 100.0 / Double(total)
        }
    }

    /// `FloatStatistics.getMedian`: the middle value, or the float mean of the two middle ones.
    static func floatMedian(_ p: [Float], _ g: Geometry, _ minT: Double, _ maxT: Double, _ pixelCount: Int) -> Double {
        guard pixelCount > 0 else { return .nan }
        var values: [Float] = []
        values.reserveCapacity(pixelCount)
        var overflow = false
        g.forEachPixel { _, _, i in
            let v = p[i]
            if Double(v) >= minT && Double(v) <= maxT {
                if values.count == pixelCount { overflow = true } else { values.append(v) }
            }
        }
        guard !overflow, values.count == pixelCount else { return .nan }
        values.sort()
        let middle = values.count / 2
        if values.count % 2 == 0 { return Double((values[middle - 1] + values[middle]) / 2) }
        return Double(values[middle])
    }

    // MARK: RGB

    private mutating func colorStatistics(_ p: [UInt32], _ g: Geometry, _ options: Measurements) {
        // ColorProcessor's unweighted luminance: rounded for the histogram, exact for moments.
        let w = 1.0 / 3.0
        func luminance(_ c: UInt32) -> Double {
            Double((c >> 16) & 0xFF) * w + Double((c >> 8) & 0xFF) * w + Double(c & 0xFF) * w
        }
        var histogram = [Int](repeating: 0, count: 256)
        g.forEachPixel { _, _, i in histogram[Int(luminance(p[i]) + 0.5)] += 1 }
        rawStatistics(histogram, 0, 255)
        if options.contains(.minMax) { rawMinMax(histogram, 0, 255) }
        centroids(g, options, nil, value: { Double(Float(luminance(p[$0]))) }) { _ in true }
        if !options.isDisjoint(with: [.centerOfMass, .skewness, .kurtosis]) {
            moments(g) { Double(Float(luminance(p[$0]))) }
        }
        if options.contains(.median) { median = Self.histogramMedian(histogram, 0, 255, pixelCount, nil) }
    }

    // MARK: Shared

    private var pw = 1.0
    private var ph = 1.0

    /// The centroid: from the fitted ellipse when ellipses or shape
    /// descriptors are measured, otherwise the mean pixel position.
    private mutating func centroids(
        _ g: Geometry, _ options: Measurements, _ threshold: ClosedRange<Double>?, value: (Int) -> Double,
        included: (Int) -> Bool
    ) {
        if !options.isDisjoint(with: [.ellipse, .shapeDescriptors]) {
            fitEllipse(g, options, threshold, value: value)
        } else if options.contains(.centroid) {
            var count = 0.0, xsum = 0.0, ysum = 0.0
            g.forEachPixel { x, y, i in
                if included(i) {
                    count += 1
                    xsum += Double(x)
                    ysum += Double(y)
                }
            }
            xCentroid = g.x(xsum / count + 0.5)
            yCentroid = g.y(ysum / count + 0.5)
        }
    }

    /// `ImageStatistics.fitEllipse`.
    private mutating func fitEllipse(
        _ g: Geometry, _ options: Measurements, _ threshold: ClosedRange<Double>?, value: (Int) -> Double
    ) {
        var mask = g.mask
        if options.contains(.limitToThreshold), let threshold {
            var limited = mask ?? Array(repeating: true, count: g.rw * g.rh)
            for y in 0..<g.rh {
                for x in 0..<g.rw {
                    let v = value((g.ry + y) * g.width + g.rx + x)
                    if v < threshold.lowerBound || v > threshold.upperBound { limited[y * g.rw + x] = false }
                }
            }
            mask = limited
        }
        var fitter = EllipseFitter()
        fitter.fit(left: g.rx, top: g.ry, width: g.rw, height: g.rh, mask: mask)
        let pixelSize = abs(g.pw - g.ph) / g.pw < 0.01 ? g.pw : 0
        major = fitter.major * pixelSize
        minor = fitter.minor * pixelSize
        angle = fitter.angle
        xCentroid = g.x(fitter.xCenter)
        yCentroid = g.y(fitter.yCenter)
    }

    /// Center of mass, skewness and kurtosis from the pixels `value` doesn't skip.
    private mutating func moments(_ g: Geometry, value: (Int) -> Double?) {
        var sum1 = 0.0, sum2 = 0.0, sum3 = 0.0, sum4 = 0.0, xsum = 0.0, ysum = 0.0
        g.forEachPixel { x, y, i in
            guard let v = value(i) else { return }
            let v2 = v * v
            sum1 += v
            sum2 += v2
            sum3 += v * v2
            sum4 += v2 * v2
            xsum += Double(x) * v
            ysum += Double(y) * v
        }
        let n = Double(pixelCount)
        let mean2 = mean * mean
        let variance = sum2 / n - mean2
        let sDeviation = variance.squareRoot()
        skewness = ((sum3 - 3.0 * mean * sum2) / n + 2.0 * mean * mean2) / (variance * sDeviation)
        kurtosis = (((sum4 - 4.0 * mean * sum3 + 6.0 * mean2 * sum2) / n - 3.0 * mean2 * mean2) / (variance * variance) - 3.0)
        xCenterOfMass = g.x(xsum / sum1 + 0.5)
        yCenterOfMass = g.y(ysum / sum1 + 0.5)
    }

    private mutating func saveThreshold(_ low: Double, _ high: Double, _ cTable: [Float]?) {
        func calibrated(_ v: Double) -> Double {
            guard let cTable, v >= 0, Int(v) < cTable.count else { return v }
            return Double(cTable[Int(v)])
        }
        lowerThreshold = calibrated(low)
        upperThreshold = calibrated(high)
    }

    /// `ImageStatistics.calculateStdDev`: the sample standard deviation.
    static func standardDeviation(_ n: Double, _ sum: Double, _ sum2: Double) -> Double {
        guard n > 0 else { return 0 }
        let s = (n * sum2 - sum * sum) / n
        return s > 0 ? (s / (n - 1.0)).squareRoot() : 0
    }

    /// `ImageStatistics.calculateMedian`: the first value past half the pixels.
    static func histogramMedian(_ histogram: [Int], _ first: Int, _ last: Int, _ pixelCount: Int, _ cTable: [Float]?) -> Double {
        guard pixelCount > 0, first >= 0, last <= histogram.count else { return .nan }
        var sum = 0.0
        var i = first - 1
        let half = Double(pixelCount) / 2.0
        repeat {
            i += 1
            sum += Double(histogram[i])
        } while sum <= half && i < last
        return cTable.map { Double($0[i]) } ?? Double(i)
    }

    /// `ImageStatistics.calculateAreaFraction`: the percentage of pixels
    /// within the threshold, or that aren't zero without one.
    static func areaFraction(_ histogram: [Int], _ threshold: ClosedRange<Double>?) -> Double {
        var inside = 0, total = 0
        if let threshold {
            let t1 = Int(JavaNumerics.round(threshold.lowerBound)), t2 = Int(JavaNumerics.round(threshold.upperBound))
            for (i, n) in histogram.enumerated() {
                if i >= t1 && i <= t2 { inside += n }
                total += n
            }
        } else {
            total = histogram.reduce(0, +)
            inside = total - histogram[0]
        }
        return Double(inside) * 100.0 / Double(total)
    }
}

/// The measured rectangle, its mask and the calibration's coordinate conversions.
struct Geometry {
    let width: Int
    let height: Int
    let rx: Int
    let ry: Int
    let rw: Int
    let rh: Int
    let mask: [Bool]?
    let pw: Double
    let ph: Double
    let xOrigin: Double
    let yOrigin: Double
    let invertY: Bool

    init(width: Int, height: Int, region: MeasurementRegion, calibration: Calibration, invertY: Bool) {
        self.width = width
        self.height = height
        (rx, ry, rw, rh) = (region.x, region.y, region.width, region.height)
        mask = region.mask
        pw = calibration.pixelWidth
        ph = calibration.pixelHeight
        xOrigin = calibration.xOrigin
        yOrigin = calibration.yOrigin
        self.invertY = invertY
    }

    /// `Calibration.getX`.
    func x(_ x: Double) -> Double { (x - xOrigin) * pw }

    /// `Calibration.getY(y, imageHeight)`, with Invert Y measured from the origin or the bottom row.
    func y(_ y: Double) -> Double {
        guard invertY else { return (y - yOrigin) * ph }
        return yOrigin != 0 ? (yOrigin - y) * ph : (Double(height) - y - 1) * ph
    }

    /// Calls `body` with the position and index of every measured pixel, row by row.
    func forEachPixel(_ body: (_ x: Int, _ y: Int, _ index: Int) -> Void) {
        for y in ry..<(ry + rh) {
            let row = y * width
            let maskRow = (y - ry) * rw
            for x in rx..<(rx + rw) where mask?[maskRow + x - rx] ?? true {
                body(x, y, row + x)
            }
        }
    }
}
