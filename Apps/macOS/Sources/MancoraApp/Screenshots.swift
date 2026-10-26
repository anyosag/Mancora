import AppKit
import CoreGraphics
import Foundation
import MancoraBridge
import MancoraCore
import MancoraMacro
import SwiftUI

// `Mancora --screenshots <folder>`: opens real windows, puts the app in each
// state a design review wants to see (no image, the inspector, a threshold,
// selections, a hyperstack, the ROI Manager, Results, plots, the macro editor, the recorder,
// a command dialog, Find Command, Update Sites, the Image menu), saves a PNG
// of the window in light and in dark mode, writes `index.md`, and exits.
//
// How windows are opened: the first window's SwiftUI scene hands its
// `openWindow` action to the run (see `screenshotDriver`), and the run opens
// the others as the menus do: `openWindow(id: "viewer", value:)` for an image,
// `openWindow(id:)` for the tool windows, `PlotWindows.open` for plots,
// and the same `ViewerModel` and `AppSession` calls the commands make.
//
// How they are captured: `cacheDisplay` of the window's frame view
// (`contentView.superview`, so the title bar and toolbar are in the picture),
// which needs no screen-recording permission. If that picture is blank, or
// fails, `/usr/sbin/screencapture -l <window number> -o` takes it instead.
// A sheet (the command dialog, Find Command) is drawn over its window.

enum Screenshots {
    /// Where the PNGs and `index.md` go; set when the app was launched with `--screenshots`.
    static var outputDirectory: URL?

    static var isActive: Bool { outputDirectory != nil }

    private static var hasStarted = false

    /// How many pictures were saved, for the exit status of a run that is cut short.
    nonisolated(unsafe) static var captured = 0

    static func configure(path: String) {
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Starts the run (once) from the first window.
    static func startOnce(bridge: AppBridge, openWindow: OpenWindowAction) {
        guard let directory = outputDirectory, !hasStarted else { return }
        hasStarted = true
        let run = ScreenshotRun(directory: directory, bridge: bridge, openWindow: openWindow)
        // Not tied to the window's task: closing that window must not stop the run.
        Task {
            let status = await run.execute()
            exit(status)
        }
    }

    nonisolated static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Ends a run that hangs (a menu that never closes, a dialog nobody answers).
    nonisolated static func startWatchdog(after seconds: Double, directory: URL) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { @Sendable in
            report("screenshots: gave up after \(Int(seconds)) seconds")
            appendNote("The run was cut off after \(Int(seconds)) seconds; the state under Running was the last one begun.", to: directory)
            exit(captured > 0 ? 0 : 1)
        }
    }

    nonisolated static func appendNote(_ note: String, to directory: URL) {
        let index = directory.appendingPathComponent("index.md")
        let existing = (try? String(contentsOf: index, encoding: .utf8)) ?? ""
        try? (existing + "\n" + note + "\n").write(to: index, atomically: true, encoding: .utf8)
    }
}

extension View {
    /// Starts the screenshot run from this window when the app was launched with `--screenshots`.
    func screenshotDriver(bridge: AppBridge) -> some View {
        modifier(ScreenshotDriver(bridge: bridge))
    }
}

struct ScreenshotDriver: ViewModifier {
    let bridge: AppBridge
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task { Screenshots.startOnce(bridge: bridge, openWindow: openWindow) }
    }
}

// MARK: The run

final class ScreenshotRun {
    struct Shot {
        let file: String
        let detail: String
        let method: String
        let size: String
        let note: String?
    }

    struct Problem {
        let state: String
        let reason: String
    }

    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// An image window, and the model behind it.
    struct Opened {
        let window: NSWindow
        let model: ViewerModel
    }

    struct Taken {
        let method: String
        let size: String
        let note: String?
    }

    private let directory: URL
    private let bridge: AppBridge
    private let openWindow: OpenWindowAction
    private let startedAt = Date()
    private var fixtures: URL?
    private var shots: [Shot] = []
    private var problems: [Problem] = []
    private var running: String?
    private var gray: Opened?
    private var screencaptureFailures = 0
    /// Also save screencapture's picture of each window, to compare with the in-process one.
    private let comparesWithScreencapture = ProcessInfo.processInfo.environment["MANCORA_SCREENSHOTS_COMPARE"] != nil

