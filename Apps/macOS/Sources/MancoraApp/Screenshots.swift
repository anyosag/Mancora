import AppKit
import CoreGraphics
import Foundation
import MancoraBridge
import MancoraCore
import MancoraFiji
import MancoraIO
import MancoraMacro
import SwiftUI

// `Mancora --screenshots <folder>`: opens real windows, puts the app in each
// state a design review wants to see (the welcome window, no image, the inspector, a threshold,
// selections, a hyperstack, the ROI Manager, Results, plots, the macro editor, the recorder,
// command dialogs, Find Command, Update Sites, Settings ▸ Fiji, the first-use Fiji sheet, the Image menu), saves a PNG
// of the window in light and in dark mode, writes `index.md`, and exits.
//
// How windows are opened: the first window's (the welcome window's) SwiftUI scene hands its
// `openWindow` action to the run (see `screenshotDriver`), and the run opens
// the others as the menus do: `openWindow(id: "viewer", value:)` for an image,
// `openWindow(id:)` for the tool windows, `PlotWindows.open` for plots,
// and the same `ViewerModel` and `AppSession` calls the commands make.
//
// What the image windows show: images made in memory (`SampleImages`: a
// 512×512 fluorescence-like micrograph and a three-channel 16-bit composite
// stack) and saved as TIFFs in a temporary folder, because windows open files.
// The small test fixtures are only the fallback when that fails.
//
// How they are captured: `/usr/sbin/screencapture -l <window number> -o`,
// which shows the pixels as the window server draws them, with the title bar
// and toolbar in the picture. A sheet (a command dialog, Find Command) is a
// window of its own, captured the same way and laid over its parent. If
// screencapture fails (it needs screen-recording permission on some
// setups), `cacheDisplay` of the window's frame view takes the picture in
// process instead; it smooths pixels, so the index says which was used.

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
    static func startOnce(bridge: AppBridge, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        guard let directory = outputDirectory, !hasStarted else { return }
        hasStarted = true
        let run = ScreenshotRun(directory: directory, bridge: bridge, openWindow: openWindow, openSettings: openSettings)
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
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task { Screenshots.startOnce(bridge: bridge, openWindow: openWindow, openSettings: openSettings) }
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

    /// The sample images as files (windows open files).
    struct SampleFiles {
        let gray: URL
        let composite: URL
        /// Files for the welcome window's list of recent images, newest first.
        let recents: [URL]
    }

    private let directory: URL
    private let bridge: AppBridge
    private let openWindow: OpenWindowAction
    private let openSettings: OpenSettingsAction
    private let startedAt = Date()
    private var fixtures: URL?
    private var samples: SampleFiles?
    private var shots: [Shot] = []
    private var problems: [Problem] = []
    private var running: String?
    private var gray: Opened?
    private var screencaptureFailures = 0

    init(directory: URL, bridge: AppBridge, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        self.directory = directory
        self.bridge = bridge
        self.openWindow = openWindow
        self.openSettings = openSettings
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
        samples = Self.makeSamples()
        fixtures = Self.findFixtures()
        Screenshots.report("screenshots: sample images \(samples == nil ? "could not be made" : "made in memory")")
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
        // What the windows list as recent: images (the welcome window) and commands (Find Command).
        // Neither is stored, so the run leaves the user's own lists alone.
        if let samples { RecentFiles.shared.show(samples.recents) }
        RecentCommands.preset = ["Gaussian Blur...", "Measure", "Find Edges", "Invert"]

        // The window the app opens at launch.
        await state("00", "welcome") {
            guard let window = await poll(timeout: 30, { Self.window(titled: "Welcome to Mancora") }) else {
                throw Failure("the welcome window never appeared")
            }
            await settle(1.0)
            await shoot("00", "welcome", "The welcome window, shown at launch", window)
        }

        // An image window with no image, which a command that makes one opens first.
        await state("01", "no-image") {
            let before = Set(Self.contentWindows().map { ObjectIdentifier($0) })
            openWindow(id: "viewer")
            guard let window = await poll(timeout: 30, { Self.contentWindows().first { !before.contains(ObjectIdentifier($0)) } }) else {
                throw Failure("no empty image window opened")
            }
            window.makeKeyAndOrderFront(nil)
            await settle(1.0)
            await shoot("01", "no-image", "An image window with no image open", window)
            // The states after this open image windows of their own.
            window.close()
        }

        await state("02", "inspector") {
            let url = try grayscaleURL()
            let opened = try await open(url)
            gray = opened
            opened.model.showsInspector = true
            await shoot("02", "inspector", "An image window with the inspector (brightness and contrast)", opened.window)
        }

        await state("03", "threshold") {
            let g = try grayscale()
            g.model.showsThreshold = true
            // Bright objects on a dark background. (Left set afterwards: the Threshold section
            // thresholds again when this changes, which would put a threshold on the image again.)
            g.model.thresholdDark = true
            g.model.autoThreshold()
            if g.model.threshold == nil {
                // Auto failed (and said so in an alert, which doesn't belong in the picture): set levels by hand.
                g.model.errorMessage = nil
                g.model.setThresholdLevels(lower: 64, upper: 255)
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
            g.model.setSelection(Roi(.rectangle(layout.rect(layout.rectangleBox))))
            await settle(0.5)
            await shoot("04", "selection-rectangle", "A rectangle selection drawn on the image", g.window)
        }

        await state("04", "selection-oval") {
            let g = try grayscale()
            AppSession.shared.tool = .oval
            g.model.setSelection(Roi(.oval(layout.rect(layout.ovalBox))))
            await settle(0.5)
            await shoot("04", "selection-oval", "An oval selection drawn on the image", g.window)
        }

        await state("05", "hyperstack") {
            let url = try hyperstackURL()
            let opened = try await open(url)
            guard let dimensions = opened.model.image?.dimensions else { throw Failure("the hyperstack is gone") }
            opened.model.channel = min(1, dimensions.channels - 1)
            opened.model.slice = min(2, dimensions.slices - 1)
            opened.model.frame = min(2, dimensions.frames - 1)
            opened.model.positionChanged()
            await settle(1.0)
            let kind = "\(dimensions.channels) channel(s), \(dimensions.slices) slice(s), \(dimensions.frames) frame(s)"
            await shoot("05", "hyperstack", "A hyperstack (\(kind)) with its C/Z/T sliders", opened.window)
        }

        await state("06", "roi-manager") {
            let g = try grayscale()
            guard let image = g.model.image else { throw Failure("the grayscale image is gone") }
            let session = AppSession.shared
            session.roiManager = RoiManagerList()
            for roi in layout.rois {
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
            g.model.setSelection(Roi(.line(layout.line)))
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
            let macro = sampleMacro
            let (window, text) = try await openEditor()
            text.show(macro)
            // The caret on the Measure line, so the status bar has a position to show.
            if let measure = macro.range(of: "Measure") {
                text.setSelectedRange(NSRange(measure.lowerBound..<measure.lowerBound, in: macro))
            }
            await settle(1.0)
            await shoot("09", "macro-editor", "The macro editor with a short macro", window)
        }

        await state("09b", "recorder") {
            let window = try await openTool("recorder", title: "Recorder")
            let recorder = AppRecorder.shared
            let oval = layout.ovalBox
            recorder.clear()
            recorder.isRecording = true
            recorder.recordLine("open(\"\(grayscaleTitle)\");")
            recorder.record("Gaussian Blur...", options: "sigma=2")
            recorder.recordLine("setAutoThreshold(\"Default dark\");")
            recorder.recordLine("makeOval(\(oval.x), \(oval.y), \(oval.width), \(oval.height));")
            recorder.record("Measure", options: "")
            await settle(1.0)
            await shoot("09b", "recorder", "The Recorder window with a recorded macro", window)
        }

        await state("10", "command-dialog") {
            try await shootDialog(
                "10", "command-dialog", command: "Gaussian Blur...", description: Self.gaussianBlurDialog, stackSize: 5,
                detail: "Gaussian Blur…, in the native command dialog (a hand-made description)")
        }

        await state("10b", "command-dialog-scale") {
            try await shootDialog(
                "10b", "command-dialog-scale", command: "Set Scale...", description: Self.setScaleDialog, stackSize: 1,
                detail: "Set Scale…, a dialog with text, number and checkbox fields (a hand-made description)")
        }

        await state("11", "find-command") {
            let g = try grayscale()
            g.model.showsCommandFinder = true
            defer { g.model.showsCommandFinder = false }
            guard await waitUntil(10, { g.window.attachedSheet != nil }) else { throw Failure("the Find Command sheet never appeared") }
            // The finder starts the Java bridge for ImageJ's commands; show it once that has settled.
            await waitUntil(40, { bridgeHasSettled })
            await settle(1.0)
            await shoot("11", "find-command", "Find Command (⌘L) with nothing typed: recent commands first", g.window)
            g.model.showsCommandFinder = false
            await waitUntil(5, { g.window.attachedSheet == nil })
        }

        await state("11b", "find-command-search") {
            let g = try grayscale()
            CommandFinder.presetQuery = "blur"
            defer {
                CommandFinder.presetQuery = nil
                g.model.showsCommandFinder = false
            }
            g.model.showsCommandFinder = true
            guard await waitUntil(10, { g.window.attachedSheet != nil }) else { throw Failure("the Find Command sheet never appeared") }
            await waitUntil(40, { bridgeHasSettled })
            await settle(1.0)
            await shoot("11b", "find-command-search", "Find Command with “blur” typed: menu paths and shortcuts", g.window)
            g.model.showsCommandFinder = false
            await waitUntil(5, { g.window.attachedSheet == nil })
        }

        await state("12", "update-sites") {
            let window = try await openTool("update-sites", title: "Update Sites")
            await settle(1.5)
            await shoot("12", "update-sites", "The Update Sites window", window)
        }

        // Update Sites as it reads with Fiji: its sites, with their descriptions and URLs. The list is
        // made from the well-known sites (a real Fiji's is read from its db.xml.gz), so nothing is read.
        await state("12b", "update-sites-fiji") {
            AppUpdateSites.shared.showPreview()
            defer { AppUpdateSites.shared.endPreview() }
            let window = try await openTool("update-sites", title: "Update Sites")
            await settle(1.5)
            await shoot("12b", "update-sites-fiji", "The Update Sites window with Fiji's update sites (a made-up list)", window)
        }

        // Settings ▸ Fiji, with a made-up Fiji so the pictures do not depend on the computer.
        await state("14", "settings-fiji") {
            try await shootFijiSettings(
                "14", "settings-fiji", installed: true, staged: false,
                detail: "Settings ▸ Fiji with Fiji installed and up to date (made-up state)")
        }

        await state("14b", "settings-fiji-not-installed") {
            try await shootFijiSettings(
                "14b", "settings-fiji-not-installed", installed: false, staged: false,
                detail: "Settings ▸ Fiji before Fiji is downloaded (made-up state)")
        }

        await state("14c", "settings-fiji-staged") {
            try await shootFijiSettings(
                "14c", "settings-fiji-staged", installed: true, staged: true,
                detail: "Settings ▸ Fiji with an update waiting for the next start and the last automatic update's error (made-up state)")
        }

        // The sheet a command that needs Fiji shows when Fiji is not installed: the offer, then a
        // download that is 42% done. Nothing is downloaded.
        await state("15", "fiji-first-use") {
            try await shootFijiSheet(
                "15", "fiji-first-use", progress: nil,
                detail: "The first-use sheet that offers to download Fiji")
        }

        await state("15b", "fiji-first-use-progress") {
            let progress = FijiProgress(phase: .downloading, completedBytes: 296_000_000, totalBytes: 703_000_000)
            try await shootFijiSheet(
                "15b", "fiji-first-use-progress", progress: progress,
                detail: "The first-use sheet while Fiji downloads (a made-up progress: nothing is downloaded)")
        }

        await state("13", "image-menu") {
            try await shootImageMenu()
        }
    }

    /// Settings ▸ Fiji in front, for a made-up Fiji (installed or not), and its picture.
    private func shootFijiSettings(_ code: String, _ name: String, installed: Bool, staged: Bool, detail: String) async throws {
        let location = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Mancora/Fiji")
        var settings = FijiSettings()
        if installed {
            settings.lastCheck = Date().addingTimeInterval(-2 * 3600)
            settings.lastUpdate = Date().addingTimeInterval(-3 * 86400)
            if staged { settings.lastError = "Fiji’s update sites couldn’t all be read: the network connection was lost." }
        }
        let version = FijiVersion(fiji: "2.18.0", imageJ2: "2.16.0", imageJ1: "1.54p", java: "21.0.7")
        FijiState.shared.showPreview(
            status: installed ? .installed(version) : .notInstalled, settings: settings,
            staged: staged ? ["update jars/trackmate-7.14.0.jar (Fiji)", "update jars/labkit-ui-0.3.11.jar (Fiji)"] : [], location: location)
        SettingsSelection.shared.tab = .fiji
        do {
            openSettings()
            guard let window = await poll(timeout: 30, { Self.settingsWindow() }) else { throw Failure("the Settings window never appeared") }
            await settle(1.2)
            await shoot(code, name, detail, window)
            window.close()
        } catch {
            SettingsSelection.shared.tab = .general
            await FijiState.shared.endPreview()
            throw error
        }
        SettingsSelection.shared.tab = .general
        await FijiState.shared.endPreview()
    }

    /// The first-use sheet on the grayscale image's window, with a made-up progress, and its picture.
    private func shootFijiSheet(_ code: String, _ name: String, progress: FijiProgress?, detail: String) async throws {
        let g = try grayscale()
        FijiSetup.shared.showPreview(reason: "This command needs Fiji.", progress: progress, on: g.window)
        guard await waitUntil(10, { g.window.attachedSheet != nil }) else {
            FijiSetup.shared.endPreview()
            throw Failure("the Fiji sheet never appeared")
        }
        await settle(1.0)
        await shoot(code, name, detail, g.window)
        FijiSetup.shared.endPreview()
        await waitUntil(5, { g.window.attachedSheet == nil })
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

    /// A command's dialog on the grayscale image, from a hand-made description, shot as a sheet.
    private func shootDialog(
        _ code: String, _ name: String, command: String, description: String, stackSize: Int, detail: String
    ) async throws {
        let g = try grayscale()
        let dialogs: BridgeDialogs
        do {
            dialogs = try JSONDecoder().decode(BridgeDialogs.self, from: Data(description.utf8))
        } catch {
            throw Failure("the hand-made dialog description does not decode: \(error)")
        }
        g.model.pendingDialog = PendingDialog(command: command, dialogs: dialogs, stackSize: stackSize)
        defer { g.model.pendingDialog = nil }
        guard await waitUntil(10, { g.window.attachedSheet != nil }) else { throw Failure("the dialog sheet never appeared") }
        await settle(1.0)
        await shoot(code, name, detail, g.window)
        g.model.pendingDialog = nil
        await waitUntil(5, { g.window.attachedSheet == nil })
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
        // With no engine installed Find Command does not start one (it only lists what one has).
        case .idle: !bridge.engineIsInstalled
        case .starting: false
        }
    }

    // MARK: Sample images

    /// Makes the sample images in memory and saves them (windows open files) in a temporary
    /// folder, in a few folders of a lab's microscopy so the welcome window's recent list reads
    /// naturally. `nil` if that failed; the states then use the fixtures.
    private static func makeSamples() -> SampleFiles? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mancora-screenshot-samples-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        func save(_ image: Hyperstack?, in folder: String) -> URL? {
            guard let image else { return nil }
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(image.title)
                try TIFFExporter.write(image, to: url.path)
                return url
            } catch {
                Screenshots.report("screenshots: cannot save \(image.title): \(error)")
                return nil
            }
        }
        guard
            let gray = save(SampleImages.fluorescence(title: "nuclei-DAPI.tif", seed: 11), in: "Microscopy/Confocal"),
            let composite = save(SampleImages.composite(title: "composite-3ch.tif", seed: 5), in: "Microscopy/Confocal")
        else { return nil }
        // More images for the recent list: other days' files, other folders.
        let others = [
            save(SampleImages.fluorescence(title: "neurons-GFP.tif", seed: 23), in: "Microscopy/Neurons"),
            save(SampleImages.fluorescence(title: "colony-plate-04.tif", seed: 42), in: "Documents/Plates"),
        ].compactMap { $0 }
        return SampleFiles(gray: gray, composite: composite, recents: [composite, gray] + others)
    }

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

    /// The grayscale image to open: the fluorescence-like sample, else the small fixture.
    private func grayscaleURL() throws -> URL {
        if let samples { return samples.gray }
        return try fixture("tiff/tf-gray8-none-le.tif")
    }

    /// The hyperstack to open: the composite sample, else the fixture (2 channels, 3 slices, 4 frames).
    private func hyperstackURL() throws -> URL {
        if let samples { return samples.composite }
        return try fixture("tiff/ij-hyperstack-16bit.tif")
    }

    private var grayscaleTitle: String {
        gray?.model.image?.title ?? "image.tif"
    }

    /// Where the selections go, in the grayscale image whatever its size.
    private var layout: SelectionLayout {
        SelectionLayout(width: gray?.model.image?.width ?? 37, height: gray?.model.image?.height ?? 23)
    }

    /// Selections as fractions of the image, so they sit well on the 512 × 512 sample and stay
    /// inside the 37 × 23 fixture.
    struct SelectionLayout {
        typealias Box = (x: Int, y: Int, width: Int, height: Int)

        let width: Int
        let height: Int

        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Box {
            (Int(Double(width) * x), Int(Double(height) * y), Int(Double(width) * w), Int(Double(height) * h))
        }

        func rect(_ box: Box) -> Roi.Rect {
            .integer(x: Int32(box.x), y: Int32(box.y), width: Int32(box.width), height: Int32(box.height))
        }

        func point(_ x: Double, _ y: Double) -> Roi.IntPoint {
            Roi.IntPoint(x: Int32(Double(width) * x), y: Int32(Double(height) * y))
        }

        var rectangleBox: Box { box(0.12, 0.16, 0.30, 0.22) }
        var ovalBox: Box { box(0.50, 0.10, 0.30, 0.28) }
        var lowerBox: Box { box(0.62, 0.60, 0.24, 0.22) }

        /// The Plot Profile line, across several blobs.
        var line: Roi.Line {
            Roi.Line(x1: Double(width) * 0.05, y1: Double(height) * 0.10, x2: Double(width) * 0.95, y2: Double(height) * 0.82)
        }

        /// Four selections for the ROI Manager.
        var rois: [Roi] {
            let triangle = Roi.Polygon(
                .polygon, .integer([point(0.08, 0.72), point(0.22, 0.58), point(0.34, 0.80), point(0.17, 0.90)]))
            return [
                Roi(.rectangle(rect(rectangleBox))),
                Roi(.oval(rect(ovalBox))),
                Roi(.polygon(triangle)),
                Roi(.rectangle(rect(lowerBox))),
            ]
        }
    }

    /// A short macro that uses what the editor colors: a comment, a keyword, functions, strings and numbers.
    private var sampleMacro: String {
        let oval = layout.ovalBox
        return """
            // Blur, threshold and measure three ovals
            open("\(grayscaleTitle)");
            run("Gaussian Blur...", "sigma=2");
            setAutoThreshold("Default dark");
            for (i = 0; i < 3; i++) {
                makeOval(\(oval.x) + i * 8, \(oval.y), \(oval.width), \(oval.height));
                run("Measure");
            }
            print("Measured " + nResults + " ovals");
            """
    }

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

    /// Set Scale…'s dialog as ImageJ lays it out: numbers, a text field, a checkbox and a message.
    private static let setScaleDialog = """
        {
          "asksForStack": false,
          "supportsPreview": false,
          "dialogs": [
            {
              "title": "Set Scale",
              "hasPreview": false,
              "fields": [
                {"kind": "number", "key": "distance", "label": "Distance in pixels", "value": "100"},
                {"kind": "number", "key": "known", "label": "Known distance", "value": "16.00"},
                {"kind": "number", "key": "pixel", "label": "Pixel aspect ratio", "value": "1.0"},
                {"kind": "string", "key": "unit", "label": "Unit of length", "value": "µm"},
                {"kind": "checkbox", "key": "global", "label": "Global", "value": "false"},
                {"kind": "message", "label": "Scale: 6.25 pixels/µm"}
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

    /// The Settings window: SwiftUI names it after its pane.
    private static func settingsWindow() -> NSWindow? {
        NSApplication.shared.windows.first { window in
            window.isVisible && window.sheetParent == nil
                && (window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
                    || ["Settings", "General", "Fiji"].contains(window.title))
        }
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

    /// The window's picture: screencapture's, which shows the pixels as they are drawn; if that
    /// fails, the in-process one (`cacheDisplay`, which smooths them).
    private func capture(_ window: NSWindow, to url: URL) async throws -> Taken {
        window.displayIfNeeded()
        if let taken = await captureWithScreencapture(window, to: url) { return taken }
        guard let image = Self.snapshot(of: window) else {
            throw Failure("screencapture failed, and cacheDisplay gave no picture")
        }
        try Self.writePNG(image, to: url)
        let note =
            Self.hasContent(window)
            ? "screencapture failed, so this is cacheDisplay's picture, which smooths pixels"
            : "screencapture failed, and the in-process picture looks blank"
        return Taken(method: "in-process", size: "\(image.width)×\(image.height)", note: note)
    }

    /// `screencapture -l` of the window, and of each sheet on it laid over it (a sheet is a window
    /// of its own, and whether the parent's picture includes it is not something to rely on).
    private func captureWithScreencapture(_ window: NSWindow, to url: URL) async -> Taken? {
        guard var picture = await screencapture(window, to: url) else { return nil }
        var note: String?
        var layers: [(sheet: NSWindow, picture: CGImage)] = []
        for sheet in window.sheets {
            let part = url.deletingPathExtension().appendingPathExtension("sheet.png")
            if let image = await screencapture(sheet, to: part) { layers.append((sheet, image)) }
            try? FileManager.default.removeItem(at: part)
        }
        if let combined = Self.composite(layers, over: picture, in: window) {
            picture = combined
            do {
                try Self.writePNG(combined, to: url)
                note = "the sheet is laid over its window"
            } catch {
                note = "the sheet could not be laid over its window: \(error)"
            }
        }
        return Taken(method: "screencapture", size: "\(picture.width)×\(picture.height)", note: note)
    }

    /// `screencapture -l <window number> -o`, saved at `url`: its picture, or `nil` when the tool
    /// failed or the picture is blank (no screen-recording permission, a window that is not on screen).
    private func screencapture(_ window: NSWindow, to url: URL) async -> CGImage? {
        // Without screen-recording permission it fails every time (or waits for a prompt).
        guard screencaptureFailures < 2, window.windowNumber > 0 else { return nil }
        try? FileManager.default.removeItem(at: url)
        let arguments = ["-l", String(window.windowNumber), "-o", "-x", url.path]
        let finished = await Self.run("/usr/sbin/screencapture", arguments, timeout: 15)
        guard finished, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0,
            let image = rep.cgImage, Self.distinctColors(in: image, upTo: 12) >= 6
        else {
            screencaptureFailures += 1
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        screencaptureFailures = 0
        return image
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

    /// `layers` drawn over `base`, each where its window sits on `window` (a window's own
    /// coordinates start at its bottom left, like the context's).
    private static func composite(_ layers: [(sheet: NSWindow, picture: CGImage)], over base: CGImage, in window: NSWindow) -> CGImage? {
        guard !layers.isEmpty, window.frame.width > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Pixels per point.
        let scale = CGFloat(base.width) / window.frame.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for layer in layers {
            let x = (layer.sheet.frame.minX - window.frame.minX) * scale
            let y = (layer.sheet.frame.minY - window.frame.minY) * scale
            context.draw(layer.picture, in: CGRect(x: x, y: y, width: CGFloat(layer.picture.width), height: CGFloat(layer.picture.height)))
        }
        return context.makeImage()
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
            // If the capture never ran, the menu would stay open for good. The timer fires on
            // the main run loop, where the menu is only ever touched.
            nonisolated(unsafe) let trackedMenu = menu
            let safety = Timer(timeInterval: 25, repeats: false) { @Sendable _ in
                MainActor.assumeIsolated { trackedMenu.cancelTracking() }
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
            "- Sample images: \(samples == nil ? "could not be made, the fixtures were used" : "made in memory")",
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
            "- Pictures marked screencapture are `/usr/sbin/screencapture -l <window> -o`: the pixels as the window server draws them. A sheet is its own window, captured the same way and laid over its parent. Those marked in-process are `cacheDisplay`, used only when screencapture failed; it smooths pixels, so judge details on the others.",
            "- State 00 is the welcome window as the app opens it at launch (its recent images are the sample files below); 01 is an empty image window, which a command that makes an image opens first.",
            "- State 09 is the macro editor (Plugins ▸ New ▸ Macro) with text put straight into its text view; 09b is the Recorder window.",
            "- State 13 is the Image menu as a pop-up (a rebuilt copy of the menu bar's menu), not hanging from the menu bar.",
            "- States 10 and 10b use hand-made descriptions of Gaussian Blur…'s and Set Scale…'s dialogs, so they need no Java. State 11 shows recent commands from a made-up list, 11b a search for “blur”.",
            "- State 12 is the Update Sites window as this computer has it; 12b shows Fiji's update sites from a made-up list (the well-known sites), so nothing is read.",
            "- States 14, 14b and 14c are Settings ▸ Fiji (installed, not installed, and with an update waiting for the next start plus the last automatic update's error) for a made-up Fiji, so they do not depend on what is installed here. States 15 and 15b are the sheet a command shows when it needs Fiji, on the first image window: the offer, and a download made up to be 42% done. Nothing is downloaded.",
            "- The images are made in memory (`SampleImages`) and saved as TIFFs in a temporary folder, because windows open files: `nuclei-DAPI.tif`, a 512×512 8-bit fluorescence-like image of soft blobs on a dark, noisy background, and `composite-3ch.tif`, a 256×256 16-bit composite of 3 channels (red, green, blue) and 5 slices. The small test fixtures in `Tests/Fixtures/tiff` are only the fallback.",
        ]
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }
}

// MARK: Sample images

/// Images for the screenshots, made in memory: a fluorescence-like micrograph and a composite
/// stack. The numbers come from a seeded generator, so every run draws the same pictures.
enum SampleImages {
    /// SplitMix64.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678_9ABC_DEF1
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A number from 0 up to (not including) 1.
        mutating func unit() -> Double {
            Double(next() >> 11) / 9_007_199_254_740_992.0
        }

        mutating func range(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * unit()
        }

        /// A normally distributed number: mean 0, standard deviation 1.
        mutating func gaussian() -> Double {
            let a = max(unit(), 1e-12)
            let b = unit()
            return (-2 * log(a)).squareRoot() * cos(2 * Double.pi * b)
        }
    }

    /// Adds a soft elliptical blob to `field` (a `size` × `size` image): a Gaussian with `sigma`
    /// along the direction `angle` and `sigma * stretch` across it, `amplitude` high at its centre.
    static func addBlob(
        to field: inout [Float], size: Int, x: Double, y: Double, sigma: Double, stretch: Double = 1, angle: Double = 0,
        amplitude: Double
    ) {
        let across = sigma * stretch
        let reach = Int((3.5 * max(sigma, across)).rounded(.up))
        let left = max(0, Int(x) - reach), right = min(size - 1, Int(x) + reach)
        let top = max(0, Int(y) - reach), bottom = min(size - 1, Int(y) + reach)
        guard left <= right, top <= bottom else { return }
        let cosine = cos(angle), sine = sin(angle)
        let alongFactor = -0.5 / (sigma * sigma), acrossFactor = -0.5 / (across * across)
        for row in top...bottom {
            let dy = Double(row) - y
            for column in left...right {
                let dx = Double(column) - x
                let u = dx * cosine + dy * sine
                let v = -dx * sine + dy * cosine
                field[row * size + column] += Float(amplitude * exp(u * u * alongFactor + v * v * acrossFactor))
            }
        }
    }

    /// A 512 × 512 8-bit image like a fluorescence micrograph: soft, slightly elongated blobs of
    /// varying brightness and a few dim specks on a dark, slightly noisy background, calibrated
    /// in micrometres.
    static func fluorescence(title: String, seed: UInt64) -> Hyperstack? {
        let size = 512
        var random = Generator(seed: seed)
        var field = [Float](repeating: 0, count: size * size)
        // Out-of-focus haze.
        for _ in 0..<5 {
            let x = random.range(0, 512), y = random.range(0, 512)
            addBlob(to: &field, size: size, x: x, y: y, sigma: random.range(70, 120), amplitude: random.range(3, 8))
        }
        // The objects themselves.
        for _ in 0..<44 {
            let x = random.range(30, 482), y = random.range(30, 482)
            let sigma = random.range(8, 17), stretch = random.range(0.6, 1), angle = random.range(0, Double.pi)
            addBlob(
                to: &field, size: size, x: x, y: y, sigma: sigma, stretch: stretch, angle: angle,
                amplitude: random.range(80, 220))
        }
        // Dim specks.
        for _ in 0..<70 {
            let x = random.range(10, 502), y = random.range(10, 502)
            addBlob(to: &field, size: size, x: x, y: y, sigma: random.range(2, 4), amplitude: random.range(20, 55))
        }
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in pixels.indices {
            var value = Double(field[i]) + 9 + 3.4 * random.gaussian()
            // The brightest cores roll off instead of clipping flat.
            if value > 185 { value = 185 + (value - 185) * 0.5 }
            pixels[i] = UInt8(min(max(value.rounded(), 0), 255))
        }
        guard let stack = try? ImageStack(width: size, height: size, planes: [.gray8(pixels)]) else { return nil }
        var calibration = Calibration()
        calibration.pixelWidth = 0.16
        calibration.pixelHeight = 0.16
        calibration.unit = "µm"
        return try? Hyperstack(title: title, stack: stack, calibration: calibration)
    }

    /// A 256 × 256 16-bit composite of 3 channels and 5 slices, like a confocal stack of cells:
    /// channel 1 (red) has vesicles, channel 2 (green) the cytoplasm and fibres, channel 3 (blue)
    /// the nuclei; each cell is in focus in a different slice.
    static func composite(title: String, seed: UInt64) -> Hyperstack? {
        let size = 256, slices = 5, channels = 3
        var random = Generator(seed: seed)

        struct Fibre {
            let x: Double
            let y: Double
            let sigma: Double
            let angle: Double
            let amplitude: Double
        }
        struct Vesicle {
            let x: Double
            let y: Double
            let sigma: Double
            let amplitude: Double
            /// The slice it is in focus in.
            let focus: Double
        }
        struct Cell {
            let x: Double
            let y: Double
            /// The slice it is in focus in.
            let focus: Double
            let nucleus: Double
            let body: Double
            let stretch: Double
            let angle: Double
            let brightness: Double
            let fibres: [Fibre]
            let vesicles: [Vesicle]
        }
        // A jittered grid of cells, so they do not pile up. Every cell's features are drawn once,
        // so they stay put from slice to slice.
        var cells: [Cell] = []
        for row in 0..<3 {
            for column in 0..<4 {
                let x = (Double(column) + 0.5) * Double(size) / 4 + random.range(-14, 14)
                let y = (Double(row) + 0.5) * Double(size) / 3 + random.range(-12, 12)
                let focus = random.range(0.4, 3.6)
                let nucleus = random.range(10, 15), body = random.range(20, 28)
                let stretch = random.range(0.7, 1), angle = random.range(0, Double.pi)
                // Fibres run outwards from the nucleus.
                var fibres: [Fibre] = []
                for _ in 0..<8 {
                    let direction = random.range(0, 2 * Double.pi), reach = random.range(nucleus * 1.2, body)
                    let tilt = random.range(-0.35, 0.35)
                    fibres.append(
                        Fibre(
                            x: x + reach * cos(direction), y: y + reach * sin(direction), sigma: random.range(6, 11),
                            angle: direction + tilt, amplitude: random.range(2500, 6000)))
                }
                // Vesicles around the nucleus, each at a depth of its own.
                var vesicles: [Vesicle] = []
                for _ in 0..<16 {
                    let direction = random.range(0, 2 * Double.pi), reach = random.range(nucleus * 1.1, body * 0.9)
                    let depthOffset = random.range(-0.9, 0.9)
                    vesicles.append(
                        Vesicle(
                            x: x + reach * cos(direction), y: y + reach * sin(direction), sigma: random.range(1.6, 2.7),
                            amplitude: random.range(20000, 46000), focus: focus + depthOffset))
                }
                cells.append(
                    Cell(
                        x: x, y: y, focus: focus, nucleus: nucleus, body: body, stretch: stretch, angle: angle,
                        brightness: random.range(0.6, 1), fibres: fibres, vesicles: vesicles))
            }
        }
        // How sharply a feature at depth `focus` shows in slice `z`.
        func depth(_ z: Int, _ focus: Double, spread: Double) -> Double {
            exp(-pow(Double(z) - focus, 2) / (2 * spread * spread))
        }

        var planes: [Plane] = []
        var channelMaximum = [Float](repeating: 1, count: channels)
        for z in 0..<slices {
            var red = [Float](repeating: 0, count: size * size)
            var green = red
            var blue = red
            for cell in cells {
                // Nuclei.
                addBlob(
                    to: &blue, size: size, x: cell.x, y: cell.y, sigma: cell.nucleus, stretch: cell.stretch, angle: cell.angle,
                    amplitude: 36000 * cell.brightness * depth(z, cell.focus, spread: 1.1))
                // Cytoplasm, with a hole where the nucleus is, and its fibres.
                let bodyDepth = depth(z, cell.focus, spread: 1.7)
                addBlob(
                    to: &green, size: size, x: cell.x, y: cell.y, sigma: cell.body, stretch: cell.stretch, angle: cell.angle,
                    amplitude: 15000 * cell.brightness * bodyDepth)
                addBlob(
                    to: &green, size: size, x: cell.x, y: cell.y, sigma: cell.nucleus * 0.9,
                    amplitude: -9000 * cell.brightness * bodyDepth)
                for fibre in cell.fibres {
                    addBlob(
                        to: &green, size: size, x: fibre.x, y: fibre.y, sigma: fibre.sigma, stretch: 0.28, angle: fibre.angle,
                        amplitude: fibre.amplitude * bodyDepth)
                }
                // Vesicles.
                for vesicle in cell.vesicles {
                    addBlob(
                        to: &red, size: size, x: vesicle.x, y: vesicle.y, sigma: vesicle.sigma,
                        amplitude: vesicle.amplitude * depth(z, vesicle.focus, spread: 0.7))
                }
            }
            for (c, field) in [red, green, blue].enumerated() {
                var pixels = [UInt16](repeating: 0, count: size * size)
                for i in pixels.indices {
                    let value = Double(field[i]) + 380 + 130 * random.gaussian()
                    pixels[i] = UInt16(min(max(value.rounded(), 0), 65535))
                    channelMaximum[c] = max(channelMaximum[c], Float(pixels[i]))
                }
                planes.append(.gray16(pixels))
            }
        }
        // A channel's display range stops a little under its brightest pixel, as auto-contrast would leave it.
        let luts = [LUT.red, LUT.green, LUT.blue]
        let displays = (0..<channels).map { c in
            ChannelDisplay(lut: luts[c], displayRange: 0...Double((channelMaximum[c] * 0.85).rounded()))
        }
        guard let stack = try? ImageStack(width: size, height: size, planes: planes) else { return nil }
        var calibration = Calibration()
        calibration.pixelWidth = 0.32
        calibration.pixelHeight = 0.32
        calibration.pixelDepth = 1
        calibration.unit = "µm"
        return try? Hyperstack(
            title: title, stack: stack, dimensions: HyperstackDimensions(channels: channels, slices: slices, frames: 1),
            calibration: calibration, channels: displays, compositeMode: .composite)
    }
}
