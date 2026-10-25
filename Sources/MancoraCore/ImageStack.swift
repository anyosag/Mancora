/// Errors raised when assembling images from parts that don't fit together.
public enum ImageModelError: Error, Equatable, Sendable {
    case invalidSize(width: Int, height: Int)
    case emptyStack
    case planeSizeMismatch(index: Int, expected: Int, actual: Int)
    case pixelTypeMismatch(index: Int, expected: PixelType, actual: PixelType)
    case dimensionMismatch(planes: Int, dimensions: HyperstackDimensions)
    case channelCountMismatch(expected: Int, actual: Int)
}

/// An ordered list of same-sized, same-typed planes.
///
/// Planes are ordered as ImageJ orders hyperstacks: channel varies fastest,
/// then Z slice, then time frame. See ``HyperstackDimensions``.
public struct ImageStack: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixelType: PixelType
    public private(set) var planes: [Plane]
    /// Optional per-plane labels (ImageJ "slice labels").
    public var labels: [String?]

    public init(width: Int, height: Int, planes: [Plane], labels: [String?]? = nil) throws(ImageModelError) {
        guard width > 0, height > 0 else { throw .invalidSize(width: width, height: height) }
        guard let first = planes.first else { throw .emptyStack }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { throw .invalidSize(width: width, height: height) }
        for (i, plane) in planes.enumerated() {
            guard plane.count == pixels else {
                throw .planeSizeMismatch(index: i, expected: pixels, actual: plane.count)
            }
            guard plane.pixelType == first.pixelType else {
                throw .pixelTypeMismatch(index: i, expected: first.pixelType, actual: plane.pixelType)
            }
        }
        self.width = width
        self.height = height
        self.pixelType = first.pixelType
        self.planes = planes
        self.labels = labels ?? Array(repeating: nil, count: planes.count)
    }

    public var count: Int { planes.count }
    public var pixelsPerPlane: Int { width * height }

    public subscript(index: Int) -> Plane { planes[index] }

    /// Replaces one plane; it must match the stack's size and type.
    public mutating func setPlane(_ plane: Plane, at index: Int) throws(ImageModelError) {
        guard plane.count == pixelsPerPlane else {
            throw .planeSizeMismatch(index: index, expected: pixelsPerPlane, actual: plane.count)
        }
        guard plane.pixelType == pixelType else {
            throw .pixelTypeMismatch(index: index, expected: pixelType, actual: plane.pixelType)
        }
        planes[index] = plane
    }
}
