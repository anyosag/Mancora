public import MancoraCore

extension Plane {
    /// Process ▸ Smooth: ImageJ's `ImageProcessor.smooth()`, the 3×3 mean
    /// (`filter(BLUR_MORE)`).
    ///
    /// Out-of-image pixels take the value of the nearest edge pixel; integer
    /// results are rounded. Like ImageJ, a plane one pixel wide is returned
    /// unchanged.
    public func smoothed(width: Int) -> Plane {
        Filters3x3.apply(.smooth, to: self, width: width)
    }

    /// Process ▸ Sharpen: ImageJ's `ImageProcessor.sharpen()`, a 3×3
    /// convolution with −1 around 12, divided by 4.
    ///
    /// Grayscale planes use the nearest edge pixel outside the image, as
    /// `convolve3x3` does. ImageJ's RGB version (`ColorProcessor.convolve3x3`)
    /// leaves the edge pixels unchanged and truncates instead of rounding;
    /// Mancora does the same. A plane one pixel wide is returned unchanged.
    public func sharpened(width: Int) -> Plane {
        Filters3x3.apply(.sharpen, to: self, width: width)
    }

    /// Process ▸ Find Edges: ImageJ's `ImageProcessor.findEdges()`, the
    /// magnitude of the 3×3 Sobel gradient (`filter(FIND_EDGES)`).
    ///
    /// Out-of-image pixels take the value of the nearest edge pixel; integer
    /// results are truncated and clipped to the type's range, RGB channels
    /// are filtered separately. A plane one pixel wide is returned unchanged.
    public func findingEdges(width: Int) -> Plane {
        Filters3x3.apply(.findEdges, to: self, width: width)
    }
}

extension ImageStack {
    /// Process ▸ Smooth on every plane.
    public func smoothed() -> ImageStack { mapPlanes { $0.smoothed(width: width) } }

    /// Process ▸ Sharpen on every plane.
    public func sharpened() -> ImageStack { mapPlanes { $0.sharpened(width: width) } }

    /// Process ▸ Find Edges on every plane.
    public func findingEdges() -> ImageStack { mapPlanes { $0.findingEdges(width: width) } }
}

/// Ports of the 3×3 filters of ImageJ 1.54p's `ByteProcessor`,
/// `ShortProcessor`, `FloatProcessor` and `ColorProcessor`.
enum Filters3x3 {
    enum Operation {
        case smooth, sharpen, findEdges
    }

    static func apply(_ op: Operation, to plane: Plane, width: Int) -> Plane {
        let height = plane.filterHeight(width: width)
        guard width > 1, height > 0 else { return plane }  // ImageJ: `if (width>1)`
        switch plane {
        case .gray8(let p): return .gray8(integer(op, p, width: width, height: height, maxValue: 255))
        case .gray16(let p): return .gray16(integer(op, p, width: width, height: height, maxValue: 65535))
        case .gray32Float(let p): return .gray32Float(float(op, p, width: width, height: height))
        case .rgb8(let p):
            if op == .sharpen { return .rgb8(sharpenRGB(p, width: width, height: height)) }
            // BLUR_MORE on packed RGB and FIND_EDGES on three ByteProcessors
            // both work per channel exactly as the 8-bit filters do.
            let channels = [16, 8, 0].map { shift in
                integer(op, p.map { UInt8(truncatingIfNeeded: $0 >> UInt32(shift)) }, width: width, height: height, maxValue: 255)
            }
            var out = [UInt32](repeating: 0, count: p.count)
            for i in out.indices {
                out[i] = 0xFF00_0000 | UInt32(channels[0][i]) << 16 | UInt32(channels[1][i]) << 8 | UInt32(channels[2][i])
            }
            return .rgb8(out)
        }
    }

    /// A copy with a one-pixel border repeating the edge pixels.
    static func padded<T>(_ p: [T], width: Int, height: Int) -> [T] {
        let pw = width + 2
        var out = [T]()
        out.reserveCapacity(pw * (height + 2))
        for py in 0..<(height + 2) {
            let row = min(max(py - 1, 0), height - 1) * width
            out.append(p[row])
            out.append(contentsOf: p[row..<(row + width)])
            out.append(p[row + width - 1])
        }
        return out
    }

