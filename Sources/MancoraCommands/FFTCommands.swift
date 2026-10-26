import MancoraCore
import MancoraProcess

/// Process ▸ FFT (`ij.plugin.FFT`): FFT, Inverse FFT, Redisplay Power
/// Spectrum and Swap Quadrants. The transform stays with the "FFT of"
/// image (ImageJ's "FHT" property) for the inverse.
enum FFTCommands {
    static var all: [CommandDefinition] { [fft, inverseFFT, redisplayPowerSpectrum, swapQuadrants] }

    /// `FFT("fft")`: the current plane (its selection's bounds, an RGB
    /// image's brightness) shown as "FFT of <title>", its power spectrum.
    /// On an "FFT of" image it's the inverse transform.
    static let fft = CommandDefinition("FFT", menu: "Process>FFT") { context, _ in
        let name = "FFT"
        guard let open = context.current else { throw CommandError.noImage(name) }
        if open.image.frequencyDomain != nil {
            try inverse(name, &context)
            return
        }
        let image = open.image
        if image.pixelType != .gray32Float, image.pixelType != .rgb8, image.calibration.valueFunction != nil {
            throw CommandError.notNative(name)  // ImageJ transforms the calibrated values
        }
        var plane = open.currentPlane
        var (width, height) = (image.width, image.height)
        if image.encodedROI != nil {
            // ip.crop(): an area selection's bounds, clipped to the image.
            guard let roi = open.roi else { throw CommandError.notNative(name) }
            if roi.isArea {
                let b = roi.bounds
                let x0 = max(b.x, 0), y0 = max(b.y, 0)
                let x1 = min(b.x + b.width, width), y1 = min(b.y + b.height, height)
                guard x1 > x0, y1 > y0 else { throw CommandError.notNative(name) }
                plane = crop(plane, planeWidth: width, x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                (width, height) = (x1 - x0, y1 - y0)
            }
        }
        let lut = image.channels[open.channel].lut
        guard let forward = FFT.forward(plane, width: width, height: height, lut: lut) else {
            var size = 2
            while size < max(width, height) { size *= 2 }
            throw CommandError.failed(command: name, detail: "Padded image is too large (\(size)x\(size))")
        }
        let domain = forward.domain
        let bitDepth = switch image.pixelType {
        case .gray8: 8
        case .gray16: 16
        case .gray32Float: 32
        case .rgb8: 24
        }
        do {
            let stack = try ImageStack(width: domain.size, height: domain.size, planes: [.gray8(forward.powerSpectrum)])
            var result = try Hyperstack(
                title: "FFT of " + image.title, stack: stack, calibration: image.calibration,
                info: "Fast Hartley Transform\nwidth: \(domain.originalWidth)\nheight: \(domain.originalHeight)\nbitdepth: \(bitDepth)\n")
            result.frequencyDomain = domain
            context.add(result)
        } catch {
            throw CommandError.failed(command: name, detail: "\(error)")
        }
    }

    /// `FFT("inverse")`: the transform back to an image, filtered by the
    /// pixels set to 0 or 255 in the spectrum. A two-slice (complex) or
    /// "FHT of" image is left to ImageJ.
    static let inverseFFT = CommandDefinition("Inverse FFT", menu: "Process>FFT") { context, _ in
        let name = "Inverse FFT"
        guard let open = context.current else { throw CommandError.noImage(name) }
        if open.title.hasPrefix("FHT of") || open.image.stack.count == 2 { throw CommandError.notNative(name) }
        guard open.image.frequencyDomain != nil else {
            throw CommandError.failed(command: name, detail: "Frequency domain image required")
        }
        try inverse(name, &context)
    }

    /// `doInverseTransform`: the image loses its selection, and a new
    /// "Inverse FFT of <original title>" image has the original type and LUT.
    static func inverse(_ name: String, _ context: inout CommandContext) throws(CommandError) {
        guard let open = context.current, let domain = open.image.frequencyDomain else { throw .noImage(name) }
        let image = open.image
        // doMasking: the current plane, unless the image is a stack.
        var mask: [UInt8]?
        if image.stack.count == 1, image.width == domain.size, image.height == domain.size {
            guard case .gray8(let spectrum) = open.currentPlane else { throw .notNative(name) }
            mask = FFT.filterMask(spectrum, size: domain.size)
            if mask == nil, FFT.integerMean(spectrum) != domain.powerSpectrumMean {
                throw .notNative(name)  // ImageJ shows "No pixels have been set to 0 (black) or 255 (white)"
            }
        }
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in open.image.encodedROI = nil }
        let result = FFT.inverse(domain, mask: mask)
        var title = image.title
        if title.hasPrefix("FFT of ") { title.removeFirst(7) }
        do {
            let stack = try ImageStack(width: result.width, height: result.height, planes: [result.plane])
            var channels: [ChannelDisplay]?
            if let range = result.displayRange {
                channels = [ChannelDisplay(lut: result.lut ?? .grays, displayRange: range)]
            }
            context.add(try Hyperstack(
                title: "Inverse FFT of " + title, stack: stack, calibration: image.calibration, channels: channels))
        } catch {
            throw .failed(command: name, detail: "\(error)")
        }
    }

