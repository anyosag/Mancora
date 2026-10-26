/// A region of interest (a selection), as ImageJ's `ij.gui.Roi` and its
/// subclasses `OvalRoi`, `PolygonRoi`, `Line`, `Arrow`, `PointRoi`,
/// `EllipseRoi` and `RotatedRectRoi` model it, with the properties ImageJ's
/// `.roi` files carry.
///
/// Coordinates are image pixels: (0, 0) is the top-left corner of the
/// top-left pixel, so pixel (x, y) is the square from (x, y) to (x+1, y+1).
/// Lines and points use pixel centers, as in ImageJ: a point at (2, 3) marks
/// pixel (2, 3).
///
/// Shapes ImageJ can't express with the cases below (composite `ShapeRoi`s,
/// text and image ROIs) decode as ``Shape-swift.enum/opaque(_:)``, which keeps
/// the original bytes so they survive a round trip.
public struct Roi: Hashable, Sendable {
    public var shape: Shape
    /// The ROI's name; `nil` if it has none (ImageJ then shows the file or
    /// ROI Manager name).
    public var name: String?
    /// Outline color as `0xAARRGGBB`, or `nil` for ImageJ's default.
    public var strokeColor: UInt32?
    /// Fill color as `0xAARRGGBB`, or `nil` to draw the ROI unfilled.
    public var fillColor: UInt32?
    /// Outline width in pixels, or 0 for ImageJ's default thin outline. For
    /// straight lines, polylines and freelines this is the line width.
    public var strokeWidth: Float
    /// Whether the outline gets wider when the image is zoomed (ImageJ's
    /// `getScaleStrokeWidth()`; `setStrokeWidth` turns it on and
    /// `setUnscalableStrokeWidth` off).
    public var scalesStrokeWidth: Bool
    /// The planes the ROI belongs to in an overlay. For point ROIs, see
    /// ``Points/positions``.
    public var position: Position
    /// ImageJ's ROI group, 0 (none) to 255.
    public var group: Int
    /// ImageJ's ROI properties, serialized as `key: value` lines
    /// (`Roi.getProperties()`); `nil` if there are none.
    public var properties: String?
    /// Label settings of the overlay the ROI was saved from (ImageJ stores
    /// them per ROI).
    public var labels: OverlayLabels

    /// - Parameter scalesStrokeWidth: defaults to `strokeWidth > 0`, as
    ///   ImageJ's `setStrokeWidth` does.
    public init(
        _ shape: Shape, name: String? = nil, strokeColor: UInt32? = nil, fillColor: UInt32? = nil,
        strokeWidth: Float = 0, scalesStrokeWidth: Bool? = nil, position: Position = .none, group: Int = 0,
        properties: String? = nil, labels: OverlayLabels = OverlayLabels()
    ) {
        self.shape = shape
        self.name = name
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.strokeWidth = strokeWidth
        self.scalesStrokeWidth = scalesStrokeWidth ?? (strokeWidth > 0)
        self.position = position
        self.group = group
        self.properties = properties
        self.labels = labels
    }
}

extension Roi {
    /// The geometry of a ROI.
    public enum Shape: Hashable, Sendable {
        /// A rectangle (ImageJ's `Roi`), with rounded corners of the given
        /// diameter when `cornerDiameter > 0`.
        case rectangle(Rect, cornerDiameter: Int = 0)
        /// An ellipse inscribed in a rectangle (ImageJ's `OvalRoi`).
        case oval(Rect)
        /// A polygon, freehand or traced outline, or a polyline, freeline or
        /// angle (ImageJ's `PolygonRoi`).
        case polygon(Polygon)
        /// A straight line, possibly with an arrow head (ImageJ's `Line` and
        /// `Arrow`).
        case line(Line)
        /// One or more points (ImageJ's `PointRoi`).
        case points(Points)
        /// A ROI kept as its original `.roi` bytes.
        case opaque(Opaque)
    }

    /// ImageJ's ROI type numbers (`Roi.getType()`).
    public enum Kind: Int, Hashable, Sendable {
        case rectangle = 0, oval, polygon, freehand, traced, line, polyline, freeline, angle, composite, point
    }

    /// ImageJ's type for this ROI (`Roi.getType()`). Text and image ROIs are
    /// rectangles there.
    public var kind: Kind {
        switch shape {
        case .rectangle: .rectangle
        case .oval: .oval
        case .polygon(let p): p.kind.roiKind
        case .line: .line
        case .points: .point
        case .opaque(let o): o.kind == .composite ? .composite : .rectangle
        }
    }

    /// Whether the ROI encloses an area (ImageJ's `Roi.isArea()`).
    public var isArea: Bool {
        switch shape {
        case .rectangle, .oval: true
        case .polygon(let p): !p.kind.isLine
        case .line, .points: false
        case .opaque(let o): o.kind == .composite
        }
    }

