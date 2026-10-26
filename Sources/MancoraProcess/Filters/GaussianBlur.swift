public import MancoraCore

extension Plane {
    /// Process ▸ Filters ▸ Gaussian Blur with the same sigma in x and y.
    ///
    /// See ``gaussianBlurred(sigmaX:sigmaY:accuracy:width:)``.
    public func gaussianBlurred(sigma: Double, accuracy: Double? = nil, width: Int) -> Plane {
        gaussianBlurred(sigmaX: sigma, sigmaY: sigma, accuracy: accuracy, width: width)
    }

    /// Process ▸ Filters ▸ Gaussian Blur: ImageJ's
    /// `GaussianBlur.blurGaussian(ip, sigmaX, sigmaY, accuracy)`.
    ///
    /// Blurs in x, then in y, with ImageJ's kernels: a Gaussian whose tail
    /// is smoothed to reach zero at the kernel edge, out-of-image pixels taken
    /// from the nearest edge pixel, and lines downscaled before convolution
    /// when sigma exceeds 8.5. Integer and RGB results are rounded back
    /// (each RGB channel is blurred separately).
    ///
    /// - Parameters:
    ///   - sigmaX: Standard deviation in pixels along x; 0 or less skips x.
    ///   - sigmaY: Standard deviation in pixels along y; 0 or less skips y.
    ///   - accuracy: Where the kernel is cut off, relative to its peak.
    ///     `nil` uses ImageJ's defaults: 0.002 for 8-bit and RGB, 0.0002 for
    ///     16 and 32-bit.
    ///   - width: The plane's width in pixels.
    ///   - rect: A selection's bounds, within the plane, or `nil` for the
    ///     whole plane. Only the rectangle changes; ImageJ blurs rows above
    ///     and below it in x too (5 sigmas of them) for the y pass to read,
    ///     then puts them back (`resetOutOfRoi`), and reads the pixels around
    ///     it as they are.
    public func gaussianBlurred(
        sigmaX: Double, sigmaY: Double, accuracy: Double? = nil, width: Int, rect: RoiBounds? = nil
    ) -> Plane {
        let height = filterHeight(width: width)
        guard count > 0, sigmaX > 0 || sigmaY > 0 else { return self }
        let r = rect ?? .whole(width: width, height: height)
        guard !r.isEmpty else { return self }
        let accuracy = accuracy ?? (pixelType == .gray8 || pixelType == .rgb8 ? 0.002 : 0.0002)
        let extraLines = Int(JavaNumerics.int32((5 * sigmaY).rounded(.up)))
        let hasRoi = r.height != height && sigmaX > 0 && sigmaY > 0
        var channels = FloatChannels.split(self)
        for c in channels.indices {
            let original = hasRoi ? channels[c] : []
            if sigmaX > 0 {
                let lineFrom = max(r.y - extraLines, 0), lineTo = min(r.y + r.height + extraLines, height)
                channels[c].withUnsafeMutableBufferPointer { pixels in
                    GaussianBlur.blurLines(
                        pixels, length: width, lines: lineFrom..<max(lineTo, lineFrom), write: r.x..<(r.x + r.width),
                        sigma: sigmaX, accuracy: accuracy)
                }
            }
            if sigmaY > 0 {
                // Columns are blurred as the rows of the transposed image:
                // the same arithmetic as ImageJ's column pass, cache-friendly.
                var columns = GaussianBlur.transposed(channels[c], width: width, height: height)
                columns.withUnsafeMutableBufferPointer { pixels in
                    GaussianBlur.blurLines(
                        pixels, length: height, lines: r.x..<(r.x + r.width), write: r.y..<(r.y + r.height),
                        sigma: sigmaY, accuracy: accuracy)
                }
                channels[c] = GaussianBlur.transposed(columns, width: height, height: width)
            }
            if hasRoi {  // resetOutOfRoi: the rows above and below that the x pass blurred
                let rows = Array(max(r.y - extraLines, 0)..<r.y) + Array((r.y + r.height)..<min(r.y + r.height + extraLines, height))
                for y in rows {
                    for x in r.x..<(r.x + r.width) { channels[c][y * width + x] = original[y * width + x] }
                }
            }
        }
        return FloatChannels.merge(channels, as: pixelType)
    }
}

