public import MancoraCore

/// The settings of Process ▸ Subtract Background (ImageJ's
/// `ij.plugin.filter.BackgroundSubtracter` dialog).
public struct BackgroundOptions: Sendable, Hashable {
    /// "Rolling ball radius", in pixels: the radius of the ball, or the
    /// curvature radius at the apex of the sliding paraboloid.
    public var radius: Double
    /// "Light background": the background is brighter than the objects (in
    /// pixel values; ImageJ swaps this for an image with an inverted LUT).
    public var lightBackground: Bool
    /// "Separate colors": each RGB channel gets its own background, instead
    /// of the brightness only (keeping hue and saturation).
    public var separateColors: Bool
    /// "Create background (don't subtract)": the result is the background.
    public var createBackground: Bool
    /// "Sliding paraboloid" instead of the rolling ball.
    public var useParaboloid: Bool
    /// The 3×3 mean (and, for the paraboloid, maximum) applied before the
    /// background is computed; "Disable smoothing" turns it off.
    public var presmooth: Bool

    public init(
        radius: Double = 50, lightBackground: Bool = false, separateColors: Bool = false,
        createBackground: Bool = false, useParaboloid: Bool = false, presmooth: Bool = true
    ) {
        self.radius = radius
        self.lightBackground = lightBackground
        self.separateColors = separateColors
        self.createBackground = createBackground
        self.useParaboloid = useParaboloid
        self.presmooth = presmooth
    }
}

/// Why a background couldn't be computed.
public enum BackgroundError: Error, Sendable, Equatable {
    /// The rolling ball shrinks the image for large radii; ImageJ fails (with
    /// an exception) when the shrunken image is less than 2 pixels wide or high.
    case imageTooSmall
}

extension Plane {
    /// Process ▸ Subtract Background on one plane, as ImageJ's
    /// `BackgroundSubtracter.run(ip)` computes it: the rolling ball
    /// (Sternberg, with ImageJ's shrinking for radii above 10) or the sliding
    /// paraboloid, in single precision as ImageJ does.
    ///
    /// Integer results are offset by 0.5 and clamped (with a light
    /// background, relative to the type's maximum); float results are the
    /// difference. RGB planes are processed on their HSB brightness unless
    /// ``BackgroundOptions/separateColors`` is set.
    ///
    /// - Parameter invertedLUT: whether the image is shown with an inverted
    ///   LUT, which swaps the meaning of a light background (as in ImageJ).
    public func subtractingBackground(
        _ options: BackgroundOptions, width: Int, invertedLUT: Bool
    ) throws(BackgroundError) -> Plane {
        let height = filterHeight(width: width)
        guard count > 0 else { return self }
        if case .rgb8(let pixels) = self, !options.separateColors {
            return .rgb8(try BackgroundSubtracter.brightnessBackground(pixels, width: width, height: height, options))
        }
        return try BackgroundSubtracter.rollingBallBackground(self, width: width, height: height, options, invertedLUT: invertedLUT)
    }
}

