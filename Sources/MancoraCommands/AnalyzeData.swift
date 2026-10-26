import MancoraCore
public import MancoraProcess

// Analyze ▸ Plot Profile and Analyze ▸ Histogram draw a plot window in
// ImageJ. Mancora gives their data instead, for a user interface to plot;
// the commands themselves stay with ImageJ (through the bridge), since
// their windows can't be reproduced pixel for pixel.

extension CommandContext {
    /// Analyze ▸ Plot Profile's data (ImageJ's `Profiler`): the profile of
    /// the current image's line or rectangular selection on the plane
    /// shown. Rectangles are averaged by row with Edit ▸ Options ▸ Plots ▸
    /// Vertical profile, or with the Alt key held.
    public func plotProfile(altKeyDown: Bool = false) throws(CommandError) -> ProfileData {
        let name = "Plot Profile"
        guard let open = current else { throw .noImage(name) }
        guard let roi = open.roi else { throw .failed(command: name, detail: ProfileError.lineOrRectangleRequired.description) }
        let options = ProfilePlot.Options(
            interpolate: settings.interpolateLineProfiles, vertical: settings.verticalProfile || altKeyDown)
        do {
            return try ProfilePlot.profile(
                of: open.currentPlane, width: open.image.width, roi: roi, calibration: open.image.calibration,
                options: options)
        } catch {
            throw .failed(command: name, detail: error.description)
        }
    }

    /// Analyze ▸ Histogram's data (ImageJ's `Histogram` and
    /// `HistogramWindow`) for the plane shown and its selection: `bins`
    /// bins from `histMin` to `histMax` in calibrated values (both 0: the
    /// pixel value range).
    ///
    /// ImageJ histograms 8-bit and RGB images with other bins or a range,
    /// and whole stacks, with `StackStatistics`, which Mancora doesn't have
    /// yet; for those, and with "Limit to threshold" on a thresholded image,
    /// this throws ``CommandError/notNative(_:)``.
    public func histogram(bins: Int = 256, histMin: Double = 0, histMax: Double = 0) throws(CommandError) -> HistogramData {
        let name = "Histogram"
        guard let open = current else { throw .noImage(name) }
        let type = open.image.pixelType
        if (type == .gray8 || type == .rgb8) && (bins != 256 || histMin != 0 || histMax != 0) { throw .notNative(name) }
        if settings.measurements.contains(.limitToThreshold) && open.threshold != nil { throw .notNative(name) }
        return HistogramData(
            plane: open.currentPlane, width: open.image.width, region: try open.statisticsRegion(name),
            calibration: open.image.calibration, bins: bins, histMin: histMin, histMax: histMax)
    }
}

extension OpenImage {
    /// The pixels `ImagePlus.getStatistics` measures for the selection: an
    /// area's mask, a single point's pixel, and the whole image for lines,
    /// several points or no selection (`nil`).
    public func statisticsRegion(_ command: String) throws(CommandError) -> MeasurementRegion? {
        guard let roi else { return nil }
        if roi.isArea {
            do { return try roi.measurementRegion(width: image.width, height: image.height) } catch {
                throw .failed(command: command, detail: "\(error)")
            }
        }
        if case .points(let points) = roi.shape, points.vertices.count == 1 {
            // ip.setRoi((int)x, (int)y, 1, 1), clipped to the image.
            let p = points.vertices.floatPoints[0]
            let x = Int(JavaNumerics.int32(p.x)), y = Int(JavaNumerics.int32(p.y))
            guard x >= 0, y >= 0, x < image.width, y < image.height else {
                return MeasurementRegion(x: 0, y: 0, width: 0, height: 0)
            }
            return MeasurementRegion(x: x, y: y, width: 1, height: 1)
        }
        return nil
    }
}
