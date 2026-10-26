// Line profiles, histograms and the keys macros hold down, ported from
// ImageJ 1.54p's Functions.java (getProfile, getLine, getHistogram,
// setKeyDown, isKeyDown).

import MancoraCommands
import MancoraCore
import MancoraProcess

extension Functions {
    // MARK: - Keys

    /// `setKeyDown(keys)`: holds down Alt, Shift, Control or the space bar
    /// until the next selection, `run` or the end of the macro.
    func setKeyDown() throws(MacroSignal) {
        let keys = javaToLowerCase(try getStringArg())
        selectionAlt = keys.contains("alt")
        session.keys.alt = selectionAlt
        selectionShift = keys.contains("shift")
        session.keys.shift = selectionShift
        session.keys.control = keys.contains("control")
        session.keys.space = keys == "space"
        if keys.contains("esc") { try unsupported("setKeyDown(\"esc\")") }
        keysSet = true
    }

    func isKeyDown() throws(MacroSignal) -> Double {
        let key = javaToLowerCase(try getStringArg())
        let keys = session.keys
        if key.contains("alt") { return keys.alt ? 1 : 0 }
        if key.contains("shift") { return keys.shift ? 1 : 0 }
        if key.contains("space") { return keys.space ? 1 : 0 }
        if key.contains("control") { return keys.control ? 1 : 0 }
        try interp.error("Invalid key")
        return 0
    }

    /// What `run` and `makeRectangle` do afterwards: `IJ.setKeyUp(IJ.ALL_KEYS)`.
    func releaseKeys() {
        session.keys.releaseAll()
        (selectionShift, selectionAlt) = (false, false)
    }

    /// A selection function, which in ImageJ adds the new selection to the
    /// previous one (shift held) or subtracts it (alt): Mancora can't
    /// combine selections yet. `combines` says which new selections ImageJ
    /// combines.
    func makingSelection(
        _ name: String, combines: (Roi) -> Bool = { _ in true }, releasingKeys: Bool = false,
        _ make: () throws(MacroSignal) -> Void
    ) throws(MacroSignal) {
        let held = selectionShift || selectionAlt
        let hadSelection = held && session.context.current?.roi != nil
        try make()
        if hadSelection, let roi = session.context.current?.roi, combines(roi) {
            try unsupported("\(name) with the shift or alt key down")
        }
        (selectionShift, selectionAlt) = (false, false)
        if releasingKeys { session.keys.releaseAll() }
    }

    // MARK: - Profiles

    /// `getLine(x1, y1, x2, y2, lineWidth)`: the straight line selection's
    /// end points (-1 without one) and the selection's width.
    func getLine() throws(MacroSignal) {
        let vx1 = try getFirstVariable()
        let vy1 = try getNextVariable()
        let vx2 = try getNextVariable()
        let vy2 = try getNextVariable()
        let lineWidth = try getLastVariable()
        let roi = try image().roi
        var (x1, y1, x2, y2) = (-1.0, -1.0, -1.0, -1.0)
        if let roi, case .line(let line) = roi.shape { (x1, y1, x2, y2) = (line.x1, line.y1, line.x2, line.y2) }
        vx1.setValue(x1)
        vy1.setValue(y1)
        vx2.setValue(x2)
        vy2.setValue(y2)
        lineWidth.setValue(roi.map { Double($0.strokeWidth) } ?? 1)
    }

    /// `getProfile()`: `ProfilePlot`'s values for the selection, rows
    /// averaged when Alt is held (`setKeyDown("alt")`).
    func getProfile() throws(MacroSignal) -> VariableArray? {
        try interp.getParens()
        let open = try image()
        guard let roi = open.roi else { try interp.fail("Selection required") }
        if session.bicubic { try unsupported("getProfile with bicubic interpolation") }
        let options = ProfilePlot.Options(
            interpolate: session.context.settings.interpolateLineProfiles, vertical: session.keys.alt)
        do {
            let data = try ProfilePlot.profile(
                of: open.currentPlane, width: open.image.width, roi: roi, calibration: open.image.calibration,
                options: options)
            return VariableArray(data.yValues.map { Variable($0) })
        } catch .splineFit {
            try unsupported("getProfile of a spline-fitted line")
        } catch {
            try interp.fail(error.description)
        }
    }

