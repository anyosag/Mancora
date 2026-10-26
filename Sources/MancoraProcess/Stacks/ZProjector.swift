public import MancoraCore

/// Image ▸ Stacks ▸ Z Project: a port of ImageJ's `ij.plugin.ZProjector`.
public enum ZProjector {
    /// The projection types of ImageJ's "Projection type" choice.
    public enum Method: String, Sendable, Hashable, CaseIterable {
        /// "Average Intensity". 8- and 16-bit stacks give the rounded mean
        /// in the same type; 32-bit stacks give the mean of the non-NaN values.
        case average = "avg"
        /// "Max Intensity", in the input type (NaN ignored).
        case max
        /// "Min Intensity", in the input type (NaN ignored).
        case min
        /// "Sum Slices", always 32-bit; signed 16-bit data is summed calibrated.
        case sum
        /// "Standard Deviation" (sample, n−1), always 32-bit.
        case standardDeviation = "sd"
        /// "Median": 8-bit stays 8-bit, 16- and 32-bit give 32-bit.
        case median

        /// The title prefix ImageJ gives the result (`AVG_`, `MAX_`, …).
        public var titlePrefix: String {
            switch self {
            case .average: "AVG_"
            case .max: "MAX_"
            case .min: "MIN_"
            case .sum: "SUM_"
            case .standardDeviation: "STD_"
            case .median: "MED_"
            }
        }
    }

    /// Projects `image` along Z.
    ///
    /// A hyperstack (an image with two or more of channels, slices and
    /// frames) is projected per channel and per frame and keeps its channel
    /// LUTs, display ranges and composite mode; sum and standard deviation
    /// reset each channel's display range. A hyperstack without slices is
    /// projected along time, as ImageJ does. Any other stack (slices only,
    /// frames only, or channels only) is projected over all its planes into
    /// a single plane.
    ///
    /// RGB stacks are projected per color component; sum and standard
    /// deviation are then scaled to 0–255 (ImageJ's `doRGBProjection`).
    ///
    /// - Parameters:
    ///   - slices: The 0-based slices to project (ImageJ's start and stop
    ///     slice, minus one): Z slices of a hyperstack, frames of a
    ///     hyperstack without slices, or planes of any other stack. Clamped
    ///     to what exists; `nil` projects all.
    ///   - allTimeFrames: Project every frame of a hyperstack ("All time
    ///     frames"); otherwise only `frame` (0-based).
    public static func project(
        _ image: Hyperstack,
        method: Method,
        slices: ClosedRange<Int>? = nil,
        allTimeFrames: Bool = true,
        frame: Int = 0
    ) -> Hyperstack {
        let dims = image.dimensions
        let title = method.titlePrefix + image.title
        let calibrationFor = { (type: PixelType) in
            ImageJRules.calibration(image.calibration, from: image.pixelType, to: type)
        }

        guard ImageJRules.isHyperStack(dims) else {
            let range = clamp(slices, count: image.stack.count)
            let result = projection(image, method: method, planes: Array(range))
            var display = ChannelDisplay(lut: result.lut, displayRange: result.displayRange)
            // The menu command shows projections of channels-only composites in gray.
            if dims.channels > 1, image.pixelType != .rgb8 { display.lut = .grays }
            return ImageJRules.image(
                like: image, planes: [result.plane], labels: nil, dimensions: HyperstackDimensions(),
                channels: [display], calibration: calibrationFor(result.plane.pixelType), compositeMode: .color,
                title: title)
        }

        // doHyperStackProjection
        let channels = dims.channels
        var depth = dims.slices
        var frames = allTimeFrames ? Array(0..<dims.frames) : [Swift.min(Swift.max(frame, 0), dims.frames - 1)]
        if depth == 1 {
            depth = dims.frames
            frames = [0]
        }
        let range = clamp(slices, count: depth)
        var planes: [Plane] = []
        var first: (lut: LUT, displayRange: ClosedRange<Double>)?
        for f in frames {
            for c in 0..<channels {
                let indices = range.map { f * channels * depth + $0 * channels + c }
                let result = projection(image, method: method, planes: indices)
                if first == nil { first = (result.lut, result.displayRange) }
                planes.append(result.plane)
            }
        }
        var displays: [ChannelDisplay]
        if channels > 1 {
            // CompositeImage.copyLuts, then resetDisplayRanges for sum and SD.
            displays = image.channels
            if method == .sum || method == .standardDeviation {
                for c in 0..<channels { displays[c].displayRange = ImageJRules.resetRange(planes[c]) }
            }
        } else {
            // The stack takes the LUT and range of the first projection (ImageStack.addSlice).
            displays = [ChannelDisplay(lut: first?.lut ?? .grays, displayRange: first?.displayRange ?? 0...255)]
        }
        return ImageJRules.image(
            like: image, planes: planes, labels: nil,
            dimensions: HyperstackDimensions(channels: channels, frames: frames.count),
            channels: displays, calibration: calibrationFor(planes[0].pixelType),
            compositeMode: channels > 1 ? image.compositeMode : .color, title: title)
    }

