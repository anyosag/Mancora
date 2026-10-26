public import MancoraCore

/// A histogram and the statistics Analyze ▸ Histogram shows beside it,
/// computed as ImageJ 1.54p's `ImagePlus.getStatistics(AREA+MEAN+MODE+MIN_MAX,
/// nBins, histMin, histMax)` computes them for one plane:
///
/// - 8-bit and RGB with 256 bins (`ByteStatistics`, `ColorStatistics`): one
///   bin per value (RGB pixels by their rounded luminance), from 0 to 255.
/// - 8-bit and RGB with other bin counts, and 16-bit (`ShortStatistics`):
///   `bins` bins from `histMin` to `histMax` (the smallest and largest value
///   when both are 0), `binWidth = (histMax - histMin + 1) / bins`. Only
///   values within the range are counted, but `min` and `max` are those of
///   every pixel; `mode` is the most frequent single value. A 16-bit range
///   is given in calibrated values.
/// - 32-bit (`FloatStatistics`): `bins` bins from `histMin` to `histMax`
///   (the data's range when both are 0), `binWidth = (histMax - histMin) /
///   bins`; `min` and `max` are clipped to the range, and `mode` is the
///   middle of the fullest bin.
///
/// Mean, standard deviation, minimum, maximum and mode are calibrated
/// values (8- and 16-bit images with a value calibration).
public struct HistogramData: Sendable, Hashable {
    /// The count in each bin (ImageJ's `histogram`).
    public var counts: [Int]
    /// The number of bins (`nBins`).
    public var bins: Int
    /// The raw value at the start of the first bin (`histMin`), and the
    /// largest raw value the bins cover (`histMax`).
    public var histMin: Double
    public var histMax: Double
    /// The width of a bin, in raw values (`binSize`).
    public var binWidth: Double
    /// The calibrated value at the start of each bin: the "value" (or "bin
    /// start") column of the histogram's List (`HistogramWindow.getXValues`).
    public var binStarts: [Double]
    /// The calibrated `histMin` and `histMax`: the labels at either end of
    /// ImageJ's histogram axis.
    public var binStart: Double
    public var binEnd: Double
    /// N: the number of pixels counted.
    public var count: Int
    public var mean: Double
    public var stdDev: Double
    public var min: Double
    public var max: Double
    /// The mode ImageJ shows (`dmode`).
    public var mode: Double
    /// The count of the fullest bin (`maxCount`), which ImageJ shows after
    /// the mode.
    public var modeCount: Int
    /// Whether more than one bin holds `modeCount` (ImageJ marks the mode
    /// with "*").
    public var isMultimodal: Bool
    /// Whether ImageJ's histogram window lists Bins and Bin Width: when the
    /// bins are not one value wide, and always for 16- and 32-bit images.
    public var showsBins: Bool

    /// The histogram of `plane` (`width` pixels wide) within `region` (the
    /// whole plane when `nil`), in `bins` bins from `histMin` to `histMax`
    /// (the data's range when both are 0, or when `histMin > histMax`).
    public init(
        plane: Plane, width: Int, region: MeasurementRegion? = nil, calibration: Calibration = Calibration(),
        bins: Int = 256, histMin: Double = 0, histMax: Double = 0, rgbWeights: RGBWeights = .unweighted
    ) {
        let cal = ProfilePlot.valueCalibration(calibration, plane)
        let stats = HistogramStatistics(
            plane: plane, width: width, region: region, calibration: cal, bins: bins, histMin: histMin, histMax: histMax,
            rgbWeights: rgbWeights)
        self.init(stats, calibration: cal, fixedRange: plane.pixelType == .gray8 || plane.pixelType == .rgb8)
    }

    init(_ s: HistogramStatistics, calibration: Calibration, fixedRange: Bool) {
        counts = s.histogram
        bins = s.nBins
        histMin = s.histMin
        histMax = s.histMax
        binWidth = s.binSize
        binStarts = (0..<s.nBins).map { calibration.calibratedValue(s.histMin + Double($0) * s.binSize) }
        binStart = calibration.calibratedValue(s.histMin)
        binEnd = calibration.calibratedValue(s.histMax)
        count = s.pixelCount
        mean = s.mean
        stdDev = s.stdDev
        min = s.min
        max = s.max
        mode = s.dmode
        modeCount = s.maxCount
        isMultimodal = s.histogram.count(where: { $0 == s.maxCount }) > 1
        showsBins = abs(s.binSize) != 1.0 || !fixedRange
    }
}

/// The fields of ImageJ's `ImageStatistics` a histogram fills in.
struct HistogramStatistics {
    var histogram: [Int] = []
    var nBins = 256
    var histMin = 0.0
    var histMax = 0.0
    var binSize = 1.0
    var pixelCount = 0
    var mean = 0.0
    var stdDev = 0.0
    var min = 0.0
    var max = 0.0
    /// The bin (or value) with the most pixels, and that count.
    var mode = 0
    var dmode = 0.0
    var maxCount = 0

