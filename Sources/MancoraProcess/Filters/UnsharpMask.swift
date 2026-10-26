public import MancoraCore

extension Plane {
    /// Process ▸ Filters ▸ Unsharp Mask: ImageJ's `UnsharpMask.sharpenFloat`.
    ///
    /// Each channel, as floats, is blurred with `sigma` (ImageJ's Gaussian
    /// Blur at accuracy 0.01), and every pixel of the rectangle becomes
    /// `(original - weight * blurred) / (1 - weight)`, in `float`
    /// arithmetic. Integer results are rounded and clipped to the type's
    /// range (`setPixels(channel, fp)`).
    ///
    /// - Parameters:
    ///   - sigma: The blur's standard deviation in pixels.
    ///   - weight: The mask weight, 0 to 0.99 in ImageJ's dialog.
    ///   - width: The plane's width in pixels.
    ///   - rect: A selection's bounds, within the plane, or `nil` for the
    ///     whole plane: only these pixels change.
    public func unsharpMasked(sigma: Double, weight: Float, width: Int, rect: RoiBounds? = nil) -> Plane {
        let height = filterHeight(width: width)
        guard count > 0 else { return self }
        let r = rect ?? .whole(width: width, height: height)
        guard !r.isEmpty else { return self }
        var channels = FloatChannels.split(self)
        for c in channels.indices {
            let snapshot = channels[c]
            GaussianBlur.blurChannel(&channels[c], width: width, sigmaX: sigma, sigmaY: sigma, accuracy: 0.01, rect: r)
            for y in r.y..<(r.y + r.height) {
                for p in (y * width + r.x)..<(y * width + r.x + r.width) {
                    channels[c][p] = (snapshot[p] - weight * channels[c][p]) / (1 - weight)
                }
            }
        }
        return FloatChannels.merge(channels, as: pixelType)
    }
}
