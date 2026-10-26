public import MancoraCore

/// What Process ▸ Find Maxima produces (ImageJ's `MaximumFinder` output types).
public enum MaximaOutput: Int, Sendable, Hashable, CaseIterable {
    /// One pixel per maximum, 255 in a new 8-bit image (`SINGLE_POINTS`).
    case singlePoints = 0
    /// Every pixel within the prominence of a maximum (`IN_TOLERANCE`).
    case inTolerance
    /// Watershed-segmented particles, one per maximum (`SEGMENTED`).
    case segmented
    /// A multi-point selection on the image (`POINT_SELECTION`).
    case pointSelection
    /// The maxima's coordinates in the Results table (`LIST`).
    case list
    /// The number of maxima, added to the Results table (`COUNT`).
    case count

    /// The names in ImageJ's dialog, in this order.
    public static let names = [
        "Single Points", "Maxima Within Tolerance", "Segmented Particles", "Point Selection", "List", "Count",
    ]

    /// Whether the output is the maxima's coordinates rather than an image.
    public var isPointList: Bool { self == .pointSelection || self == .list || self == .count }
}

/// The area of an image Find Maxima looks at: a rectangle and, for other
/// area selections, a mask over it (ImageJ's `ip.getRoi()` and
/// `ip.getMaskArray()`), plus the test `Roi.contains(x, y)` that decides
/// which maxima are reported as points.
public struct MaximaRegion: Sendable {
    public var bounds: RoiBounds
    /// `bounds.width × bounds.height` flags, row by row; `nil` for the whole rectangle.
    public var mask: [Bool]?
    public var contains: @Sendable (Int, Int) -> Bool

    public init(bounds: RoiBounds, mask: [Bool]? = nil, contains: @escaping @Sendable (Int, Int) -> Bool) {
        self.bounds = bounds
        self.mask = mask
        self.contains = contains
    }
}

/// A port of ImageJ 1.54p's `ij.plugin.filter.MaximumFinder`: maxima that
/// stand out from their surroundings by more than a prominence, and the
/// watershed segmentation that starts from them (also used by the EDM
/// commands).
public struct MaximumFinder {
    /// Pixel types noted while analyzing, as bits (`MaximumFinder.MAXIMUM` etc.).
    static let maximum: UInt8 = 1, listed: UInt8 = 2, processed: UInt8 = 4, maxArea: UInt8 = 8, equal: UInt8 = 16,
        maxPoint: UInt8 = 32, eliminated: UInt8 = 64
    static let dirXOffset = [0, 1, 1, 1, 0, -1, -1, -1]
    static let dirYOffset = [-1, -1, 0, 1, 1, 1, 0, -1]
    static let sqrt2: Float = 1.4142135624

    /// The result of ``find(values:width:height:isFloat:tolerance:strict:threshold:output:excludeOnEdges:isEDM:region:)``.
    public struct Result: Sendable {
        /// The 8-bit output (255 marked, 0 elsewhere) for the image outputs.
        public var image: [UInt8]?
        /// The maxima's pixel coordinates, highest first, for the point outputs.
        public var points: [Point]
    }

    let width: Int
    let height: Int
    let intEncodeXMask: Int
    let intEncodeYMask: Int
    let intEncodeShift: Int
    /// Offsets of the 8 neighbors, clockwise from north.
    let dirOffset: [Int]
    /// The pixel values, as `ip.getPixelValue` reads them.
    let values: [Float]

    init(values: [Float], width: Int, height: Int) {
        self.values = values
        self.width = width
        self.height = height
        var shift = 0, mult = 1
        repeat {
            shift += 1
            mult *= 2
        } while mult < width
        intEncodeXMask = mult - 1
        intEncodeYMask = ~intEncodeXMask
        intEncodeShift = shift
        dirOffset = [-width, -width + 1, 1, width + 1, width, width - 1, -1, -width - 1]
    }

