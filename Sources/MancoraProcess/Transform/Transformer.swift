public import MancoraCore

extension Plane {
    /// Image ▸ Transform ▸ Flip Horizontally for one plane: ImageJ's
    /// `ImageProcessor.flipHorizontal()`, which mirrors the columns of the
    /// processor's rectangle (`rect`, within the plane; `nil` for all of it).
    public func flippedHorizontally(width: Int, rect: RoiBounds? = nil) -> Plane {
        let height = count / max(width, 1)
        let r = rect ?? RoiBounds(x: 0, y: 0, width: width, height: height)
        return rearranged(count: count) { i in
            let x = i % width, y = i / width
            guard x >= r.x, x < r.x + r.width, y >= r.y, y < r.y + r.height else { return i }
            return y * width + (2 * r.x + r.width - 1 - x)
        }
    }

    /// Image ▸ Transform ▸ Flip Vertically for one plane:
    /// `ImageProcessor.flipVertical()`, which mirrors the rows of `rect`.
    public func flippedVertically(width: Int, rect: RoiBounds? = nil) -> Plane {
        let height = count / max(width, 1)
        let r = rect ?? RoiBounds(x: 0, y: 0, width: width, height: height)
        return rearranged(count: count) { i in
            let x = i % width, y = i / width
            guard x >= r.x, x < r.x + r.width, y >= r.y, y < r.y + r.height else { return i }
            return (2 * r.y + r.height - 1 - y) * width + x
        }
    }

    /// Image ▸ Transform ▸ Rotate 90 Degrees Right for one plane:
    /// `ImageProcessor.rotateRight()`, a `height × width` plane. Row `y`
    /// of this plane becomes column `height - 1 - y`.
    public func rotatedRight(width: Int) -> Plane {
        let height = count / max(width, 1)
        return rearranged(count: count) { i in
            let x2 = i % height, y2 = i / height
            return (height - 1 - x2) * width + y2
        }
    }

    /// Image ▸ Transform ▸ Rotate 90 Degrees Left for one plane:
    /// `ImageProcessor.rotateLeft()`. Row `y` of this plane, reversed,
    /// becomes column `y`.
    public func rotatedLeft(width: Int) -> Plane {
        let height = count / max(width, 1)
        return rearranged(count: count) { i in
            let x2 = i % height, y2 = i / height
            return x2 * width + (width - 1 - y2)
        }
    }
}

extension ImageStack {
    /// Every plane rotated 90 degrees (`StackProcessor.rotateRight` and
    /// `rotateLeft`), labels kept.
    public func rotated90(clockwise: Bool) throws(ImageModelError) -> ImageStack {
        try ImageStack(
            width: height, height: width,
            planes: (0..<count).map { clockwise ? self[$0].rotatedRight(width: width) : self[$0].rotatedLeft(width: width) },
            labels: labels)
    }

    /// The planes and their labels in reverse order (`StackReverser.flipStack`).
    public func reversed() throws(ImageModelError) -> ImageStack {
        try ImageStack(width: width, height: height, planes: (0..<count).reversed().map { self[$0] }, labels: labels.reversed())
    }
}
