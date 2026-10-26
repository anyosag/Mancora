public import MancoraCore

/// The part of a plane a filter works on, as ImageJ's `PlugInFilterRunner`
/// sets it up (`ImageProcessor.setRoi(roi)`): the selection's bounding
/// rectangle, clipped to the plane, and for a non-rectangular selection the
/// mask that `ImageProcessor.reset(mask)` uses afterwards to restore the
/// pixels of the rectangle outside it.
///
/// Filters process the rectangle (some, like ImageJ's 3×3 filters, also an
/// edge row or column next to it) and read pixels outside it; see each
/// filter's `rect` parameter.
public struct FilterRegion: Sendable, Hashable {
    /// The rectangle, within the plane (`ImageProcessor.getRoi()`). It is
    /// empty when the selection lies outside the plane.
    public var rect: RoiBounds
    /// `rect.width × rect.height` flags, row by row; `nil` for a plain
    /// rectangle, whose ImageJ mask is `null`.
    public var mask: [Bool]?

    public init(rect: RoiBounds, mask: [Bool]? = nil) {
        precondition(mask == nil || mask!.count == rect.width * rect.height, "mask size does not match the rectangle")
        self.rect = rect
        self.mask = mask
    }

    /// `PlugInFilterRunner.prepareProcessor` for `roi` on a `width × height`
    /// plane: an area selection's bounds and mask, clipped to the plane.
    /// Lines and points are not areas, and filters treat them as no
    /// selection: the result is `nil` for them.
    ///
    /// - Throws: ``RoiMaskError`` for selections whose mask Mancora can't
    ///   compute (composite and spline-fitted ones).
    public init?(selection roi: Roi, width: Int, height: Int) throws(RoiMaskError) {
        guard roi.isArea else { return nil }
        if case .rectangle(_, let corner) = roi.shape, corner == 0 {
            // ip.setRoi(Rectangle): the intersection with the plane, no mask.
            let b = roi.bounds
            let x1 = max(b.x, 0), y1 = max(b.y, 0)
            let x2 = min(b.x + b.width, width), y2 = min(b.y + b.height, height)
            if x2 > x1, y2 > y1 {
                self.init(rect: RoiBounds(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
            } else {
                self.init(rect: RoiBounds(x: 0, y: 0, width: 0, height: 0))
            }
            return
        }
        let mask = try roi.mask(width: width, height: height)
        self.init(rect: mask.bounds, mask: mask.pixels)
    }

    /// Whether the rectangle holds no pixels (a selection outside the plane).
    public var isEmpty: Bool { rect.width <= 0 || rect.height <= 0 }

    /// Whether the region is the whole `width × height` plane, unmasked.
    public func isWhole(width: Int, height: Int) -> Bool {
        mask == nil && rect.x == 0 && rect.y == 0 && rect.width == width && rect.height == height
    }

    /// `ImageProcessor.reset(mask)`: `filtered` with the pixels of the
    /// rectangle that lie outside the mask put back from `snapshot`. Without
    /// a mask, `filtered` is returned unchanged.
    public func restoringOutsideMask(_ filtered: Plane, snapshot: Plane, width: Int) -> Plane {
        guard let mask else { return filtered }
        var out = filtered
        let r = rect
        out.copyPixels(from: snapshot) { copy in
            for my in 0..<r.height {
                let row = (r.y + my) * width + r.x
                for mx in 0..<r.width where !mask[my * r.width + mx] { copy(row + mx) }
            }
        }
        return out
    }
}

extension RoiBounds {
    /// The whole `width × height` plane.
    static func whole(width: Int, height: Int) -> RoiBounds { RoiBounds(x: 0, y: 0, width: width, height: height) }

    func covers(width: Int, height: Int) -> Bool { x <= 0 && y <= 0 && x + self.width >= width && y + self.height >= height }

    var isEmpty: Bool { width <= 0 || height <= 0 }
}

extension Plane {
    /// Copies the pixels `body` names (by index) from `source`, a plane of
    /// the same type and size, in place.
    mutating func copyPixels(from source: Plane, _ body: ((Int) -> Void) -> Void) {
        switch (self, source) {
        case (.gray8(var p), .gray8(let s)):
            self = .gray8([])
            body { p[$0] = s[$0] }
            self = .gray8(p)
        case (.gray16(var p), .gray16(let s)):
            self = .gray8([])
            body { p[$0] = s[$0] }
            self = .gray16(p)
        case (.gray32Float(var p), .gray32Float(let s)):
            self = .gray8([])
            body { p[$0] = s[$0] }
            self = .gray32Float(p)
        case (.rgb8(var p), .rgb8(let s)):
            self = .gray8([])
            body { p[$0] = s[$0] }
            self = .rgb8(p)
        default:
            preconditionFailure("planes of different types")
        }
    }

    /// `original` with this plane's pixels (a filtered copy of it) where
    /// `processed(x, y)` holds: what a filter that writes only those pixels
    /// leaves behind.
    func merged(into original: Plane, width: Int, where processed: (Int, Int) -> Bool) -> Plane {
        var out = original
        let height = count / max(width, 1)
        out.copyPixels(from: self) { copy in
            for y in 0..<height {
                for x in 0..<width where processed(x, y) { copy(y * width + x) }
            }
        }
        return out
    }

    /// `original` with this plane's pixels (a filtered copy of it) inside `rect`.
    func merged(into original: Plane, width: Int, within rect: RoiBounds) -> Plane {
        var out = original
        out.copyPixels(from: self) { copy in
            for y in rect.y..<(rect.y + rect.height) {
                for x in rect.x..<(rect.x + rect.width) { copy(y * width + x) }
            }
        }
        return out
    }
}

/// The pixels ImageJ's `ByteProcessor.filter` writes for a rectangle
/// (`setRoi`'s `xMin`…`yMax` limits and `filterEdge`): the rectangle's
/// inner part, its rows and columns on the image edge, and, when the
/// rectangle ends one pixel short of the right or bottom edge, that edge's
/// column or row next to it, although it lies outside.
struct ByteFilterArea {
    let rect: RoiBounds
    let width: Int
    let height: Int

    var xMin: Int { max(rect.x, 1) }
    var xMax: Int { min(rect.x + rect.width - 1, width - 2) }
    var yMin: Int { max(rect.y, 1) }
    var yMax: Int { min(rect.y + rect.height - 1, height - 2) }

    func contains(_ x: Int, _ y: Int) -> Bool {
        let inRows = y >= rect.y && y < rect.y + rect.height
        let inColumns = x >= rect.x && x < rect.x + rect.width
        if width == 1 { return x == rect.x && inRows }  // filterEdge down the only column
        if x >= xMin && x <= xMax && y >= yMin && y <= yMax { return true }
        if xMin == 1 && x == rect.x && inRows { return true }
        if yMin == 1 && y == rect.y && inColumns { return true }
        if xMax == width - 2 && x == width - 1 && inRows { return true }
        if yMax == height - 2 && y == height - 1 && inColumns { return true }
        return false
    }

    /// The inner part only (`ColorProcessor.convolve3x3`, `BinaryProcessor`).
    func containsInner(_ x: Int, _ y: Int) -> Bool {
        x >= xMin && x <= xMax && y >= yMin && y <= yMax
    }
}