    /// A rectangle with whole-pixel or subpixel corners: ImageJ's
    /// `new Roi(int, int, int, int)` versus `new Roi(double, double, double, double)`.
    ///
    /// ImageJ keeps at least one pixel: a width or height below 1 is treated
    /// as 1. Subpixel rectangles and ovals still select whole pixels: those of
    /// the integer rectangle `((int)x, (int)y, ceil(width), ceil(height))`.
    public enum Rect: Hashable, Sendable {
        case integer(x: Int32, y: Int32, width: Int32, height: Int32)
        case subpixel(x: Double, y: Double, width: Double, height: Double)
    }

    /// A vertex with whole-pixel coordinates (ImageJ's `java.awt.Polygon`).
    public struct IntPoint: Hashable, Sendable {
        public var x: Int32
        public var y: Int32
        public init(x: Int32, y: Int32) {
            self.x = x
            self.y = y
        }
    }

    /// A vertex with subpixel coordinates (ImageJ's `FloatPolygon`).
    public struct FloatPoint: Hashable, Sendable {
        public var x: Float
        public var y: Float
        public init(x: Float, y: Float) {
            self.x = x
            self.y = y
        }
    }

    /// Vertex coordinates, in whole pixels or subpixel (ImageJ's
    /// `subPixelResolution()`).
    ///
    /// Subpixel vertices are the absolute coordinates ImageJ's `PolygonRoi`
    /// and `PointRoi` constructors take. ImageJ stores them relative to their
    /// minimum in 32-bit floats, so the coordinates it reports and saves
    /// (`getFloatPolygon()`) can differ from these in the last bit; Mancora
    /// reproduces that when it masks or encodes.
    public enum Vertices: Hashable, Sendable {
        case integer([IntPoint])
        case subpixel([FloatPoint])

        public var count: Int {
            switch self {
            case .integer(let p): p.count
            case .subpixel(let p): p.count
            }
        }

        /// The vertices as 32-bit floats (integers convert like Java's `(float)`).
        public var floatPoints: [FloatPoint] {
            switch self {
            case .integer(let p): p.map { FloatPoint(x: Float($0.x), y: Float($0.y)) }
            case .subpixel(let p): p
            }
        }
    }

    /// A `PolygonRoi`: an area (polygon, freehand, traced) or an open line
    /// (polyline, freeline, angle).
    public struct Polygon: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case polygon, freehand, traced, polyline, freeline, angle

            /// Polylines, freelines and angles are lines; the others are areas.
            public var isLine: Bool { self == .polyline || self == .freeline || self == .angle }