    /// `MaximumFinder.findMaxima(ip, tolerance, strict, threshold, outputType, excludeOnEdges, isEDM)`.
    ///
    /// - Parameters:
    ///   - values: The pixel values (`getPixelValue`): 8- and 16-bit values,
    ///     floats, or the mean of R, G and B.
    ///   - isFloat: Whether the image is 32-bit (float sorting is accurate
    ///     only to a fraction of the range, which ImageJ allows for).
    ///   - tolerance: The prominence.
    ///   - threshold: Maxima below this value are ignored; `nil` for none.
    ///   - region: The selection; `nil` for the whole image.
    public static func find(
        values: [Float], width: Int, height: Int, isFloat: Bool, tolerance: Double, strict: Bool, threshold: Double?,
        output: MaximaOutput, excludeOnEdges: Bool, isEDM: Bool, region: MaximaRegion? = nil
    ) -> Result {
        let finder = MaximumFinder(values: values, width: width, height: height)
        return finder.findMaxima(
            isFloat: isFloat, tolerance: tolerance, strict: strict, threshold: threshold, output: output,
            excludeOnEdges: excludeOnEdges, isEDM: isEDM, region: region)
    }

    func findMaxima(
        isFloat: Bool, tolerance: Double, strict: Bool, threshold thresholdIn: Double?, output: MaximaOutput,
        excludeOnEdges: Bool, isEDM: Bool, region: MaximaRegion?
    ) -> Result {
        let roi = region?.bounds ?? RoiBounds(x: 0, y: 0, width: width, height: height)
        var threshold = thresholdIn
        var types = [UInt8](repeating: 0, count: width * height)
        var globalMin = Float.greatestFiniteMagnitude
        var globalMax = -Float.greatestFiniteMagnitude
        for y in roi.y..<(roi.y + roi.height) {
            for x in roi.x..<(roi.x + roi.width) {
                let v = values[x + y * width]
                if globalMin > v { globalMin = v }
                if globalMax < v { globalMax = v }
            }
        }
        var maximumPossible = globalMax > globalMin
        if strict && Double(globalMax - globalMin) <= tolerance { maximumPossible = false }
        if let t = threshold { threshold = t - Double(globalMax - globalMin) * 1e-6 }
        let excludeEdgesNow = excludeOnEdges && output != .segmented

        let maxPoints =
            maximumPossible
            ? sortedMaxPoints(&types, roi: roi, excludeEdgesNow: excludeEdgesNow, isEDM: isEDM, globalMin: globalMin,
                              globalMax: globalMax, threshold: threshold)
            : []
        var maxSortingError: Float = 0
        if isFloat { maxSortingError = 1.1 * (isEDM ? Self.sqrt2 / 2 : (globalMax - globalMin) / 2e9) }
        let points = analyzeAndMarkMaxima(
            &types, maxPoints: maxPoints, excludeEdgesNow: excludeEdgesNow, isEDM: isEDM, tolerance: tolerance,
            strict: strict, output: output, excludeOnEdges: excludeOnEdges, maxSortingError: maxSortingError,
            contains: region?.contains)
        if output.isPointList { return Result(image: nil, points: points) }

        var out: [UInt8]
        if output == .segmented {
            out = make8bit(types, isEDM: isEDM, globalMin: globalMin, globalMax: globalMax, threshold: threshold)
            cleanupMaxima(&out, &types, maxPoints)
            watershedSegment(&out)
            if !isEDM { cleanupExtraLines(&out) }
            for i in out.indices where out[i] < 255 { out[i] = 0 }  // watershedPostProcess
            if excludeOnEdges { deleteEdgeParticles(&out, types) }
        } else {
            let mask = output == .singlePoints ? Self.maxPoint : Self.maxArea
            out = types.map { $0 & mask != 0 ? 255 : 0 }
        }
        // Everything outside the selection is deleted.
        for y in 0..<height {
            for x in 0..<width {
                let i = x + y * width
                if x < roi.x || x >= roi.x + roi.width || y < roi.y || y >= roi.y + roi.height {
                    out[i] = 0
                } else if let mask = region?.mask, !mask[x - roi.x + roi.width * (y - roi.y)] {
                    out[i] = 0
                }
            }
        }
        return Result(image: out, points: [])
    }

    @inline(__always)
    func isWithin(_ x: Int, _ y: Int, _ direction: Int) -> Bool {
        let xmax = width - 1, ymax = height - 1
        switch direction {
        case 0: return y > 0
        case 1: return x < xmax && y > 0
        case 2: return x < xmax
        case 3: return x < xmax && y < ymax
        case 4: return y < ymax
        case 5: return x > 0 && y < ymax
        case 6: return x > 0
        case 7: return x > 0 && y > 0
        default: return false
        }
    }

