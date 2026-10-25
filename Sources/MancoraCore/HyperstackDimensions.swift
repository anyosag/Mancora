/// Channel, Z-slice and time-frame counts of a hyperstack.
///
/// Indices here are 0-based. The macro language and the UI show them
/// 1-based, as ImageJ does; convert only at that boundary.
public struct HyperstackDimensions: Sendable, Hashable, CustomStringConvertible {
    public var channels: Int
    public var slices: Int
    public var frames: Int

    public init(channels: Int = 1, slices: Int = 1, frames: Int = 1) {
        self.channels = channels
        self.slices = slices
        self.frames = frames
    }

    /// Total number of planes, or `nil` if a count is not positive or the
    /// product overflows.
    public var planeCount: Int? {
        guard channels > 0, slices > 0, frames > 0 else { return nil }
        let (cz, o1) = channels.multipliedReportingOverflow(by: slices)
        let (czt, o2) = cz.multipliedReportingOverflow(by: frames)
        return o1 || o2 ? nil : czt
    }

    /// Plane index for a (channel, slice, frame) position, channel fastest.
    public func planeIndex(channel: Int, slice: Int, frame: Int) -> Int {
        precondition((0..<channels).contains(channel), "channel \(channel) out of range")
        precondition((0..<slices).contains(slice), "slice \(slice) out of range")
        precondition((0..<frames).contains(frame), "frame \(frame) out of range")
        return (frame * slices + slice) * channels + channel
    }

    /// The (channel, slice, frame) position of a plane index.
    public func position(ofPlane index: Int) -> (channel: Int, slice: Int, frame: Int) {
        precondition(index >= 0 && index < (planeCount ?? 0), "plane \(index) out of range")
        return (index % channels, (index / channels) % slices, index / (channels * slices))
    }

    public var description: String { "c=\(channels) z=\(slices) t=\(frames)" }
}
