public import MancoraCore

/// Process ▸ Filters ▸ Gaussian Blur 3D: a port of ImageJ 1.54p's
/// `ij.plugin.GaussianBlur3D.blur`.
public enum GaussianBlur3D {
    /// Blurs every plane in x and y (as Gaussian Blur does, rounding integer
    /// data), then each volume along z: a stack as one volume, a hyperstack
    /// per channel and frame along its slices (or, with one slice, along its
    /// frames). The z pass reads the voxels as floats and writes them back
    /// as `ImageStack.setVoxels` does: clipped and rounded for 8- and
    /// 16-bit data, truncated without clipping for each RGB channel.
    ///
    /// - Parameter isHyperstack: ImageJ's `isHyperStack()`: an image opened
    ///   as a hyperstack with more than three dimensions.
    public static func blur(
        _ image: Hyperstack, sigmaX: Double, sigmaY: Double, sigmaZ: Double, isHyperstack: Bool
    ) throws(ImageModelError) -> Hyperstack {
        var out = image
        let type = image.pixelType
        let accuracy = type == .gray8 || type == .rgb8 ? 0.002 : 0.0002
        if sigmaX > 0 || sigmaY > 0 {
            for index in 0..<image.stack.count {
                try out.setPlane(
                    image.stack[index].gaussianBlurred(sigmaX: sigmaX, sigmaY: sigmaY, accuracy: accuracy, width: image.width),
                    at: index)
            }
        }
        guard sigmaZ > 0 else { return out }
        let dims = image.dimensions
        var volumes: [[Int]] = []
        if isHyperstack {
            for c in 0..<dims.channels {
                if dims.slices == 1 {
                    volumes.append((0..<dims.frames).map { dims.planeIndex(channel: c, slice: 0, frame: $0) })
                } else {
                    for t in 0..<dims.frames {
                        volumes.append((0..<dims.slices).map { dims.planeIndex(channel: c, slice: $0, frame: t) })
                    }
                }
            }
        } else {
            volumes = [Array(0..<image.stack.count)]
        }
        for volume in volumes {
            let planes = try blurZ(volume.map { out.stack[$0] }, width: image.width, sigma: sigmaZ, accuracy: accuracy)
            for (index, plane) in zip(volume, planes) { try out.setPlane(plane, at: index) }
        }
        return out
    }

    /// `blurZ`: `blur1Direction` along z for every (x, y) and channel.
    static func blurZ(_ planes: [Plane], width: Int, sigma: Double, accuracy: Double) throws(ImageModelError) -> [Plane] {
        let depth = planes.count
        guard depth > 0 else { return planes }
        let size = planes[0].count
        let channelCount = planes[0].pixelType == .rgb8 ? 3 : 1
        let split = planes.map(FloatChannels.split)
        var result = split
        for c in 0..<channelCount {
            // One line of `depth` voxels per pixel, pixel by pixel.
            var lines = [Float](repeating: 0, count: size * depth)
            for z in 0..<depth {
                let channel = split[z][c]
                for i in 0..<size { lines[i * depth + z] = channel[i] }
            }
            lines.withUnsafeMutableBufferPointer { pixels in
                GaussianBlur.blurLines(
                    pixels, length: depth, lines: 0..<size, write: 0..<depth, sigma: sigma, accuracy: accuracy)
            }
            for z in 0..<depth {
                for i in 0..<size { result[z][c][i] = lines[i * depth + z] }
            }
        }
        return planes.indices.map { z in
            switch planes[z] {
            case .gray8:
                return .gray8(result[z][0].map { v in UInt8(truncatingIfNeeded: JavaNumerics.int32(min(max(v, 0), 255) + 0.5)) })
            case .gray16:
                return .gray16(result[z][0].map { v in UInt16(truncatingIfNeeded: JavaNumerics.int32(min(max(v, 0), 65535) + 0.5)) })
            case .gray32Float:
                return .gray32Float(result[z][0])
            case .rgb8(let original):
                return .rgb8(original.indices.map { i in
                    // (int)voxel & 0xff, per channel.
                    let r = UInt32(bitPattern: JavaNumerics.int32(result[z][0][i])) & 0xFF
                    let g = UInt32(bitPattern: JavaNumerics.int32(result[z][1][i])) & 0xFF
                    let b = UInt32(bitPattern: JavaNumerics.int32(result[z][2][i])) & 0xFF
                    return (original[i] & 0xFF00_0000) | r << 16 | g << 8 | b
                })
            }
        }
    }
}