    /// `ImagePlus.getStatistics(AREA+MEAN+MODE+MIN_MAX, bins, histMin, histMax)`
    /// with `calibration` the one ImageJ keeps for the plane's type.
    init(
        plane: Plane, width: Int, region: MeasurementRegion?, calibration: Calibration, bins: Int, histMin: Double,
        histMax: Double, rgbWeights: RGBWeights
    ) {
        let height = width > 0 ? plane.count / width : 0
        let r = region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height)
        // ImageProcessor.setHistogramSize and setHistogramRange.
        let size = Swift.max(bins, 1)
        var low = histMin, high = histMax
        if case .gray16 = plane, !(low == 0 && high == 0) {
            low = calibration.rawValue(low)
            high = calibration.rawValue(high)
        }
        if low > high { (low, high) = (0, 0) }
        switch plane {
        case .gray8(let p):
            let table = MeasurementStatistics.cTable(calibration, count: 256)
            if bins == 256 {
                byteStatistics(Self.counts(256, r, width, height) { Int(p[$0]) }, table, color: false)
            } else {
                shortStatistics(Self.counts(65536, r, width, height) { Int(p[$0]) }, table, size, low, high)
            }
        case .rgb8(let p):
            let w = rgbWeights
            let luminance: (Int) -> Int = { i in
                let c = p[i]
                let v = Double((c >> 16) & 0xFF) * w.red + Double((c >> 8) & 0xFF) * w.green + Double(c & 0xFF) * w.blue + 0.5
                return Int(JavaNumerics.int32(v)) & 0xFF
            }
            if bins == 256 {
                byteStatistics(Self.counts(256, r, width, height, luminance), nil, color: true)
            } else {
                shortStatistics(Self.counts(65536, r, width, height, luminance), nil, size, low, high)
            }
        case .gray16(let p):
            let table = MeasurementStatistics.cTable(calibration, count: 65536)
            shortStatistics(Self.counts(65536, r, width, height) { Int(p[$0]) }, table, size, low, high)
        case .gray32Float(let p):
            floatStatistics(p, r, width, height, size, low, high)
        }
    }

    /// The count of each value `value` gives the region's pixels (by index).
    static func counts(_ size: Int, _ r: MeasurementRegion, _ width: Int, _ height: Int, _ value: (Int) -> Int) -> [Int] {
        var histogram = [Int](repeating: 0, count: size)
        forEachPixel(r, width, height) { histogram[value($0)] += 1 }
        return histogram
    }

    /// The index of every pixel of the region inside the image, row by row.
    static func forEachPixel(_ r: MeasurementRegion, _ width: Int, _ height: Int, _ body: (Int) -> Void) {
        let y0 = Swift.max(r.y, 0), y1 = Swift.min(r.y + r.height, height)
        let x0 = Swift.max(r.x, 0), x1 = Swift.min(r.x + r.width, width)
        guard y0 < y1, x0 < x1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 where r.contains(x, y) { body(y * width + x) }
        }
    }

    // MARK: ByteStatistics and ColorStatistics

    /// `ByteStatistics` (with the calibration table, if any) and
    /// `ColorStatistics`: 256 bins, one per value.
    private mutating func byteStatistics(_ hist: [Int], _ cTable: [Float]?, color: Bool) {
        histogram = hist
        nBins = 256
        binSize = 1
        if let cTable {
            // getCalibratedStatistics
            var sum = 0.0, sum2 = 0.0
            for i in 0...255 {
                let count = hist[i]
                let value = Double(cTable[i])
                if count > 0 && !value.isNaN {
                    pixelCount += count
                    sum += value * Double(count)
                    sum2 += (value * value) * Double(count)
                    if count > maxCount {
                        maxCount = count
                        mode = i
                    }
                }
            }
            mean = sum / Double(pixelCount)
            dmode = Double(cTable[mode])
            stdDev = MeasurementStatistics.standardDeviation(Double(pixelCount), sum, sum2)
        } else {
            // getRawStatistics
            var sum = 0.0, sum2 = 0.0
            for i in 0...255 {
                let count = hist[i]
                pixelCount += count
                sum += Double(i) * Double(count)
                let value = Double(i)
                sum2 += (value * value) * Double(count)
                if count > maxCount {
                    maxCount = count
                    mode = i
                }
            }
            mean = sum / Double(pixelCount)
            dmode = Double(mode)
            stdDev = MeasurementStatistics.standardDeviation(Double(pixelCount), sum, sum2)
        }
        histMin = 0
        histMax = 255
        if pixelCount == 0 && !color {
            (min, max) = (.nan, .nan)
        } else if let cTable {
            min = Double.greatestFiniteMagnitude
            max = -Double.greatestFiniteMagnitude
            for i in 0...255 where hist[i] > 0 {
                let v = Double(cTable[i])
                if v < min { min = v }
                if v > max { max = v }
            }
        } else {
            var low = 0
            while hist[low] == 0 && low < 255 { low += 1 }
            var high = 255
            while hist[high] == 0 && high > 0 { high -= 1 }
            (min, max) = (Double(low), Double(high))
        }
    }

    // MARK: ShortStatistics

    /// `ShortStatistics`: `hist` holds the count of every raw value.
    private mutating func shortStatistics(
        _ hist: [Int], _ cTable: [Float]?, _ size: Int, _ rangeMin: Double, _ rangeMax: Double
    ) {
        // getRawMinAndMax
        var low = 0
        while hist[low] == 0 && low < hist.count - 1 { low += 1 }
        var high = hist.count - 1
        while hist[high] == 0 && high > 0 { high -= 1 }
        (min, max) = (Double(low), Double(high))
        // getStatistics
        nBins = size
        histMin = rangeMin
        histMax = rangeMax
        var first = low, last = high
        if histMin == 0 && histMax == 0 {
            histMin = min
            histMax = max
        } else {
            if Double(first) < histMin { first = Int(JavaNumerics.int32(histMin)) }
            if Double(last) > histMax { last = Int(JavaNumerics.int32(histMax)) }
        }
        binSize = (histMax - histMin + 1) / Double(nBins)
        let scale = 1.0 / binSize
        let hMin = Int(JavaNumerics.int32(histMin))
        histogram = [Int](repeating: 0, count: nBins)
        var sum = 0.0, sum2 = 0.0
        var valueMaxCount = 0
        if first <= last {
            for i in first...last {
                let count = hist[i]
                if count > valueMaxCount {
                    valueMaxCount = count
                    dmode = Double(i)
                }
                pixelCount += count
                let value = cTable.map { Double($0[i]) } ?? Double(i)
                sum += value * Double(count)
                sum2 += (value * value) * Double(count)
                var index = Int(JavaNumerics.int32(scale * Double(i - hMin)))
                if index >= nBins { index = nBins - 1 }
                histogram[Swift.max(index, 0)] += count
            }
        }
        mean = sum / Double(pixelCount)
        stdDev = MeasurementStatistics.standardDeviation(Double(pixelCount), sum, sum2)
        if let cTable { dmode = Double(cTable[Int(dmode)]) }
        binMode()
        if let cTable {
            // getCalibratedMinAndMax over every value present
            min = Double.greatestFiniteMagnitude
            max = -Double.greatestFiniteMagnitude
            if low <= high {
                for i in low...high where hist[i] > 0 {
                    let v = Double(cTable[i])
                    if v < min { min = v }
                    if v > max { max = v }
                }
            }
        }
    }

    /// `getMode()` of 16- and 32-bit statistics: the fullest bin.
    private mutating func binMode() {
        maxCount = 0
        for (i, count) in histogram.enumerated() where count > maxCount {
            maxCount = count
            mode = i
        }
    }

    // MARK: FloatStatistics

    /// `FloatStatistics`: NaN and infinite values are not counted.
    private mutating func floatStatistics(
        _ p: [Float], _ r: MeasurementRegion, _ width: Int, _ height: Int, _ size: Int, _ rangeMin: Double, _ rangeMax: Double
    ) {
        let minThreshold = -Double(Float.greatestFiniteMagnitude), maxThreshold = Double(Float.greatestFiniteMagnitude)
        nBins = size
        histMin = rangeMin
        histMax = rangeMax
        histogram = [Int](repeating: 0, count: nBins)
        var roiMin = Double.greatestFiniteMagnitude, roiMax = -Double.greatestFiniteMagnitude
        Self.forEachPixel(r, width, height) { i in
            let v = Double(p[i])
            if v >= minThreshold && v <= maxThreshold {
                if v < roiMin { roiMin = v }
                if v > roiMax { roiMax = v }
            }
        }
        (min, max) = (roiMin, roiMax)
        if histMin == 0 && histMax == 0 {
            histMin = min
            histMax = max
        } else {
            if min < histMin { min = histMin }
            if max > histMax { max = histMax }
        }
        binSize = (histMax - histMin) / Double(nBins)
        let scale = Double(nBins) / (histMax - histMin)
        var sum = 0.0, sum2 = 0.0
        var count = 0
        let (hMin, hMax, bins) = (histMin, histMax, nBins)
        var hist = histogram
        Self.forEachPixel(r, width, height) { i in
            let v = Double(p[i])
            if v >= minThreshold && v <= maxThreshold && v >= hMin && v <= hMax {
                count += 1
                sum += v
                sum2 += v * v
                var index = Int(JavaNumerics.int32(scale * (v - hMin)))
                if index >= bins { index = bins - 1 }
                hist[Swift.max(index, 0)] += 1
            }
        }
        histogram = hist
        pixelCount = count
        mean = sum / Double(count)
        stdDev = MeasurementStatistics.standardDeviation(Double(count), sum, sum2)
        binMode()
        dmode = histMin + Double(mode) * binSize
        if binSize != 1.0 { dmode += binSize / 2.0 }
    }
}