    /// Projects the planes at the given stack indices, as `doProjection` does
    /// for one channel, with the first channel's LUT and display range as
    /// ImageJ's current processor.
    static func projection(_ image: Hyperstack, method: Method, planes indices: [Int]) -> Projection {
        let stack = image.stack
        let display = image.channels[0]
        return project(
            indices.map { stack[$0] }, method: method, lut: display.lut, displayRange: display.displayRange,
            calibration: image.calibration.valueFunction, signed16: ImageJRules.isSigned16(image.calibration))
    }

    // MARK: Projection of one ray of planes

    struct Projection {
        var plane: Plane
        var lut: LUT
        var displayRange: ClosedRange<Double>
    }

    static func clamp(_ range: ClosedRange<Int>?, count: Int) -> ClosedRange<Int> {
        guard let range else { return 0...(count - 1) }
        let lo = Swift.min(Swift.max(range.lowerBound, 0), count - 1)
        let hi = Swift.min(Swift.max(range.upperBound, lo), count - 1)
        return lo...hi
    }

    /// `ZProjector.doProjection` for a list of planes of one type.
    static func project(
        _ planes: [Plane],
        method: Method,
        lut: LUT,
        displayRange: ClosedRange<Double>,
        calibration: Calibration.ValueFunction?,
        signed16: Bool
    ) -> Projection {
        switch planes[0] {
        case .rgb8:
            let rgb = planes.map { plane -> [UInt32] in
                guard case .rgb8(let p) = plane else { preconditionFailure("mixed plane types") }
                return p
            }
            return Projection(plane: .rgb8(rgbProjection(rgb, method: method)), lut: .grays, displayRange: 0...255)
        case .gray32Float where method == .average:
            let out = Plane.gray32Float(averageIgnoringNaN(planes))
            return Projection(plane: out, lut: .grays, displayRange: ImageJRules.resetRange(out))
        default:
            break
        }
        if method == .median {
            let out = median(planes, calibration: calibration)
            switch planes[0] {
            case .gray8:
                // ip2.convertToByte(false), which resets the display range.
                guard case .gray32Float(let p) = out else { preconditionFailure() }
                return Projection(plane: .gray8(p.map(TypeConverter.floatToByte)), lut: lut, displayRange: 0...255)
            case .gray32Float:
                // The duplicated float processor keeps the stack's display range.
                return Projection(
                    plane: out, lut: lut, displayRange: ImageJRules.setRange(displayRange, on: planes[0]))
            default:
                return Projection(plane: out, lut: lut, displayRange: ImageJRules.resetRange(out))
            }
        }

        var acc = Accumulator(method: method, count: planes[0].count, slices: planes.count)
        for plane in planes { acc.add(plane) }
        var result = acc.finish()
        switch method {
        case .sum:
            if signed16 {
                let c = Float(-(Double(planes.count) * 32768.0))
                result = result.map { $0 + c }
            }
            let out = Plane.gray32Float(result)
            return Projection(plane: out, lut: .grays, displayRange: ImageJRules.resetRange(out))
        case .standardDeviation:
            let out = Plane.gray32Float(result)
            return Projection(plane: out, lut: .grays, displayRange: ImageJRules.resetRange(out))
        default:
            // makeOutputImage
            switch planes[0] {
            case .gray8:
                let out = Plane.gray8(result.map { UInt8(truncatingIfNeeded: ImageJRules.int($0 + 0.5)) })
                return Projection(plane: out, lut: lut, displayRange: 0...255)
            case .gray16:
                let out = Plane.gray16(result.map { UInt16(truncatingIfNeeded: ImageJRules.int($0 + 0.5)) })
                return Projection(plane: out, lut: lut, displayRange: ImageJRules.resetRange(out))
            default:
                let out = Plane.gray32Float(result)
                return Projection(plane: out, lut: .grays, displayRange: ImageJRules.resetRange(out))
            }
        }
    }

