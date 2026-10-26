import AppKit
import CoreGraphics
import MancoraBridge
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraMacro
import Observation
import UniformTypeIdentifiers

/// What a viewer window should open: a file, read in full or as a virtual stack.
struct OpenRequest: Codable, Hashable {
    var url: URL
    var virtual = false
}

/// State for one viewer window: the open image, the position shown, its
/// display settings and the rendered bitmap.
@Observable
final class ViewerModel {
    enum Zoom: Equatable {
        case fit
        case scale(Double)
    }

    private(set) var image: Hyperstack?
    private(set) var rendered: CGImage?
    private(set) var fileURL: URL?
    private(set) var isBusy = false
    var errorMessage: String?
    var channel = 0
    var slice = 0
    var frame = 0
    var zoom = Zoom.fit
    /// The pixel under the pointer, as ImageJ's status bar shows it.
    private(set) var pointerText: String?

    /// Find Command (⌘L) is showing.
    var showsCommandFinder = false
    /// What the last ImageJ command or macro logged or measured.
    var report: String?

    @ObservationIgnored private var autoState = BrightnessContrast.AutoState()
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    var hasImage: Bool { image != nil }

    // MARK: Opening and saving

    func presentOpenPanel(virtual: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        // Mancora reads TIFF itself; other formats open in ImageJ through the bridge.
        if virtual { panel.allowedContentTypes = [.tiff] }
        panel.allowsMultipleSelection = false
        panel.title = virtual ? "Open as Virtual Stack" : "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// The bridge, for files Mancora can't read itself.
    @ObservationIgnored var bridge: AppBridge?

    func open(_ request: OpenRequest) {
        isBusy = true
        let path = request.url.path, virtual = request.virtual
        let isTIFF = ["tif", "tiff", "btf", "tf8"].contains(request.url.pathExtension.lowercased())
        Task {
            // Large files take a while to decode; keep the window responsive.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Hyperstack, MancoraIOError> in
                do throws(MancoraIOError) {
                    return .success(try TIFFImporter.read(path: path, options: .init(virtual: virtual)))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let image):
                isBusy = false
                show(image, from: request.url)
            case .failure(let error):
                // Not a TIFF, or a TIFF feature Mancora lacks: ImageJ, or Bio-Formats, may read it.
                var unsupported = false
                if case .unsupported = error { unsupported = true }
                if let bridge, !virtual, !isTIFF || unsupported {
                    await openInBridge(path, bridge: bridge, url: request.url, fallback: error.description)
                } else {
                    isBusy = false
                    errorMessage = error.description
                }
            }
        }
    }