extension ImageStack {
    /// Process ▸ Filters ▸ Gaussian Blur on every plane; see
    /// `Plane.gaussianBlurred(sigmaX:sigmaY:accuracy:width:)`.
    public func gaussianBlurred(sigma: Double, accuracy: Double? = nil) -> ImageStack {
        gaussianBlurred(sigmaX: sigma, sigmaY: sigma, accuracy: accuracy)
    }

    /// Process ▸ Filters ▸ Gaussian Blur on every plane; see
    /// `Plane.gaussianBlurred(sigmaX:sigmaY:accuracy:width:)`.
    public func gaussianBlurred(sigmaX: Double, sigmaY: Double, accuracy: Double? = nil) -> ImageStack {
        mapPlanes { $0.gaussianBlurred(sigmaX: sigmaX, sigmaY: sigmaY, accuracy: accuracy, width: width) }
    }
}

/// A port of ImageJ 1.54p's `ij.plugin.filter.GaussianBlur`, for a plane
/// or a rectangle of it. Float arithmetic follows the Java code operation by operation, so
/// results are bit-identical.
enum GaussianBlur {
    static let upscaleKernelRadius = 2
    static let minDownscaledSigma = 4.0

    /// `blur1Direction(ip, sigma, accuracy, xDirection: true, …)`: blurs
    /// rows `lines` of a `length`-wide image in place, writing points
    /// `write` of each (and reading as far around them as the kernel needs).
    static func blurLines(
        _ pixels: UnsafeMutableBufferPointer<Float>, length: Int, lines: Range<Int>, write: Range<Int>, sigma: Double,
        accuracy: Double
    ) {
        let pointInc = 1, lineInc = length
        let writeFrom = write.lowerBound, writeTo = write.upperBound

        let doDownscaling = sigma > 2 * minDownscaledSigma + 0.5
        let reduceBy = doDownscaling
            ? min(Int(JavaNumerics.int32((sigma / minDownscaledSigma).rounded(.down))), length) : 1
        // Downscaling and upscaling blur too (variance 1/3 and 1/4 in
        // downscaled pixels), so the Gaussian makes up the rest.
        let sigmaGauss = doDownscaling
            ? (sigma * sigma / Double(reduceBy * reduceBy) - 1.0 / 3.0 - 1.0 / 4.0).squareRoot() : sigma
        let maxLength = doDownscaling ? (length + reduceBy - 1) / reduceBy + 2 * (upscaleKernelRadius + 1) : length
        let (kernel, kernelSum) = makeGaussianKernel(sigma: sigmaGauss, accuracy: accuracy, maxRadius: maxLength)
        let kRadius = kernel.count * reduceBy  // the kernel radius after upscaling
        let readFrom = writeFrom - kRadius < 0 ? 0 : writeFrom - kRadius
        let readTo = writeTo + kRadius > length ? length : writeTo + kRadius
        let newLength = doDownscaling
            ? (readTo - readFrom + reduceBy - 1) / reduceBy + 2 * (upscaleKernelRadius + 1) : length
        let unscaled0 = readFrom - (upscaleKernelRadius + 1) * reduceBy  // input point at cache index 0
        let downscaleKernel = doDownscaling ? makeDownscaleKernel(reduceBy) : []
        let upscaleKernel = doDownscaling ? makeUpscaleKernel(reduceBy) : []

        var cache1 = [Float](repeating: 0, count: newLength)  // before convolution (after downscaling)
        var cache2 = [Float](repeating: 0, count: doDownscaling ? newLength : 0)  // after convolution
        let base = pixels.baseAddress!
        kernel.withUnsafeBufferPointer { kern in
        kernelSum.withUnsafeBufferPointer { kernSum in
        downscaleKernel.withUnsafeBufferPointer { downKernel in
        upscaleKernel.withUnsafeBufferPointer { upKernel in
        cache1.withUnsafeMutableBufferPointer { cache1 in
        cache2.withUnsafeMutableBufferPointer { cache2 in
            for line in lines {
                let pixel0 = line * lineInc
                if doDownscaling {
                    downscaleLine(
                        base, cache: cache1, kernel: downKernel, reduceBy: reduceBy, pixel0: pixel0,
                        unscaled0: unscaled0, length: length, pointInc: pointInc)
                    convolveLine(
                        input: UnsafeBufferPointer(cache1), output: cache2.baseAddress!, kernel: kern,
                        kernelSum: kernSum, writeFrom: 1, writeTo: newLength - 1, point0: 0, pointInc: 1)
                    upscaleLine(
                        cache: cache2, pixels: base, kernel: upKernel, reduceBy: reduceBy, pixel0: pixel0,
                        unscaled0: unscaled0, writeFrom: writeFrom, writeTo: writeTo, pointInc: pointInc)
                } else {
                    // Only the points the kernel reaches are read; the rest of
                    // the cache is never used (as in ImageJ).
                    var p = pixel0 + readFrom * pointInc
                    for i in readFrom..<readTo {
                        cache1[i] = base[p]
                        p += pointInc
                    }
                    convolveLine(
                        input: UnsafeBufferPointer(cache1), output: base, kernel: kern, kernelSum: kernSum,
                        writeFrom: writeFrom, writeTo: writeTo, point0: pixel0, pointInc: pointInc)
                }
            }
        }
        }
        }
        }
        }
        }
    }