    /// 8 and 16-bit: `filter(BLUR_MORE)`, `filter(FIND_EDGES)` and
    /// `convolve3x3` with the sharpen kernel, in integer arithmetic.
    static func integer<T: FixedWidthInteger & UnsignedInteger>(
        _ op: Operation, _ p: [T], width: Int, height: Int, maxValue: Int
    ) -> [T] {
        let src = padded(p, width: width, height: height)
        let pw = width + 2
        return [T](unsafeUninitializedCapacity: p.count) { dst, initialized in
            src.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    for x in 0..<width {
                        let t = y * pw + x, m = t + pw, b = m + pw
                        let p1 = Int(src[t]), p2 = Int(src[t + 1]), p3 = Int(src[t + 2])
                        let p4 = Int(src[m]), p5 = Int(src[m + 1]), p6 = Int(src[m + 2])
                        let p7 = Int(src[b]), p8 = Int(src[b + 1]), p9 = Int(src[b + 2])
                        var sum: Int
                        switch op {
                        case .smooth:
                            sum = (p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + 4) / 9
                        case .sharpen:
                            sum = 12 * p5 - p1 - p2 - p3 - p4 - p6 - p7 - p8 - p9
                            sum = (sum + 2) / 4  // (sum + scale/2) / scale, truncating like Java
                            sum = min(max(sum, 0), maxValue)
                        case .findEdges:
                            let sum1 = p1 + 2 * p2 + p3 - p7 - 2 * p8 - p9
                            let sum2 = p1 + 2 * p4 + p7 - p3 - 2 * p6 - p9
                            sum = min(Int(Double(sum1 * sum1 + sum2 * sum2).squareRoot()), maxValue)
                        }
                        (dst.baseAddress! + y * width + x).initialize(to: T(truncatingIfNeeded: sum))
                    }
                }
            }
            initialized = p.count
        }
    }

    /// 32-bit: `FloatProcessor.filter3x3`, in float arithmetic in Java's
    /// order of operations.
    static func float(_ op: Operation, _ p: [Float], width: Int, height: Int) -> [Float] {
        let src = padded(p, width: width, height: height)
        let pw = width + 2
        // convolve3x3 with the sharpen kernel: the kernel as floats, scale 1/4.
        let k: Float = -1, k5: Float = 12, scale: Float = 1 / Float(4)
        return [Float](unsafeUninitializedCapacity: p.count) { dst, initialized in
            src.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    for x in 0..<width {
                        let t = y * pw + x, m = t + pw, b = m + pw
                        let v1 = src[t], v2 = src[t + 1], v3 = src[t + 2]
                        let v4 = src[m], v5 = src[m + 1], v6 = src[m + 2]
                        let v7 = src[b], v8 = src[b + 1], v9 = src[b + 2]
                        let result: Float
                        switch op {
                        case .smooth:
                            var sum = v1 + v2
                            sum += v3
                            sum += v4
                            sum += v5
                            sum += v6
                            sum += v7
                            sum += v8
                            sum += v9
                            result = sum * 0.11111111
                        case .sharpen:
                            var sum = k * v1 + k * v2
                            sum += k * v3
                            sum += k * v4
                            sum += k5 * v5
                            sum += k * v6
                            sum += k * v7
                            sum += k * v8
                            sum += k * v9
                            result = sum * scale
                        case .findEdges:
                            var sum1 = v1 + 2 * v2
                            sum1 += v3
                            sum1 -= v7
                            sum1 -= 2 * v8
                            sum1 -= v9
                            var sum2 = v1 + 2 * v4
                            sum2 += v7
                            sum2 -= v3
                            sum2 -= 2 * v6
                            sum2 -= v9
                            result = Float(Double(sum1 * sum1 + sum2 * sum2).squareRoot())
                        }
                        (dst.baseAddress! + y * width + x).initialize(to: result)
                    }
                }
            }
            initialized = p.count
        }
    }

    /// `ColorProcessor.convolve3x3` with the sharpen kernel: inner pixels
    /// only, each channel's sum divided by 4 with truncation.
    static func sharpenRGB(_ p: [UInt32], width: Int, height: Int) -> [UInt32] {
        var out = p.map { $0 | 0xFF00_0000 }
        guard width > 2, height > 2 else { return out }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var channels: UInt32 = 0xFF00_0000
                for shift: UInt32 in [16, 8, 0] {
                    func c(_ dx: Int, _ dy: Int) -> Int { Int((p[(y + dy) * width + x + dx] >> shift) & 0xFF) }
                    var sum = 12 * c(0, 0) - c(-1, -1) - c(0, -1) - c(1, -1) - c(-1, 0) - c(1, 0) - c(-1, 1) - c(0, 1) - c(1, 1)
                    sum /= 4
                    sum = min(max(sum, 0), 255)
                    channels |= UInt32(sum) << shift
                }
                out[y * width + x] = channels
            }
        }
        return out
    }
}