    /// `getSortedMaxPoints`: every local maximum, as value (scaled to 32 bits)
    /// in the upper half and pixel offset in the lower, sorted.
    func sortedMaxPoints(
        _ types: inout [UInt8], roi: RoiBounds, excludeEdgesNow: Bool, isEDM: Bool, globalMin: Float, globalMax: Float,
        threshold: Double?
    ) -> [Int64] {
        var nMax = 0
        for y in roi.y..<(roi.y + roi.height) {
            for x in roi.x..<(roi.x + roi.width) {
                let i = x + y * width
                let v = values[i]
                let vTrue = isEDM ? trueEdmHeight(x, y) : v
                if v == globalMin { continue }
                if excludeEdgesNow && (x == 0 || x == width - 1 || y == 0 || y == height - 1) { continue }
                if let threshold, Double(v) < threshold { continue }
                var isMax = true
                let isInner = (y != 0 && y != height - 1) && (x != 0 && x != width - 1)
                for d in 0..<8 where isInner || isWithin(x, y, d) {
                    let x2 = x + Self.dirXOffset[d], y2 = y + Self.dirYOffset[d]
                    let vNeighbor = values[x2 + y2 * width]
                    let vNeighborTrue = isEDM ? trueEdmHeight(x2, y2) : vNeighbor
                    if vNeighbor > v && vNeighborTrue > vTrue {
                        isMax = false
                        break
                    }
                }
                if isMax {
                    types[i] = Self.maximum
                    nMax += 1
                }
            }
        }
        let vFactor = Float(2e9 / Double(globalMax - globalMin))
        var maxPoints: [Int64] = []
        maxPoints.reserveCapacity(nMax)
        for y in roi.y..<(roi.y + roi.height) {
            for x in roi.x..<(roi.x + roi.width) {
                let p = x + y * width
                guard types[p] == Self.maximum else { continue }
                let fValue = isEDM ? trueEdmHeight(x, y) : values[p]
                let iValue = JavaNumerics.int32((fValue - globalMin) * vFactor)
                maxPoints.append(Int64(iValue) << 32 | Int64(p))
            }
        }
        maxPoints.sort()
        return maxPoints
    }

