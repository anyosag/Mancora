/// The pixels a ROI selects, within a rectangle of the image (ImageJ's
/// `Roi.getMask()` placed at `Roi.getBounds()`).
public struct RoiMask: Hashable, Sendable {
    /// Where the mask lies in the image.
    public var bounds: RoiBounds
    /// `bounds.width × bounds.height` flags, row by row.
    public var pixels: [Bool]

    public init(bounds: RoiBounds, pixels: [Bool]) {
        precondition(pixels.count == bounds.width * bounds.height, "mask size does not match its bounds")
        self.bounds = bounds
        self.pixels = pixels
    }

    /// Whether image pixel (x, y) is selected; false outside the bounds.
    public subscript(x x: Int, y y: Int) -> Bool {
        let mx = x - bounds.x, my = y - bounds.y
        guard mx >= 0, my >= 0, mx < bounds.width, my < bounds.height else { return false }
        return pixels[my * bounds.width + mx]
    }

    /// The number of selected pixels.
    public var count: Int { pixels.reduce(0) { $0 + ($1 ? 1 : 0) } }
}

/// Why a ROI has no mask.
public enum RoiMaskError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Lines and points don't enclose pixels.
    case notAnArea
    /// Mancora can't compute this mask yet (composite, text and image ROIs,
    /// and spline-fitted outlines).
    case unsupported(String)
    /// The bounds exceed what ImageJ can allocate (2³¹ − 1 pixels).
    case tooLarge(width: Int, height: Int)

    public var description: String {
        switch self {
        case .notAnArea: "Lines and points have no mask."
        case .unsupported(let what): "Masks of \(what) are not supported yet."
        case .tooLarge(let w, let h): "A \(w)×\(h) mask is too large."
        }
    }
}

extension Roi {
    /// The pixels inside the ROI, at ``bounds``: exactly the pixels ImageJ
    /// 1.54p's `Roi.getMask()` selects (all of them for a plain rectangle,
    /// whose ImageJ mask is `null`).
    ///
    /// Ovals use `OvalRoi.getMask()`'s own pixel test, rounded rectangles
    /// flatten their corners as `ShapeRoi` does, and polygons are filled by a
    /// port of ImageJ's `PolygonFiller` (even-odd, pixel centers).
    public func mask() throws(RoiMaskError) -> RoiMask {
        try mask(clip: nil)
    }

    /// The pixels of a `width × height` image inside the ROI: the mask
    /// clipped to the image, as `ImageProcessor.setRoi(roi)` crops it (and
    /// `ImageProcessor.fill(roi)` fills). A ROI entirely outside the image
    /// gives an empty mask at (0, 0).
    public func mask(width: Int, height: Int) throws(RoiMaskError) -> RoiMask {
        try mask(clip: RoiBounds(x: 0, y: 0, width: max(width, 0), height: max(height, 0)))
    }

    private func mask(clip: RoiBounds?) throws(RoiMaskError) -> RoiMask {
        let b = bounds
        let filler: Filler
        switch shape {
        case .line, .points:
            throw .notAnArea
        case .opaque(let o):
            throw .unsupported(o.kind == .composite ? "composite ROIs" : o.kind == .text ? "text ROIs" : "image ROIs")
        case .rectangle(_, let corner) where corner > 0:
            let path = FlattenedPath.roundedRectangle(
                x: Int32(b.x), y: Int32(b.y), width: Int32(b.width), height: Int32(b.height),
                corner: Int32(clamping: corner))
            // ShapeRoi.FILL_FLATNESS; the offset is getXBase() - x = 0.
            let p = FlattenedPath.polygon(path, flatness: 0.01)
            filler = .polygon(PolygonFiller(xs: p.xs, ys: p.ys, xOffset: 0, yOffset: 0))
        case .rectangle:
            filler = .all
        case .oval:
            filler = .oval
        case .polygon(let p):
            if p.kind.isLine { throw .notAnArea }
            if p.isSplineFit { throw .unsupported("spline-fitted outlines") }
            let s = p.state
            if let xpf = s.xpf, let ypf = s.ypf {
                filler = .polygon(PolygonFiller(
                    xs: xpf, ys: ypf, xOffset: s.xBase - Double(s.x), yOffset: s.yBase - Double(s.y)))
            } else {
                filler = .polygon(PolygonFiller(xs: s.xp ?? [], ys: s.yp ?? []))
            }
        }
        let (area, overflow) = b.width.multipliedReportingOverflow(by: b.height)
        guard b.width >= 0, b.height >= 0, !overflow, area <= Int(Int32.max) else {
            throw .tooLarge(width: b.width, height: b.height)
        }

        // The part of the mask to keep, in mask coordinates.
        var keep = RoiBounds(x: 0, y: 0, width: b.width, height: b.height)
        var placed = b
        if let clip, b.x < 0 || b.y < 0 || b.x + b.width > clip.width || b.y + b.height > clip.height {
            let x1 = max(b.x, clip.x), y1 = max(b.y, clip.y)
            let x2 = min(b.x + b.width, clip.x + clip.width), y2 = min(b.y + b.height, clip.y + clip.height)
            guard x2 > x1, y2 > y1 else { return RoiMask(bounds: RoiBounds(x: 0, y: 0, width: 0, height: 0), pixels: []) }
            keep = RoiBounds(x: x1 - b.x, y: y1 - b.y, width: x2 - x1, height: y2 - y1)
            placed = RoiBounds(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        }
        var pixels = [Bool](repeating: false, count: keep.width * keep.height)
        switch filler {
        case .all:
            pixels = [Bool](repeating: true, count: pixels.count)
        case .oval:
            // OvalRoi.getMask(): pixel centers inside the inscribed ellipse.
            var a = Double(b.width) / 2.0, bb = Double(b.height) / 2.0
            let a2 = a * a, b2 = bb * bb
            a -= 0.5
            bb -= 0.5
            for my in 0..<keep.height {
                let yy = Double(keep.y + my) - bb
                for mx in 0..<keep.width {
                    let xx = Double(keep.x + mx) - a
                    if xx * xx / a2 + yy * yy / b2 <= 1.0 { pixels[my * keep.width + mx] = true }
                }
            }
        case .polygon(var pf):
            pf.fill(width: b.width, height: b.height, rowLimit: keep.y + keep.height) { y, x1, x2 in
                guard y >= keep.y else { return }
                let from = max(x1, keep.x), to = min(x2, keep.x + keep.width)
                guard from < to else { return }
                let row = (y - keep.y) * keep.width - keep.x
                for x in from..<to { pixels[row + x] = true }
            }
        }
        return RoiMask(bounds: placed, pixels: pixels)
    }

    private enum Filler {
        case all, oval
        case polygon(PolygonFiller)
    }
}
