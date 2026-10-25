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
}
