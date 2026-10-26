import MancoraCore

extension GeometryProcessor {
    // MARK: New processors

    /// `createProcessor(width, height)`: a blank processor of the same type
    /// with this one's interpolation method, display range and LUT
    /// inversion, and the type's default background.
    func created(_ plane: Plane, width: Int) -> GeometryProcessor {
        var p = GeometryProcessor(plane, width: width)
        p.interpolation = interpolation
        p.invertedLUT = invertedLUT
        if case .rgb8 = plane {} else { p.minMax = currentMinMaxForCopy }
        return p
    }

    /// What `createProcessor` copies: `setMinAndMax(getMin(), getMax())`.
    var currentMinMaxForCopy: (min: Double, max: Double)? {
        switch plane {
        case .gray8: return minMax
        case .gray16, .gray32Float:
            let (lo, hi) = currentMinMax
            if lo == 0 && hi == 0 { return nil }
            return (lo, hi)
        case .rgb8: return nil
        }
    }

    /// `crop()`: the selected rectangle as a new processor.
    public func cropped() -> GeometryProcessor {
        let r = roi
        func rows<T>(_ p: [T]) -> [T] {
            var out: [T] = []
            out.reserveCapacity(r.width * r.height)
            for y in r.y..<(r.y + r.height) {
                out.append(contentsOf: p[(y * width + r.x)..<(y * width + r.x + r.width)])
            }
            return out
        }
        switch plane {
        case .gray8(let p): return created(.gray8(rows(p)), width: r.width)
        case .gray16(let p): return created(.gray16(rows(p)), width: r.width)
        case .gray32Float(let p): return created(.gray32Float(rows(p)), width: r.width)
        case .rgb8(let p): return created(.rgb8(rows(p)), width: r.width)
        }
    }

    // MARK: resize