    /// `analyzeAndMarkMaxima`: from the highest, each maximum's surroundings
    /// within the prominence are explored; a maximum that reaches a higher
    /// point or one processed before is no maximum. Returns the maxima kept
    /// (for the point outputs).
    func analyzeAndMarkMaxima(
        _ types: inout [UInt8], maxPoints: [Int64], excludeEdgesNow: Bool, isEDM: Bool, tolerance: Double,
        strict: Bool, output: MaximaOutput, excludeOnEdges: Bool, maxSortingError: Float,
        contains: (@Sendable (Int, Int) -> Bool)?
    ) -> [Point] {
        let nMax = maxPoints.count
        var pList = [Int](repeating: 0, count: width * height)
        var points: [Point] = []
        let displayOrCount = output.isPointList
        let toleranceF = Float(tolerance)
        var iMax = nMax - 1
        while iMax >= 0 {
            defer { iMax -= 1 }
            var offset0 = Int(Int32(truncatingIfNeeded: maxPoints[iMax]))
            if types[offset0] & Self.processed != 0 { continue }
            var x0 = offset0 % width
            var y0 = offset0 / width
            var v0 = isEDM ? trueEdmHeight(x0, y0) : values[offset0]
            var sortingError: Bool
            repeat {
                pList[0] = offset0
                types[offset0] |= (Self.equal | Self.listed)
                var listLen = 1
                var listI = 0
                var isEdgeMaximum = x0 == 0 || x0 == width - 1 || y0 == 0 || y0 == height - 1
                sortingError = false
                var maxPossible = true
                var xEqual = Double(x0)
                var yEqual = Double(y0)
                var nEqual = 1
                repeat {
                    let offset = pList[listI]
                    let x = offset % width
                    let y = offset / width
                    let isInner = (y != 0 && y != height - 1) && (x != 0 && x != width - 1)
                    for d in 0..<8 {
                        let offset2 = offset + dirOffset[d]
                        guard (isInner || isWithin(x, y, d)) && types[offset2] & Self.listed == 0 else { continue }
                        if isEDM && values[offset2] <= 0 { continue }  // the background
                        if types[offset2] & Self.processed != 0 {
                            maxPossible = false  // reached a point processed before: no maximum
                            break
                        }
                        let x2 = x + Self.dirXOffset[d]
                        let y2 = y + Self.dirYOffset[d]
                        let v2 = isEDM ? trueEdmHeight(x2, y2) : values[offset2]
                        if v2 > v0 + maxSortingError {
                            maxPossible = false  // reached a higher point: no maximum
                            break
                        } else if v2 >= v0 - toleranceF {
                            if v2 > v0 {  // this point should have been treated earlier
                                sortingError = true
                                offset0 = offset2
                                v0 = v2
                                x0 = x2
                                y0 = y2
                            }
                            pList[listLen] = offset2
                            listLen += 1
                            types[offset2] |= Self.listed
                            if (x2 == 0 || x2 == width - 1 || y2 == 0 || y2 == height - 1) && (strict || v2 >= v0) {
                                isEdgeMaximum = true
                                if excludeEdgesNow {
                                    maxPossible = false
                                    break  // an edge maximum
                                }
                            }
                            if v2 == v0 {  // for the center of equal points
                                types[offset2] |= Self.equal
                                xEqual += Double(x2)
                                yEqual += Double(y2)
                                nEqual += 1
                            }
                        }
                    }
                    listI += 1
                } while listI < listLen

                if sortingError {
                    // Not the true maximum: reset what was found and retry from the higher point.
                    for k in 0..<listLen { types[pList[k]] = 0 }
                } else {
                    let resetMask = ~(maxPossible ? Self.listed : (Self.listed | Self.equal))
                    xEqual /= Double(nEqual)
                    yEqual /= Double(nEqual)
                    var minDist2 = 1e20
                    var nearestI = 0
                    for k in 0..<listLen {
                        let offset = pList[k]
                        let x = offset % width
                        let y = offset / width
                        types[offset] &= resetMask
                        types[offset] |= Self.processed
                        if maxPossible {
                            types[offset] |= Self.maxArea
                            if types[offset] & Self.equal != 0 {
                                let dist2 = (xEqual - Double(x)) * (xEqual - Double(x)) + (yEqual - Double(y)) * (yEqual - Double(y))
                                if dist2 < minDist2 {
                                    minDist2 = dist2
                                    nearestI = k
                                }
                            }
                        }
                    }
                    if maxPossible {
                        let offset = pList[nearestI]
                        types[offset] |= Self.maxPoint
                        if displayOrCount && !(excludeOnEdges && isEdgeMaximum) {
                            let x = offset % width
                            let y = offset / width
                            if contains?(x, y) ?? true { points.append(Point(x: x, y: y)) }
                        }
                    }
                }
            } while sortingError
        }
        if nMax == 0 {  // no maxima at all: everything is within the tolerance
            for i in types.indices { types[i] = Self.processed | Self.maxArea }
        }
        return points
    }

    /// `make8bit`: the image scaled to 1–254 (0 below the threshold), with
    /// the areas of the maxima at 255, for the watershed.
    func make8bit(_ types: [UInt8], isEDM: Bool, globalMin: Float, globalMax: Float, threshold thresholdIn: Double?) -> [UInt8] {
        var threshold = thresholdIn
        let minValue: Double
        if isEDM {
            threshold = 0.5
            minValue = 1
        } else {
            minValue = threshold ?? Double(globalMin)
        }
        let offset = minValue - (Double(globalMax) - minValue) * (1.0 / 253 / 2 - 1e-6)
        var factor = 253 / (Double(globalMax) - minValue)
        if isEDM && factor > 1 { factor = 1 }  // with an EDM, no better resolution
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in pixels.indices {
            let rawValue = values[i]
            if let threshold, Double(rawValue) < threshold {
                pixels[i] = 0
            } else if types[i] & Self.maxArea != 0 {
                pixels[i] = 255
            } else {
                let v = 1 + JavaNumerics.round((Double(rawValue) - offset) * factor)
                pixels[i] = v < 1 ? 1 : v <= 254 ? UInt8(v & 255) : 254
            }
        }
        return pixels
    }