/// A port of ImageJ 1.54p's `BackgroundSubtracter` and its `RollingBall`,
/// keeping its `float` arithmetic and evaluation order.
enum BackgroundSubtracter {
    /// `rollingBallBrightnessBackground`: the background of the brightness,
    /// with hue and saturation kept (through 8-bit HSB, as ImageJ does).
    static func brightnessBackground(
        _ pixels: [UInt32], width: Int, height: Int, _ options: BackgroundOptions
    ) throws(BackgroundError) -> [UInt32] {
        let n = pixels.count
        var hues = [UInt8](repeating: 0, count: n), saturations = hues, brightness = hues
        for i in 0..<n {
            let c = pixels[i]
            let (h, s, b) = rgbToHSB(Int32((c >> 16) & 0xFF), Int32((c >> 8) & 0xFF), Int32(c & 0xFF))
            hues[i] = JavaNumerics.byte(Double(h) * 255.0)
            saturations[i] = JavaNumerics.byte(Double(s) * 255.0)
            brightness[i] = JavaNumerics.byte(Double(b) * 255.0)
        }
        // A new ByteProcessor without a color model: never an inverted LUT.
        guard case .gray8(let background) = try rollingBallBackground(
            .gray8(brightness), width: width, height: height, options, invertedLUT: false)
        else { return pixels }
        var out = pixels
        for i in 0..<n {
            let (r, g, b) = LUT.hsbToRGB(
                hue: Float(Double(hues[i]) / 255.0), saturation: Float(Double(saturations[i]) / 255.0),
                brightness: Float(Double(background[i]) / 255.0))
            out[i] = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
        return out
    }

    /// `java.awt.Color.RGBtoHSB`.
    static func rgbToHSB(_ r: Int32, _ g: Int32, _ b: Int32) -> (Float, Float, Float) {
        var cmax = r > g ? r : g
        if b > cmax { cmax = b }
        var cmin = r < g ? r : g
        if b < cmin { cmin = b }
        let brightness = Float(cmax) / 255.0
        let saturation: Float = cmax != 0 ? Float(cmax - cmin) / Float(cmax) : 0
        var hue: Float
        if saturation == 0 {
            hue = 0
        } else {
            let redc = Float(cmax - r) / Float(cmax - cmin)
            let greenc = Float(cmax - g) / Float(cmax - cmin)
            let bluec = Float(cmax - b) / Float(cmax - cmin)
            if r == cmax {
                hue = bluec - greenc
            } else if g == cmax {
                hue = 2.0 + redc - bluec
            } else {
                hue = 4.0 + greenc - redc
            }
            hue = hue / 6.0
            if hue < 0 { hue = hue + 1.0 }
        }
        return (hue, saturation, brightness)
    }

    /// `rollingBallBackground(ip, radius, createBackground, lightBackground,
    /// useParaboloid, doPresmooth, true)` for any plane type, one channel at
    /// a time.
    static func rollingBallBackground(
        _ plane: Plane, width: Int, height: Int, _ options: BackgroundOptions, invertedLUT: Bool
    ) throws(BackgroundError) -> Plane {
        let invert = (invertedLUT && !options.lightBackground) || (!invertedLUT && options.lightBackground)
        let ball = options.useParaboloid ? nil : RollingBall(radius: options.radius)
        var channels = FloatChannels.split(plane)
        var out = plane
        for channel in channels.indices {
            var fp = channels[channel]
            if let ball {
                try rollingBallFloatBackground(&fp, width: width, height: height, invert: invert, presmooth: options.presmooth, ball: ball)
            } else {
                slidingParaboloidFloatBackground(
                    &fp, width: width, height: height, radius: Float(options.radius), invert: invert,
                    presmooth: options.presmooth, correctCorners: true)
            }
            if options.createBackground {
                channels[channel] = fp
                continue
            }
            // Subtract the background now; integer types add 0.5 for rounding.
            switch out {
            case .gray32Float(let original):
                out = .gray32Float(zip(original, fp).map { $0 - $1 })
            case .gray16(var pixels):
                let offset: Float = invert ? 65535.5 : 0.5
                for p in pixels.indices {
                    var value = Float(pixels[p]) - fp[p] + offset
                    if value < 0 { value = 0 }
                    if value > 65535 { value = 65535 }
                    pixels[p] = UInt16(truncatingIfNeeded: JavaNumerics.int32(value))
                }
                out = .gray16(pixels)
            case .gray8(var pixels):
                let offset: Float = invert ? 255.5 : 0.5
                for p in pixels.indices {
                    var value = Float(pixels[p]) - fp[p] + offset
                    if value < 0 { value = 0 }
                    if value > 255 { value = 255 }
                    pixels[p] = UInt8(truncatingIfNeeded: JavaNumerics.int32(value))
                }
                out = .gray8(pixels)
            case .rgb8(var pixels):
                let offset: Float = invert ? 255.5 : 0.5
                let shift = UInt32(16 - 8 * channel)
                let resetMask = ~(UInt32(255) << shift)
                for p in pixels.indices {
                    let pxl = pixels[p]
                    var value = Float((pxl >> shift) & 0xFF) - fp[p] + offset
                    if value < 0 { value = 0 }
                    if value > 255 { value = 255 }
                    pixels[p] = (pxl & resetMask) | UInt32(bitPattern: JavaNumerics.int32(value) << Int32(shift))
                }
                out = .rgb8(pixels)
            }
        }
        if options.createBackground {
            // `ip.setPixels(channel, fp)`: rounded and clamped for integer types.
            var merged = FloatChannels.merge(channels, as: plane.pixelType)
            if case .rgb8(let original) = plane, case .rgb8(var pixels) = merged {
                for i in pixels.indices { pixels[i] = (pixels[i] & 0x00FF_FFFF) | (original[i] & 0xFF00_0000) }
                merged = .rgb8(pixels)
            }
            return merged
        }
        return out
    }

    // MARK: Sliding paraboloid

    /// `slidingParaboloidFloatBackground`.
    static func slidingParaboloidFloatBackground(
        _ pixels: inout [Float], width: Int, height: Int, radius: Float, invert: Bool, presmooth: Bool,
        correctCorners: Bool
    ) {
        var cache = [Float](repeating: 0, count: max(width, height))
        var nextPoint = [Int](repeating: 0, count: max(width, height))
        let coeff2: Float = 0.5 / radius
        let coeff2diag: Float = 1.0 / radius
        if invert {
            for i in pixels.indices { pixels[i] = -pixels[i] }
        }
        var shiftBy: Float = 0
        if presmooth {
            shiftBy = Float(filter3x3(&pixels, width: width, height: height, maximum: true))
            _ = filter3x3(&pixels, width: width, height: height, maximum: false)
        }
        if correctCorners {
            self.correctCorners(&pixels, width: width, height: height, coeff2: coeff2, cache: &cache, nextPoint: &nextPoint)
        }
        let passes: [(Direction, Float)] = [
            (.x, coeff2), (.y, coeff2), (.x, coeff2), (.diagonal1A, coeff2diag), (.diagonal1B, coeff2diag),
            (.diagonal2A, coeff2diag), (.diagonal2B, coeff2diag), (.diagonal1A, coeff2diag), (.diagonal1B, coeff2diag),
        ]
        for (direction, coefficient) in passes {
            filter1D(&pixels, width: width, height: height, direction: direction, coeff2: coefficient, cache: &cache, nextPoint: &nextPoint)
        }
        if invert {
            for i in pixels.indices { pixels[i] = -(pixels[i] - shiftBy) }
        } else if presmooth {
            for i in pixels.indices { pixels[i] -= shiftBy }
        }
    }

    enum Direction { case x, y, diagonal1A, diagonal1B, diagonal2A, diagonal2B }

    /// `filter1D`: the parabola slid along every line in one direction
    /// (the diagonal directions cover half the image each).
    static func filter1D(
        _ pixels: inout [Float], width: Int, height: Int, direction: Direction, coeff2: Float, cache: inout [Float],
        nextPoint: inout [Int]
    ) {
        var startLine = 0, nLines = 0, lineInc = 0, pointInc = 0, length = 0
        switch direction {
        case .x: (nLines, lineInc, pointInc, length) = (height, width, 1, width)
        case .y: (nLines, lineInc, pointInc, length) = (width, 1, width, height)
        case .diagonal1A: (nLines, lineInc, pointInc) = (width - 2, 1, width + 1)
        case .diagonal1B: (startLine, nLines, lineInc, pointInc) = (1, height - 2, width, width + 1)
        case .diagonal2A: (startLine, nLines, lineInc, pointInc) = (2, width, 1, width - 1)
        case .diagonal2B: (startLine, nLines, lineInc, pointInc) = (0, height - 2, width, width - 1)
        }
        var i = startLine
        while i < nLines {
            var startPixel = i * lineInc
            if direction == .diagonal2B { startPixel += width - 1 }
            switch direction {
            case .diagonal1A: length = min(height, width - i)
            case .diagonal1B: length = min(width, height - i)
            case .diagonal2A: length = min(height, i + 1)
            case .diagonal2B: length = min(width, height - i)
            case .x, .y: break
            }
            _ = lineSlideParabola(
                &pixels, start: startPixel, inc: pointInc, length: length, coeff2: coeff2, cache: &cache,
                nextPoint: &nextPoint, correctEdges: false)
            i += 1
        }
    }

    /// `lineSlideParabola`: one line, with points the parabola can't touch
    /// raised to it. With `correctEdges`, also the two edge values estimated
    /// without an edge particle (allowing for vignetting).
    static func lineSlideParabola(
        _ pixels: inout [Float], start: Int, inc: Int, length: Int, coeff2: Float, cache: inout [Float],
        nextPoint: inout [Int], correctEdges: Bool
    ) -> (Float, Float) {
        let noPoint = Int(Int32.max)
        var minValue = Float.greatestFiniteMagnitude
        var lastpoint = 0
        var firstCorner = length - 1
        var lastCorner = 0
        var vPrevious1: Float = 0
        var vPrevious2: Float = 0
        let curvatureTest: Float = 1.999 * coeff2
        var p = start
        for i in 0..<max(length, 0) {
            let v = pixels[p]
            cache[i] = v
            if v < minValue { minValue = v }
            if i >= 2 && vPrevious1 + vPrevious1 - vPrevious2 - v < curvatureTest {
                nextPoint[lastpoint] = i - 1
                lastpoint = i - 1
            }
            vPrevious2 = vPrevious1
            vPrevious1 = v
            p += inc
        }
        guard length > 0 else { return (0, 0) }
        nextPoint[lastpoint] = length - 1
        nextPoint[length - 1] = noPoint

        var i1 = 0
        while i1 < length - 1 {
            let v1 = cache[i1]
            var minSlope = Float.greatestFiniteMagnitude
            var i2 = 0
            var searchTo = length
            var recalculateLimitNow = 0
            var j = nextPoint[i1]
            while j < searchTo {
                let v2 = cache[j]
                let slope = (v2 - v1) / Float(j - i1) + coeff2 * Float(j - i1)
                if slope < minSlope {
                    minSlope = slope
                    i2 = j
                    recalculateLimitNow = -3
                }
                if recalculateLimitNow == 0 {
                    let b = Double(0.5 * minSlope / coeff2)
                    let reach = JavaNumerics.int32(b + (b * b + Double((v1 - minValue) / coeff2)).squareRoot() + 1)
                    let maxSearch = Int32(truncatingIfNeeded: i1) &+ reach  // may overflow, as in ImageJ
                    if Int(maxSearch) < searchTo && maxSearch > 0 { searchTo = Int(maxSearch) }
                }
                j = nextPoint[j]
                recalculateLimitNow += 1
            }
            if i1 == 0 { firstCorner = i2 }
            if i2 == length - 1 { lastCorner = i1 }
            var q = start + (i1 + 1) * inc
            var k = i1 + 1
            while k < i2 {
                pixels[q] = v1 + Float(k - i1) * (minSlope - Float(k - i1) * coeff2)
                k += 1
                q += inc
            }
            // ImageJ loops forever when no slope is a number (NaN data); stop instead.
            if i2 <= i1 { break }
            i1 = i2
        }
        guard correctEdges else { return (0, 0) }
        if 4 * firstCorner >= length { firstCorner = 0 }
        if 4 * (length - 1 - lastCorner) >= length { lastCorner = length - 1 }
        let v1 = cache[firstCorner]
        let v2 = cache[lastCorner]
        let slope = (v2 - v1) / Float(lastCorner - firstCorner)
        let value0 = v1 - slope * Float(firstCorner)
        var coeff6: Float = 0
        let mid: Float = 0.5 * Float(lastCorner + firstCorner)
        var i = (length + 2) / 3
        while i <= (2 * length) / 3 {
            let dx = (Float(i) - mid) * 2 / Float(lastCorner - firstCorner)
            let poly6 = dx * dx * dx * dx * dx * dx - 1
            if cache[i] < value0 + slope * Float(i) + coeff6 * poly6 {
                coeff6 = -(value0 + slope * Float(i) - cache[i]) / poly6
            }
            i += 1
        }
        var dx = (Float(firstCorner) - mid) * 2 / Float(lastCorner - firstCorner)
        let edge0 = value0 + coeff6 * (dx * dx * dx * dx * dx * dx - 1) + coeff2 * Float(firstCorner) * Float(firstCorner)
        dx = (Float(lastCorner) - mid) * 2 / Float(lastCorner - firstCorner)
        let edge1 = value0 + Float(length - 1) * slope + coeff6 * (dx * dx * dx * dx * dx * dx - 1)
            + coeff2 * Float(length - 1 - lastCorner) * Float(length - 1 - lastCorner)
        return (edge0, edge1)
    }

    /// `correctCorners`: corner pixels lowered where a particle sits in a
    /// corner, from the edge and diagonal lines through it.
    static func correctCorners(
        _ pixels: inout [Float], width: Int, height: Int, coeff2: Float, cache: inout [Float], nextPoint: inout [Int]
    ) {
        func slide(_ start: Int, _ inc: Int, _ length: Int, _ coeff: Float) -> (Float, Float) {
            lineSlideParabola(&pixels, start: start, inc: inc, length: length, coeff2: coeff, cache: &cache, nextPoint: &nextPoint, correctEdges: true)
        }
        var corners: [Float] = [0, 0, 0, 0]
        var edges = slide(0, 1, width, coeff2)
        corners[0] = edges.0
        corners[1] = edges.1
        edges = slide((height - 1) * width, 1, width, coeff2)
        corners[2] = edges.0
        corners[3] = edges.1
        edges = slide(0, width, height, coeff2)
        corners[0] += edges.0
        corners[2] += edges.1
        edges = slide(width - 1, width, height, coeff2)
        corners[1] += edges.0
        corners[3] += edges.1
        let diagLength = min(width, height)
        let coeff2diag = 2 * coeff2
        corners[0] += slide(0, 1 + width, diagLength, coeff2diag).0
        corners[1] += slide(width - 1, -1 + width, diagLength, coeff2diag).0
        corners[2] += slide((height - 1) * width, 1 - width, diagLength, coeff2diag).0
        corners[3] += slide(width * height - 1, -1 - width, diagLength, coeff2diag).0
        let positions = [0, width - 1, (height - 1) * width, width * height - 1]
        for (k, p) in positions.enumerated() where pixels[p] > corners[k] / 3 {
            pixels[p] = corners[k] / 3
        }
    }

    // MARK: Rolling ball

    /// `rollingBallFloatBackground`.
    static func rollingBallFloatBackground(
        _ pixels: inout [Float], width: Int, height: Int, invert: Bool, presmooth: Bool, ball: RollingBall
    ) throws(BackgroundError) {
        let shrink = ball.shrinkFactor > 1
        if invert {
            for i in pixels.indices { pixels[i] = -pixels[i] }
        }
        if presmooth { _ = filter3x3(&pixels, width: width, height: height, maximum: false) }
        if shrink {
            var (small, smallWidth, smallHeight) = shrinkImage(pixels, width: width, height: height, shrinkFactor: ball.shrinkFactor)
            rollBall(ball, &small, width: smallWidth, height: smallHeight)
            try enlargeImage(
                small, smallWidth: smallWidth, smallHeight: smallHeight, into: &pixels, width: width, height: height,
                shrinkFactor: ball.shrinkFactor)
        } else {
            rollBall(ball, &pixels, width: width, height: height)
        }
        if invert {
            for i in pixels.indices { pixels[i] = -pixels[i] }
        }
    }

    /// `shrinkImage`: each pixel of the small image is the minimum of its
    /// `shrinkFactor²` block.
    static func shrinkImage(_ pixels: [Float], width: Int, height: Int, shrinkFactor: Int) -> ([Float], Int, Int) {
        let sWidth = (width + shrinkFactor - 1) / shrinkFactor
        let sHeight = (height + shrinkFactor - 1) / shrinkFactor
        var small = [Float](repeating: 0, count: sWidth * sHeight)
        for ySmall in 0..<sHeight {
            for xSmall in 0..<sWidth {
                var minimum = Float.greatestFiniteMagnitude
                var y = shrinkFactor * ySmall
                for _ in 0..<shrinkFactor where y < height {
                    var x = shrinkFactor * xSmall
                    for _ in 0..<shrinkFactor where x < width {
                        let v = pixels[x + y * width]
                        if v < minimum { minimum = v }
                        x += 1
                    }
                    y += 1
                }
                small[xSmall + ySmall * sWidth] = minimum
            }
        }
        return (small, sWidth, sHeight)
    }

    /// `rollBall`: the hull of the ball rolled under the surface.
    static func rollBall(_ ball: RollingBall, _ pixels: inout [Float], width: Int, height: Int) {
        let ballWidth = ball.width
        let radius = ballWidth / 2
        var cache = [Float](repeating: 0, count: width * ballWidth)
        ball.data.withUnsafeBufferPointer { zBall in
            pixels.withUnsafeMutableBufferPointer { pixels in
                cache.withUnsafeMutableBufferPointer { cache in
                    for y in -radius..<(height + radius) {
                        let nextLineToWriteInCache = (y + radius) % ballWidth
                        let nextLineToRead = y + radius
                        if nextLineToRead < height {
                            for x in 0..<width {
                                cache[nextLineToWriteInCache * width + x] = pixels[nextLineToRead * width + x]
                                pixels[nextLineToRead * width + x] = -Float.greatestFiniteMagnitude
                            }
                        }
                        let y0 = max(y - radius, 0)
                        let yBall0 = y0 - y + radius
                        let yend = min(y + radius, height - 1)
                        guard y0 <= yend else { continue }
                        for x in -radius..<(width + radius) {
                            var z = Float.greatestFiniteMagnitude
                            let x0 = max(x - radius, 0)
                            let xBall0 = x0 - x + radius
                            let xend = min(x + radius, width - 1)
                            guard x0 <= xend else { continue }
                            var yBall = yBall0
                            for yp in y0...yend {
                                var cachePointer = (yp % ballWidth) * width + x0
                                var bp = xBall0 + yBall * ballWidth
                                for _ in x0...xend {
                                    let zReduced = cache[cachePointer] - zBall[bp]
                                    if z > zReduced { z = zReduced }
                                    cachePointer += 1
                                    bp += 1
                                }
                                yBall += 1
                            }
                            yBall = yBall0
                            for yp in y0...yend {
                                var p = x0 + yp * width
                                var bp = xBall0 + yBall * ballWidth
                                for _ in x0...xend {
                                    let zMin = z + zBall[bp]
                                    if pixels[p] < zMin { pixels[p] = zMin }
                                    p += 1
                                    bp += 1
                                }
                                yBall += 1
                            }
                        }
                    }
                }
            }
        }
    }

    /// `enlargeImage`: bilinear interpolation (extrapolation at the edges)
    /// of the shrunken background back to full size.
    static func enlargeImage(
        _ small: [Float], smallWidth: Int, smallHeight: Int, into pixels: inout [Float], width: Int, height: Int,
        shrinkFactor: Int
    ) throws(BackgroundError) {
        guard smallWidth >= 2, smallHeight >= 2 else { throw .imageTooSmall }
        let (xSmallIndices, xWeights) = interpolationArrays(length: width, smallLength: smallWidth, shrinkFactor: shrinkFactor)
        let (ySmallIndices, yWeights) = interpolationArrays(length: height, smallLength: smallHeight, shrinkFactor: shrinkFactor)
        var line0 = [Float](repeating: 0, count: width)
        var line1 = [Float](repeating: 0, count: width)
        for x in 0..<width {
            line1[x] = small[xSmallIndices[x]] * xWeights[x] + small[xSmallIndices[x] + 1] * (1 - xWeights[x])
        }
        var ySmallLine0 = -1
        for y in 0..<height {
            if ySmallLine0 < ySmallIndices[y] {
                swap(&line0, &line1)
                ySmallLine0 += 1
                let sYPointer = (ySmallIndices[y] + 1) * smallWidth
                for x in 0..<width {
                    line1[x] = small[sYPointer + xSmallIndices[x]] * xWeights[x]
                        + small[sYPointer + xSmallIndices[x] + 1] * (1 - xWeights[x])
                }
            }
            let weight = yWeights[y]
            for x in 0..<width {
                pixels[y * width + x] = line0[x] * weight + line1[x] * (1 - weight)
            }
        }
    }

    /// `makeInterpolationArrays`: the left small-image index for each pixel
    /// and its weight.
    static func interpolationArrays(length: Int, smallLength: Int, shrinkFactor: Int) -> ([Int], [Float]) {
        var indices = [Int](repeating: 0, count: length)
        var weights = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var smallIndex = (i - shrinkFactor / 2) / shrinkFactor
            if smallIndex >= smallLength - 1 { smallIndex = smallLength - 2 }
            indices[i] = smallIndex
            let distance = (Float(i) + 0.5) / Float(shrinkFactor) - (Float(smallIndex) + 0.5)
            weights[i] = 1 - distance
        }
        return (indices, weights)
    }

