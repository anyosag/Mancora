public import MancoraCore

/// Process ▸ Binary ▸ Options ▸ EDM output: where Distance Map, Ultimate
/// Points and Voronoi put their result (ImageJ's `EDM.setOutputType`).
public enum EDMOutput: Int, Sendable, Hashable, CaseIterable {
    /// The 8-bit input is overwritten (`BYTE_OVERWRITE`).
    case overwrite = 0
    /// A new 8-bit image (`BYTE`).
    case byte
    /// A new 16-bit image (`SHORT`).
    case short
    /// A new 32-bit image (`FLOAT`).
    case float

    /// The names in ImageJ's dialog, in this order.
    public static let names = ["Overwrite", "8-bit", "16-bit", "32-bit"]

    public var name: String { Self.names[rawValue] }
}

/// The Euclidean distance map commands of Process ▸ Binary (ImageJ's
/// `ij.plugin.filter.EDM`).
public enum EDMOperation: Sendable, Hashable {
    /// Distance Map: each foreground pixel gets its distance to the nearest
    /// background pixel.
    case distanceMap
    /// Ultimate Points: the maxima of the distance map, with its values.
    case ultimatePoints
    /// Watershed: particles cut at their necks, along the watershed of the
    /// distance map (always overwrites the input).
    case watershed
    /// Voronoi: lines of equal distance to the two nearest particles, with
    /// the distance as value; zero inside the cells.
    case voronoi

    /// The title prefix of a new output image (`EDM.TITLE_PREFIX`).
    public var titlePrefix: String {
        switch self {
        case .distanceMap: "EDM of "
        case .ultimatePoints: "UEPs of "
        case .watershed: ""
        case .voronoi: "Voronoi of "
        }
    }
}

/// A port of ImageJ 1.54p's `EDM` plugin filter.
public enum EDM {
    /// What one plane becomes.
    public struct Result: Sendable {
        /// The input plane's new pixels, for Watershed and the Overwrite output.
        public var overwritten: [UInt8]?
        /// For Overwrite: the display range ImageJ leaves on the processor
        /// (`setPixels(0, fp)` takes the EDM's range, reset to 0–255 above 255).
        public var displayRange: ClosedRange<Double>?
        /// For a new image: the plane in the output type.
        public var output: Plane?

        public init(overwritten: [UInt8]? = nil, displayRange: ClosedRange<Double>? = nil, output: Plane? = nil) {
            self.overwritten = overwritten
            self.displayRange = displayRange
            self.output = output
        }
    }

    /// The MaximumFinder prominence ImageJ uses on distance maps.
    static let maxFinderTolerance = 0.5

    /// `EDM.run(ip)` on one 8-bit binary plane.
    ///
    /// - Parameter background255: whether the background is 255 rather than
    ///   0 (ImageJ: an inverted LUT with Black background, or a normal LUT
    ///   without it).
    public static func run(
        _ operation: EDMOperation, on pixels: [UInt8], width: Int, background255: Bool, output: EDMOutput
    ) -> Result {
        let height = width > 0 ? pixels.count / width : 0
        let backgroundValue: UInt8 =
            operation == .voronoi ? (background255 ? 0 : 255) : (background255 ? 255 : 0)
        var edm = floatEDM(pixels, width: width, height: height, backgroundValue: backgroundValue)
        var maxImage: [UInt8]?
        if operation != .distanceMap {
            if operation == .voronoi { edm = edm.map { $0 * -1 } }  // Voronoi starts from the EDM's minima
            let found = MaximumFinder.find(
                values: edm, width: width, height: height, isFloat: true, tolerance: maxFinderTolerance, strict: false,
                threshold: nil, output: operation == .ultimatePoints ? .singlePoints : .segmented, excludeOnEdges: false,
                isEDM: operation != .voronoi)
            let image = found.image ?? []
            maxImage = image
            if operation != .watershed {
                if operation == .voronoi { edm = edm.map { $0 * -1 } }
                let resetOn: UInt8 = operation == .voronoi ? 255 : 0
                for i in edm.indices where image[i] == resetOn { edm[i] = 0 }
            }
        }
        if operation == .watershed {
            let segmented = maxImage ?? pixels
            return Result(overwritten: background255 ? segmented.map { 255 - $0 } : segmented)
        }
        switch output {
        case .float:
            return Result(output: .gray32Float(edm))
        case .short:
            return Result(output: TypeConverter.toGray16(.gray32Float(edm), displayRange: 0...65535, scale: true))
        case .byte:
            return Result(output: TypeConverter.toGray8(.gray32Float(edm), displayRange: 0...255, scale: true))
        case .overwrite:
            guard case .gray8(let bytes) = FloatChannels.merge([edm], as: .gray8) else { return Result() }
            // ByteProcessor.setMinAndMax(fp.getMin(), fp.getMax()), with Math.round.
            var range: ClosedRange<Double> = 0...255
            if let first = edm.first(where: { !$0.isNaN }) {
                var lo = first, hi = first
                for v in edm where !v.isNaN {
                    if v < lo { lo = v } else if v > hi { hi = v }
                }
                if Double(hi) <= 255 {
                    range = Double(JavaNumerics.roundToInt32(Double(lo)))...Double(JavaNumerics.roundToInt32(Double(hi)))
                }
            }
            return Result(overwritten: bytes, displayRange: range)
        }
    }