    /// `resize(dstWidth, dstHeight)`: a scaled copy of the selected
    /// rectangle, sampled with the interpolation method. Images one pixel wide
    /// or high are interpolated linearly along their length
    /// (`resizeLinearly`); RGB images are resized per channel for bicubic.
    public func resized(width dstWidth: Int, height dstHeight: Int) -> GeometryProcessor {
        precondition(dstWidth > 0 && dstHeight > 0, "can't resize to \(dstWidth)×\(dstHeight)")
        if roi.width == dstWidth && roi.height == dstHeight { return cropped() }
        if case .rgb8 = plane {
            if interpolation != .none && (width == 1 || height == 1) {
                let channels = (0..<3).map { c -> [UInt8] in
                    var bp = GeometryProcessor(.gray8(channel(c)), width: width)
                    bp.interpolation = interpolation
                    guard case .gray8(let p) = bp.resizedLinearly(width: dstWidth, height: dstHeight).plane else { return [] }
                    return p
                }
                return created(.rgb8(Self.merge(channels)), width: dstWidth)
            }
            if interpolation == .bicubic {
                let channels = rgbChannels().map { bp -> [UInt8] in
                    guard case .gray8(let p) = bp.resized(width: dstWidth, height: dstHeight).plane else { return [] }
                    return p
                }
                return created(.rgb8(Self.merge(channels)), width: dstWidth)
            }
        } else if (width == 1 || height == 1) && interpolation != .none {
            return resizedLinearly(width: dstWidth, height: dstHeight)
        }
        let srcCenterX = Double(roi.x) + Double(roi.width) / 2.0
        let srcCenterY = Double(roi.y) + Double(roi.height) / 2.0
        var dstCenterX = Double(dstWidth) / 2.0
        var dstCenterY = Double(dstHeight) / 2.0
        let xScale = Double(dstWidth) / Double(roi.width)
        let yScale = Double(dstHeight) / Double(roi.height)
        if interpolation != .none {
            if dstWidth != width { dstCenterX += xScale / 4.0 }
            if dstHeight != height { dstCenterY += yScale / 4.0 }
        }
        let count = dstWidth * dstHeight
        let method = interpolation
        let xlimit = Double(width) - 1.0, xlimit2 = Double(width) - 1.001
        let ylimit = Double(height) - 1.0, ylimit2 = Double(height) - 1.001

        /// The loop every type shares: `store(index2, xs, ys, index1)` for each destination pixel.
        func sweep(_ store: (Int, Double, Double, Int) -> Void) {
            for y in 0..<dstHeight {
                var ys = (Double(y) - dstCenterY) / yScale + srcCenterY
                if method == .bilinear {
                    if ys < 0.0 { ys = 0.0 }
                    if ys >= ylimit { ys = ylimit2 }
                }
                let index1 = width * ImageJRules.int(ys)
                var index2 = y * dstWidth
                for x in 0..<dstWidth {
                    var xs = (Double(x) - dstCenterX) / xScale + srcCenterX
                    if method == .bilinear {
                        if xs < 0.0 { xs = 0.0 }
                        if xs >= xlimit { xs = xlimit2 }
                    }
                    store(index2, xs, ys, index1)
                    index2 += 1
                }
            }
        }

        switch plane {
        case .gray8(let p): return created(.gray8(resizeIntegers(p, count, sweep)), width: dstWidth)
        case .gray16(let p): return created(.gray16(resizeIntegers(p, count, sweep)), width: dstWidth)
        case .gray32Float(let p):
            var out = [Float](repeating: 0, count: count)
            sweep { i, xs, ys, index1 in
                switch method {
                case .bicubic: out[i] = Float(bicubicInterpolatedPixel(x: xs, y: ys, source: self))
                case .bilinear: out[i] = Float(Kernels.bilinear(xs, ys, p, width))
                case .none: out[i] = Kernels.at(p, index1 + ImageJRules.int(xs))
                }
            }
            return created(.gray32Float(out), width: dstWidth)
        case .rgb8(let p):
            var out = [UInt32](repeating: 0xFF00_0000, count: count)
            sweep { i, xs, ys, index1 in
                out[i] = method == .bilinear
                    ? Kernels.bilinearRGB(xs, ys, p, width) : Kernels.at(p, index1 + ImageJRules.int(xs))
            }
            return created(.rgb8(out), width: dstWidth)
        }

        func resizeIntegers<T: FixedWidthInteger & UnsignedInteger>(
            _ p: [T], _ count: Int, _ sweep: ((Int, Double, Double, Int) -> Void) -> Void
        ) -> [T] {
            let maxValue = Int(T.max)
            var out = [T](repeating: 0, count: count)
            sweep { i, xs, ys, index1 in
                switch method {
                case .bicubic:
                    var value = ImageJRules.int(bicubicInterpolatedPixel(x: xs, y: ys, source: self) + 0.5)
                    if value < 0 { value = 0 }
                    if value > maxValue { value = maxValue }
                    out[i] = T(value)
                case .bilinear:
                    out[i] = T(truncatingIfNeeded: ImageJRules.int(Kernels.bilinear(xs, ys, p, width) + 0.5))
                case .none:
                    out[i] = Kernels.at(p, index1 + ImageJRules.int(xs))
                }
            }
            return out
        }
    }

    /// `resizeLinearly`: for images one pixel wide or high, the first row
    /// (or column) interpolated linearly to the new length and repeated.
    func resizedLinearly(width width2: Int, height height2: Int) -> GeometryProcessor {
        let rotate = width == 1
        var values = floatValues(channel: 0)
        var width1 = width, height1 = height
        var w2 = width2, h2 = height2
        if rotate {
            values = Self.rotateLeft(values, width: width1, height: height1)
            swap(&width1, &height1)
            swap(&w2, &h2)
        }
        let scale = Double(width1 - 1) / Double(w2 - 1)
        var data2 = [Float](repeating: 0, count: w2)
        for x in 0..<w2 {
            let x1 = ImageJRules.int(Double(x) * scale)
            var x2 = x1 + 1
            if x2 == width1 { x2 = width1 - 1 }
            let fraction = Double(x) * scale - Double(x1)
            data2[x] = Float((1.0 - fraction) * Double(Kernels.at(values, x1)) + fraction * Double(Kernels.at(values, x2)))
        }
        var out = [Float]()
        out.reserveCapacity(w2 * h2)
        for _ in 0..<h2 { out += data2 }
        if rotate { out = Self.rotateRight(out, width: w2, height: h2) }
        switch plane {
        case .gray8:
            var p = created(.gray8(out.map { UInt8(FloatChannels.roundClamped($0, max: 255)) }), width: width2)
            p.minMax = nil  // convertToByte(false) resets the range
            return p
        case .gray16:
            let shorts = out.map { f -> UInt16 in
                var value = Double(f)
                if value < 0.0 { value = 0.0 }
                if value > 65535.0 { value = 65535.0 }
                return UInt16(truncatingIfNeeded: ImageJRules.int(value + 0.5))
            }
            var p = created(.gray16(shorts), width: width2)
            p.minMax = nil  // a new ShortProcessor shows its own range
            return p
        case .gray32Float:
            return created(.gray32Float(out), width: width2)
        case .rgb8:
            preconditionFailure("RGB images are resized linearly per channel")
        }
    }

