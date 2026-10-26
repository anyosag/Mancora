public import MancoraCore

/// A convolution kernel for `Plane.convolved(with:normalize:width:)`,
/// as typed into ImageJ's Process ▸ Filters ▸ Convolve dialog.
public struct ConvolutionKernel: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// Row-major coefficients, `width × height` of them.
    public let values: [Float]

    /// - Throws: ``FilterError/invalidKernel(width:height:valueCount:)``
    ///   unless both sizes are odd and positive and `values` has one value
    ///   per element (ImageJ's `Convolver` requires odd sizes too).
    public init(width: Int, height: Int, values: [Float]) throws(FilterError) {
        guard width > 0, height > 0, width % 2 == 1, height % 2 == 1, values.count == width * height else {
            throw .invalidKernel(width: width, height: height, valueCount: values.count)
        }
        self.width = width
        self.height = height
        self.values = values
    }

    /// The factor ImageJ's "Normalize Kernel" applies (`Convolver.getScale`):
    /// one over the sum of the coefficients, or 1 if they sum to zero.
    public var normalizationScale: Double {
        var sum = 0.0
        for v in values { sum += Double(v) }
        return sum != 0 ? 1 / sum : 1
    }
}

extension Plane {
    /// Process ▸ Filters ▸ Convolve: ImageJ's `Convolver`, applied the way
    /// the command applies it.
    ///
    /// Each channel is converted to float, convolved with the kernel
    /// (`convolveFloat`, or `convolveFloat1D` for a single row or column),
    /// and converted back with rounding and clipping for integer and RGB
    /// planes. Out-of-image pixels take the value of the nearest edge pixel.
    /// As in ImageJ, the kernel is not flipped (this is a correlation), each
    /// product is rounded to float and the sum is accumulated in double.
    ///
    /// - Parameters:
    ///   - kernel: The kernel; its center is at `(width/2, height/2)`.
    ///   - normalize: ImageJ's "Normalize Kernel": divide by the sum of the
    ///     coefficients unless it is zero.
    ///   - width: The plane's width in pixels.
    ///   - rect: A selection's bounds, within the plane, or `nil` for the
    ///     whole plane. Only the rectangle changes; the kernel reads the
    ///     pixels around it.
    public func convolved(with kernel: ConvolutionKernel, normalize: Bool = true, width: Int, rect: RoiBounds? = nil) -> Plane {
        let height = filterHeight(width: width)
        guard count > 0 else { return self }
        let rect = rect ?? .whole(width: width, height: height)
        guard !rect.isEmpty else { return self }
        let scale = normalize ? kernel.normalizationScale : 1
        let channels = FloatChannels.split(self).map {
            Convolver.convolve($0, width: width, height: height, rect: rect, kernel: kernel, scale: scale)
        }
        return FloatChannels.merge(channels, as: pixelType)
    }
}

extension ImageStack {
    /// Process ▸ Filters ▸ Convolve on every plane; see
    /// `Plane.convolved(with:normalize:width:)`.
    public func convolved(with kernel: ConvolutionKernel, normalize: Bool = true) -> ImageStack {
        mapPlanes { $0.convolved(with: kernel, normalize: normalize, width: width) }
    }
}

/// A port of ImageJ 1.54p's `Convolver.convolveFloat` and
/// `convolveFloat1D`, which write the processor's rectangle and read the
/// snapshot (the input) around it.
enum Convolver {
    static func convolve(
        _ input: [Float], width: Int, height: Int, rect: RoiBounds, kernel: ConvolutionKernel, scale: Double
    ) -> [Float] {
        let uc = kernel.width / 2, vc = kernel.height / 2
        let xedge = width - uc, yedge = height - vc
        var output = input
        output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { pixels in
                kernel.values.withUnsafeBufferPointer { k in
                    for y in rect.y..<(rect.y + rect.height) {
                        for x in rect.x..<(rect.x + rect.width) {
                            var sum = 0.0
                            var i = 0
                            if y < vc || y >= yedge || x < uc || x >= xedge {
                                for v in -vc...vc {
                                    let row = min(max(y + v, 0), height - 1) * width
                                    for u in -uc...uc {
                                        sum += Double(pixels[row + min(max(x + u, 0), width - 1)] * k[i])
                                        i += 1
                                    }
                                }
                            } else {
                                for v in -vc...vc {
                                    let offset = x + (y + v) * width
                                    for u in -uc...uc {
                                        sum += Double(pixels[offset + u] * k[i])
                                        i += 1
                                    }
                                }
                            }
                            out[y * width + x] = Float(sum * scale)
                        }
                    }
                }
            }
        }
        return output
    }
}