    /// `trueEdmHeight`: the estimated height of an EDM ridge or maximum at
    /// a pixel, which needn't lie at the highest point.
    func trueEdmHeight(_ x: Int, _ y: Int) -> Float {
        let xmax = width - 1
        let ymax = height - 1
        let offset = x + y * width
        let v = values[offset]
        if x == 0 || y == 0 || x == xmax || y == ymax || v == 0 { return v }
        var trueH = v + 0.5 * Self.sqrt2
        var ridgeOrMax = false
        for d in 0..<4 {
            let d2 = (d + 4) % 8
            let v1 = values[offset + dirOffset[d]]
            let v2 = values[offset + dirOffset[d2]]
            var h: Float
            if v >= v1 && v >= v2 {
                ridgeOrMax = true
                h = (v1 + v2) / 2
            } else {
                h = min(v1, v2)
            }
            h += d % 2 == 0 ? 1 : Self.sqrt2
            if trueH > h { trueH = h }
        }
        if !ridgeOrMax { trueH = v }
        return trueH
    }

    /// `cleanupMaxima`: maxima that didn't qualify are flattened to the
    /// level of the saddle towards a qualifying one.
    func cleanupMaxima(_ pixels: inout [UInt8], _ types: inout [UInt8], _ maxPoints: [Int64]) {
        var pList = [Int](repeating: 0, count: width * height)
        for iMax in stride(from: maxPoints.count - 1, through: 0, by: -1) {
            let offset0 = Int(Int32(truncatingIfNeeded: maxPoints[iMax]))
            if types[offset0] & (Self.maxArea | Self.eliminated) != 0 { continue }
            let level = Int(pixels[offset0])
            var loLevel = level + 1
            pList[0] = offset0
            types[offset0] |= Self.listed
            var listLen = 1
            var lastLen = 1
            var saddleFound = false
            while !saddleFound && loLevel > 0 {
                loLevel -= 1
                lastLen = listLen
                var listI = 0
                repeat {
                    let offset = pList[listI]
                    let x = offset % width
                    let y = offset / width
                    let isInner = (y != 0 && y != height - 1) && (x != 0 && x != width - 1)
                    for d in 0..<8 {
                        let offset2 = offset + dirOffset[d]
                        guard (isInner || isWithin(x, y, d)) && types[offset2] & Self.listed == 0 else { continue }
                        if types[offset2] & Self.maxArea != 0
                            || (types[offset2] & Self.eliminated != 0 && Int(pixels[offset2]) >= loLevel)
                        {
                            saddleFound = true  // touching a true maximum, or a level not lower that does
                            break
                        } else if Int(pixels[offset2]) >= loLevel && types[offset2] & Self.eliminated == 0 {
                            pList[listLen] = offset2
                            listLen += 1
                            types[offset2] |= Self.listed
                        }
                    }
                    if saddleFound { break }
                    listI += 1
                } while listI < listLen
            }
            for k in 0..<listLen { types[pList[k]] &= ~Self.listed }
            for k in 0..<lastLen {
                let offset = pList[k]
                pixels[offset] = UInt8(truncatingIfNeeded: loLevel)
                types[offset] |= Self.eliminated
            }
        }
    }