    init(directory: URL, bridge: AppBridge, openWindow: OpenWindowAction) {
        self.directory = directory
        self.bridge = bridge
        self.openWindow = openWindow
    }

    /// Runs every state; the exit status is 1 only when nothing was captured.
    func execute() async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Screenshots.report("screenshots: cannot create \(directory.path): \(error)")
            return 1
        }
        Screenshots.startWatchdog(after: 480, directory: directory)
        // A new image window must be a window of its own, not a tab of the first.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.activate()
        setAppearance(dark: false)
        fixtures = Self.findFixtures()
        Screenshots.report("screenshots: fixtures at \(fixtures?.path ?? "(not found)")")
        await runStates()
        // Find Command starts the Java helper; don't leave it running.
        await bridge.stop()
        running = nil
        writeIndex()
        Screenshots.report("screenshots: \(shots.count) picture(s), \(problems.count) problem(s), see \(directory.path)/index.md")
        return shots.isEmpty ? 1 : 0
    }

    // MARK: States

    private func runStates() async {
        await state("01", "no-image") {
            guard let window = await poll(timeout: 30, { Self.window(titled: "Mancora") }) else {
                throw Failure("the first window never appeared")
            }
            await settle(1.0)
            await shoot("01", "no-image", "The app with no image open", window)
        }

        await state("02", "inspector") {
            let url = try fixture("tiff/tf-gray8-none-le.tif")
            let opened = try await open(url)
            gray = opened
            opened.model.showsInspector = true
            await shoot("02", "inspector", "An image window with the inspector (brightness and contrast)", opened.window)
        }

        await state("03", "threshold") {
            let g = try grayscale()
            g.model.showsThreshold = true
            g.model.autoThreshold()
            if g.model.threshold == nil {
                // Auto failed (and said so in an alert, which doesn't belong in the picture): set levels by hand.
                g.model.errorMessage = nil
                g.model.setThresholdLevels(lower: 64, upper: 192)
            }
            defer {
                g.model.resetThreshold()
                g.model.showsThreshold = false
            }
            await settle(1.0)
            await shoot("03", "threshold", "The inspector's Threshold section, with a threshold set", g.window)
        }

        await state("04", "selection-rectangle") {
            let g = try grayscale()
            AppSession.shared.tool = .rectangle
            g.model.setSelection(Roi(.rectangle(.integer(x: 5, y: 4, width: 18, height: 11))))
            await settle(0.5)
            await shoot("04", "selection-rectangle", "A rectangle selection drawn on the image", g.window)
        }

        await state("04", "selection-oval") {
            let g = try grayscale()
            AppSession.shared.tool = .oval
            g.model.setSelection(Roi(.oval(.integer(x: 14, y: 3, width: 20, height: 16))))
            await settle(0.5)
            await shoot("04", "selection-oval", "An oval selection drawn on the image", g.window)
        }

        await state("05", "hyperstack") {
            let url = try fixture("tiff/ij-hyperstack-16bit.tif")
            let opened = try await open(url)
            opened.model.channel = 1
            opened.model.slice = 1
            opened.model.frame = 2
            opened.model.positionChanged()
            await settle(1.0)
            await shoot("05", "hyperstack", "A hyperstack (2 channels, 3 slices, 4 frames) with its C/Z/T sliders", opened.window)
        }

        await state("06", "roi-manager") {
            let g = try grayscale()
            guard let image = g.model.image else { throw Failure("the grayscale image is gone") }
            let session = AppSession.shared
            session.roiManager = RoiManagerList()
            for roi in Self.sampleRois {
                let label = AppSession.managerLabel(roi, image: image, sliceNumber: 1)
                var named = roi
                named.name = label
                session.roiManager.entries.append(.init(name: label, roi: named))
            }
            session.roiManager.selected = [1]
            session.showsAllRois = true
            defer { session.showsAllRois = false }
            let window = try await openTool("roi-manager", title: "ROI Manager")
            await settle(1.0)
            await shoot("06", "roi-manager", "The ROI Manager with four ROIs", window)
        }

        await state("07", "results") {
            let g = try grayscale()
            do throws(AppSession.ManagerError) {
                try g.model.measure(AppSession.shared.roiManager.entries.map(\.roi))
            } catch {
                throw Failure(error.text)
            }
            let window = try await openTool("results", title: "Results")
            await settle(1.0)
            await shoot("07", "results", "The Results table after Measure", window)
        }

        await state("08", "plot-profile") {
            let g = try grayscale()
            g.model.setSelection(Roi(.line(.init(x1: 1, y1: 2, x2: 35, y2: 20))))
            let window = try await openPlot("Plot Profile", titlePrefix: "Plot of", viewer: g.model)
            await settle(1.0)
            await shoot("08", "plot-profile", "A Plot Profile window", window)
        }

        await state("08", "histogram") {
            let g = try grayscale()
            g.model.setSelection(nil)
            let window = try await openPlot("Histogram", titlePrefix: "Histogram of", viewer: g.model)
            await settle(1.0)
            await shoot("08", "histogram", "A Histogram window", window)
        }

        await state("09", "macro-editor") {
            let (window, text) = try await openEditor()
            text.show(Self.sampleMacro)
            // The caret on the Measure line, so the status bar has a position to show.
            if let measure = Self.sampleMacro.range(of: "Measure") {
                text.setSelectedRange(NSRange(measure.lowerBound..<measure.lowerBound, in: Self.sampleMacro))
            }
            await settle(1.0)
            await shoot("09", "macro-editor", "The macro editor with a short macro", window)
        }

        await state("09b", "recorder") {
            let window = try await openTool("recorder", title: "Recorder")
            let recorder = AppRecorder.shared
            recorder.clear()
            recorder.isRecording = true
            recorder.recordLine("open(\"tf-gray8-none-le.tif\");")
            recorder.record("Gaussian Blur...", options: "sigma=2")
            recorder.recordLine("setAutoThreshold(\"Default dark\");")
            recorder.recordLine("makeOval(14, 3, 20, 16);")
            recorder.record("Measure", options: "")
            await settle(1.0)
            await shoot("09b", "recorder", "The Recorder window with a recorded macro", window)
        }

        await state("10", "command-dialog") {
            let g = try grayscale()
            let dialogs: BridgeDialogs
            do {
                dialogs = try JSONDecoder().decode(BridgeDialogs.self, from: Data(Self.gaussianBlurDialog.utf8))
            } catch {
                throw Failure("the hand-made dialog description does not decode: \(error)")
            }
            g.model.pendingDialog = PendingDialog(command: "Gaussian Blur...", dialogs: dialogs, stackSize: 5)
            defer { g.model.pendingDialog = nil }
            guard await waitUntil(10, { g.window.attachedSheet != nil }) else { throw Failure("the dialog sheet never appeared") }
            await settle(1.0)
            await shoot("10", "command-dialog", "Gaussian Blur…, in the native command dialog (a hand-made description)", g.window)
            g.model.pendingDialog = nil
            await waitUntil(5, { g.window.attachedSheet == nil })
        }

        await state("11", "find-command") {
            let g = try grayscale()
            g.model.showsCommandFinder = true
            defer { g.model.showsCommandFinder = false }
            guard await waitUntil(10, { g.window.attachedSheet != nil }) else { throw Failure("the Find Command sheet never appeared") }
            // The finder starts the Java bridge for ImageJ's commands; show it once that has settled.
            await waitUntil(40, { bridgeHasSettled })
            await settle(1.0)
            await shoot("11", "find-command", "Find Command (⌘L)", g.window)
            g.model.showsCommandFinder = false
            await waitUntil(5, { g.window.attachedSheet == nil })
        }

        await state("12", "update-sites") {
            let window = try await openTool("update-sites", title: "Update Sites")
            await settle(1.5)
            await shoot("12", "update-sites", "The Update Sites window", window)
        }

        await state("13", "image-menu") {
            try await shootImageMenu()
        }
    }

    /// Runs one state; a state that can't be set up is a problem in the index, and the run goes on.
    private func state(_ code: String, _ name: String, _ body: () async throws -> Void) async {
        let label = "\(code)-\(name)"
        running = label
        writeIndex()
        Screenshots.report("screenshots: \(label)")
        do {
            try await body()
        } catch {
            problems.append(Problem(state: label, reason: "\(error)"))
            Screenshots.report("screenshots: \(label) failed: \(error)")
        }
        // An error alert left on a window would be in every later picture.
        for viewer in AppSession.shared.imageViewers { viewer.errorMessage = nil }
        running = nil
        writeIndex()
    }

    // MARK: Opening windows

    /// An image in a window of its own, rendered and laid out.
    private func open(_ url: URL) async throws -> Opened {
        let before = Set(Self.contentWindows().map { ObjectIdentifier($0) })
        openWindow(id: "viewer", value: OpenRequest(url: url))
        guard let window = await poll(timeout: 30, { Self.contentWindows().first { !before.contains(ObjectIdentifier($0)) } }) else {
            throw Failure("no window opened for \(url.lastPathComponent)")
        }
        guard let model = await poll(timeout: 30, { AppSession.shared.imageViewers.first { $0.fileURL == url && $0.rendered != nil } })
        else {
            throw Failure("\(url.lastPathComponent) never finished opening")
        }
        window.makeKeyAndOrderFront(nil)
        await settle(1.0)
        return Opened(window: window, model: model)
    }

    /// A tool window (a `Window` scene) by its scene id and title.
    private func openTool(_ id: String, title: String) async throws -> NSWindow {
        openWindow(id: id)
        guard let window = await poll(timeout: 30, { Self.window(titled: title) }) else {
            throw Failure("the \(title) window never appeared")
        }
        return window
    }

    /// Analyze ▸ Plot Profile or Histogram, as the menu runs it.
    private func openPlot(_ command: String, titlePrefix: String, viewer: ViewerModel) async throws -> NSWindow {
        let before = Set(Self.contentWindows().map { ObjectIdentifier($0) })
        guard PlotWindows.open(command, viewer: viewer, openWindow: openWindow) else {
            throw Failure("\(command) is plotted by ImageJ, not natively")
        }
        let window = await poll(timeout: 30, {
            Self.contentWindows().first { !before.contains(ObjectIdentifier($0)) && $0.title.hasPrefix(titlePrefix) }
        })
        guard let window else { throw Failure(viewer.errorMessage ?? "no \(command) window opened") }
        return window
    }

    /// Plugins ▸ New ▸ Macro: an empty editor window of its own, and its text view. The editor's model
    /// lives in the window's state, and the app reaches it only as the focused scene value of menu
    /// commands; the text view is what shows the text, and `show` is what `MacroEditorModel.load` ends with.
    private func openEditor() async throws -> (NSWindow, MacroTextView) {
        let before = Set(Self.contentWindows().map { ObjectIdentifier($0) })
        openWindow(id: "macro-editor", value: EditorRequest(serial: UUID()))
        guard let window = await poll(timeout: 30, { Self.contentWindows().first { !before.contains(ObjectIdentifier($0)) } }) else {
            throw Failure("no macro editor window opened")
        }
        guard let text = await poll(timeout: 30, { window.contentView.flatMap { Self.textView(in: $0) } }) else {
            throw Failure("the macro editor window has no text view")
        }
        window.makeKeyAndOrderFront(nil)
        return (window, text)
    }

    private static func textView(in view: NSView) -> MacroTextView? {
        if let found = view as? MacroTextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    /// The grayscale image window, in front.
    private func grayscale() throws -> Opened {
        guard let gray else { throw Failure("the grayscale image did not open (see 02-inspector)") }
        gray.window.makeKeyAndOrderFront(nil)
        return gray
    }

    private var bridgeHasSettled: Bool {
        switch bridge.state {
        case .ready, .failed: true
        case .idle, .starting: false
        }
    }

    // MARK: Fixtures and samples

    /// `Tests/Fixtures`: from `MANCORA_FIXTURES`, else next to the sources the app was built from
    /// (as the bridge finds its resources), else under the current folder.
    private static func findFixtures() -> URL? {
        let files = FileManager.default
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["MANCORA_FIXTURES"] {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(folder.appendingPathComponent("Tests/Fixtures", isDirectory: true))
            folder.deleteLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("Tests/Fixtures", isDirectory: true))
        return candidates.first { files.fileExists(atPath: $0.appendingPathComponent("tiff/ij-hyperstack-16bit.tif").path) }
    }

    private func fixture(_ path: String) throws -> URL {
        guard let fixtures else { throw Failure("Tests/Fixtures was not found (set MANCORA_FIXTURES to its path)") }
        let url = fixtures.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("\(url.path) is missing") }
        return url
    }

    /// Four selections for the ROI Manager, inside the 37 × 23 grayscale fixture.
    private static let sampleRois: [Roi] = {
        let triangle = Roi.Polygon(
            .polygon,
            .integer([
                Roi.IntPoint(x: 3, y: 17), Roi.IntPoint(x: 11, y: 12), Roi.IntPoint(x: 17, y: 20), Roi.IntPoint(x: 9, y: 22),
            ]))
        return [
            Roi(.rectangle(.integer(x: 5, y: 4, width: 18, height: 11))),
            Roi(.oval(.integer(x: 14, y: 3, width: 20, height: 16))),
            Roi(.polygon(triangle)),
            Roi(.rectangle(.integer(x: 24, y: 12, width: 10, height: 8))),
        ]
    }()

    /// A short macro that uses what the editor colors: a comment, a keyword, functions, strings and numbers.
    private static let sampleMacro = """
        // Blur, threshold and measure three ovals
        open("tf-gray8-none-le.tif");
        run("Gaussian Blur...", "sigma=2");
        setAutoThreshold("Default dark");
        for (i = 0; i < 3; i++) {
            makeOval(14 + i, 3, 20, 16);
            run("Measure");
        }
        print("Measured " + nResults + " ovals");
        """

    /// What the bridge would describe for Gaussian Blur…, written by hand so the dialog
    /// can be shown without Java.
    private static let gaussianBlurDialog = """
        {
          "asksForStack": true,
          "supportsPreview": true,
          "dialogs": [
            {
              "title": "Gaussian Blur...",
              "hasPreview": true,
              "fields": [
                {"kind": "number", "key": "sigma", "label": "Sigma (Radius)", "value": "2.00", "units": "pixels"},
                {"kind": "checkbox", "key": "scaled", "label": "Scaled Units (µm)", "value": "false"}
              ]
            }
          ]
        }
        """

    // MARK: Windows

    /// The app's own windows: titled, visible, not sheets or panels.
    private static func contentWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.isVisible && $0.sheetParent == nil && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
    }

    private static func window(titled title: String) -> NSWindow? {
        contentWindows().first { $0.title == title }
    }

    private func setAppearance(dark: Bool) {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// Lets SwiftUI lay out and draw: the run loop turns while this sleeps.
    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        for window in NSApplication.shared.windows { window.displayIfNeeded() }
    }

    private func poll<T>(timeout: Double, _ check: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = check() { return found }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: Capturing

    /// Saves `window` in light and in dark mode as `<code>-name-light.png` and `<code>-name-dark.png`.
    private func shoot(_ code: String, _ name: String, _ detail: String, _ window: NSWindow) async {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            setAppearance(dark: dark)
            window.makeKeyAndOrderFront(nil)
            await settle(0.8)
            let file = "\(code)-\(name)-\(mode).png"
            let url = directory.appendingPathComponent(file)
            do {
                let taken = try await capture(window, to: url)
                add(file: file, detail: "\(detail), \(mode) mode", taken: taken)
                if comparesWithScreencapture, taken.method != "screencapture" {
                    let other = url.deletingPathExtension().appendingPathExtension("screencapture.png")
                    if let size = await screencapture(window, to: other) {
                        let copy = Taken(method: "screencapture", size: size, note: "the same window, to compare with \(file)")
                        add(file: other.lastPathComponent, detail: "\(detail), \(mode) mode", taken: copy)
                    }
                }
            } catch {
                problems.append(Problem(state: file, reason: "\(error)"))
            }
        }
    }

    private func add(file: String, detail: String, taken: Taken) {
        shots.append(Shot(file: file, detail: detail, method: taken.method, size: taken.size, note: taken.note))
        Screenshots.captured += 1
        writeIndex()
    }

    /// The window's picture: in-process, or from screencapture when that is blank or fails.
    private func capture(_ window: NSWindow, to url: URL) async throws -> Taken {
        window.displayIfNeeded()
        let image = Self.snapshot(of: window)
        if let image, Self.hasContent(window) {
            try Self.writePNG(image, to: url)
            return Taken(method: "in-process", size: "\(image.width)×\(image.height)", note: nil)
        }
        let reason = image == nil ? "cacheDisplay gave no picture" : "the in-process picture was blank"
        if let size = await screencapture(window, to: url) {
            return Taken(method: "screencapture", size: size, note: reason)
        }
        if let image {
            try Self.writePNG(image, to: url)
            return Taken(method: "in-process", size: "\(image.width)×\(image.height)", note: "\(reason), and screencapture failed too")
        }
        throw Failure("\(reason), and screencapture failed too")
    }

    /// `screencapture -l <window number> -o`: the pixel size of its picture, or `nil`.
    private func screencapture(_ window: NSWindow, to url: URL) async -> String? {
        // Without screen-recording permission it fails every time (or waits for a prompt).
        guard screencaptureFailures < 2 else { return nil }
        try? FileManager.default.removeItem(at: url)
        let arguments = ["-l", String(window.windowNumber), "-o", "-x", url.path]
        let finished = await Self.run("/usr/sbin/screencapture", arguments, timeout: 15)
        guard finished, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 else {
            screencaptureFailures += 1
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        screencaptureFailures = 0
        return "\(rep.pixelsWide)×\(rep.pixelsHigh)"
    }

    /// A tool being run. `Process` isn't `Sendable`, and the task that ends the tool after its time
    /// limit has to reach it.
    nonisolated final class Tool: @unchecked Sendable {
        let process = Process()
    }

    /// Runs a tool and waits for it, ending it after `timeout` seconds; whether it exited normally.
    private static func run(_ path: String, _ arguments: [String], timeout: Double) async -> Bool {
        let tool = Tool()
        tool.process.executableURL = URL(fileURLWithPath: path)
        tool.process.arguments = arguments
        tool.process.standardOutput = FileHandle.nullDevice
        tool.process.standardError = FileHandle.nullDevice
        let limit = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if tool.process.isRunning { tool.process.terminate() }
        }
        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Called on another thread, so it must not be taken for a main-actor closure.
            tool.process.terminationHandler = { @Sendable finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try tool.process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
        limit.cancel()
        return succeeded
    }

    /// The window's frame view drawn into a bitmap, with its sheets drawn over it.
    private static func snapshot(of window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview ?? window.contentView, let base = bitmap(of: frameView) else { return nil }
        let sheets = window.sheets
        if sheets.isEmpty { return base }
        guard window.frame.width > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        // Pixels per point; a window's own coordinates start at its bottom left, like the context's.
        let scale = CGFloat(base.width) / window.frame.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for sheet in sheets {
            guard let sheetView = sheet.contentView?.superview ?? sheet.contentView, let picture = bitmap(of: sheetView) else { continue }
            let x = (sheet.frame.minX - window.frame.minX) * scale
            let y = (sheet.frame.minY - window.frame.minY) * scale
            context.draw(picture, in: CGRect(x: x, y: y, width: CGFloat(picture.width), height: CGFloat(picture.height)))
        }
        return context.makeImage() ?? base
    }

    private static func bitmap(of view: NSView) -> CGImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    /// Whether the window's content drew anything: text and controls make hundreds of colors,
    /// a view that did not render makes one.
    private static func hasContent(_ window: NSWindow) -> Bool {
        guard let view = window.contentView, let picture = bitmap(of: view) else { return false }
        return distinctColors(in: picture, upTo: 12) >= 6
    }

    private static func distinctColors(in image: CGImage, upTo limit: Int) -> Int {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var seen = Set<UInt32>()
        var offset = 0
        while offset + 3 < pixels.count {
            var color = UInt32(pixels[offset]) << 24
            color |= UInt32(pixels[offset + 1]) << 16
            color |= UInt32(pixels[offset + 2]) << 8
            color |= UInt32(pixels[offset + 3])
            seen.insert(color)
            if seen.count >= limit { break }
            offset += 4 * 7
        }
        return seen.count
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure("the picture could not be encoded as PNG") }
        try data.write(to: url)
    }

    // MARK: The Image menu

    /// The menu bar's Image menu, open. A menu can only be open while its tracking loop runs, so a
    /// task captures it from inside that loop and then closes it. It is shown as a pop-up
    /// (a rebuilt copy of the menu), not hanging from the menu bar.
    private func shootImageMenu() async throws {
        let g = try grayscale()
        let app = NSApplication.shared
        guard let source = app.mainMenu?.items.first(where: { $0.title == "Image" })?.submenu else {
            let titles = (app.mainMenu?.items.map(\.title) ?? []).joined(separator: ", ")
            throw Failure("the menu bar has no Image menu (it has: \(titles))")
        }
        guard let view = g.window.contentView else { throw Failure("the image window has no content view") }
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            setAppearance(dark: dark)
            g.window.makeKeyAndOrderFront(nil)
            await settle(0.8)
            let menu = Self.rebuilt(source)
            let file = "13-image-menu-\(mode).png"
            let tracker = Task {
                await self.captureOpenMenu(menu, file: file, detail: "The Image menu open, \(mode) mode")
            }
            // If the capture never ran, the menu would stay open for good.
            let safety = Timer(timeInterval: 25, repeats: false) { @Sendable _ in
                MainActor.assumeIsolated { menu.cancelTracking() }
            }
            RunLoop.main.add(safety, forMode: .common)
            let top: CGFloat = view.isFlipped ? 16 : view.bounds.height - 16
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 16, y: top), in: view)
            safety.invalidate()
            await tracker.value
        }
    }

    private func captureOpenMenu(_ menu: NSMenu, file: String, detail: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        defer { menu.cancelTracking() }
        let popUps = NSApplication.shared.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
        guard let window = popUps.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            problems.append(Problem(state: file, reason: "no menu window was open while the menu was tracking"))
            return
        }
        do {
            let taken = try await capture(window, to: directory.appendingPathComponent(file))
            add(file: file, detail: detail, taken: taken)
        } catch {
            problems.append(Problem(state: file, reason: "\(error)"))
        }
    }

    /// A menu with the same titles, shortcuts and submenus, without the actions of the real one.
    private static func rebuilt(_ source: NSMenu) -> NSMenu {
        let menu = NSMenu(title: source.title)
        menu.autoenablesItems = false
        for item in source.items where !item.isHidden {
            if item.isSeparatorItem {
                menu.addItem(NSMenuItem.separator())
                continue
            }
            let copy = NSMenuItem(title: item.title, action: nil, keyEquivalent: item.keyEquivalent)
            copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            copy.isEnabled = true
            if let submenu = item.submenu { copy.submenu = rebuilt(submenu) }
            menu.addItem(copy)
        }
        return menu
    }

    // MARK: The index

    private func writeIndex() {
        var lines = ["# Mancora screenshots", ""]
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let screens = NSScreen.screens.map { screen in
            "\(Int(screen.frame.width))×\(Int(screen.frame.height)) at \(Int(screen.backingScaleFactor))x"
        }
        lines.append("\(shots.count) picture(s) after \(seconds) s, \(problems.count) problem(s).")
        if let running { lines.append("Running: \(running)") }
        lines += [
            "",
            "- Run: \(ISO8601DateFormatter().string(from: startedAt))",
            "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- Screens: \(screens.joined(separator: ", "))",
            "- App active: \(NSApplication.shared.isActive)",
            "- Fixtures: \(fixtures?.path ?? "not found")",
            "",
            "## Pictures",
            "",
        ]
        for shot in shots {
            var line = "- [`\(shot.file)`](\(shot.file)): \(shot.detail); \(shot.method), \(shot.size) px"
            if let note = shot.note { line += "; \(note)" }
            lines.append(line)
        }
        lines += ["", "## Problems", ""]
        if problems.isEmpty { lines.append("None.") }
        for problem in problems { lines.append("- `\(problem.state)`: \(problem.reason)") }
        lines += [
            "",
            "## Notes",
            "",
            "- Pictures marked in-process are `cacheDisplay` of the window's frame view; those marked screencapture are `/usr/sbin/screencapture -l`, used when the in-process picture was blank.",
            "- State 09 is the macro editor (Plugins ▸ New ▸ Macro) with text put straight into its text view; 09b is the Recorder window.",
            "- State 13 is the Image menu as a pop-up (a rebuilt copy of the menu bar's menu), not hanging from the menu bar.",
            "- State 10 uses a hand-made description of Gaussian Blur…'s dialog, so it needs no Java.",
            "- The images are the small test fixtures in `Tests/Fixtures/tiff`: `tf-gray8-none-le.tif` (grayscale) and `ij-hyperstack-16bit.tif`.",
        ]
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }
}
