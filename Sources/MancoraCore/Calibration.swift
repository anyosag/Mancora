/// Spatial, temporal and value calibration, mirroring ImageJ's `Calibration`.
public struct Calibration: Sendable, Hashable {
    /// Maps stored pixel values to calibrated values.
    public enum ValueFunction: Sendable, Hashable {
        /// `calibrated = intercept + slope * raw`. ImageJ uses
        /// `(-32768, 1)` for signed 16-bit data stored unsigned.
        case straightLine(intercept: Double, slope: Double)

        public func apply(_ raw: Double) -> Double {
            switch self {
            case .straightLine(let intercept, let slope): intercept + slope * raw
            }
        }
    }

    public var pixelWidth: Double = 1
    public var pixelHeight: Double = 1
    public var pixelDepth: Double = 1
    /// Spatial unit; `"pixel"` when uncalibrated, as in ImageJ.
    public var unit: String = "pixel"
    public var xOrigin: Double = 0
    public var yOrigin: Double = 0
    public var zOrigin: Double = 0
    /// Seconds (or `timeUnit`) between frames; 0 when unknown.
    public var frameInterval: Double = 0
    public var timeUnit: String = "sec"
    /// Vertical and depth units when they differ from `unit`; `nil` otherwise.
    public var yUnit: String?
    public var zUnit: String?
    /// Animation speed in frames per second; 0 means ImageJ's default.
    public var fps: Double = 0
    /// Whether animation loops back and forth.
    public var loop: Bool = false
    public var invertY: Bool = false
    public var valueFunction: ValueFunction?
    public var valueUnit: String = "Gray Value"

    public init() {}

    /// Whether any spatial calibration is set.
    public var isSpatiallyCalibrated: Bool {
        unit != "pixel" && !unit.isEmpty
    }

    /// The calibrated value of a raw pixel value.
    public func calibratedValue(_ raw: Double) -> Double {
        valueFunction?.apply(raw) ?? raw
    }

    /// The raw pixel value of a calibrated value (ImageJ's `getRawValue`):
    /// the straight line inverted, or 0 when it's flat (the first entry of
    /// ImageJ's calibration table that comes closest).
    public func rawValue(_ calibrated: Double) -> Double {
        guard let valueFunction else { return calibrated }
        switch valueFunction {
        case .straightLine(let intercept, let slope): return slope != 0 ? (calibrated - intercept) / slope : 0
        }
    }
}