    // MARK: Common

    /// `filter3x3`: the 3×3 maximum or mean, as a 1D filter along rows and
    /// then columns. For the maximum, returns the average change.
    static func filter3x3(_ pixels: inout [Float], width: Int, height: Int, maximum: Bool) -> Double {
        var shiftBy = 0.0
        for y in 0..<height { shiftBy += filter3(&pixels, length: width, pixel0: y * width, inc: 1, maximum: maximum) }
        for x in 0..<width { shiftBy += filter3(&pixels, length: height, pixel0: x, inc: width, maximum: maximum) }
        return shiftBy / Double(width) / Double(height)
    }

    /// `filter3`: one line, maximum or mean of 3 neighbors.
    static func filter3(_ pixels: inout [Float], length: Int, pixel0: Int, inc: Int, maximum: Bool) -> Double {
        var shiftBy = 0.0
        var v3 = pixels[pixel0]
        var v2 = v3
        var v1: Float
        var p = pixel0
        for i in 0..<length {
            v1 = v2
            v2 = v3
            if i < length - 1 { v3 = pixels[p + inc] }
            if maximum {
                var maxValue = v1 > v3 ? v1 : v3
                if v2 > maxValue { maxValue = v2 }
                shiftBy += Double(maxValue - v2)
                pixels[p] = maxValue
            } else {
                pixels[p] = (v1 + v2 + v3) * 0.33333333
            }
            p += inc
        }
        return shiftBy
    }
}