    /// `EDM.makeFloatEDM(ip, backgroundValue, edgesAreBackground)`: for each
    /// pixel not equal to `backgroundValue`, the distance to the nearest one
    /// that is (an 8SSEDT-like approximation, exact below 13 pixels).
    public static func floatEDM(
        _ pixels: [UInt8], width: Int, height: Int, backgroundValue: UInt8, edgesAreBackground: Bool = false
    ) -> [Float] {
        var fPixels = [Float](repeating: 0, count: width * height)
        for i in fPixels.indices where pixels[i] != backgroundValue { fPixels[i] = .greatestFiniteMagnitude }
        var pointBufs = [[Int]](repeating: [Int](repeating: noPoint, count: width), count: 2)
        var yDist = Int(Int32.max)  // used only if edges are background
        for y in 0..<height {
            if edgesAreBackground { yDist = y + 1 }
            edmLine(pixels, &fPixels, &pointBufs, width: width, offset: y * width, y: y, backgroundValue: backgroundValue, yDist: yDist)
        }
        pointBufs = [[Int]](repeating: [Int](repeating: noPoint, count: width), count: 2)
        for y in stride(from: height - 1, through: 0, by: -1) {
            if edgesAreBackground { yDist = height - y }
            edmLine(pixels, &fPixels, &pointBufs, width: width, offset: y * width, y: y, backgroundValue: backgroundValue, yDist: yDist)
        }
        // fp.sqrt()
        for i in fPixels.indices { fPixels[i] = fPixels[i] <= 0 ? 0 : Float(Double(fPixels[i]).squareRoot()) }
        return fPixels
    }

    static let noPoint = -1

    /// `edmLine`: one line, left to right and right to left.
    static func edmLine(
        _ bPixels: [UInt8], _ fPixels: inout [Float], _ pointBufs: inout [[Int]], width: Int, offset start: Int, y: Int,
        backgroundValue: UInt8, yDist: Int
    ) {
        let edgesAreBackground = yDist != Int(Int32.max)
        var distSqr = Int(Int32.max)
        var pPrev = noPoint
        var pDiag = noPoint
        var offset = start
        for x in 0..<width {
            let pNextDiag = pointBufs[0][x]
            if bPixels[offset] == backgroundValue {
                pointBufs[0][x] = x | y << 16
            } else {
                if edgesAreBackground { distSqr = x + 1 < yDist ? (x + 1) * (x + 1) : yDist * yDist }
                let dist2 = minDist2(&pointBufs[0], pPrev, pDiag, x, y, distSqr)
                if fPixels[offset] > dist2 { fPixels[offset] = dist2 }
            }
            pPrev = pointBufs[0][x]
            pDiag = pNextDiag
            offset += 1
        }
        offset -= 1
        pPrev = noPoint
        pDiag = noPoint
        for x in stride(from: width - 1, through: 0, by: -1) {
            let pNextDiag = pointBufs[1][x]
            if bPixels[offset] == backgroundValue {
                pointBufs[1][x] = x | y << 16
            } else {
                if edgesAreBackground { distSqr = width - x < yDist ? (width - x) * (width - x) : yDist * yDist }
                let dist2 = minDist2(&pointBufs[1], pPrev, pDiag, x, y, distSqr)
                if fPixels[offset] > dist2 { fPixels[offset] = dist2 }
            }
            pPrev = pointBufs[1][x]
            pDiag = pNextDiag
            offset -= 1
        }
    }

    /// `minDist2`: the smallest squared distance from (x, y) to the nearest
    /// background points known for the previous line, the previous pixel
    /// and the diagonal, recording the nearest in `points[x]`.
    static func minDist2(_ points: inout [Int], _ pPrev: Int, _ pDiag: Int, _ x: Int, _ y: Int, _ distSqrIn: Int) -> Float {
        var distSqr = distSqrIn
        let p0 = points[x]
        var nearestPoint = p0
        if p0 != noPoint {
            let x0 = p0 & 0xFFFF, y0 = (p0 >> 16) & 0xFFFF
            let dist1Sqr = (x - x0) * (x - x0) + (y - y0) * (y - y0)
            if dist1Sqr < distSqr { distSqr = dist1Sqr }
        }
        if pDiag != p0 && pDiag != noPoint {
            let x1 = pDiag & 0xFFFF, y1 = (pDiag >> 16) & 0xFFFF
            let dist1Sqr = (x - x1) * (x - x1) + (y - y1) * (y - y1)
            if dist1Sqr < distSqr {
                nearestPoint = pDiag
                distSqr = dist1Sqr
            }
        }
        if pPrev != pDiag && pPrev != noPoint {
            let x1 = pPrev & 0xFFFF, y1 = (pPrev >> 16) & 0xFFFF
            let dist1Sqr = (x - x1) * (x - x1) + (y - y1) * (y - y1)
            if dist1Sqr < distSqr {
                nearestPoint = pPrev
                distSqr = dist1Sqr
            }
        }
        points[x] = nearestPoint
        return Float(distSqr)
    }
}