    private func openInBridge(_ path: String, bridge: AppBridge, url: URL, fallback: String) async {
        defer { isBusy = false }
        do {
            let result = try await bridge.open(path)
            guard let first = result.images.first else {
                errorMessage = fallback
                return
            }
            show(first.image, from: nil)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func show(_ image: Hyperstack, from url: URL?) {
        self.image = image
        fileURL = url
        channel = 0
        slice = 0
        frame = 0
        zoom = .fit
        autoState.reset()
        render()
    }

    func presentSavePanel() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        let base = (image.title as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + ".tif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    /// Saves as an ImageJ-compatible TIFF that ImageJ and Fiji reopen as the same image.
    func save(to url: URL) {
        guard let image else { return }
        isBusy = true
        let path = url.path
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> MancoraIOError? in
                do throws(MancoraIOError) {
                    try TIFFExporter.write(image, to: path)
                    return nil
                } catch {
                    return error
                }
            }.value
            isBusy = false
            if let error {
                errorMessage = error.description
            } else {
                self.image?.title = url.lastPathComponent
                fileURL = url
                AppRecorder.shared.recordSave(url)
            }
        }
    }

    // MARK: Commands and the Java bridge

    /// Runs an ImageJ command on this image: natively when Mancora has it,
    /// otherwise in ImageJ through the bridge. Returns files for the new
    /// images it made, for the caller to open in new windows.
    func runCommand(_ name: String, options: String = "", bridge: AppBridge) async -> [URL] {
        let registry = CommandRegistry.standard
        if registry.isNative(name) {
            var context = CommandContext()
            if let image {
                context.add(image)
                let (c, z, t) = (channel, slice, frame)
                try? context.withCurrent(name) { (open: inout OpenImage) in
                    open.channel = c
                    open.slice = z
                    open.frame = t
                }
            }
            do {
                try registry.run(name, options: MacroOptions(options), in: &context)
                AppRecorder.shared.record(name, options: options)
                var created: [Hyperstack] = []
                for open in context.images {
                    if open.id == -1 { replace(with: open.image) } else { created.append(open.image) }
                }
                if !context.log.isEmpty { report = context.log.joined(separator: "\n") }
                return saveForNewWindows(created)
            } catch CommandError.notNative {
                // Mancora has the command but not with these options: ImageJ does.
            } catch {
                errorMessage = "\(error)"
                return []
            }
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await bridge.run(name, options: options, on: image)
            AppRecorder.shared.record(name, options: options)
            return handle(result)
        } catch {
            errorMessage = "\(error)"
            return []
        }
    }

    /// Runs ImageJ macro code with this image open (Plugins ▸ Macros ▸ Run):
    /// natively when Mancora has everything it uses, otherwise in ImageJ
    /// through the bridge.
    func runMacro(_ code: String, bridge: AppBridge) async -> [URL] {
        isBusy = true
        defer { isBusy = false }
        if MacroSupport.unsupported(in: code, registry: .standard).isEmpty {
            let input = image
            let position = (channel, slice, frame)
            // log, results, return value, error, the input as the macro left it, new images
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (String, ResultsTable, String?, String?, Hyperstack?, [Hyperstack]) in
                let session = MacroSession()
                session.batchMode = false
                var inputID: Int?
                if let input {
                    inputID = session.add(input)
                    try? session.context.withCurrent("") { (open: inout OpenImage) in
                        (open.channel, open.slice, open.frame) = position
                    }
                }
                var value: String?
                var failure: String?
                do throws(MacroError) { value = try session.run(code) } catch { failure = error.description }
                var changed: Hyperstack?
                var created: [Hyperstack] = []
                for open in session.context.images {
                    if open.id == inputID {
                        if open.image != input { changed = open.image }
                    } else {
                        created.append(open.image)
                    }
                }
                return (session.logText, session.context.results, value, failure, changed, created)
            }.value
            let (log, results, value, failure, changed, created) = outcome
            if let changed { replace(with: changed) }
            var lines: [String] = []
            if !log.isEmpty { lines.append(log) }
            if !results.isEmpty {
                let hasLabels = results.labels.contains { $0 != nil }
                lines.append(((hasLabels ? ["Label"] : []) + results.columns).joined(separator: "\t"))
                for row in 0..<results.count {
                    var cells = hasLabels ? [results.labels[row] ?? ""] : []
                    for column in results.columns {
                        if case .text(let t)? = results.value(column, row: row) {
                            cells.append(t)
                        } else {
                            cells.append(String(format: "%.4g", results.number(column, row: row)))
                        }
                    }
                    lines.append(cells.joined(separator: "\t"))
                }
            }
            if let value { lines.append("Returned: \(value)") }
            if !lines.isEmpty { report = lines.joined(separator: "\n") }
            if let failure { errorMessage = "Macro Error: " + failure }
            return saveForNewWindows(created)
        }
        do {
            return handle(try await bridge.runMacro(code, on: image))
        } catch {
            errorMessage = "\(error)"
            return []
        }
    }

