/// What Analyze ▸ Measure records (`ij.measure.Measurements`, with ImageJ's
/// bit values so settings and recorded macros carry over).
public struct Measurements: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let area = Measurements(rawValue: 1)
    public static let mean = Measurements(rawValue: 2)
    public static let standardDeviation = Measurements(rawValue: 4)
    public static let mode = Measurements(rawValue: 8)
    public static let minMax = Measurements(rawValue: 16)
    public static let centroid = Measurements(rawValue: 32)
    public static let centerOfMass = Measurements(rawValue: 64)
    public static let perimeter = Measurements(rawValue: 128)
    public static let limitToThreshold = Measurements(rawValue: 256)
    public static let boundingRectangle = Measurements(rawValue: 512)
    public static let labels = Measurements(rawValue: 1024)
    public static let ellipse = Measurements(rawValue: 2048)
    public static let invertY = Measurements(rawValue: 4096)
    public static let shapeDescriptors = Measurements(rawValue: 8192)
    public static let feret = Measurements(rawValue: 16384)
    public static let integratedDensity = Measurements(rawValue: 0x8000)
    public static let median = Measurements(rawValue: 0x10000)
    public static let skewness = Measurements(rawValue: 0x20000)
    public static let kurtosis = Measurements(rawValue: 0x40000)
    public static let areaFraction = Measurements(rawValue: 0x80000)
    public static let stackPosition = Measurements(rawValue: 0x100000)
    public static let scientificNotation = Measurements(rawValue: 0x200000)
    public static let addToOverlay = Measurements(rawValue: 0x400000)
    public static let nanEmptyCells = Measurements(rawValue: 0x800000)

    /// ImageJ's default: area, mean, min and max.
    public static let defaults: Measurements = [.area, .mean, .minMax]

    /// The Set Measurements dialog's checkboxes, in its order.
    public static let dialogLabels: [(label: String, option: Measurements)] = [
        ("Area", .area), ("Mean gray value", .mean), ("Standard deviation", .standardDeviation),
        ("Modal gray value", .mode), ("Min & max gray value", .minMax), ("Centroid", .centroid),
        ("Center of mass", .centerOfMass), ("Perimeter", .perimeter), ("Bounding rectangle", .boundingRectangle),
        ("Fit ellipse", .ellipse), ("Shape descriptors", .shapeDescriptors), ("Feret's diameter", .feret),
        ("Integrated density", .integratedDensity), ("Median", .median), ("Skewness", .skewness),
        ("Kurtosis", .kurtosis), ("Area_fraction", .areaFraction), ("Stack position", .stackPosition),
        ("Limit to threshold", .limitToThreshold), ("Display label", .labels), ("Invert Y coordinates", .invertY),
        ("Scientific notation", .scientificNotation), ("Add to overlay", .addToOverlay),
        ("NaN empty cells", .nanEmptyCells),
    ]
}

/// The pixels a measurement covers: a rectangle within the image and, for
/// a selection that isn't one, a mask over the rectangle.
public struct MeasurementRegion: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// `width × height` flags, row by row; `nil` for the whole rectangle.
    public var mask: [Bool]?

    public init(x: Int, y: Int, width: Int, height: Int, mask: [Bool]? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mask = mask
    }

    func contains(_ x: Int, _ y: Int) -> Bool {
        guard let mask else { return true }
        return mask[(y - self.y) * width + (x - self.x)]
    }
}