    /// A `height × width` copy with rows and columns swapped, built in
    /// tiles to stay in cache.
    static func transposed(_ src: [Float], width: Int, height: Int) -> [Float] {
        let tile = 32
        return [Float](unsafeUninitializedCapacity: src.count) { dst, initialized in
            src.withUnsafeBufferPointer { src in
                for y0 in stride(from: 0, to: height, by: tile) {
                    for x0 in stride(from: 0, to: width, by: tile) {
                        for y in y0..<min(y0 + tile, height) {
                            for x in x0..<min(x0 + tile, width) {
                                (dst.baseAddress! + x * height + y).initialize(to: src[y * width + x])
                            }
                        }
                    }
                }
            }
            initialized = src.count
        }
    }

    /// `downscaleLine`: scales one line down by `reduceBy` into `cache`;
    /// out-of-line points are the nearest edge point.
    static func downscaleLine(
        _ pixels: UnsafeMutablePointer<Float>, cache: UnsafeMutableBufferPointer<Float>, kernel: UnsafeBufferPointer<Float>,
        reduceBy: Int, pixel0: Int, unscaled0: Int, length: Int, pointInc: Int
    ) {
        let newLength = cache.count
        var p = pixel0 + pointInc * (unscaled0 - reduceBy * 3 / 2)
        let pLast = pixel0 + pointInc * (length - 1)
        for xout in -1...newLength {
            var sum0: Float = 0, sum1: Float = 0, sum2: Float = 0
            for x in 0..<reduceBy {
                let v = pixels[p < pixel0 ? pixel0 : (p > pLast ? pLast : p)]
                sum0 += v * kernel[x + 2 * reduceBy]
                sum1 += v * kernel[x + reduceBy]
                sum2 += v * kernel[x]
                p += pointInc
            }
            if xout > 0 { cache[xout - 1] += sum0 }
            if xout >= 0 && xout < newLength { cache[xout] += sum1 }
            if xout + 1 < newLength { cache[xout + 1] = sum2 }
        }
    }

