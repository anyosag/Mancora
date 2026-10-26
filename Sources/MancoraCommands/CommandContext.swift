public import MancoraCore
import MancoraIO
public import MancoraProcess

/// An image open in a session, with what ImageJ keeps alongside it.
public struct OpenImage: Sendable {
    /// ImageJ's image ID: negative, starting at -1, never reused.
    public let id: Int
    public var image: Hyperstack
    /// The position shown (0-based).
    public var channel = 0
    public var slice = 0
    public var frame = 0
    /// The threshold set on the image (ImageJ's `getMinThreshold()` and
    /// `getMaxThreshold()`, in raw values), or `nil`.
    public var threshold: ThresholdLevels?

    public var title: String { image.title }

    /// The selection, kept in the image as ImageJ `.roi` bytes (which is
    /// how TIFFs carry it); `nil` when there's none or it can't be read.
    public var roi: Roi? {
        get { image.encodedROI.flatMap { try? RoiCodec.decode($0) } }
        set { image.encodedROI = newValue.map(RoiCodec.encode) }
    }

    /// The plane at the current position.
    public var currentPlane: Plane { image.plane(channel: channel, slice: slice, frame: frame) }
}

/// Options that change how commands behave, from ImageJ's Edit ▸ Options.
public struct CommandSettings: Sendable, Hashable {
    /// Process ▸ Binary ▸ Options ▸ Black background (on by default, as in
    /// ImageJ's default preferences).
    public var blackBackground = true
    /// Process ▸ Binary ▸ Options: iterations and count for erode and dilate, and Pad edges when eroding.
    public var binaryIterations = 1
    public var binaryCount = 1
    public var padEdges = false
    /// Edit ▸ Options ▸ Conversions ▸ Scale when converting.
    public var scaleConversions = true
    /// Analyze ▸ Set Measurements ▸ Decimal places.
    public var decimalPlaces = 3
    /// Analyze ▸ Set Measurements: what Measure records.
    public var measurements = Measurements.defaults

    public init() {}
}

/// The state commands work on: ImageJ's open images (WindowManager), the
/// current image, the results table and the log.
public struct CommandContext: Sendable {
    public private(set) var images: [OpenImage] = []
    public private(set) var currentID: Int?
    public var results = ResultsTable()
    public var log: [String] = []
    public var settings = CommandSettings()
    private var nextID = -1

    public init() {}

    public var current: OpenImage? {
        currentID.flatMap { id in images.first { $0.id == id } }
    }

    /// Adds an image and makes it current, as showing a new image does.
    @discardableResult
    public mutating func add(_ image: Hyperstack) -> Int {
        let id = nextID
        nextID -= 1
        images.append(OpenImage(id: id, image: image))
        currentID = id
        return id
    }

    public mutating func select(id: Int) throws(CommandError) {
        guard images.contains(where: { $0.id == id }) else { throw .noSuchImage("\(id)") }
        currentID = id
    }

    /// `selectWindow(title)`: the most recent image with that title.
    public mutating func select(title: String) throws(CommandError) {
        guard let match = images.last(where: { $0.title == title }) else { throw .noSuchImage(title) }
        currentID = match.id
    }

    /// Closes an image; the most recently opened remaining one becomes current.
    public mutating func close(id: Int) {
        images.removeAll { $0.id == id }
        if currentID == id { currentID = images.last?.id }
    }

    public mutating func closeAll() {
        images = []
        currentID = nil
    }

    /// Changes the current image, or throws ``CommandError/noImage(_:)`` for `command`.
    public mutating func withCurrent<T>(
        _ command: String, _ body: (inout OpenImage) throws(CommandError) -> T
    ) throws(CommandError) -> T {
        guard let id = currentID, let index = images.firstIndex(where: { $0.id == id }) else {
            throw .noImage(command)
        }
        return try body(&images[index])
    }
}

public enum CommandError: Error, Equatable, Sendable, CustomStringConvertible {
    /// ImageJ's "There are no images open".
    case noImage(String)
    case noSuchImage(String)
    /// ImageJ's `Unrecognized command: "…"`.
    case unrecognized(String)
    /// Known to ImageJ but not (yet) native, and no fallback handled it.
    case notNative(String)
    case invalidOption(command: String, detail: String)
    case failed(command: String, detail: String)

    public var description: String {
        switch self {
        case .noImage(let command): "\"\(command)\" requires an image, and there are no images open."
        case .noSuchImage(let name): "No image named \"\(name)\" is open."
        case .unrecognized(let command): "Unrecognized command: \"\(command)\""
        case .notNative(let command): "\"\(command)\" isn't available without the Java bridge."
        case .invalidOption(let command, let detail): "\(command): \(detail)"
        case .failed(let command, let detail): "\(command) failed: \(detail)"
        }
    }
}
