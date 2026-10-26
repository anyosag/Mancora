public import MancoraCore

extension Plane {
    /// The pixels of `rect`, which must lie within the plane:
    /// `ImageProcessor.crop()` with the processor's rectangle set to it.
    public func cropped(width: Int, to rect: RoiBounds) -> Plane {
        rearranged(count: rect.width * rect.height) { i in
            (rect.y + i / rect.width) * width + rect.x + i % rect.width
        }
    }

    /// Image ▸ Adjust ▸ Canvas Size for one plane (`CanvasResizer.expandImage`):
    /// a `newWidth × newHeight` plane filled with `fill`, with this plane
    /// copied in at (`xOffset`, `yOffset`) and clipped to it
    /// (`ImageProcessor.insert`).
    ///
    /// `fill` is stored as `ImageProcessor.fill()` stores the fill value:
    /// truncated and clamped for 8 and 16-bit, as a `float` for 32-bit, and
    /// as a packed `0xRRGGBB` color for RGB.
    public func onCanvas(
        width: Int, newWidth: Int, newHeight: Int, xOffset: Int, yOffset: Int, fill: Double
    ) -> Plane {
        let height = count / max(width, 1)
        let n = newWidth * newHeight
        func place<T>(_ src: [T], _ value: T) -> [T] {
            var out = [T](repeating: value, count: n)
            let x0 = max(xOffset, 0), x1 = min(xOffset + width, newWidth)
            let y0 = max(yOffset, 0), y1 = min(yOffset + height, newHeight)
            guard x1 > x0, y1 > y0 else { return out }
            for y in y0..<y1 {
                let from = (y - yOffset) * width + (x0 - xOffset), to = y * newWidth + x0
                for i in 0..<(x1 - x0) { out[to + i] = src[from + i] }
            }
            return out
        }
        let int = Int(JavaNumerics.int32(fill))
        switch self {
        case .gray8(let p): return .gray8(place(p, UInt8(min(max(int, 0), 255))))
        case .gray16(let p): return .gray16(place(p, UInt16(min(max(int, 0), 65535))))
        case .gray32Float(let p): return .gray32Float(place(p, Float(fill)))
        case .rgb8(let p): return .rgb8(place(p, 0xFF00_0000 | UInt32(bitPattern: Int32(truncatingIfNeeded: int)) & 0xFF_FFFF))
        }
    }

    /// A plane of `count` pixels whose pixel `i` is this plane's pixel `source(i)`.
    func rearranged(count: Int, _ source: (Int) -> Int) -> Plane {
        switch self {
        case .gray8(let p): return .gray8((0..<count).map { p[source($0)] })
        case .gray16(let p): return .gray16((0..<count).map { p[source($0)] })
        case .gray32Float(let p): return .gray32Float((0..<count).map { p[source($0)] })
        case .rgb8(let p): return .rgb8((0..<count).map { p[source($0)] })
        }
    }
}

extension ImageStack {
    /// Every plane cropped to `rect` (within the planes), labels kept:
    /// `StackProcessor.resize` to the rectangle's size, which crops.
    public func cropped(to rect: RoiBounds) throws(ImageModelError) -> ImageStack {
        try ImageStack(
            width: rect.width, height: rect.height, planes: (0..<count).map { self[$0].cropped(width: width, to: rect) },
            labels: labels)
    }

    /// Every plane on a `newWidth × newHeight` canvas (`CanvasResizer.expandStack`).
    public func onCanvas(
        newWidth: Int, newHeight: Int, xOffset: Int, yOffset: Int, fill: Double
    ) throws(ImageModelError) -> ImageStack {
        try ImageStack(
            width: newWidth, height: newHeight,
            planes: (0..<count).map {
                self[$0].onCanvas(
                    width: width, newWidth: newWidth, newHeight: newHeight, xOffset: xOffset, yOffset: yOffset, fill: fill)
            },
            labels: labels)
    }
}