            var roiKind: Roi.Kind {
                switch self {
                case .polygon: .polygon
                case .freehand: .freehand
                case .traced: .traced
                case .polyline: .polyline
                case .freeline: .freeline
                case .angle: .angle
                }
            }
        }

        /// ImageJ's polygons that are defined by parameters rather than their
        /// vertices.
        public enum Parametric: Hashable, Sendable {
            /// `EllipseRoi` (a freehand ROI of 72 vertices). Its major axis
            /// runs from vertex `count / 2` to vertex 0.
            case ellipse(aspectRatio: Double)
            /// `RotatedRectRoi` (a 4-vertex polygon) of the given width. Its
            /// axis joins the midpoints of edges 3→0 and 1→2.
            case rotatedRectangle(width: Double)
        }

        public var kind: Kind
        public var vertices: Vertices
        /// Whether ImageJ shows the outline as a spline through the vertices
        /// (Edit ▸ Selection ▸ Fit Spline).
        public var isSplineFit: Bool
        public var parametric: Parametric?

        public init(_ kind: Kind, _ vertices: Vertices, splineFit: Bool = false, parametric: Parametric? = nil) {
            self.kind = kind
            self.vertices = vertices
            self.isSplineFit = splineFit
            self.parametric = parametric
        }

        /// A rotated rectangle whose axis runs from (x1, y1) to (x2, y2), with
        /// the vertices ImageJ's `RotatedRectRoi` computes.
        public static func rotatedRectangle(x1: Double, y1: Double, x2: Double, y2: Double, width: Double) -> Polygon {
            let length = ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot()
            let wsa = 0.5 * width * (y2 - y1) / length
            let wca = -0.5 * width * (x2 - x1) / length
            let points = [
                FloatPoint(x: Float(x1 + wsa), y: Float(y1 + wca)),
                FloatPoint(x: Float(x2 + wsa), y: Float(y2 + wca)),
                FloatPoint(x: Float(x2 - wsa), y: Float(y2 - wca)),
                FloatPoint(x: Float(x1 - wsa), y: Float(y1 - wca)),
            ]
            return Polygon(.polygon, .subpixel(points), parametric: .rotatedRectangle(width: width))
        }
    }

    /// A straight line between pixel centers (ImageJ's `Line`); its width is
    /// ``Roi/strokeWidth``.
    public struct Line: Hashable, Sendable {
        public var x1: Double
        public var y1: Double
        public var x2: Double
        public var y2: Double
        /// The arrow head, for ImageJ's `Arrow`.
        public var arrow: Arrow?

        public init(x1: Double, y1: Double, x2: Double, y2: Double, arrow: Arrow? = nil) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
            self.arrow = arrow
        }
    }

    /// ImageJ's `Arrow` settings.
    public struct Arrow: Hashable, Sendable {
        public enum Style: Int, Hashable, Sendable {
            case filled = 0, notched, open, headless, bar
        }

        public var style: Style
        /// Head size, 0–30 in ImageJ's dialog.
        public var headSize: Double
        public var doubleHeaded: Bool
        public var outline: Bool

        public init(style: Style = .filled, headSize: Double = 10, doubleHeaded: Bool = false, outline: Bool = false) {
            self.style = style
            self.headSize = headSize
            self.doubleHeaded = doubleHeaded
            self.outline = outline
        }
    }

    /// A single or multi-point selection (ImageJ's `PointRoi`).
    public struct Points: Hashable, Sendable {
        public enum PointType: Int, Hashable, Sendable {
            case hybrid = 0, cross, dot, circle
        }

        public var vertices: Vertices
        public var pointType: PointType
        /// ImageJ's size index: 0 (Tiny) to 6 (XXXL); 1 is Small.
        public var size: Int
        public var showLabels: Bool
        public var promptBeforeDeleting: Bool
        /// Each point's counter (category, 0–255), or `nil` if none was ever
        /// set, as in ImageJ (where the saved counters are then all zero).
        public var counters: [UInt8]?
        /// Each point's stack position (0 = all), or `nil` for none.
        ///
        /// ImageJ keeps point positions per point. ``Roi/position`` set to
        /// `.stack(n)` on a point ROI assigns `n` to every point when encoding,
        /// as `PointRoi.setPosition(n)` does.
        public var positions: [Int32]?

        public init(
            _ vertices: Vertices, pointType: PointType = .hybrid, size: Int = 1, showLabels: Bool = false,
            promptBeforeDeleting: Bool = false, counters: [UInt8]? = nil, positions: [Int32]? = nil
        ) {
            self.vertices = vertices
            self.pointType = pointType
            self.size = size
            self.showLabels = showLabels
            self.promptBeforeDeleting = promptBeforeDeleting
            self.counters = counters
            self.positions = positions
        }
    }

    /// A ROI Mancora doesn't model yet, kept as the `.roi` bytes it was read
    /// from. The encoder writes `bytes` unchanged, so edits to the ROI's
    /// common properties are not saved for these.
    public struct Opaque: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// ImageJ's `ShapeRoi` (a composite of paths).
            case composite
            /// ImageJ's `TextRoi`.
            case text
            /// ImageJ's `ImageRoi`.
            case image
        }

        public var kind: Kind
        public var bytes: [UInt8]
        /// The bounding rectangle in the file's header.
        public var bounds: RoiBounds

        public init(kind: Kind, bytes: [UInt8], bounds: RoiBounds) {
            self.kind = kind
            self.bytes = bytes
            self.bounds = bounds
        }
    }

    /// Which planes of a stack or hyperstack the ROI belongs to (all 1-based).
    public enum Position: Hashable, Sendable {
        /// All planes.
        case none
        /// One image of a stack (ImageJ's `setPosition(n)`).
        case stack(Int)
        /// A hyperstack position, where 0 means all channels, slices or
        /// frames (ImageJ's `setPosition(c, z, t)`).
        case hyperstack(channel: Int, slice: Int, frame: Int)
    }

    /// The label settings of ImageJ's prototype overlay
    /// (`Roi.getPrototypeOverlay()`).
    public struct OverlayLabels: Hashable, Sendable {
        /// ImageJ's label font: SansSerif of this size, plain or bold.
        public struct Font: Hashable, Sendable {
            public var size: Int
            public var bold: Bool
            public init(size: Int, bold: Bool = false) {
                self.size = size
                self.bold = bold
            }
        }

        public var drawLabels: Bool
        public var drawNames: Bool
        public var drawBackgrounds: Bool
        /// Label color as `0xAARRGGBB`; ImageJ always reads it back opaque.
        public var color: UInt32?
        public var font: Font?
        /// Whether labels scale with the zoom.
        public var scalable: Bool

        public init(
            drawLabels: Bool = false, drawNames: Bool = false, drawBackgrounds: Bool = false, color: UInt32? = nil,
            font: Font? = nil, scalable: Bool = false
        ) {
            self.drawLabels = drawLabels
            self.drawNames = drawNames
            self.drawBackgrounds = drawBackgrounds
            self.color = color
            self.font = font
            self.scalable = scalable
        }
    }
}

/// An integer rectangle in image pixels: a ROI's bounds (ImageJ's
/// `Roi.getBounds()`) or the placement of a ``RoiMask``.
public struct RoiBounds: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