    /// `ImageProcessor.rotateLeft` of a row-major array.
    static func rotateLeft<T>(_ p: [T], width: Int, height: Int) -> [T] {
        // ip2(x: row, y: i) = ip(width-1-i, row); ip2 is height × width.
        var out = p
        for row in 0..<height {
            for i in 0..<width { out[i * height + row] = p[row * width + (width - 1 - i)] }
        }
        return out
    }

    /// `ImageProcessor.rotateRight` of a row-major array.
    static func rotateRight<T>(_ p: [T], width: Int, height: Int) -> [T] {
        // ip2(x: height-1-row, y: i) = ip(i, row); ip2 is height × width.
        var out = p
        for row in 0..<height {
            for i in 0..<width { out[i * height + (height - 1 - row)] = p[row * width + i] }
        }
        return out
    }

    /// `resize(dstWidth, dstHeight, useAveraging)`: when shrinking with
    /// averaging, each channel is converted to float and downsized with a
    /// kernel matching the interpolation method (`FloatProcessor.downsize`);
    /// otherwise the same as ``resized(width:height:)``.
    public func resized(width dstWidth: Int, height dstHeight: Int, averaging: Bool) -> GeometryProcessor {
        if (dstWidth >= roi.width && dstHeight >= roi.height) || !averaging {
            return resized(width: dstWidth, height: dstHeight)
        }
        let channelCount = pixelType == .rgb8 ? 3 : 1
        var results: [GeometryProcessor] = []
        for c in 0..<channelCount {
            // toFloat: a float processor is its own; the others copy the
            // ROI and their display range (0–255 for RGB channels).
            var fp = self
            if pixelType != .gray32Float {
                fp = GeometryProcessor(.gray32Float(floatValues(channel: c)), width: width)
                fp.interpolation = interpolation
                fp.setRoi(roi)
                let (lo, hi) = pixelType == .rgb8 ? (0, 255) : currentMinMax
                fp.setMinAndMax(lo, hi)
            }
            results.append(fp.downsized(width: dstWidth, height: dstHeight))
        }
        let fp2 = results[0]
        guard case .gray32Float(let f) = fp2.plane else { preconditionFailure("downsizing works on float") }
        switch plane {
        case .gray8:
            var p = created(.gray8(f.map { UInt8(FloatChannels.roundClamped($0, max: 255)) }), width: dstWidth)
            p.setMinAndMax(fp2.displayMin, fp2.displayMax)
            return p
        case .gray16:
            var p = created(.gray16(f.map { UInt16(FloatChannels.roundClamped($0, max: 65535)) }), width: dstWidth)
            p.setMinAndMax(fp2.displayMin, fp2.displayMax)
            return p
        case .gray32Float:
            var p = created(.gray32Float(f), width: dstWidth)
            p.setMinAndMax(fp2.displayMin, fp2.displayMax)
            return p
        case .rgb8:
            let channels = results.map { r -> [UInt8] in
                guard case .gray32Float(let f) = r.plane else { return [] }
                return f.map { UInt8(FloatChannels.roundClamped($0, max: 255)) }
            }
            return created(.rgb8(Self.merge(channels)), width: dstWidth)
        }
    }

    /// `FloatProcessor.downsize`: averaging along x, then y, then any
    /// enlarging the other way. Only for float processors.
    func downsized(width dstWidth: Int, height dstHeight: Int) -> GeometryProcessor {
        var ip2 = self
        if dstWidth < roi.width {
            ip2 = ip2.downsized1D(width: dstWidth, height: roi.height, xDirection: true)
            ip2.setRoi(RoiBounds(x: 0, y: 0, width: dstWidth, height: roi.height))
        }
        if dstHeight < roi.height {
            ip2 = ip2.downsized1D(width: ip2.roi.width, height: dstHeight, xDirection: false)
        }
        if ip2.width != dstWidth || ip2.height != dstHeight {
            ip2 = ip2.resized(width: dstWidth, height: dstHeight)
        }
        return ip2
    }