    /// ZProjector's ray functions (`AverageIntensity`, `MaxIntensity`,
    /// `MinIntensity`, `StandardDeviation`) over float accumulators.
    struct Accumulator {
        let method: Method
        let slices: Int
        var values: [Float]
        var sum: [Double] = []
        var sum2: [Double] = []

        init(method: Method, count: Int, slices: Int) {
            self.method = method
            self.slices = slices
            switch method {
            case .max: values = Array(repeating: -Float.greatestFiniteMagnitude, count: count)
            case .min: values = Array(repeating: Float.greatestFiniteMagnitude, count: count)
            default: values = Array(repeating: 0, count: count)
            }
            if method == .standardDeviation {
                sum = Array(repeating: 0, count: count)
                sum2 = sum
            }
        }

        mutating func add(_ plane: Plane) {
            switch plane {
            case .gray8(let p):
                if method == .standardDeviation {
                    for i in p.indices {
                        let v = Int(p[i])
                        sum[i] += Double(v)
                        sum2[i] += Double(v * v)
                    }
                } else {
                    addIntegers(p)
                }
            case .gray16(let p):
                if method == .standardDeviation {
                    for i in p.indices {
                        let v = Double(p[i])
                        sum[i] += v
                        sum2[i] += v * v
                    }
                } else {
                    addIntegers(p)
                }
            case .gray32Float(let p):
                switch method {
                case .standardDeviation:
                    for i in p.indices {
                        let v = Double(p[i])
                        sum[i] += v
                        sum2[i] += v * v
                    }
                case .max:
                    for i in p.indices where !p[i].isNaN && p[i] > values[i] { values[i] = p[i] }
                case .min:
                    for i in p.indices where p[i] < values[i] { values[i] = p[i] }
                default:
                    for i in p.indices { values[i] += p[i] }
                }
            case .rgb8:
                preconditionFailure("RGB planes are projected per component")
            }
        }

        private mutating func addIntegers<T: BinaryInteger>(_ p: [T]) {
            switch method {
            case .max:
                for i in p.indices {
                    let v = Float(p[i])
                    if v > values[i] { values[i] = v }
                }
            case .min:
                for i in p.indices {
                    let v = Float(p[i])
                    if v < values[i] { values[i] = v }
                }
            default:
                for i in p.indices { values[i] += Float(p[i]) }
            }
        }

        func finish() -> [Float] {
            switch method {
            case .average:
                let n = Float(slices)
                return values.map { $0 / n }
            case .standardDeviation:
                let n = Double(slices)
                return (0..<sum.count).map { i in
                    guard slices > 1 else { return 0 }
                    let variance = (n * sum2[i] - sum[i] * sum[i]) / n
                    return variance > 0 ? Float((variance / (n - 1)).squareRoot()) : 0
                }
            default:
                return values
            }
        }
    }