/// ImageJ's `RollingBall`: the square top patch of a ball, and the factor by
/// which the image is shrunk before rolling it.
struct RollingBall: Sendable {
    let data: [Float]
    let width: Int
    let shrinkFactor: Int

    init(radius: Double) {
        let arcTrimPer: Int
        if radius <= 10 {
            (shrinkFactor, arcTrimPer) = (1, 24)
        } else if radius <= 30 {
            (shrinkFactor, arcTrimPer) = (2, 24)
        } else if radius <= 100 {
            (shrinkFactor, arcTrimPer) = (4, 32)
        } else {
            (shrinkFactor, arcTrimPer) = (8, 40)
        }
        var smallBallRadius = radius / Double(shrinkFactor)
        if smallBallRadius < 1 { smallBallRadius = 1 }
        let rsquare = smallBallRadius * smallBallRadius
        let xtrim = Int(JavaNumerics.int32(Double(arcTrimPer) * smallBallRadius)) / 100
        let halfWidth = Int(JavaNumerics.roundToInt32(smallBallRadius - Double(xtrim)))
        width = 2 * halfWidth + 1
        var data = [Float](repeating: 0, count: width * width)
        var p = 0
        for y in 0..<width {
            for x in 0..<width {
                let xval = x - halfWidth, yval = y - halfWidth
                let temp = rsquare - Double(xval * xval) - Double(yval * yval)
                data[p] = temp > 0 ? Float(temp.squareRoot()) : 0
                p += 1
            }
        }
        self.data = data
    }
}