    /// `makeDownscaleKernel`: runs from -1.5 to +1.5 downscaled pixels.
    static func makeDownscaleKernel(_ unitLength: Int) -> [Float] {
        let mid = unitLength * 3 / 2
        var kernel = [Float](repeating: 0, count: 3 * unitLength)
        for i in 0...(unitLength / 2) {
            let x = Double(i) / Double(unitLength)
            let v = Float((0.75 - x * x) / Double(unitLength))
            kernel[mid - i] = v
            kernel[mid + i] = v
        }
        var i = unitLength / 2 + 1
        while i < (unitLength * 3 + 1) / 2 {
            let x = Double(i) / Double(unitLength)
            let v = Float((0.125 + 0.5 * (x - 1) * (x - 2)) / Double(unitLength))
            kernel[mid - i] = v
            kernel[mid + i] = v
            i += 1
        }
        return kernel
    }

    /// `upscaleLine`: scales the convolved line back up into points
    /// `writeFrom..<writeTo` of the image's line.
    static func upscaleLine(
        cache: UnsafeMutableBufferPointer<Float>, pixels: UnsafeMutablePointer<Float>, kernel: UnsafeBufferPointer<Float>,
        reduceBy: Int, pixel0: Int, unscaled0: Int, writeFrom: Int, writeTo: Int, pointInc: Int
    ) {
        var p = pixel0 + pointInc * writeFrom
        for xout in writeFrom..<writeTo {
            let xin = (xout - unscaled0 + reduceBy - 1) / reduceBy
            let x = reduceBy - 1 - (xout - unscaled0 + reduceBy - 1) % reduceBy
            pixels[p] = cache[xin - 2] * kernel[x] + cache[xin - 1] * kernel[x + reduceBy]
                + cache[xin] * kernel[x + 2 * reduceBy] + cache[xin + 1] * kernel[x + 3 * reduceBy]
            p += pointInc
        }
    }

    /// `makeUpscaleKernel`: four unit squares convolved, from -2 to +2.
    static func makeUpscaleKernel(_ unitLength: Int) -> [Float] {
        var kernel = [Float](repeating: 0, count: 4 * unitLength)
        let mid = 2 * unitLength
        for i in 0..<unitLength {
            let x = Double(i) / Double(unitLength)
            let v = Float(2.0 / 3.0 - x * x * (1 - 0.5 * x))
            kernel[mid + i] = v
            kernel[mid - i] = v
        }
        for i in unitLength..<(2 * unitLength) {
            let x = Double(i) / Double(unitLength)
            let v = Float((2.0 - x) * (2.0 - x) * (2.0 - x) / 6.0)
            kernel[mid + i] = v
            kernel[mid - i] = v
        }
        return kernel
    }