    // MARK: - Histograms

    /// `getHistogram(values, counts, nBins[, histMin, histMax])`: the
    /// histogram `ImagePlus.getStatistics` computes. 8-bit and RGB images
    /// with other than 256 bins are histogrammed whole (ImageJ copies the
    /// image without its selection), as 16-bit values from 0 to 256; a
    /// 16-bit image with 65536 bins gives the count of every value.
    func getHistogram() throws(MacroSignal) {
        try interp.getLeftParen()
        var values: Variable?
        if interp.nextToken() == NUMBER { _ = try interp.getExpression() } else { values = try getArrayVariable() }
        try interp.getComma()
        let counts = try getArrayVariable()
        try interp.getComma()
        let nBins = jIntI(try interp.getExpression())
        let open = try image()
        let bitDepth = open.image.pixelType.bitDepth
        var histMin = 0.0, histMax = 0.0
        if interp.nextToken() == ch(",") {
            histMin = try getNextArg()
            histMax = try getLastArg()
            if bitDepth == 8 || bitDepth == 24 { try interp.error("16 or 32-bit image required to set histMin and histMax") }
        } else {
            try interp.getRightParen()
        }
        if nBins < 1 { try unsupported("getHistogram with \(nBins) bins") }
        let width = open.image.width, height = open.image.height
        let histogram: [Int]
        if nBins == 65536 && bitDepth == 16, case .gray16(let p) = open.currentPlane {
            // ip.setRoi(roi); ip.getHistogram(): every value; `values` is left alone.
            if let roi = open.roi, !roi.isArea {
                try unsupported("getHistogram with 65536 bins and a line or point selection")
            }
            let region = try statisticsRegion(open)
            var counts65536 = [Int](repeating: 0, count: 65536)
            let r = region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height)
            for y in max(r.y, 0)..<max(max(r.y, 0), min(r.y + r.height, height)) {
                for x in max(r.x, 0)..<max(max(r.x, 0), min(r.x + r.width, width)) where r.contains(x, y) {
                    counts65536[Int(p[y * width + x])] += 1
                }
            }
            histogram = counts65536
        } else {
            let custom8Bit = (bitDepth == 8 || bitDepth == 24) && nBins != 256
            var calibration = open.image.calibration
            var region: MeasurementRegion?
            if custom8Bit {
                // imp.createImagePlus() with a 16-bit copy: no selection, and a
                // range from 0 to 256 that, as for any 16-bit image, is
                // calibrated (the copy keeps the 8-bit value calibration).
                (histMin, histMax) = (calibration.rawValue(0), calibration.rawValue(256))
            } else {
                region = try statisticsRegion(open)
            }
            // 32-bit and RGB images have no value calibration.
            if bitDepth == 32 || bitDepth == 24 { calibration.valueFunction = nil }
            let data = HistogramData(
                plane: open.currentPlane, width: width, region: region, calibration: calibration, bins: nBins,
                histMin: histMin, histMax: histMax)
            histogram = data.counts
            if let values {
                let cal = calibration
                var value = cal.calibratedValue(data.histMin)
                var inc = 1.0
                if bitDepth == 16 || bitDepth == 32 || cal.valueFunction != nil || custom8Bit {
                    inc = (cal.calibratedValue(data.histMax) - cal.calibratedValue(data.histMin)) / Double(data.bins)
                }
                var array: [Double] = []
                for _ in 0..<nBins {
                    array.append(value)
                    value += inc
                }
                values.setArray(VariableArray(array.map { Variable($0) }))
            }
        }
        if let array = counts.getArray(), array.count == nBins {
            for i in 0..<nBins { array[i].setValue(Double(histogram[i])) }
        } else {
            counts.setArray(VariableArray(histogram.map { Variable(Double($0)) }))
        }
    }

    /// The pixels `ImagePlus.getStatistics` measures: the selection's mask,
    /// a single point, or (`nil`) the whole image.
    private func statisticsRegion(_ open: OpenImage) throws(MacroSignal) -> MeasurementRegion? {
        do { return try open.statisticsRegion("getHistogram") } catch {
            if case .failed(_, let detail) = error { try interp.fail(detail) }
            try interp.fail(error.description)
        }
    }
}