    /// `FFT("redisplay")`: the power spectrum again, as computed, in place of the image.
    static let redisplayPowerSpectrum = CommandDefinition("Redisplay Power Spectrum", menu: "Process>FFT") {
        context, _ in
        let name = "Redisplay Power Spectrum"
        guard let open = context.current else { throw CommandError.noImage(name) }
        guard let domain = open.image.frequencyDomain else {
            throw CommandError.failed(command: name, detail: "Frequency domain image required")
        }
        guard open.image.stack.count == 1 else { throw CommandError.notNative(name) }
        let spectrum = FHT(size: domain.size).powerSpectrum(domain.transform)
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let image = open.image
            do {
                let stack = try ImageStack(width: domain.size, height: domain.size, planes: [.gray8(spectrum)])
                var out = try Hyperstack(
                    title: image.title, stack: stack, calibration: image.calibration, info: image.info,
                    properties: image.properties)
                out.encodedROI = image.encodedROI
                out.encodedOverlay = image.encodedOverlay
                out.frequencyDomain = domain
                open.image = out
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
        }
    }

    /// `FFT("swap")`: every plane of a square image has its quadrants
    /// swapped (1 with 3, 2 with 4).
    static let swapQuadrants = CommandDefinition("Swap Quadrants", menu: "Process>FFT") { context, _ in
        let name = "Swap Quadrants"
        try context.withCurrent(name) { (open: inout OpenImage) throws(CommandError) in
            let width = open.image.width
            guard width == open.image.height else { throw .failed(command: name, detail: "Image must be square") }
            for index in 0..<open.image.stack.count {
                open.image.modifyPlane(at: index) { plane in
                    switch plane {
                    case .gray8(var p): FHT.swapQuadrants(&p, width: width); plane = .gray8(p)
                    case .gray16(var p): FHT.swapQuadrants(&p, width: width); plane = .gray16(p)
                    case .gray32Float(var p): FHT.swapQuadrants(&p, width: width); plane = .gray32Float(p)
                    case .rgb8(var p): FHT.swapQuadrants(&p, width: width); plane = .rgb8(p)
                    }
                }
            }
        }
    }

    /// `ip.crop()` of a rectangle inside the plane.
    static func crop(_ plane: Plane, planeWidth: Int, x: Int, y: Int, width w: Int, height h: Int) -> Plane {
        func rows<T>(_ p: [T]) -> [T] {
            var out: [T] = []
            out.reserveCapacity(w * h)
            for row in y..<(y + h) { out += p[(row * planeWidth + x)..<(row * planeWidth + x + w)] }
            return out
        }
        return switch plane {
        case .gray8(let p): .gray8(rows(p))
        case .gray16(let p): .gray16(rows(p))
        case .gray32Float(let p): .gray32Float(rows(p))
        case .rgb8(let p): .rgb8(rows(p))
        }
    }
}