    /// `FloatProcessor.downsize1D`: each source pixel added to its
    /// destination pixels with the `DownsizeTable` weights.
    func downsized1D(width dstWidth: Int, height dstHeight: Int, xDirection: Bool) -> GeometryProcessor {
        guard case .gray32Float(let pixels) = plane else { preconditionFailure("downsizing works on float") }
        let srcPointInc = xDirection ? 1 : width
        let srcLineInc = xDirection ? width : 1
        let dstPointInc = xDirection ? 1 : dstWidth
        let dstLineInc = xDirection ? dstWidth : 1
        let srcLine0 = xDirection ? roi.y : roi.x
        let dstLines = xDirection ? dstHeight : dstWidth
        let dt = xDirection
            ? DownsizeTable(srcSize: width, srcOrigin: roi.x, srcLength: roi.width, dstSize: dstWidth, method: interpolation)
            : DownsizeTable(srcSize: height, srcOrigin: roi.y, srcLength: roi.height, dstSize: dstHeight, method: interpolation)
        var pixels2 = [Float](repeating: 0, count: dstWidth * dstHeight)
        let k = dt.kernelSize
        var srcLine = srcLine0
        for dstLine in 0..<dstLines {
            let dstLineOffset = dstLine * dstLineInc
            var tablePointer = 0
            if dt.srcStart <= dt.srcEnd {
                var p = dt.srcStart * srcPointInc + srcLine * srcLineInc
                for _ in dt.srcStart...dt.srcEnd {
                    let v = Kernels.at(pixels, p)
                    for _ in 0..<k {
                        let d = dstLineOffset + dt.indices[tablePointer] * dstPointInc
                        if d >= 0 && d < pixels2.count { pixels2[d] += v * dt.weights[tablePointer] }
                        tablePointer += 1
                    }
                    p += srcPointInc
                }
            }
            srcLine += 1
        }
        return created(.gray32Float(pixels2), width: dstWidth)
    }

    // MARK: scale