    /// `doAverageFloatProjection`: the mean of the non-NaN values (NaN where
    /// there are none), summed in double precision.
    static func averageIgnoringNaN(_ planes: [Plane]) -> [Float] {
        let n = planes[0].count
        var sum = [Double](repeating: 0, count: n)
        var count = [Int](repeating: 0, count: n)
        for plane in planes {
            guard case .gray32Float(let p) = plane else { preconditionFailure("mixed plane types") }
            for i in 0..<n where !p[i].isNaN {
                sum[i] += Double(p[i])
                count[i] += 1
            }
        }
        return (0..<n).map { Float(sum[$0] / Double(count[$0])) }
    }

    /// `doMedianProjection`: the median of each pixel's (calibrated) values as
    /// a float plane, sorted the way `Arrays.sort(float[])` sorts.
    static func median(_ planes: [Plane], calibration: Calibration.ValueFunction?) -> Plane {
        let n = planes[0].count
        let k = planes.count
        // getPixelValue: 8- and 16-bit values go through the calibration table.
        let columns: [[Float]] = planes.map { plane in
            switch plane {
            case .gray8(let p):
                guard let calibration else { return p.map { Float($0) } }
                return p.map { Float(calibration.apply(Double($0))) }
            case .gray16(let p):
                guard let calibration else { return p.map { Float($0) } }
                return p.map { Float(calibration.apply(Double($0))) }
            case .gray32Float(let p):
                return p
            case .rgb8:
                preconditionFailure("RGB planes are projected per component")
            }
        }
        var out = [Float](repeating: 0, count: n)
        var values = [Float](repeating: 0, count: k)
        let middle = k / 2
        for i in 0..<n {
            for j in 0..<k { values[j] = columns[j][i] }
            values.sort { javaFloatOrder($0) < javaFloatOrder($1) }
            out[i] = k % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        }
        return .gray32Float(out)
    }

    /// A key that orders floats as `Float.compare` does: −0 before +0, NaN last.
    @inline(__always)
    static func javaFloatOrder(_ v: Float) -> Int32 {
        if v.isNaN { return .max }
        let bits = Int32(bitPattern: v.bitPattern)
        return bits < 0 ? bits ^ Int32.max : bits
    }

    /// `doRGBProjection`: each color component projected as an 8-bit stack;
    /// sum and standard deviation are scaled by 255 over the largest
    /// component value, then each component maps its own range to 0–255
    /// (`RGBStackMerge.mergeStacks`).
    static func rgbProjection(_ planes: [[UInt32]], method: Method) -> [UInt32] {
        let n = planes[0].count
        var components: [[UInt8]] = []
        var floats: [[Float]] = []
        for shift in [UInt32(16), 8, 0] {
            let channel = planes.map { p in Plane.gray8(p.map { UInt8(truncatingIfNeeded: $0 >> shift) }) }
            let result = project(
                channel, method: method, lut: .grays, displayRange: 0...255, calibration: nil, signed16: false)
            switch result.plane {
            case .gray8(let p): components.append(p)
            case .gray32Float(let p): floats.append(p)
            default: preconditionFailure("unexpected projection type")
            }
        }
        if !floats.isEmpty {
            // ImageStatistics max: the largest finite value.
            var largest = -Double.greatestFiniteMagnitude
            for f in floats {
                for v in f where v.isFinite && Double(v) > largest { largest = Double(v) }
            }
            let scale = Float(255.0 / largest)
            components = floats.map { f in
                let scaled = f.map { $0 * scale }
                let r = ImageJRules.pixelRange(scaled)
                return ImageJRules.lutIndices(.gray32Float(scaled), ImageJRules.closed(r.min, r.max))
            }
        }
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = 0xFF00_0000 | UInt32(components[0][i]) << 16 | UInt32(components[1][i]) << 8 | UInt32(components[2][i])
        }
        return out
    }
}
