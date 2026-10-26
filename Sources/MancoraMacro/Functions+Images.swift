// The built-in functions that work on images: the current image, its
// pixels, selection, threshold, display range and calibration, and the
// commands run on it. Ports of the corresponding parts of ImageJ 1.54p's
// Functions.java, working on Mancora's images through `MacroSession`.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraProcess

extension OpenImage {
    /// `ImagePlus.getCurrentSlice()`: the 1-based stack index shown.
    var currentSliceNumber: Int { stackIndex + 1 }
    var stackIndex: Int { image.dimensions.planeIndex(channel: channel, slice: slice, frame: frame) }
}

extension Functions {
    // MARK: - The current image

    /// `getImage()`: the current image, or "There are no images open". As in
    /// ImageJ, it drops the cached processor, so the next `getProcessor()`
    /// applies the macro's drawing color again.
    func image() throws(MacroSignal) -> OpenImage {
        let open = try currentImage()
        cachedProcessor = nil
        return open
    }

    func currentImage() throws(MacroSignal) -> OpenImage {
        guard let open = session.context.current else { try interp.fail("There are no images open") }
        return open
    }

    /// `resetImage()`.
    func resetImage() { cachedProcessor = nil }

    /// Changes the current image.
    func modifyImage(_ body: (inout OpenImage) -> Void) throws(MacroSignal) {
        _ = try currentImage()
        try? session.context.withCurrent("") { (open: inout OpenImage) in body(&open) }
    }

    /// Replaces the plane shown.
    func setCurrentPlane(_ plane: Plane) throws(MacroSignal) {
        try modifyImage { open in try? open.image.setPlane(plane, at: open.stackIndex) }
    }

    /// Changes the plane shown in place (with its width and height): a
    /// macro setting pixels one by one doesn't copy the image each time.
    func modifyCurrentPlane(_ body: (inout Plane, Int, Int) -> Void) throws(MacroSignal) {
        _ = try currentImage()
        try? session.context.withCurrent("") { (open: inout OpenImage) in
            let index = open.stackIndex, width = open.image.width, height = open.image.height
            open.image.modifyPlane(at: index) { body(&$0, width, height) }
        }
    }

    func commandError(_ error: CommandError) throws(MacroSignal) -> Never {
        switch error {
        case .noImage: try interp.fail("There are no images open")
        case .unrecognized(let name): try interp.fail("Unrecognized command: \"\(name)\"")
        case .notNative(let name): try unsupported("\"\(name)\" with these options")
        default: try interp.fail(error.description)
        }
    }

    func runCommand(_ name: String, options: String?) throws(MacroSignal) {
        resetImage()
        do { try session.runCommand(name, options: options) } catch { try commandError(error) }
    }

    func doRun() throws(MacroSignal) {
        try interp.getLeftParen()
        let arg1 = try getString()
        interp.getToken()
        if !(interp.token == ch(")") || interp.token == ch(",")) { try interp.error("',' or ')'  expected") }
        var arg2: String?
        if interp.token == ch(",") {
            arg2 = try getString()
            try interp.getRightParen()
        }
        try runCommand(arg1, options: arg2)
    }

    func selectWindow() throws(MacroSignal) {
        let title = try getStringArg()
        resetImage()
        if let match = session.context.images.first(where: { $0.title == title }) {
            session.activate(match.id)
            return
        }
        // Results, Log and other non-image windows: nothing to activate here.
        if title == "Results" || title == "Log" || session.context.tables[title] != nil { return }
        try interp.fail("No window with the title \"\(title)\" found.")
    }

    func selectImage() throws(MacroSignal) {
        resetImage()
        try interp.getLeftParen()
        if isStringArg() {
            let title = try getString()
            guard let match = session.context.images.first(where: { $0.title == title }) else {
                try interp.fail("\"\(title)\" not found")
            }
            session.activate(match.id)
            try interp.getRightParen()
        } else {
            var id = jIntI(try interp.getExpression())
            if id > 0 {
                // The Nth image.
                guard id <= session.context.images.count else {
                    try interp.fail("Image \(id) not found or no images are open.")
                }
                id = session.context.images[id - 1].id
            }
            guard session.context.images.contains(where: { $0.id == id }) else { try interp.fail("Image \(id) not found") }
            session.activate(id)
            try interp.getRightParen()
        }
    }