    /// `convolveLine`: convolves `input` with the one-sided `kernel` and
    /// writes points `writeFrom..<writeTo` to `output[point0 + i*pointInc]`.
    /// `kernelSum[n]` is the sum of the kernel beyond `n`, which weights the
    /// edge pixels that stand in for out-of-line points.
    static func convolveLine(
        input: UnsafeBufferPointer<Float>, output: UnsafeMutablePointer<Float>, kernel kern: UnsafeBufferPointer<Float>,
        kernelSum kernSum: UnsafeBufferPointer<Float>, writeFrom: Int, writeTo: Int, point0: Int, pointInc: Int
    ) {
        let length = input.count
        let first = input[0]
        let last = input[length - 1]
        let kern0 = kern[0]
        let kRadius = kern.count
        let firstPart = kRadius < length ? kRadius : length
        var p = point0 + writeFrom * pointInc
        var i = writeFrom
        while i < firstPart {  // the sum would include pixels < 0
            var result = input[i] * kern0
            result += kernSum[i] * first
            if i + kRadius > length { result += kernSum[length - i - 1] * last }
            for k in 1..<kRadius {
                var v: Float = 0
                if i - k >= 0 { v += input[i - k] }
                if i + k < length { v += input[i + k] }
                result += kern[k] * v
            }
            output[p] = result
            i += 1
            p += pointInc
        }
        let iEndInside = length - kRadius < writeTo ? length - kRadius : writeTo
        if pointInc == 1 {
            // Eight points at once: each lane does exactly the scalar loop's
            // float operations in the same order, so results are identical.
            let raw = UnsafeRawPointer(input.baseAddress!)
            let stride = MemoryLayout<Float>.stride
            while i + 8 <= iEndInside {
                var result = raw.loadUnaligned(fromByteOffset: i * stride, as: SIMD8<Float>.self) * kern0
                for k in 1..<kRadius {
                    let below = raw.loadUnaligned(fromByteOffset: (i - k) * stride, as: SIMD8<Float>.self)
                    let above = raw.loadUnaligned(fromByteOffset: (i + k) * stride, as: SIMD8<Float>.self)
                    result += kern[k] * (below + above)
                }
                UnsafeMutableRawPointer(output + p).storeBytes(of: result, as: SIMD8<Float>.self)
                i += 8
                p += 8
            }
        }
        while i < iEndInside {  // only points within the line
            var result = input[i] * kern0
            for k in 1..<kRadius {
                result += kern[k] * (input[i - k] + input[i + k])
            }
            output[p] = result
            i += 1
            p += pointInc
        }
        while i < writeTo {  // the sum would include pixels >= length
            var result = input[i] * kern0
            if i < kRadius { result += kernSum[i] * first }
            if i + kRadius >= length { result += kernSum[length - i - 1] * last }
            for k in 1..<kRadius {
                var v: Float = 0
                if i - k >= 0 { v += input[i - k] }
                if i + k < length { v += input[i + k] }
                result += kern[k] * v
            }
            output[p] = result
            i += 1
            p += pointInc
        }
    }

    /// `makeGaussianKernel`: one side of a normalized Gaussian, its tail
    /// replaced by a parabola reaching zero at the first point outside, and
    /// the running sum beyond each point.
    static func makeGaussianKernel(sigma: Double, accuracy: Double, maxRadius: Int) -> (kernel: [Float], sum: [Float]) {
        var kRadius = Int(JavaNumerics.int32((sigma * (-2 * Libm.logarithm(accuracy)).squareRoot()).rounded(.up))) + 1
        let maxRadius = max(maxRadius, 50)  // too small a radius would make the sum inaccurate
        if kRadius > maxRadius { kRadius = maxRadius }
        var kernel = [Float](repeating: 0, count: kRadius)
        var runningSum = [Float](repeating: 0, count: kRadius)
        for i in 0..<kRadius {
            kernel[i] = Float(Libm.exponential(-0.5 * Double(i) * Double(i) / sigma / sigma))
        }
        if kRadius < maxRadius && kRadius > 3 {  // edge correction
            var sqrtSlope = Double.greatestFiniteMagnitude
            var r = kRadius
            while r > kRadius / 2 {
                r -= 1
                let a = Double(kernel[r]).squareRoot() / Double(kRadius - r)
                if a < sqrtSlope { sqrtSlope = a } else { break }
            }
            var r1 = r + 2
            while r1 < kRadius {
                kernel[r1] = Float(Double((kRadius - r1) * (kRadius - r1)) * sqrtSlope * sqrtSlope)
                r1 += 1
            }
        }
        var sum: Double
        if kRadius < maxRadius {
            sum = Double(kernel[0])
            for i in 1..<kRadius { sum += Double(2 * kernel[i]) }
        } else {
            sum = sigma * (2 * Double.pi).squareRoot()
        }
        var rsum = 0.5 + 0.5 * Double(kernel[0]) / sum
        for i in 0..<kRadius {
            let v = Double(kernel[i]) / sum
            kernel[i] = Float(v)
            rsum -= v
            runningSum[i] = Float(rsum)
        }
        return (kernel, runningSum)
    }
}