    /// `cleanupExtraLines`: removes foreground patches, single dots and
    /// lines that end inside a particle (from local minima of non-EDM images).
    func cleanupExtraLines(_ pixels: inout [UInt8]) {
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                let v = pixels[i]
                if v != 255 && v != 0 {
                    let radii = nRadii(pixels, x, y)
                    if radii == 0 {
                        pixels[i] = 255
                    } else if radii == 1 {
                        removeLineFrom(&pixels, x, y)
                    }
                }
                i += 1
            }
        }
    }

    /// `removeLineFrom`: deletes a line from (x, y) to the next 4-connected vertex.
    func removeLineFrom(_ pixels: inout [UInt8], _ startX: Int, _ startY: Int) {
        var x = startX, y = startY
        pixels[x + width * y] = 255
        var continues: Bool
        repeat {
            continues = false
            let isInner = (y != 0 && y != height - 1) && (x != 0 && x != width - 1)
            for d in stride(from: 0, to: 8, by: 2) where isInner || isWithin(x, y, d) {
                let v = pixels[x + width * y + dirOffset[d]]
                if v != 255 && v != 0 {
                    let radii = nRadii(pixels, x + Self.dirXOffset[d], y + Self.dirYOffset[d])
                    if radii <= 1 {
                        x += Self.dirXOffset[d]
                        y += Self.dirYOffset[d]
                        pixels[x + width * y] = 255
                        continues = radii == 1
                        break
                    }
                }
            }
        } while continues
    }

    /// `nRadii`: the number of 4-connected lines (pixels below 255) leaving
    /// a pixel; edge pixels count as lines.
    func nRadii(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int {
        let offset = x + y * width
        var countTransitions = 0
        var prevPixelSet = true
        var firstPixelSet = true
        let isInner = (y != 0 && y != height - 1) && (x != 0 && x != width - 1)
        for d in 0..<8 {
            var pixelSet = prevPixelSet
            if isInner || isWithin(x, y, d) {
                let isSet = pixels[offset + dirOffset[d]] != 255
                if d & 1 == 0 {
                    pixelSet = isSet
                } else if !isSet {
                    pixelSet = false
                }
            } else {
                pixelSet = true
            }
            if pixelSet && !prevPixelSet { countTransitions += 1 }
            prevPixelSet = pixelSet
            if d == 0 { firstPixelSet = pixelSet }
        }
        if firstPixelSet && !prevPixelSet { countTransitions += 1 }
        return countTransitions
    }

    /// `deleteEdgeParticles`: particles whose maximum area touches the edge
    /// are filled with 0, as ImageJ fills the wand's traced outline.
    func deleteEdgeParticles(_ pixels: inout [UInt8], _ types: [UInt8]) {
        func deleteParticle(_ x: Int, _ y: Int) {
            let (xs, ys) = Wand.outline(
                values: pixels.map { Float($0) }, width: width, x: x, y: y, lower: 255, upper: 255, mode: .legacy)
            guard !xs.isEmpty else { return }
            let points = zip(xs, ys).map { Roi.IntPoint(x: $0, y: $1) }
            let roi = Roi(.polygon(.init(.traced, .integer(points))))
            guard let mask = try? roi.mask(width: width, height: height) else { return }
            for my in 0..<mask.bounds.height {
                for mx in 0..<mask.bounds.width where mask.pixels[my * mask.bounds.width + mx] {
                    pixels[(mask.bounds.y + my) * width + mask.bounds.x + mx] = 0
                }
            }
        }
        for x in 0..<width {
            var y = 0
            if types[x + y * width] & Self.maxArea != 0 && pixels[x + y * width] != 0 { deleteParticle(x, y) }
            y = height - 1
            if types[x + y * width] & Self.maxArea != 0 && pixels[x + y * width] != 0 { deleteParticle(x, y) }
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                var x = 0
                if types[x + y * width] & Self.maxArea != 0 && pixels[x + y * width] != 0 { deleteParticle(x, y) }
                x = width - 1
                if types[x + y * width] & Self.maxArea != 0 && pixels[x + y * width] != 0 { deleteParticle(x, y) }
            }
        }
    }

    /// `watershedSegment`: dilates the maxima (255) level by level, from 254
    /// down, without letting particles merge; lines keep their levels.
    func watershedSegment(_ pixels: inout [UInt8]) {
        var histogram = [Int](repeating: 0, count: 256)
        for v in pixels { histogram[Int(v)] += 1 }
        let arraySize = width * height - histogram[0] - histogram[255]
        var coordinates = [Int](repeating: 0, count: arraySize)
        var highestValue = 0
        var offset = 0
        var levelStart = [Int](repeating: 0, count: 256)
        for v in 1..<255 {
            levelStart[v] = offset
            offset += histogram[v]
            if histogram[v] > 0 { highestValue = v }
        }
        var levelOffset = [Int](repeating: 0, count: highestValue + 1)
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                let v = Int(pixels[i])
                if v > 0 && v < 255 {
                    offset = levelStart[v] + levelOffset[v]
                    coordinates[offset] = x | y << intEncodeShift
                    levelOffset[v] += 1
                }
                i += 1
            }
        }
        var setPointList: [Int] = []
        let table = Self.fateTable
        let directionSequence = [7, 3, 1, 5, 0, 4, 2, 6]  // diagonal directions first
        var level = highestValue
        while level >= 1 {
            defer { level -= 1 }
            var remaining = histogram[level]
            var idle = 0
            while remaining > 0 && idle < 8 {
                var dIndex = 0
                repeat {
                    let n = processLevel(
                        directionSequence[dIndex % 8], &pixels, table, levelStart[level], remaining, &coordinates,
                        &setPointList)
                    remaining -= n
                    if n > 0 { idle = 0 }
                    dIndex += 1
                    // Java's `while (remaining>0 && idle++<8)`.
                    if remaining <= 0 { break }
                    let wasIdle = idle
                    idle += 1
                    if wasIdle >= 8 { break }
                } while true
            }
            if remaining > 0 && level > 1 {
                var nextLevel = level
                repeat { nextLevel -= 1 } while nextLevel > 1 && histogram[nextLevel] == 0
                // Only the unreached pixels at an edge (of the image or of the
                // area below the threshold) go to the next level; others are
                // left for cleanupExtraLines.
                if nextLevel > 0 {
                    var newNextLevelEnd = levelStart[nextLevel] + histogram[nextLevel]
                    var p = levelStart[level]
                    for _ in 0..<remaining {
                        let xy = coordinates[p]
                        let x = xy & intEncodeXMask
                        let y = (xy & intEncodeYMask) >> intEncodeShift
                        let pOffset = x + y * width
                        var addToNext = false
                        if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                            addToNext = true
                        } else {
                            for d in 0..<8 where isWithin(x, y, d) && pixels[pOffset + dirOffset[d]] == 0 {
                                addToNext = true
                                break
                            }
                        }
                        if addToNext {
                            coordinates[newNextLevelEnd] = xy
                            newNextLevelEnd += 1
                        }
                        p += 1
                    }
                    histogram[nextLevel] = newNextLevelEnd - levelStart[nextLevel]
                }
            }
        }
    }

    /// `processLevel`: one dilation step of the particles in direction
    /// `pass` on one level. Returns the number of pixels set to 255.
    func processLevel(
        _ pass: Int, _ pixels: inout [UInt8], _ fateTable: [Int], _ levelStart: Int, _ levelNPoints: Int,
        _ coordinates: inout [Int], _ setPointList: inout [Int]
    ) -> Int {
        let xmax = width - 1
        let ymax = height - 1
        setPointList.removeAll(keepingCapacity: true)
        var nUnchanged = 0
        var p = levelStart
        for _ in 0..<levelNPoints {
            let xy = coordinates[p]
            let x = xy & intEncodeXMask
            let y = (xy & intEncodeYMask) >> intEncodeShift
            let offset = x + y * width
            var index = 0
            if y > 0 && pixels[offset - width] == 255 { index ^= 1 }
            if x < xmax && y > 0 && pixels[offset - width + 1] == 255 { index ^= 2 }
            if x < xmax && pixels[offset + 1] == 255 { index ^= 4 }
            if x < xmax && y < ymax && pixels[offset + width + 1] == 255 { index ^= 8 }
            if y < ymax && pixels[offset + width] == 255 { index ^= 16 }
            if x > 0 && y < ymax && pixels[offset + width - 1] == 255 { index ^= 32 }
            if x > 0 && pixels[offset - 1] == 255 { index ^= 64 }
            if x > 0 && y > 0 && pixels[offset - width - 1] == 255 { index ^= 128 }
            let mask = 1 << pass
            if fateTable[index] & mask == mask {
                setPointList.append(offset)
            } else {
                coordinates[levelStart + nUnchanged] = xy
                nUnchanged += 1
            }
            p += 1
        }
        for offset in setPointList { pixels[offset] = 255 }
        return setPointList.count
    }

    /// `makeFateTable`: for each 3×3 neighborhood of set pixels, the passes
    /// (directions) in which the center may be added without joining two
    /// particles.
    static let fateTable: [Int] = {
        var table = [Int](repeating: 0, count: 256)
        for item in 0..<256 {
            var isSet = (0..<8).map { item & (1 << $0) != 0 }
            for i in 0..<8 where isSet[(i + 4) % 8] { table[item] |= 1 << i }
            for i in stride(from: 0, to: 8, by: 2) where isSet[i] {
                isSet[(i + 1) % 8] = true
                isSet[(i + 7) % 8] = true
            }
            var transitions = 0
            for i in 0..<8 where isSet[i] != isSet[(i + 1) % 8] { transitions += 1 }
            if transitions >= 4 { table[item] = 0 }
        }
        return table
    }()
}

extension MaximumFinder {
    /// A pixel position.
    public struct Point: Sendable, Hashable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }
}