    func isOpen() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        if isStringArg() {
            let title = try getString()
            try interp.getRightParen()
            return session.context.images.contains { $0.title == title } || session.context.tables[title] != nil ? 1 : 0
        }
        let id = jIntI(try interp.getExpression())
        try interp.getRightParen()
        return session.context.images.contains { $0.id == id } ? 1 : 0
    }

    func isActive() throws(MacroSignal) -> Double {
        let id = jIntI(try getArg())
        return session.context.currentID == id ? 1 : 0
    }

    func rename(_ title: String) throws(MacroSignal) {
        try modifyImage { $0.image.title = title }
    }

    func close() throws(MacroSignal) {
        var pattern: String?
        var keep = false
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if interp.nextToken() != ch(")") { pattern = try getString() }
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                keep = javaCompareToIgnoreCase(try getString(), "keep") == 0
            }
            try interp.getRightParen()
        }
        _ = keep  // Mancora doesn't track unsaved changes yet, so nothing is kept for them.
        guard let pattern else {
            session.close(id: try image().id)
            return
        }
        if pattern == "Results" { session.context.results.reset() }
        if pattern.lowercased() == "roi manager" { session.roiManager = RoiManagerList() }
        session.context.tables[pattern] = nil
        let others = pattern == "\\Others"
        let front = session.context.currentID
        for open in session.context.images {
            let match = others ? open.id != front : Self.wildcardMatch(open.title, pattern)
            if match { session.close(id: open.id) }
        }
        if let front, session.context.images.contains(where: { $0.id == front }) { session.activate(front) }
    }

    /// `WildcardMatch` without case sensitivity: `*` any run, `?` one character.
    static func wildcardMatch(_ s: String, _ pattern: String) -> Bool {
        let a = Array(s.lowercased().utf16), p = Array(pattern.lowercased().utf16)
        var memo = [Int: Bool]()
        func match(_ i: Int, _ j: Int) -> Bool {
            let key = i * (p.count + 1) + j
            if let m = memo[key] { return m }
            var result: Bool
            if j == p.count {
                result = i == a.count
            } else if p[j] == 42 {  // *
                result = match(i, j + 1) || (i < a.count && match(i + 1, j))
            } else if i < a.count && (p[j] == 63 || p[j] == a[i]) {  // ?
                result = match(i + 1, j + 1)
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    func open() throws(MacroSignal) {
        try interp.getLeftParen()
        if interp.nextToken() == ch(")") { try unsupported("open() with a file dialog") }
        let path = try getString()
        var n = Double.nan
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            if isStringArg() { _ = try getString() } else { n = try interp.getExpression() }
        }
        try interp.getRightParen()
        let lower = path.lowercased()
        if lower.hasSuffix(".ijm") || lower.hasSuffix(".txt") || lower.hasSuffix(".csv") || lower.hasSuffix(".roi")
            || lower.hasSuffix(".zip")
        {
            if lower.hasSuffix(".roi") {
                do { try modifyImage { $0.roi = nil } } catch {}
                let roi: Roi
                do { roi = try RoiCodec.read(path: path) } catch { try interp.fail("\(error)") }
                try modifyImage { $0.roi = roi }
                return
            }
            if lower.hasSuffix(".zip") {
                try roiManagerOpen(path)
                return
            }
            try unsupported("open(\"\(Self.javaFileName(path))\")")
        }
        var image: Hyperstack
        do {
            image = try TIFFImporter.read(path: path)
        } catch {
            if !lower.hasSuffix(".tif") && !lower.hasSuffix(".tiff") {
                try unsupported("open(\"\(Self.javaFileName(path))\")")
            }
            try interp.fail("File is not in a supported format, a reader\nplugin is not available, or it was not found.\n" + path)
        }
        image.properties["Mancora.path"] = path
        session.add(image)
        if !n.isNaN {
            try modifyImage { open in
                let index = max(0, min(open.image.stack.count - 1, jIntI(n) - 1))
                let p = open.image.dimensions.position(ofPlane: index)
                (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
            }
        }
        session.lastDirectory = (Self.javaParent(path) ?? "") + Self.separator
        session.lastName = Self.javaFileName(path)
    }

    func newImage() throws(MacroSignal) {
        let title = try getFirstString()
        let type = try getNextString()
        let width = jIntI(try getNextArg())
        let height = jIntI(try getNextArg())
        let depth = jIntI(try getNextArg())
        var c = -1, z = -1, t = -1
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
        } else {
            c = depth
            z = jIntI(try getNextArg())
            t = jIntI(try getLastArg())
        }
        if width < 1 || height < 1 { try interp.fail("Width or height < 1") }
        let lower = type.lowercased()
        var bitDepth = 8
        if lower.contains("16") { bitDepth = 16 }
        if lower.contains("32") { bitDepth = 32 }
        if lower.contains("24") || lower.contains("rgb") || lower.contains("32-bit int") { bitDepth = 24 }
        enum Fill { case white, black, ramp }
        var fill: Fill = bitDepth == 16 || bitDepth == 32 ? .black : .white
        if lower.contains("white") {
            fill = .white
        } else if lower.contains("black") {
            fill = .black
        } else if lower.contains("ramp") || lower.contains("label") {
            fill = .ramp
        } else if lower.contains("noise") || lower.contains("random") {
            try unsupported("newImage with noise")
        }
        let planes = c < 0 ? max(depth, 1) : max(c, 1) * max(z, 1) * max(t, 1)
        let count = width * height
        var plane: Plane
        switch bitDepth {
        case 16:
            var p = [UInt16](repeating: 0, count: count)
            if fill == .ramp {
                for x in 0..<width {
                    let v = UInt16(truncatingIfNeeded: Int32(truncatingIfNeeded: Int64((Double(x) * 65536.0) / Double(width) + 0.5)))
                    for y in 0..<height { p[y * width + x] = v }
                }
            }
            plane = .gray16(p)
        case 32:
            var p = [Float](repeating: 0, count: count)
            if fill == .ramp {
                for x in 0..<width {
                    for y in 0..<height { p[y * width + x] = Float(Double(x) / Double(width)) }
                }
            }
            plane = .gray32Float(p)
        case 24:
            var p = [UInt32](repeating: fill == .white ? 0xFFFF_FFFF : 0xFF00_0000, count: count)
            if fill == .ramp {
                for x in 0..<width {
                    let g = UInt32(UInt8(truncatingIfNeeded: Int(Double(x) * 256.0 / Double(width))))
                    for y in 0..<height { p[y * width + x] = 0xFF00_0000 | g << 16 | g << 8 | g }
                }
            }
            plane = .rgb8(p)
        default:
            var p = [UInt8](repeating: fill == .white ? 255 : 0, count: count)
            if fill == .ramp {
                for x in 0..<width {
                    let v = UInt8(truncatingIfNeeded: Int(Double(x) * 256.0 / Double(width)))
                    for y in 0..<height { p[y * width + x] = v }
                }
            }
            plane = .gray8(p)
        }
        let dims = c < 0 ? HyperstackDimensions(slices: planes) : HyperstackDimensions(channels: max(c, 1), slices: max(z, 1), frames: max(t, 1))
        do {
            let stack = try ImageStack(width: width, height: height, planes: Array(repeating: plane, count: planes))
            var image = try Hyperstack(title: title, stack: stack, dimensions: dims)
            for channel in 0..<dims.channels {
                var display = image.channels[channel]
                switch bitDepth {
                case 16: display.displayRange = 0...65535
                case 32: display.displayRange = 0...1
                default: break
                }
                if fill == .white && (bitDepth == 16 || bitDepth == 32) { display.lut = display.lut.inverted() }
                image.setDisplay(display, forChannel: channel)
            }
            if dims.channels > 1 && bitDepth != 24 {
                image.compositeMode = lower.contains("composite") ? .composite : lower.contains("gray") ? .grayscale : .color
                if !lower.contains("composite") && !lower.contains("color") && !lower.contains("gray") {
                    image.compositeMode = .composite
                }
            }
            session.add(image)
        } catch {
            try interp.fail("\(error)")
        }
    }

    func save(_ path: String) throws(MacroSignal) {
        try saveImage(path, format: "tiff")
    }

    func saveAs() throws(MacroSignal) {
        let format = try getFirstString()
        var path: String?
        var oneArg = false
        if interp.nextToken() == ch(",") {
            path = try getLastString()
        } else {
            try interp.getRightParen()
            oneArg = true
        }
        if oneArg && (format.contains(Self.separator) || format.contains("/")) {
            try saveImage(format, format: "tiff")
            return
        }
        try saveImage(path ?? "", format: format.lowercased())
    }

    private func saveImage(_ pathIn: String, format: String) throws(MacroSignal) {
        if pathIn.isEmpty { try unsupported("saveAs with a save dialog") }
        var path = pathIn
        switch format {
        case "tiff", "tif":
            let open = try image()
            if !path.lowercased().hasSuffix(".tif") && !path.lowercased().hasSuffix(".tiff") { path += ".tif" }
            do { try TIFFExporter.write(open.image, to: path) } catch { try interp.fail("\(error)") }
            let title = Self.javaFileName(path)
            try modifyImage { $0.image.title = title }
        case "results", "measurements":
            if !path.contains(".") { path += ".csv" }
            let text = ResultsFormatter.csv(session.context.results, decimalPlaces: session.context.settings.decimalPlaces)
            do { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) } catch { try interp.fail("\(error)") }
        case "text":
            try unsupported("saveAs(\"Text\")")
        case "selection":
            let open = try image()
            guard let roi = open.roi else { try interp.fail("Selection required") }
            if !path.hasSuffix(".roi") { path += ".roi" }
            do {
                try Data(RoiCodec.encode(roi)).write(to: URL(fileURLWithPath: path))
            } catch {
                try interp.fail("\(error)")
            }
        case "lut":
            try unsupported("saveAs(\"LUT\")")
        default:
            try unsupported("saveAs(\"\(format)\")")
        }
    }

    // MARK: - Stack position

    func setSlice() throws(MacroSignal) {
        let n = jIntI(try getArg())
        let open = try image()
        let nSlices = open.image.stack.count
        if n == 1 && nSlices == 1 { return }
        if n < 1 || n > nSlices { try interp.fail("Argument must be >=1 and <=\(nSlices)") }
        try modifyImage { open in
            let p = open.image.dimensions.position(ofPlane: n - 1)
            (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
        }
    }

    func getDimensions() throws(MacroSignal) {
        let width = try getFirstVariable()
        let height = try getNextVariable()
        let channels = try getNextVariable()
        let slices = try getNextVariable()
        let frames = try getLastVariable()
        let open = try image()
        let d = open.image.dimensions
        width.setValue(Double(open.image.width))
        height.setValue(Double(open.image.height))
        channels.setValue(Double(d.channels))
        slices.setValue(Double(d.slices))
        frames.setValue(Double(d.frames))
    }

    func doStack() throws(MacroSignal) -> Double {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if interp.token != WORD && interp.token != PREDEFINED_FUNCTION { try interp.error("Function name expected: ") }
        let name = interp.tokenString ?? ""
        switch name {
        case "size": return Double(try image().image.stack.count)
        case "isHyperstack", "isHyperStack": return try image().image.dimensions.isHyperstack ? 1 : 0
        case "getDimensions":
            try getDimensions()
            return .nan
        default: break
        }
        let open = try image()
        let d = open.image.dimensions
        func setPosition(_ c: Int, _ z: Int, _ t: Int) throws(MacroSignal) {
            try modifyImage { open in
                open.channel = max(0, min(d.channels - 1, c - 1))
                open.slice = max(0, min(d.slices - 1, z - 1))
                open.frame = max(0, min(d.frames - 1, t - 1))
            }
        }
        switch name {
        case "setPosition":
            let c = jIntI(try getFirstArg())
            let z = jIntI(try getNextArg())
            let t = jIntI(try getLastArg())
            try setPosition(c, z, t)
            return .nan
        case "setChannel":
            try setPosition(jIntI(try getArg()), open.slice + 1, open.frame + 1)
            return .nan
        case "setSlice":
            try setPosition(open.channel + 1, jIntI(try getArg()), open.frame + 1)
            return .nan
        case "setFrame":
            try setPosition(open.channel + 1, open.slice + 1, jIntI(try getArg()))
            return .nan
        case "getPosition":
            let channel = try getFirstVariable()
            let slice = try getNextVariable()
            let frame = try getLastVariable()
            channel.setValue(Double(open.channel + 1))
            slice.setValue(Double(open.slice + 1))
            frame.setValue(Double(open.frame + 1))
            return .nan
        case "getFrameRate":
            try interp.getParens()
            return open.image.calibration.fps
        case "setFrameRate":
            let fps = try getArg()
            try modifyImage { $0.image.calibration.fps = fps }
            return .nan
        case "getFrameInterval":
            try interp.getParens()
            return open.image.calibration.frameInterval
        case "setFrameInterval":
            let interval = try getArg()
            try modifyImage { $0.image.calibration.frameInterval = interval }
            return .nan
        case "setTUnit":
            let unit = try getStringArg()
            try modifyImage { $0.image.calibration.timeUnit = unit }
            return .nan
        case "setXUnit":
            let unit = Self.sanitizeUnit(try getStringArg())
            try modifyImage { $0.image.calibration.unit = unit }
            return .nan
        case "setYUnit":
            let unit = try getStringArg()
            try modifyImage { $0.image.calibration.yUnit = unit.isEmpty ? nil : unit }
            return .nan
        case "setZUnit":
            let unit = try getStringArg()
            try modifyImage { $0.image.calibration.zUnit = unit.isEmpty ? nil : unit }
            return .nan
        case "getUnits":
            let x = try getFirstVariable()
            let y = try getNextVariable()
            let z = try getNextVariable()
            let time = try getNextVariable()
            let value = try getLastVariable()
            let cal = open.image.calibration
            x.setString(cal.unit)
            y.setString(cal.yUnit ?? cal.unit)
            z.setString(cal.zUnit ?? cal.unit)
            time.setString(cal.timeUnit)
            value.setString(cal.valueUnit)
            return .nan
        default: break
        }
        if open.image.stack.count == 1 {
            try interp.error("Stack required")
            return .nan
        }
        switch name {
        case "setDimensions":
            let c = jIntI(try getFirstArg())
            let z = jIntI(try getNextArg())
            let t = jIntI(try getLastArg())
            guard c * z * t == open.image.stack.count else { return .nan }
            var failed = false
            try modifyImage { open in
                do {
                    try open.image.setDimensions(HyperstackDimensions(channels: c, slices: z, frames: t))
                } catch {
                    failed = true
                }
                (open.channel, open.slice, open.frame) = (0, 0, 0)
            }
            if failed { try unsupported("Stack.setDimensions") }
        case "setDisplayMode":
            let mode = try getStringArg().lowercased()
            try modifyImage { open in
                open.image.compositeMode = mode.hasPrefix("comp") ? .composite : mode.hasPrefix("gray") ? .grayscale : .color
            }
        case "getDisplayMode":
            let v = try getVariableArg()
            v.setString(open.image.compositeMode.rawValue)
        case "getStatistics":
            try unsupported("Stack.getStatistics")
        default:
            try unsupported("Stack." + name)
        }
        return .nan
    }

    final func getVariableArg() throws(MacroSignal) -> Variable {
        try interp.getLeftParen()
        let v = try getVariable()
        try interp.getRightParen()
        return v
    }

    // MARK: - Pixels

    func getPixel() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        let a1 = try interp.getExpression()
        let open = try processor()
        let plane = open.currentPlane
        let width = open.image.width, height = open.image.height
        interp.getToken()
        if interp.token == ch(",") {
            let a2 = try interp.getExpression()
            try interp.getRightParen()
            let ix = jIntI(a1), iy = jIntI(a2)
            if a1 == Double(ix) && a2 == Double(iy) {
                guard ix >= 0, ix < width, iy >= 0, iy < height else {
                    return plane.pixelType == .gray32Float ? .nan : 0
                }
                return Self.rawPixel(plane, iy * width + ix)
            }
            if case .rgb8(let p) = plane { return Double(Self.interpolatedRGB(p, width: width, height: height, a1, a2)) }
            return Self.interpolatedValue(plane, width: width, height: height, a1, a2)
        }
        if interp.token != ch(")") { try interp.error("')' expected") }
        let index = jIntI(a1)
        guard index >= 0, index < plane.count else { try interp.fail("Index (\(index)) out of range") }
        return Self.rawPixel(plane, index)
    }

    /// `ip.getPixel` (or `getPixelValue` for floats): the stored value; RGB
    /// as the Java int ImageJ keeps, alpha included (so usually negative).
    static func rawPixel(_ plane: Plane, _ i: Int) -> Double {
        switch plane {
        case .gray8(let p): Double(p[i])
        case .gray16(let p): Double(p[i])
        case .gray32Float(let p): Double(p[i])
        case .rgb8(let p): Double(Int32(bitPattern: p[i]))
        }
    }

    /// `ImageProcessor.getInterpolatedValue(x, y)`: bilinear, with ImageJ's edge rules.
    static func interpolatedValue(_ plane: Plane, width: Int, height: Int, _ x: Double, _ y: Double) -> Double {
        if x < -1 || x >= Double(width) || y < -1 || y >= Double(height) { return 0 }
        func pixel(_ x: Int, _ y: Int) -> Double {
            let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
            return plane.value(at: cy * width + cx)
        }
        if x < 0 || y < 0 || x >= Double(width - 1) || y >= Double(height - 1) {
            // getInterpolatedEdgeValue
            let xbase = jIntI(jFloor(x)), ybase = jIntI(jFloor(y))
            let xf = x - Double(xbase), yf = y - Double(ybase)
            let ll = pixel(xbase, ybase), lr = pixel(xbase + 1, ybase)
            let ur = pixel(xbase + 1, ybase + 1), ul = pixel(xbase, ybase + 1)
            let upper = ul + xf * (ur - ul), lower = ll + xf * (lr - ll)
            return lower + yf * (upper - lower)
        }
        let xbase = jIntI(x), ybase = jIntI(y)
        let xf = x - Double(xbase), yf = y - Double(ybase)
        let ll = pixel(xbase, ybase), lr = pixel(xbase + 1, ybase)
        let ur = pixel(xbase + 1, ybase + 1), ul = pixel(xbase, ybase + 1)
        let upper = ul + xf * (ur - ul), lower = ll + xf * (lr - ll)
        return lower + yf * (upper - lower)
    }

    /// `ColorProcessor.getPixelInterpolated`: each channel bilinear, rounded, as a Java int (alpha included).
    static func interpolatedRGB(_ p: [UInt32], width: Int, height: Int, _ x: Double, _ y: Double) -> Int32 {
        if x < 0 || y < 0 || x >= Double(width - 1) || y >= Double(height - 1) { return 0 }
        let xbase = jIntI(x), ybase = jIntI(y)
        let xf = x - Double(xbase), yf = y - Double(ybase)
        let offset = ybase * width + xbase
        let ll = p[offset], lr = p[offset + 1], ur = p[offset + width + 1], ul = p[offset + width]
        func channel(_ shift: UInt32) -> Int32 {
            func c(_ v: UInt32) -> Double { Double((v >> shift) & 0xFF) }
            let upper = c(ul) + xf * (c(ur) - c(ul)), lower = c(ll) + xf * (c(lr) - c(ll))
            return jInt(lower + yf * (upper - lower) + 0.5)
        }
        let r = channel(16), g = channel(8), b = channel(0)
        return Int32(bitPattern: 0xFF00_0000) | ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff)
    }

    func setPixel() throws(MacroSignal) {
        try interp.getLeftParen()
        let a1 = jIntI(try interp.getExpression())
        try interp.getComma()
        let a2 = try interp.getExpression()
        interp.getToken()
        let count: Int
        do {
            let open = try processor()
            count = open.image.width * open.image.height
        }
        if interp.token == ch(",") {
            let a3 = try interp.getExpression()
            try interp.getRightParen()
            let x = a1, y = jIntI(a2)
            try modifyCurrentPlane { plane, width, height in
                guard x >= 0, x < width, y >= 0, y < height else { return }
                Self.putPixel(&plane, y * width + x, a3)
            }
        } else {
            if interp.token != ch(")") { try interp.error("')' expected") }
            let index = a1
            guard index >= 0, index < count else { try interp.fail("Index (\(index)) out of range") }
            try modifyCurrentPlane { plane, _, _ in
                if case .rgb8 = plane {
                    Self.putPixel(&plane, index, a2)  // ip.set(i, (int)v): the int as given
                } else {
                    Self.setFloat(&plane, index, Float(a2))
                }
            }
        }
    }

    /// `putPixel(x, y, (int)v)` (clamped for 8 and 16 bits) or `putPixelValue` for floats.
    /// Each case lets go of `plane` before writing, so the pixels change in place.
    static func putPixel(_ plane: inout Plane, _ i: Int, _ v: Double) {
        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            p[i] = UInt8(max(0, min(255, Int(jInt(v)))))
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            p[i] = UInt16(max(0, min(65535, Int(jInt(v)))))
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            p[i] = Float(v)
            plane = .gray32Float(p)
        case .rgb8(var p):
            plane = .gray8([])
            p[i] = UInt32(bitPattern: jInt(v))  // ColorProcessor stores the int as given
            plane = .rgb8(p)
        }
    }

    /// `ip.setf(i, v)`: no clamping; integer types truncate as Java's casts do.
    static func setFloat(_ plane: inout Plane, _ i: Int, _ v: Float) {
        switch plane {
        case .gray8(var p):
            plane = .gray8([])
            p[i] = UInt8(truncatingIfNeeded: jInt(Double(v)))
            plane = .gray8(p)
        case .gray16(var p):
            plane = .gray8([])
            p[i] = UInt16(truncatingIfNeeded: jInt(Double(v)))
            plane = .gray16(p)
        case .gray32Float(var p):
            plane = .gray8([])
            p[i] = v
            plane = .gray32Float(p)
        case .rgb8: break
        }
    }

    func changeValues() throws(MacroSignal) {
        var v1 = try getFirstArg()
        var v2 = try getNextArg()
        let v3 = try getLastArg()
        let open = try image()
        var plane = open.currentPlane
        let width = open.image.width, height = open.image.height
        var region = MeasurementRegion(x: 0, y: 0, width: width, height: height)
        if let roi = open.roi, roi.isArea {
            do { region = try roi.measurementRegion(width: width, height: height) } catch { try interp.fail("\(error)") }
        }
        let isFloat = plane.pixelType == .gray32Float
        if plane.pixelType == .rgb8 {
            v1 = Double(jInt(v1) & 0xFF_FFFF)
            v2 = Double(jInt(v2) & 0xFF_FFFF)
        }
        for y in max(region.y, 0)..<min(region.y + region.height, height) {
            for x in max(region.x, 0)..<min(region.x + region.width, width) where region.contains(x, y) {
                let i = y * width + x
                var v = Self.rawPixel(plane, i)
                if case .rgb8(let p) = plane { v = Double(p[i] & 0xFF_FFFF) }
                var replace = v >= v1 && v <= v2
                if v1.isNaN && v2.isNaN && v.isNaN { replace = true }
                if replace { Self.putPixel(&plane, i, isFloat ? v3 : Double(jInt(v3))) }
            }
        }
        try setCurrentPlane(plane)
    }

    func snapshotOrReset(_ type: Int) throws(MacroSignal) {
        try interp.getParens()
        let open = try image()
        if type == SNAPSHOT {
            snapshot = (open.id, open.stackIndex, open.currentPlane)
        } else if let snapshot, snapshot.id == open.id, snapshot.plane.count == open.currentPlane.count {
            try modifyImage { try? $0.image.setPlane(snapshot.plane, at: $0.stackIndex) }
        }
    }

    /// `getProcessor()`: the current image. The first call since
    /// `getImage()` or `resetImage()` gives its processor the macro's
    /// `setColor` color or value, else the foreground color; later calls
    /// keep the processor as it is.
    @discardableResult
    func processor() throws(MacroSignal) -> OpenImage {
        let open = try currentImage()
        if cachedProcessor == open.id { return open }
        cachedProcessor = open.id
        if let color = session.drawingColor {
            session.processorFill[open.id] = EditCommands.fillValue(color: color, for: open)
        } else if let value = session.drawingValue {
            session.processorFill[open.id] = value
        } else {
            session.processorFill[open.id] = EditCommands.fillValue(color: session.foreground, for: open)
        }
        return open
    }

    /// The value drawing and filling use on `open`.
    func drawingValue(for open: OpenImage) -> Double {
        session.processorFill[open.id] ?? EditCommands.fillValue(color: session.foreground, for: open)
    }

    func fill() throws(MacroSignal) {
        try interp.getParens()
        try processor()
        let open = try image()
        let width = open.image.width, height = open.image.height
        var region = MeasurementRegion(x: 0, y: 0, width: width, height: height)
        if let roi = open.roi {
            guard roi.isArea else { try unsupported("fill() with a line selection") }
            do { region = try roi.measurementRegion(width: width, height: height) } catch { try interp.fail("\(error)") }
        }
        let value = drawingValue(for: open)
        try modifyCurrentPlane { plane, _, _ in
            for y in max(region.y, 0)..<max(max(region.y, 0), min(region.y + region.height, height)) {
                for x in max(region.x, 0)..<max(max(region.x, 0), min(region.x + region.width, width)) where region.contains(x, y) {
                    EditCommands.putFill(&plane, y * width + x, value)
                }
            }
        }
    }

    func drawOrFill(_ type: Int) throws(MacroSignal) {
        let x = jIntI(try getFirstArg())
        let y = jIntI(try getNextArg())
        let w = jIntI(try getNextArg())
        let h = jIntI(try getLastArg())
        let value = drawingValue(for: try processor())
        try draw(value) { canvas, pen in
            switch type {
            case FILL_RECT: canvas.fillRect(x, y, w, h)
            case DRAW_RECT: canvas.drawRect(x, y, w, h, pen: &pen)
            case FILL_OVAL: canvas.fillOval(x, y, w, h)
            default: canvas.drawOval(x, y, w, h, pen: &pen)
            }
        }
    }

    /// Draws on the plane shown with `value`, in place.
    private func draw(_ value: Double, _ body: (inout Canvas, inout (x: Int, y: Int)) -> Void) throws(MacroSignal) {
        var pen = self.pen
        let lineWidth = session.lineWidth
        try modifyCurrentPlane { plane, width, height in
            var canvas = Canvas(plane: Self.take(&plane), width: width, height: height, value: value, lineWidth: lineWidth)
            body(&canvas, &pen)
            plane = canvas.plane
        }
        self.pen = pen
    }

    /// Takes the pixels out of `plane`, leaving it empty, so the taker owns them.
    static func take(_ plane: inout Plane) -> Plane {
        let taken = plane
        plane = .gray8([])
        return taken
    }

    /// `(int)Math.round(expression)`.
    private func roundedArgument() throws(MacroSignal) -> Int {
        Int(Int32(truncatingIfNeeded: javaMathRound(try interp.getExpression())))
    }

    func drawLine() throws(MacroSignal) {
        try interp.getLeftParen()
        let x1 = try roundedArgument()
        try interp.getComma()
        let y1 = try roundedArgument()
        try interp.getComma()
        let x2 = try roundedArgument()
        try interp.getComma()
        let y2 = try roundedArgument()
        try interp.getRightParen()
        let value = drawingValue(for: try processor())
        pen = (x1, y1)
        try draw(value) { canvas, pen in canvas.lineTo(x2, y2, pen: &pen) }
    }

    func moveTo() throws(MacroSignal) {
        try interp.getLeftParen()
        let x = try roundedArgument()
        try interp.getComma()
        let y = try roundedArgument()
        try interp.getRightParen()
        try processor()
        pen = (x, y)
    }

    func lineTo() throws(MacroSignal) {
        try interp.getLeftParen()
        let x = try roundedArgument()
        try interp.getComma()
        let y = try roundedArgument()
        try interp.getRightParen()
        let value = drawingValue(for: try processor())
        try draw(value) { canvas, pen in canvas.lineTo(x, y, pen: &pen) }
    }

    func setForegroundColor() throws(MacroSignal) {
        let isImage = session.context.current != nil
        if isImage { try processor() }
        let color = try colorArguments()
        session.foreground = color
        resetImage()
        // setLineWidth's getProcessor() still applies the macro's color, then it is cleared.
        if isImage { try processor() }
        session.drawingColor = nil
        session.drawingValue = nil
    }

    func setBackgroundColor() throws(MacroSignal) {
        session.background = try colorArguments()
        resetImage()
    }

    /// `(r, g, b)` or `(0xRRGGBB)`.
    private func colorArguments() throws(MacroSignal) -> UInt32 {
        let arg1 = Int(jInt(try getFirstArg()))
        var red: Int, green: Int, blue: Int
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
            red = (arg1 & 0xff0000) >> 16
            green = (arg1 & 0xff00) >> 8
            blue = arg1 & 0xff
        } else {
            red = arg1
            green = Int(jInt(try getNextArg()))
            blue = Int(jInt(try getLastArg()))
        }
        // java.awt.Color(r, g, b) rejects values outside 0-255.
        guard (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) else {
            try interp.fail("Color parameter outside of expected range")
        }
        return UInt32(red << 16 | green << 8 | blue)
    }

    func setColor() throws(MacroSignal) {
        try interp.getLeftParen()
        if isStringArg() {
            let name = try getString()
            guard let color = Self.namedColor(name) else {
                try interp.fail("'red', 'green', or '#0000ff' etc. expected")
            }
            session.drawingColor = color
            session.drawingValue = nil
            if session.context.current != nil {
                let open = try processor()
                session.processorFill[open.id] = EditCommands.fillValue(color: color, for: open)
            }
            try interp.getRightParen()
            return
        }
        let arg1 = try interp.getExpression()
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
            try processor()
            let open = try image()
            var value = arg1
            switch open.image.pixelType {
            case .gray8:
                if value < 0 || value > 255 { try interp.error("Argument out of 8-bit range (0-255)") }
            case .gray16:
                if case .straightLine(-32768, 1)? = open.image.calibration.valueFunction { value += 32768 }
                if value < 0 || value > 65535 { try interp.error("Argument out of 16-bit range (0-65535)") }
            default: break
            }
            session.drawingValue = value
            session.drawingColor = nil
            session.processorFill[open.id] = value
            return
        }
        let red = max(0, min(255, Int(jInt(arg1))))
        let green = max(0, min(255, Int(jInt(try getNextArg()))))
        let blue = max(0, min(255, Int(jInt(try getLastArg()))))
        let color = UInt32(red << 16 | green << 8 | blue)
        session.drawingColor = color
        session.drawingValue = nil
        if session.context.current != nil {
            let open = try processor()
            session.processorFill[open.id] = EditCommands.fillValue(color: color, for: open)
        }
    }

    /// `getColor()`'s names and `#rrggbb`.
    static func namedColor(_ nameIn: String) -> UInt32? {
        let name = nameIn.lowercased()
        let colors: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x00FF00, "blue": 0x0000FF,
            "cyan": 0x00FFFF, "darkgray": 0x404040, "gray": 0x808080, "lightgray": 0xC0C0C0, "magenta": 0xFF00FF,
            "orange": 0xFFC800, "yellow": 0xFFFF00, "pink": 0xFFAFAF,
        ]
        if let color = colors[name] { return color }
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 16) { return value & 0xFF_FFFF }
        return nil
    }

    // MARK: - Display range and threshold

    func resetMinAndMax() throws(MacroSignal) {
        let open = try image()
        guard open.image.pixelType.usesLUT else { return }
        try modifyImage { open in
            var display = open.image.channels[open.channel]
            if open.image.pixelType == .gray8 {
                display.displayRange = 0...255
            } else if let range = open.currentPlane.valueRange() {
                display.displayRange = range
            }
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    func setMinAndMax() throws(MacroSignal) {
        let minimum = try getFirstArg()
        let maximum = try getNextArg()
        if interp.nextToken() == ch(",") {
            _ = try getLastArg()
            if try image().image.pixelType != .rgb8 { try interp.error("RGB image required") }
            try unsupported("setMinAndMax on RGB channels")
        }
        try interp.getRightParen()
        let open = try image()
        let cal = open.image.calibration
        var lo = Self.rawValue(minimum, cal), hi = Self.rawValue(maximum, cal)
        switch open.image.pixelType {
        case .rgb8: try unsupported("setMinAndMax on RGB images")
        case .gray8, .gray16:
            if hi < lo { return }
            lo = Double(javaMathRound(lo))
            hi = Double(javaMathRound(hi))
        case .gray32Float:
            lo = Double(Float(lo))
            hi = Double(Float(hi))
        }
        guard lo <= hi else { return }
        try modifyImage { open in
            var display = open.image.channels[open.channel]
            display.displayRange = lo...hi
            open.image.setDisplay(display, forChannel: open.channel)
        }
    }

    func getMinAndMax() throws(MacroSignal) {
        let minimum = try getFirstVariable()
        let maximum = try getLastVariable()
        let open = try image()
        let range = open.image.pixelType == .rgb8 ? 0...255 : open.image.channels[open.channel].displayRange
        minimum.setValue(open.image.calibration.calibratedValue(range.lowerBound))
        maximum.setValue(open.image.calibration.calibratedValue(range.upperBound))
    }

    /// `Calibration.getRawValue`.
    static func rawValue(_ value: Double, _ cal: Calibration) -> Double {
        switch cal.valueFunction {
        case .straightLine(let intercept, let slope)? where slope != 0: (value - intercept) / slope
        default: value
        }
    }

    func setThreshold() throws(MacroSignal) {
        var lower = try getFirstArg()
        var upper = try getNextArg()
        var mode: String?
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            mode = try getString()
        }
        try interp.getRightParen()
        let open = try image()
        if !(mode?.contains("raw") ?? false) {
            lower = Self.rawValue(lower, open.image.calibration)
            upper = Self.rawValue(upper, open.image.calibration)
        }
        guard open.image.pixelType != .rgb8 else { return }
        let levels = Threshold.manual(open.image.pixelType, lower: lower, upper: upper)
        try modifyImage { $0.threshold = levels }
    }

    func resetThreshold() throws(MacroSignal) {
        try modifyImage { $0.threshold = nil }
    }

    func getThreshold() throws(MacroSignal) {
        let lower = try getFirstVariable()
        let upper = try getLastVariable()
        let open = try image()
        if let t = open.threshold {
            lower.setValue(open.image.calibration.calibratedValue(t.lower))
            upper.setValue(open.image.calibration.calibratedValue(t.upper))
        } else {
            lower.setValue(-1)
            upper.setValue(-1)
        }
    }

    func setAutoThreshold() throws(MacroSignal) {
        var method: String?
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if isStringArg() { method = try getString() }
            try interp.getRightParen()
        }
        let open = try image()
        if open.image.pixelType == .rgb8 { try interp.fail("Non-RGB image expected") }
        if open.roi != nil { try unsupported("setAutoThreshold with a selection") }
        let inverted = open.image.channels[open.channel].lut.isInverted
        let result: AutoThresholdResult
        do {
            if let method {
                let words = method.split(separator: " ").map(String.init)
                guard let name = words.first, let m = AutoThresholder.Method(rawValue: name) else {
                    try interp.fail("Unrecognized method: \"\(method)\"")
                }
                let options = AutoThresholdOptions(
                    darkBackground: words.contains("dark"), sixteenBitHistogram: words.contains("16-bit"),
                    noReset: words.contains("no-reset"), invertedLUT: inverted)
                if words.contains("stack") {
                    result = try Threshold.auto(stack: open.image.stack, method: m, options: options, currentPlane: open.stackIndex)
                } else {
                    result = try Threshold.auto(
                        open.currentPlane, method: m, options: options,
                        displayRange: open.image.pixelType == .gray8 ? nil : open.image.channels[open.channel].displayRange)
                }
                session.thresholdMethod = name
            } else {
                result = try Threshold.legacyIsoData(open.currentPlane, invertedLUT: inverted)
            }
        } catch {
            try interp.fail("Non-RGB image expected")
        }
        try modifyImage { open in
            open.threshold = result.levels
            if let range = result.displayRange {
                var display = open.image.channels[open.channel]
                display.displayRange = range
                open.image.setDisplay(display, forChannel: open.channel)
            }
        }
    }

    // MARK: - Calibration

    func getPixelSize() throws(MacroSignal) {
        let unit = try getFirstVariable()
        let width = try getNextVariable()
        let height = try getNextVariable()
        var depth: Variable?
        if interp.nextToken() == ch(",") { depth = try getNextVariable() }
        try interp.getRightParen()
        let cal = try image().image.calibration
        unit.setString(Self.pluralUnits(cal.unit))
        width.setValue(cal.pixelWidth)
        height.setValue(cal.pixelHeight)
        depth?.setValue(cal.pixelDepth)
    }

    func getVoxelSize() throws(MacroSignal) {
        let width = try getFirstVariable()
        let height = try getNextVariable()
        let depth = try getNextVariable()
        let unit = try getLastVariable()
        let cal = try image().image.calibration
        width.setValue(cal.pixelWidth)
        height.setValue(cal.pixelHeight)
        depth.setValue(cal.pixelDepth)
        unit.setString(Self.pluralUnits(cal.unit))
    }

    func setVoxelSize() throws(MacroSignal) {
        let width = try getFirstArg()
        let height = try getNextArg()
        let depth = try getNextArg()
        let unit = Self.sanitizeUnit(try getLastString())
        try modifyImage { open in
            open.image.calibration.pixelWidth = width
            open.image.calibration.pixelHeight = height
            open.image.calibration.pixelDepth = depth
            open.image.calibration.unit = unit
        }
    }

    func calibrate(_ value: Double) throws(MacroSignal) -> Double {
        try image().image.calibration.calibratedValue(value)
    }

    /// `Calibration.sanitizeUnit`.
    static func sanitizeUnit(_ unit: String) -> String {
        switch unit {
        case "", "pixels": "pixel"
        case "um", "micron", "microns": "µm"
        case "A": "Å"
        default: unit
        }
    }

    /// `Calibration.getUnits()`: "pixels", "microns" and "inches" for their singulars.
    static func pluralUnits(_ unit: String) -> String {
        switch unit {
        case "pixel": "pixels"
        case "micron": "microns"
        case "inch": "inches"
        default: unit
        }
    }

    func toScaled() throws(MacroSignal) {
        try scale(toScaled: true)
    }

    func toUnscaled() throws(MacroSignal) {
        try scale(toScaled: false)
    }

    /// `toScaled(x, y)`, `toScaled(length)` and their inverses.
    private func scale(toScaled: Bool) throws(MacroSignal) {
        let open = try image()
        let cal = open.image.calibration
        let x = try getFirstVariable()
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
            x.setValue(toScaled ? x.getValue() * cal.pixelWidth : x.getValue() / cal.pixelWidth)
            return
        }
        let y = try getNextVariable()
        var z: Variable?
        if interp.nextToken() == ch(",") { z = try getNextVariable() }
        try interp.getRightParen()
        let height = Double(open.image.height)
        if toScaled {
            x.setValue((x.getValue() - cal.xOrigin) * cal.pixelWidth)
            let yv = cal.invertY ? (height - y.getValue() - 1 - cal.yOrigin) : (y.getValue() - cal.yOrigin)
            y.setValue(yv * cal.pixelHeight)
            if let z { z.setValue((z.getValue() - cal.zOrigin) * cal.pixelDepth) }
        } else {
            x.setValue(x.getValue() / cal.pixelWidth + cal.xOrigin)
            let yv = y.getValue() / cal.pixelHeight
            y.setValue(cal.invertY ? height - (yv + cal.yOrigin) - 1 : yv + cal.yOrigin)
            if let z { z.setValue(z.getValue() / cal.pixelDepth + cal.zOrigin) }
        }
    }

    // MARK: - Metadata

    func setMetadata() throws(MacroSignal) {
        var metadata: String?
        let arg1 = try getFirstString()
        if interp.nextToken() == ch(",") { metadata = try getLastString() } else { try interp.getRightParen() }
        let open = try image()
        var isInfo = false
        if metadata == nil {
            metadata = arg1
            if open.image.stack.count == 1 { isInfo = true }
            if arg1.hasPrefix("Info:") {
                metadata = String(arg1.dropFirst(5))
                isInfo = true
            }
        } else {
            isInfo = arg1.hasPrefix("info") || arg1.hasPrefix("Info")
        }
        if metadata?.isEmpty == true { metadata = nil }
        let value = metadata
        if isInfo {
            try modifyImage { $0.image.info = value }
        } else {
            try modifyImage { open in
                var stack = open.image.stack
                stack.labels[open.stackIndex] = value
                if let image = try? Hyperstack(
                    title: open.image.title, stack: stack, dimensions: open.image.dimensions,
                    calibration: open.image.calibration, channels: open.image.channels,
                    compositeMode: open.image.compositeMode, info: open.image.info, properties: open.image.properties)
                {
                    var replaced = image
                    replaced.encodedROI = open.image.encodedROI
                    replaced.encodedOverlay = open.image.encodedOverlay
                    open.image = replaced
                }
            }
        }
    }

    func getMetadata() throws(MacroSignal) -> String {
        let open = try image()
        var type: String
        if interp.nextToken() == ch("(") && interp.nextNextToken() != ch(")") {
            type = try getStringArg().lowercased()
        } else {
            try interp.getParens()
            type = open.image.stack.count > 1 ? "label" : "info"
        }
        if type.contains("info") { return open.image.info ?? "" }
        return open.image.stack.labels[open.stackIndex] ?? ""
    }

    /// `getInfo(key)` for keys about the current image; `nil` when the key isn't one.
    func imageInfo(forKey key: String, lowercaseKey: String) throws(MacroSignal) -> String? {
        switch lowercaseKey {
        case "slice.label":
            let open = try image()
            if open.image.stack.count == 1 { return open.image.properties["Slice_Label"] ?? "" }
            return Analyzer.shortSliceLabel(open.image.stack.labels[open.stackIndex]) ?? ""
        case "selection.name", "roi.name":
            return try image().roi?.name ?? ""
        case "image.description":
            return ""
        case "image.filename":
            return try image().image.properties["Mancora.path"].map(Self.javaFileName) ?? ""
        case "image.directory":
            guard let path = try image().image.properties["Mancora.path"] else { return "" }
            return (Self.javaParent(path) ?? "") + Self.separator
        case "image.subtitle":
            _ = try image()  // there's no window to give a subtitle in batch mode
            return ""
        default:
            break
        }
        if !javaContains(key, ".") {
            let open = try image()
            if let value = open.image.properties[key] { return value }
            if let info = open.image.info, let value = Self.infoProperty(info, key) { return value }
            return ""
        }
        return nil
    }

    /// `ImagePlus.getStringProperty(key)` from the Info text: "key: value" or "key = value" lines.
    static func infoProperty(_ info: String, _ key: String) -> String? {
        for line in info.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let s = String(line)
            for separator in [": ", " = ", "="] {
                if s.hasPrefix(key + separator) {
                    return String(s.dropFirst(key.count + separator.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    func imageInfo() throws(MacroSignal) -> String {
        try unsupported("getImageInfo")
    }

    func imageCalculator() throws(MacroSignal) {
        let op = try getFirstString()
        try interp.getComma()
        let id1 = try imageArgument()
        try interp.getComma()
        let id2 = try imageArgument()
        try interp.getRightParen()
        let title1 = session.context.images.first { $0.id == id1 }!.title
        let title2 = session.context.images.first { $0.id == id2 }!.title
        // ImageCalculator's macro options are the two titles and the operation.
        let previous = session.context.currentID
        try runCommand(
            "Image Calculator...", options: "image1=[\(title1)] operation=\(op.split(separator: " ").first.map(String.init) ?? op) image2=[\(title2)]"
                + (op.lowercased().contains("create") ? " create" : "") + (op.lowercased().contains("32") ? " 32-bit" : "")
                + (op.lowercased().contains("stack") ? " stack" : ""))
        _ = previous
    }

    /// An image given by title or ID.
    private func imageArgument() throws(MacroSignal) -> Int {
        if isStringArg() {
            let title = try getString()
            guard let match = session.context.images.first(where: { $0.title == title }) else {
                try interp.fail("Image not found")
            }
            return match.id
        }
        let id = jIntI(try interp.getExpression())
        guard session.context.images.contains(where: { $0.id == id }) else { try interp.fail("Image not found") }
        return id
    }

    // MARK: - Batch mode and settings

    func setBatchMode() throws(MacroSignal) {
        try interp.getLeftParen()
        if isStringArg() {
            let arg = try getString().lowercased()
            if arg == "hide" { session.batchMode = true } else if arg == "exit and display" { session.batchMode = false }
        } else {
            let arg = try interp.getBooleanExpression()
            try interp.checkBoolean(arg)
            session.batchMode = arg == 1
        }
        try interp.getRightParen()
    }

    func saveSettings() throws(MacroSignal) {
        try interp.getParens()
        session.savedSettings = session.context.settings
    }

    func restoreSettings() throws(MacroSignal) {
        try interp.getParens()
        if let saved = session.savedSettings { session.context.settings = saved }
    }

    func setOption() throws(MacroSignal) {
        let arg1 = try getFirstString()
        var state = true
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            let arg2 = try interp.getBooleanExpression()
            try interp.checkBoolean(arg2)
            state = arg2 != 0
        }
        try interp.getRightParen()
        let option = arg1.lowercased()
        func measurement(_ m: Measurements) {
            if state { session.context.settings.measurements.insert(m) } else { session.context.settings.measurements.remove(m) }
        }
        switch option {
        case _ where option.hasPrefix("black"): session.context.settings.blackBackground = state
        case _ where option.hasPrefix("display lab"): measurement(.labels)
        case _ where option.hasPrefix("limit to"): measurement(.limitToThreshold)
        case _ where option.hasPrefix("add to"): measurement(.addToOverlay)
        case "area": measurement(.area)
        case "mean": measurement(.mean)
        case _ where option.hasPrefix("perim"): measurement(.perimeter)
        case "stack position": measurement(.stackPosition)
        case _ where option.hasPrefix("std"): measurement(.standardDeviation)
        case _ where option.hasPrefix("expandablearrays"): expandableArrays = state
        case "scaleconversions": session.context.settings.scaleConversions = state
        case "changes", "debugmode", "openusingplugins", "queuemacros", "disableundo", "showrowindexes",
            "antialiasedtext", "savebatchoutput", "waitforcompletion", "interpolatelines", "flipfitsimages",
            "disablepopupmenu", "inverty":
            break
        case _
        where option.hasPrefix("show") || option.hasPrefix("openashyper") || option.hasPrefix("bicubic")
            || option.hasPrefix("wand") || option.contains("points") || option.hasPrefix("loop")
            || option.hasPrefix("jfilechooser") || option.hasPrefix("auto") || option.hasPrefix("converttomicrons")
            || option.hasPrefix("supportmacroundo") || option.hasPrefix("copyhead") || option.hasPrefix("monospaced")
            || option.hasPrefix("fullrange") || option.hasPrefix("opengrayscale") || option.hasPrefix("calibrate")
            || option.hasPrefix("mousewheel") || option.hasPrefix("setijmenubar"):
            break
        default:
            try interp.error("Invalid option")
        }
    }

    func isFunction() throws(MacroSignal) -> Double {
        let arg = try getStringArg().lowercased()
        var state = false
        if arg == "locked" {
            state = false
        } else if arg.contains("invert") && arg.contains("lut") {
            let open = try image()
            state = open.image.channels[open.channel].lut.isInverted
        } else if arg.contains("hyper") {
            state = try image().image.dimensions.isHyperstack
        } else if arg.contains("batch") {
            state = session.batchMode
        } else if arg.contains("applet") || arg.contains("caps") || arg.contains("animated") || arg.hasPrefix("fft") {
            state = false
        } else if arg.contains("virtual") {
            state = try image().image.stack.isVirtual
        } else if arg.contains("composite") {
            let open = try image()
            state = open.image.channels.count > 1 && open.image.pixelType != .rgb8
        } else if arg.contains("change") {
            state = false
        } else if arg.contains("binary") {
            let plane = try image().currentPlane
            if case .gray8(let p) = plane { state = p.allSatisfy { $0 == 0 || $0 == 255 } }
        } else if arg.contains("grayscale") {
            let open = try image()
            switch open.currentPlane {
            case .rgb8(let p): state = p.allSatisfy { ($0 >> 16) & 0xFF == ($0 >> 8) & 0xFF && ($0 >> 8) & 0xFF == $0 & 0xFF }
            default: state = open.image.channels[open.channel].lut.isGray && !open.image.channels[open.channel].lut.isInverted
            }
        } else if arg.hasPrefix("global") {
            state = false
        } else if arg == "inverty" {
            state = try image().image.calibration.invertY
        } else if arg.hasPrefix("area") {
            state = try image().roi?.isArea ?? false
        } else if arg.hasPrefix("line") {
            state = try image().roi.map { !$0.isArea && $0.kind != .point } ?? false
        } else {
            try interp.error("Invalid argument")
        }
        return state ? 1 : 0
    }

    // MARK: - Statistics

    func getStatistics(calibrated: Bool) throws(MacroSignal) {
        let count = try getFirstVariable()
        var mean: Variable?, minimum: Variable?, maximum: Variable?, std: Variable?, hist: Variable?
        interp.getToken()
        var arg = 1
        while interp.token == ch(",") {
            arg += 1
            switch arg {
            case 2: mean = try getVariable()
            case 3: minimum = try getVariable()
            case 4: maximum = try getVariable()
            case 5: std = try getVariable()
            case 6: hist = try getArrayVariable()
            default: try interp.error("')' expected")
            }
            interp.getToken()
        }
        if interp.token != ch(")") { try interp.error("')' expected") }
        let open = try image()
        let roi = open.roi
        if let roi, !roi.isArea { try unsupported("getStatistics with a line or point selection") }
        var region: MeasurementRegion?
        if let roi {
            do { region = try roi.measurementRegion(width: open.image.width, height: open.image.height) } catch {
                try interp.fail("\(error)")
            }
        }
        let options: Measurements = [.area, .mean, .minMax, .standardDeviation]
        let stats = MeasurementStatistics(
            plane: open.currentPlane, width: open.image.width, region: region, options: options,
            calibration: calibrated ? open.image.calibration : Calibration())
        count.setValue(calibrated ? stats.area : Double(stats.pixelCount))
        mean?.setValue(stats.mean)
        minimum?.setValue(stats.min)
        maximum?.setValue(stats.max)
        std?.setValue(stats.standardDeviation)
        if let hist {
            let histogram = Self.histogram(open.currentPlane, width: open.image.width, region: region) ?? []
            hist.setArray(VariableArray(histogram.map { Variable(Double($0)) }))
        }
    }

    /// The 256-bin histogram `ImageStatistics` gives for `region`: by value
    /// for 8-bit and RGB (the mean of R, G and B); from the minimum to the
    /// maximum in the region for 16-bit (`ShortStatistics`) and 32-bit
    /// (`FloatStatistics`) planes.
    static func histogram(_ plane: Plane, width: Int, region: MeasurementRegion?) -> [Int]? {
        let height = plane.count / max(width, 1)
        let r = region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height)
        var histogram = [Int](repeating: 0, count: 256)
        func forEach(_ body: (Int) -> Void) {
            for y in max(r.y, 0)..<max(max(r.y, 0), min(r.y + r.height, height)) {
                for x in max(r.x, 0)..<max(max(r.x, 0), min(r.x + r.width, width)) where r.contains(x, y) { body(y * width + x) }
            }
        }
        switch plane {
        case .gray8(let p): forEach { histogram[Int(p[$0])] += 1 }
        case .rgb8(let p):
            forEach {
                let c = p[$0]
                histogram[(Int((c >> 16) & 0xFF) + Int((c >> 8) & 0xFF) + Int(c & 0xFF)) / 3] += 1
            }
        case .gray16(let p):
            var counts = [Int](repeating: 0, count: 65536)
            forEach { counts[Int(p[$0])] += 1 }
            guard let lo = counts.firstIndex(where: { $0 > 0 }), let hi = counts.lastIndex(where: { $0 > 0 }) else { return histogram }
            let binSize = Double(hi - lo + 1) / 256
            let scale = 1 / binSize
            for i in lo...hi where counts[i] > 0 {
                histogram[min(255, jIntI(scale * Double(i - lo)))] += counts[i]
            }
        case .gray32Float(let p):
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            forEach {
                let v = Double(p[$0])
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            let scale = 256 / (hi - lo)
            forEach {
                let v = Double(p[$0])
                guard v >= lo && v <= hi else { return }
                histogram[min(255, jIntI(scale * (v - lo)))] += 1
            }
        }
        return histogram
    }

    func getHistogram() throws(MacroSignal) {
        try interp.getLeftParen()
        var values: Variable?
        if interp.nextToken() == NUMBER { _ = try interp.getExpression() } else { values = try getArrayVariable() }
        try interp.getComma()
        let counts = try getArrayVariable()
        try interp.getComma()
        let nBins = jIntI(try interp.getExpression())
        let open = try image()
        let bitDepth = open.image.pixelType.bitDepth
        if interp.nextToken() == ch(",") {
            _ = try getNextArg()
            _ = try getLastArg()
            if bitDepth == 8 || bitDepth == 24 { try interp.error("16 or 32-bit image required to set histMin and histMax") }
            try unsupported("getHistogram with histMin and histMax")
        }
        try interp.getRightParen()
        var region: MeasurementRegion?
        if let roi = open.roi {
            guard roi.isArea else { try unsupported("getHistogram with a line selection") }
            do { region = try roi.measurementRegion(width: open.image.width, height: open.image.height) } catch {
                try interp.fail("\(error)")
            }
        }
        var histogram: [Int]
        if nBins == 65536 && bitDepth == 16, case .gray16(let p) = open.currentPlane {
            histogram = [Int](repeating: 0, count: 65536)
            let width = open.image.width, height = open.image.height
            let r = region ?? MeasurementRegion(x: 0, y: 0, width: width, height: height)
            for y in max(r.y, 0)..<min(r.y + r.height, height) {
                for x in max(r.x, 0)..<min(r.x + r.width, width) where r.contains(x, y) { histogram[Int(p[y * width + x])] += 1 }
            }
        } else if nBins == 256, (bitDepth == 8 || bitDepth == 24),
            let h = Self.histogram(open.currentPlane, width: open.image.width, region: region)
        {
            histogram = h
            if let values {
                let cal = open.image.calibration
                var array: [Double] = []
                var value = cal.calibratedValue(0)
                let increment = cal.valueFunction != nil ? (cal.calibratedValue(256) - cal.calibratedValue(0)) / 256 : 1
                for _ in 0..<256 {
                    array.append(value)
                    value += increment
                }
                values.setArray(VariableArray(array.map { Variable($0) }))
            }
        } else {
            try unsupported("getHistogram with \(nBins) bins on \(bitDepth)-bit images")
        }
        if let array = counts.getArray(), array.count == histogram.count {
            for (i, v) in histogram.enumerated() { array[i].setValue(Double(v)) }
        } else {
            counts.setArray(VariableArray(histogram.map { Variable(Double($0)) }))
        }
    }

    func getLut() throws(MacroSignal) {
        let reds = try getFirstArrayVariable()
        try interp.getComma()
        let greens = try getArrayVariable()
        let blues = try getLastArrayVariable()
        let open = try image()
        if open.image.pixelType == .rgb8 { try interp.fail("Non-RGB image expected") }
        let lut = open.image.channels[open.channel].lut
        reds.setArray(VariableArray(lut.reds.map { Variable(Double($0)) }))
        greens.setArray(VariableArray(lut.greens.map { Variable(Double($0)) }))
        blues.setArray(VariableArray(lut.blues.map { Variable(Double($0)) }))
    }

    func getValue() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        if !isStringArg() {
            let x = try interp.getExpression()
            let y = try getLastArg()
            let open = try image()
            let ix = jIntI(x), iy = jIntI(y)
            let width = open.image.width, height = open.image.height
            if x == Double(ix) && y == Double(iy) {
                guard ix >= 0, ix < width, iy >= 0, iy < height else { return .nan }
                let raw = open.currentPlane.value(at: iy * width + ix)
                return open.image.pixelType == .gray32Float ? raw : open.image.calibration.calibratedValue(raw)
            }
            return Self.interpolatedValue(open.currentPlane, width: width, height: height, x, y)
        }
        let key = try getString()
        try interp.getRightParen()
        switch key {
        case "rgb.foreground": return Double(session.foreground)
        case "rgb.background": return Double(session.background)
        case "results.count": return Double(session.context.results.count)
        case "selection.size":
            guard let roi = try image().roi else { return 0 }
            return Double(Self.roiSize(roi))
        case "selection.width":
            guard let roi = try image().roi else { try interp.fail("No selection") }
            return Double(roi.strokeWidth)
        case "done": return interp.done ? 1 : 0
        case "image.size":
            let open = try image()
            return Double(open.image.width * open.image.height * open.image.stack.count * open.image.pixelType.bytesPerPixel)
        default: break
        }
        if key.contains("foreground") || key.contains("background") {
            let open = try image()
            let color = key.contains("foreground") ? session.foreground : session.background
            if open.image.pixelType == .rgb8 { return Double(color) }
            let saved = (session.drawingColor, session.drawingValue)
            session.drawingColor = color
            session.drawingValue = nil
            defer { (session.drawingColor, session.drawingValue) = saved }
            return drawingValue(for: open)
        }
        if key.hasPrefix("Length") { try unsupported("getValue(\"Length\")") }
        for heading in ResultsTable.standardHeadings where key.hasPrefix(heading) {
            return try measuredValue(key)
        }
        try interp.error("Invalid key")
        return 0
    }

    /// `IJ.getValue(imp, measurement)`: one measurement of the current plane and selection.
    private func measuredValue(_ keyIn: String) throws(MacroSignal) -> Double {
        var key = keyIn
        var options = ""
        if let space = key.firstIndex(of: " ") {
            options = String(key[key.index(after: space)...])
            key = String(key[..<space])
        }
        let open = try image()
        var measurements = Measurements.allStatistics.union(.stackPosition)
        if options.contains("limit") { measurements.insert(.limitToThreshold) }
        var image = open.image
        if options.contains("raw") { image.calibration = Calibration() }
        if let roi = open.roi, !roi.isArea || roi.kind == .composite { try unsupported("getValue with a line selection") }
        var table = ResultsTable()
        let threshold = open.threshold.flatMap { $0.lower <= $0.upper ? $0.lower...$0.upper : nil }
        do {
            try Analyzer.measure(
                image, channel: open.channel, slice: open.slice, frame: open.frame, roi: open.roi, options: measurements,
                threshold: threshold, into: &table)
        } catch {
            try interp.fail("\(error)")
        }
        guard table.columns.contains(key) else { return .nan }
        return table.number(key, row: 0)
    }

    /// `Roi.size()`: the number of points (polygon vertices, 4 for rectangles).
    static func roiSize(_ roi: Roi) -> Int {
        switch roi.shape {
        case .rectangle(_, let corner): corner > 0 ? roi.outline()?.xs.count ?? 0 : 4
        case .oval: roi.outline()?.xs.count ?? 0
        case .polygon(let p): p.vertices.count
        case .line: 2
        case .points(let p): p.vertices.count
        case .opaque: 0
        }
    }

    // MARK: - Lists

    func getList() throws(MacroSignal) -> VariableArray {
        let key = try getStringArg()
        switch key {
        case "image.titles":
            return VariableArray(session.context.images.map { Variable($0.title) })
        case "window.titles", "window.list":
            return VariableArray(session.context.tables.keys.sorted().map { Variable($0) })
        case "threshold.methods":
            return VariableArray(AutoThresholder.Method.allCases.map { Variable($0.rawValue) })
        case "LUTs":
            return VariableArray(LUT.builtIn.map { Variable($0.name) })
        case "java.properties":
            return VariableArray(["os.name", "file.separator", "line.separator", "user.home", "user.dir"].map { Variable($0) })
        default:
            try interp.fail("Unvalid key")
        }
    }

    func getProfile() throws(MacroSignal) -> VariableArray? {
        try unsupported("getProfile")
    }
}

/// An `ImageProcessor`'s drawing on a plane: the fill value, line width and
/// clipping (the whole image) it draws with.
struct Canvas {
    var plane: Plane
    let width: Int
    let height: Int
    let value: Double
    let lineWidth: Int

    init(plane: Plane, width: Int, height: Int, value: Double, lineWidth: Int) {
        self.plane = plane
        self.width = width
        self.height = height
        self.value = value
        self.lineWidth = max(lineWidth, 1)
    }

    mutating func drawPixel(_ x: Int, _ y: Int) {
        if x >= 0 && x < width && y >= 0 && y < height { EditCommands.putFill(&plane, y * width + x, value) }
    }

    /// `ImageProcessor.lineTo`: from the pen to (x2, y2), skipping the part outside the image.
    mutating func lineTo(_ x2: Int, _ y2: Int, pen: inout (x: Int, y: Int)) {
        let xMin = 0 - lineWidth / 2 - 1, xMax = width - 1 + lineWidth / 2 + 1
        let yMin = 0 - lineWidth / 2 - 1, yMax = height - 1 + lineWidth / 2 + 1
        let dx = x2 - pen.x, dy = y2 - pen.y
        let n = max(abs(dx), abs(dy))
        let xinc = dx != 0 ? Double(dx) / Double(n) : 0
        let yinc = dy != 0 ? Double(dy) / Double(n) : 0
        var x = Double(pen.x), y = Double(pen.y)
        pen = (x2, y2)
        var i1 = 0
        if dx > 0 {
            i1 = max(i1, jIntI((Double(xMin) - x) / xinc))
        } else if dx < 0 {
            i1 = max(i1, jIntI((Double(xMax) - x) / xinc))
        } else if x < Double(xMin) || x > Double(xMax) {
            return
        }
        if dy > 0 {
            i1 = max(i1, jIntI((Double(yMin) - y) / yinc))
        } else if dy < 0 {
            i1 = max(i1, jIntI((Double(yMax) - y) / yinc))
        } else if y < Double(yMin) || y > Double(yMax) {
            return
        }
        var i2 = n
        if dx > 0 {
            i2 = min(i2, jIntI((Double(xMax) - x) / xinc))
        } else if dx < 0 {
            i2 = min(i2, jIntI((Double(xMin) - x) / xinc))
        }
        if dy > 0 {
            i2 = min(i2, jIntI((Double(yMax) - y) / yinc))
        } else if dy < 0 {
            i2 = min(i2, jIntI((Double(yMin) - y) / yinc))
        }
        x += Double(i1) * xinc
        y += Double(i1) * yinc
        guard i1 <= i2 else { return }
        for _ in i1...i2 {
            let px = Int(Int32(truncatingIfNeeded: javaMathRound(x))), py = Int(Int32(truncatingIfNeeded: javaMathRound(y)))
            switch lineWidth {
            case 1: drawPixel(px, py)
            case 2:
                drawPixel(px, py)
                drawPixel(px - 1, py)
                drawPixel(px, py - 1)
                drawPixel(px - 1, py - 1)
            default: drawDot(px, py)
            }
            x += xinc
            y += yinc
        }
    }

    /// `ImageProcessor.drawDot`: a disk `lineWidth` across.
    mutating func drawDot(_ xcenter: Int, _ ycenter: Int) {
        var r = Double(lineWidth) / 2.0
        let xmin = jIntI(Double(xcenter) - r + 0.5), ymin = jIntI(Double(ycenter) - r + 0.5)
        let xmax = xmin + lineWidth, ymax = ymin + lineWidth
        if xmin < 0 || ymin < 0 || xmax > width - 1 || ymax > height - 1 {
            let r2 = r * r
            r -= 0.5
            let xoffset = Double(xmin) + r, yoffset = Double(ymin) + r
            for y in ymin..<ymax {
                for x in xmin..<xmax {
                    let xx = Double(x) - xoffset, yy = Double(y) - yoffset
                    if xx * xx + yy * yy <= r2 { drawPixel(x, y) }
                }
            }
        } else if let mask = try? Roi(.oval(.integer(x: 0, y: 0, width: Int32(lineWidth), height: Int32(lineWidth)))).mask() {
            for y in 0..<lineWidth {
                for x in 0..<lineWidth where mask[x: x, y: y] { drawPixel(xmin + x, ymin + y) }
            }
        }
    }

    mutating func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard w > 0 && h > 0 else { return }
        for yy in max(y, 0)..<max(max(y, 0), min(y + h, height)) {
            for xx in max(x, 0)..<max(max(x, 0), min(x + w, width)) { drawPixel(xx, yy) }
        }
    }

    mutating func drawRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, pen: inout (x: Int, y: Int)) {
        guard w >= 1 && h >= 1 else { return }
        let e = lineWidth == 1 ? 1 : 0
        pen = (x, y)
        lineTo(x + w - e, y, pen: &pen)
        lineTo(x + w - e, y + h - e, pen: &pen)
        lineTo(x, y + h - e, pen: &pen)
        lineTo(x, y, pen: &pen)
    }

    /// `fillOval`: the pixels of the `OvalRoi`'s mask.
    mutating func fillOval(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard w > 0 && h > 0, w * h <= 4 * width * height,
            let mask = try? Roi(.oval(.integer(x: Int32(x), y: Int32(y), width: Int32(w), height: Int32(h)))).mask()
        else { return }
        let b = mask.bounds
        for yy in b.y..<(b.y + b.height) {
            for xx in b.x..<(b.x + b.width) where mask[x: xx, y: yy] { drawPixel(xx, yy) }
        }
    }

    /// `drawOval`: the outline the wand traces around the oval's mask.
    mutating func drawOval(_ x: Int, _ y: Int, _ w: Int, _ h: Int, pen: inout (x: Int, y: Int)) {
        guard w > 0 && h > 0, w * h <= 4 * width * height,
            let mask = try? Roi(.oval(.integer(x: 0, y: 0, width: Int32(w), height: Int32(h)))).mask()
        else { return }
        let values = mask.pixels.map { $0 ? Float(255) : 0 }
        let outline = Wand.outline(
            values: values, width: mask.bounds.width, x: w / 2, y: h / 2, lower: 255, upper: 255, mode: .legacy)
        guard let first = outline.xs.first else { return }
        pen = (Int(first) + x, Int(outline.ys[0]) + y)
        for (px, py) in zip(outline.xs, outline.ys) { lineTo(Int(px) + x, Int(py) + y, pen: &pen) }
        lineTo(Int(first) + x, Int(outline.ys[0]) + y, pen: &pen)
    }
}
