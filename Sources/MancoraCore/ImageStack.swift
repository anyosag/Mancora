/// Errors raised when assembling images from parts that don't fit together.
public enum ImageModelError: Error, Equatable, Sendable {
    case invalidSize(width: Int, height: Int)
    case emptyStack
    case planeSizeMismatch(index: Int, expected: Int, actual: Int)
    case pixelTypeMismatch(index: Int, expected: PixelType, actual: PixelType)
    case dimensionMismatch(planes: Int, dimensions: HyperstackDimensions)
    case channelCountMismatch(expected: Int, actual: Int)
}

/// Supplies the planes of a virtual stack on demand, like ImageJ's
/// `VirtualStack`: a file reader that decodes each plane when it's shown.
///
/// Implementations must be safe to call from several threads.
public protocol PlaneSource: Sendable {
    var width: Int { get }
    var height: Int { get }
    var pixelType: PixelType { get }
    var count: Int { get }
    /// Reads plane `index` (0-based); the result must match the size and type above.
    func plane(at index: Int) throws -> Plane
}

/// An ordered list of same-sized, same-typed planes, held in memory or read
/// on demand from a ``PlaneSource`` (a virtual stack).
///
/// Planes are ordered as ImageJ orders hyperstacks: channel varies fastest,
/// then Z slice, then time frame. See ``HyperstackDimensions``.
public struct ImageStack: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixelType: PixelType
    private var storage: Storage
    /// Optional per-plane labels (ImageJ "slice labels").
    public var labels: [String?]

    private enum Storage: Sendable {
        case memory([Plane])
        /// Planes come from the source unless they've been replaced.
        case virtual(any PlaneSource, edits: [Int: Plane])
    }

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
        self.storage = .memory(planes)
        self.labels = labels ?? Array(repeating: nil, count: planes.count)
    }

    /// A virtual stack whose planes are read from `source` when first needed.
    public init(source: any PlaneSource, labels: [String?]? = nil) throws(ImageModelError) {
        guard source.width > 0, source.height > 0, !source.width.multipliedReportingOverflow(by: source.height).overflow
        else { throw .invalidSize(width: source.width, height: source.height) }
        guard source.count > 0 else { throw .emptyStack }
        self.width = source.width
        self.height = source.height
        self.pixelType = source.pixelType
        self.storage = .virtual(source, edits: [:])
        self.labels = labels ?? Array(repeating: nil, count: source.count)
    }

    public var count: Int {
        switch storage {
        case .memory(let planes): planes.count
        case .virtual(let source, _): source.count
        }
    }

    public var pixelsPerPlane: Int { width * height }

    /// Whether planes are read on demand rather than held in memory.
    public var isVirtual: Bool {
        if case .virtual = storage { return true }
        return false
    }

    /// Where a virtual stack's planes come from; `nil` for an in-memory stack.
    public var source: (any PlaneSource)? {
        if case .virtual(let source, _) = storage { return source }
        return nil
    }

    /// Plane `index`. A virtual plane that can't be read comes back blank,
    /// as in ImageJ; use ``loadPlane(at:)`` to see the error.
    public subscript(index: Int) -> Plane {
        (try? loadPlane(at: index)) ?? Plane(zeroed: pixelType, count: pixelsPerPlane)
    }

    /// Plane `index`, reading it from the source of a virtual stack.
    public func loadPlane(at index: Int) throws -> Plane {
        switch storage {
        case .memory(let planes):
            return planes[index]
        case .virtual(let source, let edits):
            if let edited = edits[index] { return edited }
            let plane = try source.plane(at: index)
            guard plane.count == pixelsPerPlane, plane.pixelType == pixelType else {
                throw ImageModelError.planeSizeMismatch(index: index, expected: pixelsPerPlane, actual: plane.count)
            }
            return plane
        }
    }

    /// Every plane. For a virtual stack this reads them all; prefer the subscript.
    public var planes: [Plane] {
        switch storage {
        case .memory(let planes): planes
        case .virtual: (0..<count).map { self[$0] }
        }
    }

    /// Replaces one plane; it must match the stack's size and type. In a
    /// virtual stack the replacement is kept in memory.
    public mutating func setPlane(_ plane: Plane, at index: Int) throws(ImageModelError) {
        guard plane.count == pixelsPerPlane else {
            throw .planeSizeMismatch(index: index, expected: pixelsPerPlane, actual: plane.count)
        }
        guard plane.pixelType == pixelType else {
            throw .pixelTypeMismatch(index: index, expected: pixelType, actual: plane.pixelType)
        }
        switch storage {
        case .memory(var planes):
            storage = .memory([])  // release the reference so the write below doesn't copy
            planes[index] = plane
            storage = .memory(planes)
        case .virtual(let source, var edits):
            edits[index] = plane
            storage = .virtual(source, edits: edits)
        }
    }

    /// Stacks are equal when their sizes, types, labels and pixels are (a
    /// virtual stack is read in full to compare).
    public static func == (a: ImageStack, b: ImageStack) -> Bool {
        guard a.width == b.width, a.height == b.height, a.pixelType == b.pixelType, a.count == b.count,
            a.labels == b.labels
        else { return false }
        if case .memory(let x) = a.storage, case .memory(let y) = b.storage { return x == y }
        return (0..<a.count).allSatisfy { a[$0] == b[$0] }
    }
}