    /// `scale(xScale, yScale)`: scales the selected rectangle in place about
    /// its center. Enlarging (both factors above 1) fills the rectangle
    /// grown by the factors; shrinking fills what the image no longer
    /// covers with the background (8-bit, RGB) or the display minimum (16-
    /// and 32-bit). RGB images are scaled per channel for bicubic.
    public mutating func scale(x xScale: Double, y yScale: Double) {
        if case .rgb8 = plane, interpolation == .bicubic {
            filterRGB { bp in bp.scale(x: xScale, y: yScale) }
            return
        }
        if case .gray8 = plane, !backgroundSet, invertedLUT { background = 0 }
        let xCenter = Double(roi.x) + Double(roi.width) / 2.0
        let yCenter = Double(roi.y) + Double(roi.height) / 2.0
        var xmin: Int, xmax: Int, ymin: Int, ymax: Int
        if xScale > 1.0 && yScale > 1.0 {
            xmin = ImageJRules.int(xCenter - (xCenter - Double(roi.x)) * xScale)
            if xmin < 0 { xmin = 0 }
            xmax = xmin + ImageJRules.int(Double(roi.width) * xScale) - 1
            if xmax >= width { xmax = width - 1 }
            ymin = ImageJRules.int(yCenter - (yCenter - Double(roi.y)) * yScale)
            if ymin < 0 { ymin = 0 }
            ymax = ymin + ImageJRules.int(Double(roi.height) * yScale) - 1
            if ymax >= height { ymax = height - 1 }
        } else {
            xmin = roi.x
            xmax = roi.x + roi.width - 1
            ymin = roi.y
            ymax = roi.y + roi.height - 1
        }
        guard xmin <= xmax, ymin <= ymax else { return }
        let source = self
        let method = interpolation
        let checkCoordinates = xScale < 1.0 || yScale < 1.0
        let xlimit = Double(width) - 1.0, xlimit2 = Double(width) - 1.001
        let ylimit = Double(height) - 1.0, ylimit2 = Double(height) - 1.001
        let w = width
        let xr = (xmin, xmax), yr = (ymin, ymax)

        /// The shared loops: `bicubic(index, xs, ys)` or `store(index, xs, ys, index2 + xsi, outside)`.
        func sweep(bicubic: (Int, Double, Double) -> Void, other: (Int, Double, Double, Int, Bool) -> Void) {
            if method == .bicubic {
                for y in yr.0...yr.1 {
                    let ys = (Double(y) - yCenter) / yScale + yCenter
                    var index1 = y * w + xr.0
                    for x in xr.0...xr.1 {
                        let xs = (Double(x) - xCenter) / xScale + xCenter
                        bicubic(index1, xs, ys)
                        index1 += 1
                    }
                }
                return
            }
            for y in yr.0...yr.1 {
                var ys = (Double(y) - yCenter) / yScale + yCenter
                let ysi = ImageJRules.int(ys)
                if ys < 0.0 { ys = 0.0 }
                if ys >= ylimit { ys = ylimit2 }
                var index1 = y * w + xr.0
                let index2 = w * ImageJRules.int(ys)
                for x in xr.0...xr.1 {
                    var xs = (Double(x) - xCenter) / xScale + xCenter
                    let xsi = ImageJRules.int(xs)
                    let outside = checkCoordinates && (xsi < xr.0 || xsi > xr.1 || ysi < yr.0 || ysi > yr.1)
                    if !outside, method == .bilinear {
                        if xs < 0.0 { xs = 0.0 }
                        if xs >= xlimit { xs = xlimit2 }
                    }
                    other(index1, xs, ys, index2 + xsi, outside)
                    index1 += 1
                }
            }
        }

        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            let copy = p
            var ip2 = GeometryProcessor(.gray8(copy), width: w)
            ip2.setBackgroundValue(source.background)
            let bg = UInt8(truncatingIfNeeded: Int(source.background))
            sweep(
                bicubic: { i, xs, ys in
                    var value = ImageJRules.int(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2) + 0.5)
                    if value < 0 { value = 0 }
                    if value > 255 { value = 255 }
                    p[i] = UInt8(value)
                },
                other: { i, xs, ys, j, outside in
                    if outside {
                        p[i] = bg
                    } else if method == .bilinear {
                        p[i] = UInt8(truncatingIfNeeded: ImageJRules.int(Kernels.bilinear(xs, ys, copy, w) + 0.5) & 255)
                    } else {
                        p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            let copy = p
            let ip2 = GeometryProcessor(.gray16(copy), width: w)  // background 0
            let min2 = UInt16(truncatingIfNeeded: ImageJRules.int(source.displayMin))
            sweep(
                bicubic: { i, xs, ys in
                    var value = ImageJRules.int(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2) + 0.5)
                    if value < 0 { value = 0 }
                    if value > 65535 { value = 65535 }
                    p[i] = UInt16(value)
                },
                other: { i, xs, ys, j, outside in
                    if outside {
                        p[i] = min2
                    } else if method == .bilinear {
                        p[i] = UInt16(truncatingIfNeeded: ImageJRules.int(Kernels.bilinear(xs, ys, copy, w) + 0.5))
                    } else {
                        p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            let copy = p
            let ip2 = GeometryProcessor(.gray32Float(copy), width: w)  // background 0
            let min2 = Float(source.displayMin)
            sweep(
                bicubic: { i, xs, ys in p[i] = Float(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2)) },
                other: { i, xs, ys, j, outside in
                    if outside {
                        p[i] = min2
                    } else if method == .bilinear {
                        p[i] = Float(Kernels.bilinear(xs, ys, copy, w))
                    } else {
                        p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray32Float(p)
        case .rgb8(var p):
            plane = .gray8([])
            let copy = p
            let bg = UInt32(bitPattern: Int32(truncatingIfNeeded: Int(source.background))) | 0xFF00_0000
            sweep(
                bicubic: { _, _, _ in },
                other: { i, xs, ys, j, outside in
                    if outside {
                        p[i] = bg
                    } else if method == .bilinear {
                        p[i] = Kernels.bilinearRGB(xs, ys, copy, w)
                    } else {
                        p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .rgb8(p)
        }
    }

    // MARK: rotate

    /// `rotate(angle)`: rotates the selected rectangle `angle` degrees
    /// clockwise about its center; what comes from outside the image is the
    /// background. RGB images are rotated per channel for bicubic.
    public mutating func rotate(degrees angle: Double) {
        let isByteOrRGB = pixelType == .gray8 || pixelType == .rgb8
        if isByteOrRGB, angle.truncatingRemainder(dividingBy: 360) == 0 { return }
        if case .rgb8 = plane, interpolation == .bicubic {
            filterRGB { bp in bp.rotate(degrees: angle) }
            return
        }
        // ByteProcessor copies its background into the bicubic source before
        // switching to black for inverted LUTs.
        let byteSourceBackground = background
        if case .gray8 = plane, !backgroundSet, invertedLUT { background = 0 }
        let centerX = Double(roi.x) + Double(roi.width - 1) / 2.0
        let centerY = Double(roi.y) + Double(roi.height - 1) / 2.0
        let xMax = roi.x + roi.width - 1
        let angleRadians = -angle / (180.0 / Double.pi)
        let ca = GeometryMath.cosine(angleRadians)
        let sa = GeometryMath.sine(angleRadians)
        let tmp1 = centerY * sa - centerX * ca
        let tmp2 = -centerX * sa - centerY * ca
        let w = width, h = height
        let dwidth = Double(width), dheight = Double(height)
        let xlimit = Double(width) - 1.0, xlimit2 = Double(width) - 1.001
        let ylimit = Double(height) - 1.0, ylimit2 = Double(height) - 1.001
        let method = interpolation
        let source = self
        guard roi.width > 0, roi.height > 0 else { return }
        let roiX = roi.x, roiY = roi.y, roiH = roi.height

        /// The shared loops: `bicubic(index, xs, ys)`, or `other(index, xs, ys, nearest)` with
        /// `nearest` the nearest pixel's index, or `nil` outside the image.
        func sweep(bicubic: (Int, Double, Double) -> Void, other: (Int, Double, Double, Int?) -> Void) {
            for y in roiY..<(roiY + roiH) {
                var index = y * w + roiX
                let tmp3 = tmp1 - Double(y) * sa + centerX
                let tmp4 = tmp2 + Double(y) * ca + centerY
                for x in roiX...xMax {
                    var xs = Double(x) * ca + tmp3
                    var ys = Double(x) * sa + tmp4
                    if method == .bicubic {
                        bicubic(index, xs, ys)
                    } else if xs >= -0.01 && xs < dwidth && ys >= -0.01 && ys < dheight {
                        if method == .bilinear {
                            if xs < 0.0 { xs = 0.0 }
                            if xs >= xlimit { xs = xlimit2 }
                            if ys < 0.0 { ys = 0.0 }
                            if ys >= ylimit { ys = ylimit2 }
                            other(index, xs, ys, -1)
                        } else {
                            var ixs = ImageJRules.int(xs + 0.5), iys = ImageJRules.int(ys + 0.5)
                            if ixs >= w { ixs = w - 1 }
                            if iys >= h { iys = h - 1 }
                            other(index, xs, ys, w * iys + ixs)
                        }
                    } else {
                        other(index, xs, ys, nil)
                    }
                    index += 1
                }
            }
        }

        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            let copy = p
            var ip2 = GeometryProcessor(.gray8(copy), width: w)
            ip2.setBackgroundValue(byteSourceBackground)
            let bg = UInt8(truncatingIfNeeded: Int(background))
            sweep(
                bicubic: { i, xs, ys in
                    var value = ImageJRules.int(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2) + 0.5)
                    if value < 0 { value = 0 }
                    if value > 255 { value = 255 }
                    p[i] = UInt8(value)
                },
                other: { i, xs, ys, nearest in
                    switch nearest {
                    case nil: p[i] = bg
                    case .some(-1): p[i] = UInt8(truncatingIfNeeded: ImageJRules.int(Kernels.bilinear(xs, ys, copy, w) + 0.5))
                    case let j?: p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            let copy = p
            let ip2 = GeometryProcessor(.gray16(copy), width: w)  // background 0
            let value = Int(background)
            let bg = UInt16(truncatingIfNeeded: signed16 ? value + 32768 : value)
            sweep(
                bicubic: { i, xs, ys in
                    var value = ImageJRules.int(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2) + 0.5)
                    if value < 0 { value = 0 }
                    if value > 65535 { value = 65535 }
                    p[i] = UInt16(value)
                },
                other: { i, xs, ys, nearest in
                    switch nearest {
                    case nil: p[i] = bg
                    case .some(-1): p[i] = UInt16(truncatingIfNeeded: ImageJRules.int(Kernels.bilinear(xs, ys, copy, w) + 0.5))
                    case let j?: p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            let copy = p
            var ip2 = GeometryProcessor(.gray32Float(copy), width: w)
            ip2.setBackgroundValue(background)
            let bg = Float(background)
            sweep(
                bicubic: { i, xs, ys in p[i] = Float(source.bicubicInterpolatedPixel(x: xs, y: ys, source: ip2)) },
                other: { i, xs, ys, nearest in
                    switch nearest {
                    case nil: p[i] = bg
                    case .some(-1): p[i] = Float(Kernels.bilinear(xs, ys, copy, w))
                    case let j?: p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .gray32Float(p)
        case .rgb8(var p):
            plane = .gray8([])
            let copy = p
            let bg = UInt32(bitPattern: Int32(truncatingIfNeeded: Int(background))) | 0xFF00_0000
            sweep(
                bicubic: { _, _, _ in },
                other: { i, xs, ys, nearest in
                    switch nearest {
                    case nil: p[i] = bg
                    case .some(-1): p[i] = Kernels.bilinearRGB(xs, ys, copy, w)
                    case let j?: p[i] = Kernels.at(copy, j)
                    }
                })
            plane = .rgb8(p)
        }
    }

    // MARK: translate

    /// `translate(xOffset, yOffset)`: moves the selected rectangle's content
    /// by the offsets, reading from a copy of the whole image; what comes
    /// from outside it is 0. Whole-pixel offsets (or no interpolation) move
    /// by `(int)` of the offsets; RGB images are translated per channel for
    /// bicubic.
    public mutating func translate(x xOffset: Double, y yOffset: Double) {
        var ip2 = self
        ip2.setBackgroundValue(0.0)
        let integerOffsets = xOffset == Double(ImageJRules.int(xOffset)) && yOffset == Double(ImageJRules.int(yOffset))
        let r = roi
        if integerOffsets || interpolation == .none {
            let dx = ImageJRules.int(xOffset), dy = ImageJRules.int(yOffset)
            for y in r.y..<(r.y + r.height) {
                for x in r.x..<(r.x + r.width) { putPixel(x, y, ip2.pixel(x - dx, y - dy)) }
            }
        } else if interpolation == .bicubic, case .rgb8 = plane {
            filterRGB { bp in bp.translate(x: xOffset, y: yOffset) }
        } else {
            for y in r.y..<(r.y + r.height) {
                for x in r.x..<(r.x + r.width) {
                    putPixel(x, y, ip2.pixelInterpolated(x: Double(x) - xOffset, y: Double(y) - yOffset))
                }
            }
        }
    }

    /// `putPixel(x, y, value)`: clamped for 8- and 16-bit, float bits for
    /// 32-bit, a packed color for RGB (made opaque, as Mancora keeps RGB).
    mutating func putPixel(_ x: Int, _ y: Int, _ value: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let i = y * width + x
        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            p[i] = UInt8(Swift.min(Swift.max(value, 0), 255))
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            p[i] = UInt16(Swift.min(Swift.max(value, 0), 65535))
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            p[i] = Float(bitPattern: UInt32(truncatingIfNeeded: value))
            plane = .gray32Float(p)
        case .rgb8(var p):
            plane = .gray8([])
            p[i] = UInt32(truncatingIfNeeded: value) | 0xFF00_0000  // Mancora keeps RGB opaque
            plane = .rgb8(p)
        }
    }

    // MARK: RGB channels

    /// One channel (0 red, 1 green, 2 blue) as bytes; the value for gray.
    func channel(_ c: Int) -> [UInt8] {
        switch plane {
        case .rgb8(let p):
            let shift = UInt32(16 - 8 * c)
            return p.map { UInt8(truncatingIfNeeded: $0 >> shift) }
        case .gray8(let p): return p
        default: return []
        }
    }

    /// `toFloat(channel)`: the channel's values as floats.
    func floatValues(channel c: Int) -> [Float] {
        switch plane {
        case .gray8(let p): return p.map { Float($0) }
        case .gray16(let p): return p.map { Float($0) }
        case .gray32Float(let p): return p
        case .rgb8: return channel(c).map { Float($0) }
        }
    }

    static func merge(_ channels: [[UInt8]]) -> [UInt32] {
        let r = channels[0], g = channels[1], b = channels[2]
        var out = [UInt32](repeating: 0, count: r.count)
        for i in out.indices { out[i] = 0xFF00_0000 | UInt32(r[i]) << 16 | UInt32(g[i]) << 8 | UInt32(b[i]) }
        return out
    }

    /// The red, green and blue byte processors of `filterRGB`: this ROI and
    /// interpolation, and each channel of the background.
    func rgbChannels() -> [GeometryProcessor] {
        let bg = Int(Int32(truncatingIfNeeded: Int(background)))
        return (0..<3).map { c in
            var bp = GeometryProcessor(.gray8(channel(c)), width: width)
            bp.setRoi(roi)
            bp.setBackgroundValue(Double((bg >> (16 - 8 * c)) & 0xFF))
            bp.interpolation = interpolation
            return bp
        }
    }

    /// `ColorProcessor.filterRGB`: `operation` on each channel, recombined.
    mutating func filterRGB(_ operation: (inout GeometryProcessor) -> Void) {
        let channels = rgbChannels().map { bp -> [UInt8] in
            var bp = bp
            operation(&bp)
            guard case .gray8(let p) = bp.plane else { return [] }
            return p
        }
        plane = .rgb8(Self.merge(channels))
    }
}

/// `ij.process.DownsizeTable`: for each source pixel along one direction,
/// the destination pixels it contributes to and with what weight, so that
/// downsizing is a convolution with a kernel of the interpolation method
/// (box, triangle or Catmull-Rom), normalized per destination pixel.
struct DownsizeTable {
    let kernelSize: Int
    let srcStart: Int
    let srcEnd: Int
    var indices: [Int]
    var weights: [Float]

    init(srcSize: Int, srcOrigin: Int, srcLength: Int, dstSize: Int, method: InterpolationMethod) {
        let scale = Double(srcLength) / Double(dstSize)
        let kernelSize = method.kernelSize
        self.kernelSize = kernelSize
        func srcIndex(_ dstIndex: Double) -> Double { Double(srcOrigin) - 0.5 + (dstIndex + 0.5) * scale }
        func dstIndex(_ srcIndex: Int) -> Double { (Double(srcIndex - srcOrigin) + 0.5) / scale - 0.5 }
        func kernel(_ x: Double) -> Float {
            switch method {
            case .none: return 1
            case .bilinear: return 1 - Float(abs(x))
            case .bicubic: return Float(Kernels.cubic(x))
            }
        }
        let k = Double(kernelSize)
        let srcStartUncorr = ImageJRules.int((1e-8 + srcIndex(-0.5 * k)).rounded(.up))
        srcStart = srcStartUncorr < 0 ? 0 : srcStartUncorr
        let srcEndUncorr = ImageJRules.int((1e-8 + srcIndex(Double(dstSize - 1) + 0.5 * k)).rounded(.down))
        srcEnd = srcEndUncorr >= srcSize ? srcSize - 1 : srcEndUncorr
        let arraySize = max((srcEnd - srcStart + 1) * kernelSize, 0)
        let unused = -1
        indices = [Int](repeating: unused, count: arraySize)
        weights = [Float](repeating: 0, count: arraySize)
        for dst in 0..<dstSize {
            var sum = 0.0
            let lowestS = ImageJRules.int((1e-8 + srcIndex(Double(dst) - 0.5 * k)).rounded(.up))
            let highestS = ImageJRules.int((-1e-8 + srcIndex(Double(dst) + 0.5 * k)).rounded(.down))
            if lowestS <= highestS {
                for src in lowestS...highestS {
                    let s = src < 0 ? 0 : (src >= srcSize ? srcSize - 1 : src)
                    var p = (s - srcStart) * kernelSize
                    guard p >= 0 else { continue }
                    while p < arraySize && indices[p] != unused && indices[p] != dst { p += 1 }
                    guard p < arraySize else { continue }
                    indices[p] = dst
                    let weight = kernel(Double(dst) - dstIndex(src))
                    sum += Double(weight)
                    weights[p] += weight
                }
            }
            var iStart = (lowestS - srcStart) * kernelSize
            if iStart < 0 { iStart = 0 }
            var iStop = (highestS - srcStart) * kernelSize + (kernelSize - 1)
            if iStop >= arraySize { iStop = arraySize - 1 }
            if iStart <= iStop {
                for i in iStart...iStop where indices[i] == dst {
                    weights[i] = Float(Double(weights[i]) / sum)
                }
            }
        }
        for i in indices.indices where indices[i] == unused { indices[i] = 0 }
    }
}
