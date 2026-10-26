/// How a multi-channel image is shown (ImageJ's `CompositeImage` modes).
public enum CompositeMode: String, Sendable, Hashable {
    /// All visible channels are blended additively.
    case composite
    /// One channel at a time, through its own LUT.
    case color
    /// One channel at a time, in gray.
    case grayscale
}

/// Display settings for one channel.
public struct ChannelDisplay: Sendable, Hashable {
    public var lut: LUT
    /// Values at or below `displayRange.lowerBound` map to LUT entry 0; at or
    /// above `upperBound`, to entry 255.
    public var displayRange: ClosedRange<Double>
    public var isVisible: Bool

    public init(lut: LUT, displayRange: ClosedRange<Double>, isVisible: Bool = true) {
        self.lut = lut
        self.displayRange = displayRange
        self.isVisible = isVisible
    }
}

/// An image with its stack, hyperstack layout, calibration and display
/// settings: Mancora's counterpart of ImageJ's `ImagePlus`.
///
/// Every image is a hyperstack; a single 2D image has one channel, slice and
/// frame. It's a value type: copies share pixel storage until one is written.
public struct Hyperstack: Sendable, Equatable {
    public var title: String
    public private(set) var stack: ImageStack
    public private(set) var dimensions: HyperstackDimensions
    public var calibration: Calibration
    /// One entry per channel.
    public private(set) var channels: [ChannelDisplay]
    public var compositeMode: CompositeMode
    /// ImageJ's "Info" property, shown by Image ▸ Show Info and saved in TIFFs.
    public var info: String?
    /// Image properties (ImageJ's `ImagePlus.setProp` keys and values),
    /// saved in TIFFs.
    public var properties: [String: String]
    /// The selection, as ImageJ `.roi` bytes (`RoiEncoder`), carried
    /// through files until Mancora decodes ROIs itself.
    public var encodedROI: [UInt8]?
    /// The overlay, one ImageJ `.roi` record per element.
    public var encodedOverlay: [[UInt8]] = []

    public init(
        title: String,
        stack: ImageStack,
        dimensions: HyperstackDimensions? = nil,
        calibration: Calibration = Calibration(),
        channels: [ChannelDisplay]? = nil,
        compositeMode: CompositeMode = .color,
        info: String? = nil,
        properties: [String: String] = [:]
    ) throws(ImageModelError) {
        let dims = dimensions ?? HyperstackDimensions(slices: stack.count)
        guard dims.planeCount == stack.count else {
            throw .dimensionMismatch(planes: stack.count, dimensions: dims)
        }
        let displays = channels ?? Self.defaultChannels(for: stack, dimensions: dims)
        guard displays.count == dims.channels else {
            throw .channelCountMismatch(expected: dims.channels, actual: displays.count)
        }
        self.title = title
        self.stack = stack
        self.dimensions = dims
        self.calibration = calibration
        self.channels = displays
        self.compositeMode = compositeMode
        self.info = info
        self.properties = properties
    }

    public var width: Int { stack.width }
    public var height: Int { stack.height }
    public var pixelType: PixelType { stack.pixelType }

    public func plane(channel: Int = 0, slice: Int = 0, frame: Int = 0) -> Plane {
        stack[dimensions.planeIndex(channel: channel, slice: slice, frame: frame)]
    }

    public mutating func setDisplay(_ display: ChannelDisplay, forChannel channel: Int) {
        channels[channel] = display
    }

    /// Colors ImageJ assigns to channels 1–7 of a new composite image.
    public static let defaultChannelLUTs: [LUT] = [.red, .green, .blue, .grays, .cyan, .magenta, .yellow]

    /// Gray for single-channel images, ImageJ's channel colors otherwise; the
    /// display range covers each channel's first plane (ImageJ's
    /// `resetMinAndMax`), or `0...255` for 8-bit and RGB data.
    public static func defaultChannels(for stack: ImageStack, dimensions: HyperstackDimensions) -> [ChannelDisplay] {
        (0..<max(dimensions.channels, 1)).map { c in
            let lut = dimensions.channels == 1 ? LUT.grays : defaultChannelLUTs[c % defaultChannelLUTs.count]
            let range: ClosedRange<Double>
            switch stack.pixelType {
            case .gray8, .rgb8:
                range = 0...255
            case .gray16, .gray32Float:
                range = c < stack.count ? (stack[c].valueRange() ?? 0...0) : 0...0
            }
            return ChannelDisplay(lut: lut, displayRange: range)
        }
    }
}