    private func handle(_ result: BridgeRunResult) -> [URL] {
        var created: [Hyperstack] = []
        for output in result.images {
            if output.replacesInput == 0 { replace(with: output.image) } else { created.append(output.image) }
        }
        var lines: [String] = []
        if !result.log.isEmpty { lines.append(result.log) }
        if !result.results.isEmpty {
            lines.append(result.results.columns.joined(separator: "\t"))
            for row in result.results.rows {
                lines.append(row.map { cell -> String in
                    switch cell {
                    case .number(let v): String(format: "%.4g", v)
                    case .text(let t): t
                    case .empty: ""
                    }
                }.joined(separator: "\t"))
            }
        }
        if let value = result.value { lines.append("Returned: \(value)") }
        if !lines.isEmpty { report = lines.joined(separator: "\n") }
        return saveForNewWindows(created)
    }

    /// Keeps the position (within the new dimensions) when a command changes
    /// the image in place.
    private func replace(with changed: Hyperstack) {
        let dims = changed.dimensions
        image = changed
        channel = min(channel, dims.channels - 1)
        slice = min(slice, dims.slices - 1)
        frame = min(frame, dims.frames - 1)
        render()
    }

    /// New images go to new windows, which open files; write them to temporary TIFFs.
    private func saveForNewWindows(_ images: [Hyperstack]) -> [URL] {
        images.compactMap { image in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Mancora-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(BridgeFileName.safe(image.title))
            return (try? TIFFExporter.write(image, to: url.path)) != nil ? url : nil
        }
    }

    // MARK: LUTs

