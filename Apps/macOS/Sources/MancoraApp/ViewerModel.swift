import AppKit
import CoreGraphics
import MancoraBridge
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraMacro
import MancoraProcess
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
    /// The Brightness & Contrast and image inspector is showing.
    var showsInspector = true
    /// A command waiting for its dialog's answers.
    var pendingDialog: PendingDialog?

    /// The selection being drawn, shown instead of the image's.
    var draft: Roi?
    /// The vertices placed so far with the polygon, segmented line or angle tool.
    var vertices: [Roi.IntPoint] = []
    /// The pointer over the image, in pixels.
    private(set) var pointer: CGPoint?
    /// The size and position of the selection being drawn, for the status bar.
    var selectionText: String?
    @ObservationIgnored var gesture: SelectionGesture?
    /// The scale the canvas shows the image at (for Zoom to Fit, the fitted one).
    @ObservationIgnored var displayedScale = 1.0

    /// The image's threshold (raw values), shown in red; commands use it.
    var threshold: ThresholdLevels?
    /// The Threshold section is showing in the inspector.
    var showsThreshold = false
    var thresholdMethod = AutoThresholder.Method.default
    var thresholdDark = false
    var thresholdStack = false
    /// The plane's 256-bin histogram over its range of values, for the Brightness & Contrast
    /// and Threshold controls. Counted while the inspector shows.
    private(set) var histogram: [Int] = []
    /// The values the histogram's bins span.
    private(set) var histogramRange: ClosedRange<Double> = 0...255

    struct LastCommand: Equatable {
        let name: String
        let options: String
    }

    /// For Process ▸ Repeat Command.
    private(set) var lastCommand: LastCommand?
    /// The window's undo manager: commands that change the image can be undone.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// What the last ImageJ command or macro logged or measured.
    var report: String?

    @ObservationIgnored private var autoState = BrightnessContrast.AutoState()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Counts the images shown (`show`, `replace`), so a histogram is counted again only when pixels change.
    @ObservationIgnored private var imageGeneration = 0
    @ObservationIgnored private var histogramSource: HistogramSource?

    private struct HistogramSource: Equatable {
        var generation: Int
        var channel: Int
        var slice: Int
        var frame: Int
    }

    var hasImage: Bool { image != nil }
    /// Unsaved changes (ImageJ's `ImagePlus.changes`): set when a command
    /// changes the image, cleared when it's opened or saved.
    var isChanged = false

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

    /// File ▸ Open: images natively (TIFF, ZIP, PNG, GIF), ROI sets into
    /// the ROI Manager, a `.roi` file as the selection, and tables into
    /// the Results window; other formats through ImageJ or Bio-Formats.
    func open(_ request: OpenRequest) {
        isBusy = true
        let path = request.url.path, virtual = request.virtual
        let isTIFF = ["tif", "tiff", "btf", "tf8"].contains(request.url.pathExtension.lowercased())
        Task {
            // Large files take a while to decode; keep the window responsive.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImageOpener.Contents, MancoraIOError> in
                do throws(MancoraIOError) {
                    return .success(try ImageOpener.open(path: path, options: .init(virtual: virtual)))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(.image(let image)):
                isBusy = false
                show(image, from: request.url)
            case .success(.rois(let entries)):
                isBusy = false
                AppSession.shared.roiManager.entries += entries.map { .init(name: $0.name, roi: $0.roi) }
                AppSession.shared.requestWindow("roi-manager")
            case .success(.roi(let roi)):
                isBusy = false
                if hasImage { setSelection(roi) } else { errorMessage = "Open an image first: \(request.url.lastPathComponent) is a selection." }
            case .success(.table(let table, let title)):
                isBusy = false
                AppSession.shared.showTable(table, title: title)
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
        AppSession.shared.register(self)
        self.image = image
        imageGeneration += 1
        fileURL = url
        channel = 0
        slice = 0
        frame = 0
        zoom = .fit
        autoState.reset()
        threshold = nil
        isChanged = false
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

    /// File ▸ Save As ▸ ZIP, PNG or GIF: the format ImageJ writes (PNG and
    /// GIF save the plane shown).
    func presentSavePanel(as format: ImageSaver.Format, extension ext: String) {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        let base = (image.title as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let position = ImageSaver.Position(channel: channel, slice: slice, frame: frame)
        do throws(MancoraIOError) {
            try ImageSaver.write(image, to: url.path, format: format, position: position)
            AppRecorder.shared.recordLine("saveAs(\"\(ext == "zip" ? "ZIP" : ext.uppercased())\", \"\(MacroRecorder.escape(url.path))\");")
        } catch {
            errorMessage = error.description
        }
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
                didSave(to: url)
            }
        }
    }

    /// Saves now, for the questions asked on close and quit; returns whether it saved.
    func saveNow(to url: URL) -> Bool {
        guard let image else { return false }
        do throws(MancoraIOError) {
            try TIFFExporter.write(image, to: url.path)
        } catch {
            errorMessage = error.description
            return false
        }
        didSave(to: url)
        return true
    }

    private func didSave(to url: URL) {
        image?.title = url.lastPathComponent
        fileURL = url
        isChanged = false
        AppRecorder.shared.recordSave(url)
    }

    /// File ▸ Save: over the TIFF the image came from, else Save As.
    func saveInPlace() {
        if let fileURL, ["tif", "tiff"].contains(fileURL.pathExtension.lowercased()) {
            save(to: fileURL)
        } else {
            presentSavePanel()
        }
    }

    // MARK: Commands and the Java bridge

    /// Runs an ImageJ command on this image: natively when Mancora has it,
    /// otherwise in ImageJ through the bridge. Returns files for the new
    /// images it made, for the caller to open in new windows.
    /// Runs a menu command as ImageJ does: one with a dialog asks for its
    /// options first (ImageJ's own dialog, read through the bridge and
    /// shown natively), then runs natively or in ImageJ.
    func perform(_ name: String, bridge: AppBridge) async -> [URL] {
        if Self.mayHaveDialog(name) {
            if !bridge.isReady { await bridge.start() }
            if bridge.isReady {
                do {
                    let dialogs = try await bridge.describeDialog(name, images: dialogImages(for: name))
                    if !dialogs.dialogs.isEmpty {
                        pendingDialog = PendingDialog(command: name, dialogs: dialogs, stackSize: image?.stack.count ?? 1)
                        return []
                    }
                } catch {
                    errorMessage = "\(error)"
                    return []
                }
            }
        }
        // Without a dialog these would wipe settings (distance 0 removes the scale).
        if Self.needsAnswers.contains(name) {
            errorMessage = "\(name) needs ImageJ for its dialog: install Java 11 or later, then try again."
            return []
        }
        return await runRecorded(name, options: "", bridge: bridge)
    }

    /// Commands whose default options undo what they set.
    static let needsAnswers: Set<String> = ["Set Scale...", "Set Measurements...", "Properties...", "Calibrate..."]

    /// The images a command's dialog chooses from: all of them for a command
    /// that combines images (this one last), else this one.
    private func dialogImages(for name: String) -> [Hyperstack] {
        let others = AppSession.multiImageCommands.contains(name)
            ? AppSession.shared.imageViewers.filter { $0 !== self }.compactMap(\.image) : []
        return others + (image.map { [$0] } ?? [])
    }

    /// Runs a command and remembers it for Repeat Command.
    func runRecorded(_ name: String, options: String, bridge: AppBridge) async -> [URL] {
        lastCommand = LastCommand(name: name, options: options)
        return await runCommand(name, options: options, bridge: bridge)
    }

    /// ImageJ ends the names of commands that ask for something with "...".
    static func mayHaveDialog(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).hasSuffix("...")
    }

    /// In [+] (`factor` above 1) and Out [-]: the next of ImageJ's zoom levels.
    func zoom(by factor: Double) {
        let current: Double
        switch zoom {
        case .scale(let s): current = s
        case .fit: current = displayedScale
        }
        let levels = Self.zoomLevels
        if factor > 1 {
            zoom = .scale(levels.first { $0 > current * (1 + 1e-9) } ?? levels[levels.count - 1])
        } else {
            zoom = .scale(levels.last { $0 < current * (1 - 1e-9) } ?? levels[0])
        }
    }

    /// `ImageCanvas.zoomLevels`.
    static let zoomLevels: [Double] = [
        1 / 72.0, 1 / 48.0, 1 / 32.0, 1 / 24.0, 1 / 16.0, 1 / 12.0, 1 / 8.0, 1 / 6.0, 1 / 4.0, 1 / 3.0, 1 / 2.0, 0.75, 1, 1.5,
        2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    /// File ▸ Revert: the file as saved.
    func revert() {
        guard let fileURL else { return }
        open(OpenRequest(url: fileURL))
    }

    /// Runs a command on this window's image, natively (off the main thread,
    /// with every open image available and the session's results and
    /// settings) or in ImageJ; changed images update their windows, and
    /// new ones come back to open in their own.
    func runCommand(_ name: String, options: String = "", bridge: AppBridge) async -> [URL] {
        let registry = CommandRegistry.standard
        let session = AppSession.shared
        session.register(self)
        if registry.isNative(name) {
            var context = CommandContext()
            context.results = session.results
            context.tables = session.tables
            context.settings = session.settings
            var owners: [Int: ViewerModel] = [:]
            var originals: [Int: Hyperstack] = [:]
            for viewer in session.imageViewers where viewer !== self {
                guard let other = viewer.image else { continue }
                let id = context.add(other)
                owners[id] = viewer
                originals[id] = other
                let levels = viewer.threshold
                try? context.withCurrent(name) { (open: inout OpenImage) in open.threshold = levels }
            }
            if let image {
                let id = context.add(image)
                owners[id] = self
                originals[id] = image
                let (c, z, t, levels) = (channel, slice, frame, threshold)
                try? context.withCurrent(name) { (open: inout OpenImage) in
                    open.channel = c
                    open.slice = z
                    open.frame = t
                    open.threshold = levels
                }
            }
            isBusy = true
            let input = context
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CommandContext, CommandError> in
                var working = input
                do throws(CommandError) {
                    try registry.run(name, options: MacroOptions(options), in: &working)
                    return .success(working)
                } catch {
                    return .failure(error)
                }
            }.value
            isBusy = false
            switch outcome {
            case .success(let done):
                AppRecorder.shared.record(name, options: options)
                session.absorb(done)
                var created: [Hyperstack] = []
                for open in done.images {
                    if let owner = owners[open.id] {
                        if open.image != originals[open.id] { owner.replace(with: open.image) }
                        if open.threshold != owner.threshold { owner.setThreshold(open.threshold, render: true) }
                    } else {
                        created.append(open.image)
                    }
                }
                return saveForNewWindows(created)
            case .failure(let error):
                // Mancora has the command but not with these options: ImageJ does.
                guard case .notNative = error else {
                    errorMessage = "\(error)"
                    return []
                }
            }
        }
        isBusy = true
        defer { isBusy = false }
        // Commands that combine images get them all, this one last (and so active).
        let others = AppSession.multiImageCommands.contains(name)
            ? session.imageViewers.filter { $0 !== self }.compactMap(\.image) : []
        let images = others + (image.map { [$0] } ?? [])
        do {
            // ImageJ gets the threshold the way a macro sets it.
            let result: BridgeRunResult
            if let threshold, image != nil {
                let code = "setThreshold(\(threshold.lower), \(threshold.upper), \"raw\");\n"
                    + "run(\"\(MacroRecorder.escape(name))\", \"\(MacroRecorder.escape(options))\");\n"
                result = try await bridge.runMacro(code, images: images)
            } else {
                result = try await bridge.run(name, options: options, images: images)
            }
            AppRecorder.shared.record(name, options: options)
            return handle(result, inputCount: images.count, hasImage: image != nil)
        } catch {
            errorMessage = "\(error)"
            return []
        }
    }

    /// Runs macro code. `onError` hears of a failure, with the text of `errorMessage` and
    /// the line it happened on if known (the macro editor shows both).
    func runMacro(_ code: String, bridge: AppBridge, onError: ((String, Int?) -> Void)? = nil) async -> [URL] {
        isBusy = true
        defer { isBusy = false }
        if MacroSupport.unsupported(in: code, registry: .standard).isEmpty {
            let input = image
            let position = (channel, slice, frame)
            let shared = AppSession.shared
            let (startResults, startSettings, startManager) = (shared.results, shared.settings, shared.roiManager)
            // what the macro left (results, settings, log, the ROI Manager), its return
            // value and error, the input as the macro left it, and new images
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (CommandContext, RoiManagerList, String?, MacroError?, Hyperstack?, [Hyperstack]) in
                let session = MacroSession()
                session.batchMode = false
                session.context.results = startResults
                session.context.settings = startSettings
                session.roiManager = startManager
                var inputID: Int?
                if let input {
                    inputID = session.add(input)
                    try? session.context.withCurrent("") { (open: inout OpenImage) in
                        (open.channel, open.slice, open.frame) = position
                    }
                }
                var value: String?
                var failure: MacroError?
                do throws(MacroError) { value = try session.run(code) } catch { failure = error }
                var changed: Hyperstack?
                var created: [Hyperstack] = []
                for open in session.context.images {
                    if open.id == inputID {
                        if open.image != input { changed = open.image }
                    } else {
                        created.append(open.image)
                    }
                }
                var left = session.context
                left.log = session.logLines
                return (left, session.roiManager, value, failure, changed, created)
            }.value
            let (left, manager, value, failure, changed, created) = outcome
            if let changed { replace(with: changed) }
            shared.absorb(left)
            shared.roiManager = manager
            if let value { report = "Returned: \(value)" }
            if let failure {
                let text = "Macro Error: " + failure.description
                errorMessage = text
                onError?(text, failure.lineNumber > 0 ? failure.lineNumber : nil)
            }
            return saveForNewWindows(created)
        }
        do {
            return handle(try await bridge.runMacro(code, on: image), onError: onError)
        } catch {
            errorMessage = "\(error)"
            onError?("\(error)", nil)
            return []
        }
    }

    /// What ImageJ gave back: results and log lines go to the session, a
    /// changed current image (the last input) updates this window, new
    /// images open in their own.
    private func handle(
        _ result: BridgeRunResult, inputCount: Int = 1, hasImage: Bool = true, onError: ((String, Int?) -> Void)? = nil
    ) -> [URL] {
        AppSession.shared.absorb(result)
        var created: [Hyperstack] = []
        for output in result.images {
            if let replaced = output.replacesInput {
                if hasImage, replaced == inputCount - 1 { replace(with: output.image) }
            } else {
                created.append(output.image)
            }
        }
        if let error = result.macroError {
            let text = "Macro Error: " + error + (result.macroErrorLine.map { " in line \($0)" } ?? "")
            errorMessage = text
            onError?(text, result.macroErrorLine)
        } else if let value = result.value {
            report = "Returned: \(value)"
        }
        return saveForNewWindows(created)
    }

    /// Stores `roi` as the image's selection, without undo (ImageJ doesn't undo selections).
    func storeSelection(_ roi: Roi?) {
        image?.encodedROI = roi.map(RoiCodec.encode)
    }

    func replace(with changed: Hyperstack) {
        let dims = changed.dimensions
        if let previous = image {
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.replace(with: previous) }
            }
        }
        image = changed
        imageGeneration += 1
        isChanged = true
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
            pointer = nil
            return
        }
        let px = point.x / displaySize.width * CGFloat(image.width)
        let py = point.y / displaySize.height * CGFloat(image.height)
        if !vertices.isEmpty { pointer = CGPoint(x: px, y: py) }
        let x = Int(px)
        let y = Int(py)
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
        let (c, z, t, levels) = (channel, slice, frame, threshold)
        // The histogram is counted again only when the plane changes, not for each display range step.
        let source = HistogramSource(generation: imageGeneration, channel: c, slice: z, frame: t)
        let wantsHistogram = image.pixelType.usesLUT && (showsInspector || showsThreshold)
        let needsHistogram = wantsHistogram && (source != histogramSource || histogram.isEmpty)
        renderTask = Task {
            let (pixels, counted) = await Task.detached(priority: .userInitiated) {
                () -> ([UInt32], (bins: [Int], range: ClosedRange<Double>)?) in
                var pixels = DisplayMapper.render(image, channel: c, slice: z, frame: t)
                let plane = image.plane(channel: c, slice: z, frame: t)
                if let levels, image.dimensions.channels == 1 || image.compositeMode != .composite {
                    Self.paintThreshold(&pixels, plane: plane, levels: levels)
                }
                return (pixels, needsHistogram ? Self.histogram(of: plane) : nil)
            }.value
            guard !Task.isCancelled else { return }
            rendered = Self.makeCGImage(pixels, width: image.width, height: image.height)
            if let counted {
                histogram = counted.bins
                histogramRange = counted.range
                histogramSource = source
            }
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