    func presentLUTPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lut") ?? .data, .plainText]
        panel.directoryURL = Self.bundledLUTDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyLUT(at: url)
    }

    func applyLUT(at url: URL) {
        do {
            apply(try LUTReader.read(path: url.path))
        } catch {
            errorMessage = "\(error)"
        }
    }

    func apply(_ lut: LUT) {
        guard var image, image.pixelType.usesLUT else { return }
        var display = image.channels[channel]
        display.lut = lut
        image.setDisplay(display, forChannel: channel)
        self.image = image
        render()
    }

    /// The LUTs shipped inside Mancora.app (`Contents/Resources/LUTs`);
    /// empty when running unbundled with `swift run`.
    static let bundledLUTDirectory = Bundle.main.url(forResource: "LUTs", withExtension: nil)

    static let bundledLUTs: [(name: String, url: URL)] = {
        guard let dir = bundledLUTDirectory,
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { ["lut", "txt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != "README.txt" }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    // MARK: Brightness and contrast

    /// The plane shown for the current channel, slice and frame.
    var currentPlane: Plane? {
        image?.plane(channel: channel, slice: slice, frame: frame)
    }

    var canAdjustContrast: Bool { image?.pixelType.usesLUT ?? false }

    var displayRange: ClosedRange<Double> {
        image.map { $0.channels[min(channel, $0.channels.count - 1)].displayRange } ?? 0...255
    }

    /// Slider limits: 0–255 for 8-bit data, otherwise the plane's values and
    /// the current range, whichever is wider (like ImageJ's B&C dialog).
    var sliderBounds: ClosedRange<Double> {
        guard let image else { return 0...255 }
        if image.pixelType == .gray8 { return 0...255 }
        var low = displayRange.lowerBound, high = displayRange.upperBound
        if let values = currentPlane?.valueRange() {
            if values.lowerBound.isFinite { low = min(low, values.lowerBound) }
            if values.upperBound.isFinite { high = max(high, values.upperBound) }
        }
        if !low.isFinite { low = 0 }
        if !high.isFinite { high = low + 1 }
        return low < high ? low...high : low...(low + 1)
    }

    func setDisplayRange(_ range: ClosedRange<Double>) {
        guard var image, image.pixelType.usesLUT else { return }
        var display = image.channels[channel]
        display.displayRange = range
        image.setDisplay(display, forChannel: channel)
        self.image = image
        render()
    }

    /// The B&C dialog's Auto button: each press saturates fewer pixels, as in ImageJ.
    func autoContrast() {
        guard let plane = currentPlane else { return }
        do {
            let result = try autoState.press(plane)
            if let range = result.displayRange { setDisplayRange(range) }
        } catch {
            errorMessage = "Auto contrast isn't available for this image (\(error))."
        }
    }

    func resetContrast() {
        autoState.reset()
        guard let plane = currentPlane, let range = BrightnessContrast.resetRange(for: plane) else { return }
        setDisplayRange(range)
    }

    func setCompositeMode(_ mode: CompositeMode) {
        image?.compositeMode = mode
        render()
    }

    func setChannelVisible(_ visible: Bool, channel c: Int) {
        guard var image else { return }
        var display = image.channels[c]
        display.isVisible = visible
        image.setDisplay(display, forChannel: c)
        self.image = image
        render()
    }

    /// Called when the channel, slice or frame changes.
    func positionChanged() {
        autoState.reset()
        render()
    }

    // MARK: Pointer readout

    func pointerMoved(to point: CGPoint?, displaySize: CGSize) {
        guard let image, let point, displaySize.width > 0, displaySize.height > 0 else {
            pointerText = nil
            return
        }
        let x = Int(point.x / displaySize.width * CGFloat(image.width))
        let y = Int(point.y / displaySize.height * CGFloat(image.height))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y), let plane = currentPlane else {
            pointerText = nil
            return
        }
        let cal = image.calibration
        var text = "x=\(x), y=\(y)"
        if cal.isSpatiallyCalibrated {
            let cx = (Double(x) - cal.xOrigin) * cal.pixelWidth, cy = (Double(y) - cal.yOrigin) * cal.pixelHeight
            text = "x=\(Self.short(cx)) \(cal.unit), y=\(Self.short(cy)) \(cal.unit) (\(x), \(y))"
        }
        let index = y * image.width + x
        if case .rgb8(let pixels) = plane {
            let c = pixels[index]
            text += ", value=\((c >> 16) & 0xFF),\((c >> 8) & 0xFF),\(c & 0xFF)"
        } else {
            let raw = plane.value(at: index)
            let calibrated = cal.calibratedValue(raw)
            text += ", value=\(Self.short(calibrated))" + (calibrated == raw ? "" : " (\(Self.short(raw)))")
        }
        pointerText = text
    }

    private static func short(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.4g", v)
    }

    // MARK: Rendering

    func render() {
        renderTask?.cancel()
        guard let image else {
            rendered = nil
            return
        }
        let (c, z, t) = (channel, slice, frame)
        renderTask = Task {
            let pixels = await Task.detached(priority: .userInitiated) {
                DisplayMapper.render(image, channel: c, slice: z, frame: t)
            }.value
            guard !Task.isCancelled else { return }
            rendered = Self.makeCGImage(pixels, width: image.width, height: image.height)
        }
    }

    /// Wraps DisplayMapper output (0xAARRGGBB words, BGRA in memory) without
    /// converting it.
    nonisolated static func makeCGImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: Smoke test

    /// Checks what a packaged app needs without showing any UI: decoding and
    /// rendering (in full and as a virtual stack), saving a TIFF, and
    /// reading it back unchanged.
    static func smokeTest(path: String) -> Bool {
        guard let image = try? TIFFImporter.read(path: path),
            let lazy = try? TIFFImporter.read(path: path, options: .init(virtual: true)),
            lazy.stack.isVirtual, lazy.stack == image.stack,
            makeCGImage(DisplayMapper.render(image), width: image.width, height: image.height) != nil
        else { return false }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-smoke-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? TIFFExporter.write(image, to: copy.path)) != nil,
            let reread = try? TIFFImporter.read(path: copy.path)
        else { return false }
        return reread.stack == image.stack && reread.dimensions == image.dimensions
            && reread.channels.map(\.displayRange) == image.channels.map(\.displayRange)
    }
}
