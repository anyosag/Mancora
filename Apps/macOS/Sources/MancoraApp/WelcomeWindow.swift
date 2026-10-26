import AppKit
import MancoraBridge
import MancoraCore
import MancoraFiji
import Observation
import SwiftUI

// The welcome window: what Mancora shows at launch when there is no image to
// look at, and from Window ▸ Welcome to Mancora. The app icon, name and
// version, ways to get an image (Open…, a sample, a new image), the images
// opened lately, and a line about the image-processing engine. Files dropped
// on it open.

// MARK: Recent images

/// The images opened lately, newest first. Mancora keeps its own short list
/// (the app is not document-based, so the system's has nothing in it).
@Observable
final class RecentFiles {
    static let shared = RecentFiles()
    static let limit = 10
    private static let key = "RecentImages"

    private(set) var urls: [URL]

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }
    }

    /// Remembers an image as the newest. Files Mancora makes for the images
    /// commands create (in the temporary folder) are not worth remembering.
    func note(_ url: URL) {
        guard url.isFileURL, !Self.isTemporary(url) else { return }
        let file = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == file }
        urls.insert(file, at: 0)
        if urls.count > Self.limit { urls.removeLast(urls.count - Self.limit) }
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        save()
    }

    func clear() {
        urls = []
        save()
    }

    /// Forgets files that are gone.
    func prune() {
        let kept = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard kept.count != urls.count else { return }
        urls = kept
        save()
    }

    /// A list to show for now, which is not stored (the screenshot run uses this).
    func show(_ files: [URL]) {
        urls = files
    }

    private func save() {
        guard !Screenshots.isActive else { return }
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.key)
    }

    private static func isTemporary(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(temporary)
    }
}

// MARK: The app icon and the engine

enum AppIcon {
    /// The bundle's icon. Run unpackaged (`swift run`, the CI build) there is none, so the
    /// same artwork is read from the source tree, as the bridge finds its resources.
    static let image: NSImage = {
        if Bundle.main.bundleIdentifier == nil, let found = sourceTreeIcon() { return found }
        return NSApplication.shared.applicationIconImage
    }()

    private static func sourceTreeIcon() -> NSImage? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Branding/AppIcon.appiconset/icon_512x512@2x.png")
            if FileManager.default.fileExists(atPath: candidate.path) { return NSImage(contentsOf: candidate) }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// What the welcome window's footer says about the image-processing engine.
struct EngineStatus {
    enum Level {
        case ready, working, inactive, failed
    }

    let text: String
    let level: Level
    var detail: String?
    /// How far a download has come, 0...1, when there is one to show.
    var fraction: Double?
}

extension AppBridge {
    /// The engine's status for the welcome window's footer: Fiji, which Mancora downloads on first
    /// use and keeps up to date; an ImageJ from before Fiji until Fiji is there.
    var engineStatus: EngineStatus {
        switch FijiState.shared.status {
        case .installing(let progress):
            return EngineStatus(
                text: FijiText.progress(progress), level: .working, fraction: progress.phase == .downloading ? progress.fractionCompleted : nil)
        case .updating:
            return EngineStatus(text: "Updating Fiji…", level: .working)
        case .installed(let version):
            switch state {
            case .starting:
                return EngineStatus(text: "Starting Fiji…", level: .working)
            case .failed(let message):
                return EngineStatus(text: "Fiji unavailable", level: .failed, detail: message)
            case .idle, .ready:
                return EngineStatus(text: FijiText.name(version) + " ready", level: .ready)
            }
        case .notInstalled:
            return imageJStatus
        }
    }

    /// Without Fiji: an ImageJ that an earlier Mancora installed keeps working, and Fiji is offered.
    private var imageJStatus: EngineStatus {
        let hasImageJ = BridgeHome.standard().hasImageJ
        switch state {
        case .ready(let imagej, _):
            return EngineStatus(text: "ImageJ \(imagej) ready", level: .ready, detail: "Fiji not installed")
        case .starting:
            return EngineStatus(text: "Starting ImageJ…", level: .working)
        case .failed(let message):
            return EngineStatus(text: "ImageJ unavailable", level: .failed, detail: message)
        case .idle:
            if hasImageJ {
                return EngineStatus(text: "ImageJ installed", level: .inactive, detail: "Fiji not installed")
            }
            return EngineStatus(text: "Fiji not installed", level: .inactive, detail: "Downloads on first use")
        }
    }
}

// MARK: The window

struct WelcomeView: View {
    let bridge: AppBridge
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var showsSamples = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingPane
                    .frame(width: 330)
                Divider()
                recentPane
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 480)
        .overlay { dropHint }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            openImages(urls)
            return urls.contains { $0.isFileURL }
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onOpenURL { url in openImages([url]) }
        .onAppear { RecentFiles.shared.prune() }
    }

    // MARK: Panes

    private var leadingPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("Mancora")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, 6)
                Text("Version \(MancoraVersion.number)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer().frame(height: 26)
            VStack(spacing: 2) {
                Button(action: openPanel) {
                    ActionRow(
                        symbol: "folder", title: "Open…", detail: "An image or stack from disk",
                        shortcut: CommandCatalog.places["Open..."]?.shortcut)
                }
                .buttonStyle(.plain)
                // A row like the others that opens a list: macOS draws a Menu's
                // custom label flattened, which lost the row's layout.
                Button { showsSamples = true } label: {
                    ActionRow(symbol: "photo.on.rectangle", title: "Open Sample", detail: "Try one of ImageJ's samples")
                }
                .buttonStyle(.plain)
                .disabled(Self.sampleNames.isEmpty)
                .popover(isPresented: $showsSamples, arrowEdge: .trailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Self.sampleNames, id: \.self) { name in
                                Button {
                                    showsSamples = false
                                    openSample(name)
                                } label: {
                                    Text(MenuCommandButton.title(name))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(width: 240, height: 360)
                }
                Button(action: newImage) {
                    ActionRow(
                        symbol: "plus.square", title: "New Image…", detail: "Create a blank image",
                        shortcut: CommandCatalog.places["Image..."]?.shortcut)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }

    private var recentPane: some View {
        let urls = RecentFiles.shared.urls
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.headline)
                Spacer()
                if !urls.isEmpty {
                    Button("Clear") { RecentFiles.shared.clear() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 36)
            .padding(.bottom, 10)
            if urls.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Images", systemImage: "clock")
                } description: {
                    Text("Images you open appear here.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(urls, id: \.self) { url in
                            RecentRow(url: url) { openImages([url]) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var footer: some View {
        let status = bridge.engineStatus
        HStack(spacing: 7) {
            Circle()
                .fill(Self.color(for: status.level))
                .frame(width: 8, height: 8)
            Text(status.text)
                .font(.callout)
            if let fraction = status.fraction {
                ProgressView(value: fraction)
                    .frame(width: 110)
            }
            if let detail = status.detail {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !FijiState.shared.isInstalled, status.level != .working {
                Button("Download Fiji…") { Task { await bridge.downloadFiji() } }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
        .help(status.detail ?? status.text)
    }

    @ViewBuilder private var dropHint: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 44, weight: .light))
                    Text("Drop to Open")
                        .font(.title2.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private static func color(for level: EngineStatus.Level) -> Color {
        switch level {
        case .ready: Color.green
        case .working: Color.orange
        case .inactive: Color.secondary
        case .failed: Color.red
        }
    }

    // MARK: Actions

    /// ImageJ's File ▸ Open Samples.
    static var sampleNames: [String] {
        for entry in ImageJMenuCommands.menu("File").entries {
            if case .submenu(let menu) = entry, menu.title == "Open Samples" { return menu.commands }
        }
        return []
    }

    /// File ▸ Open.
    private func openPanel() {
        AppMenuActions.openFile(virtual: false, viewer: nil, openWindow: openWindow)
    }

    /// As the menu runs it with no image window: a new one runs the command and shows what it makes.
    private func openSample(_ name: String) {
        AppMenuActions.perform(name, viewer: nil, bridge: bridge, openWindow: openWindow)
    }

    /// File ▸ New ▸ Image…
    private func newImage() {
        AppMenuActions.perform("Image...", viewer: nil, bridge: bridge, openWindow: openWindow)
    }

    /// Files dropped on the window, picked from the recent list or opened from the Finder.
    private func openImages(_ urls: [URL]) {
        for url in urls where url.isFileURL && !Self.isFolder(url) {
            AppRecorder.shared.recordOpen(url, virtual: false)
            openWindow(id: "viewer", value: OpenRequest(url: url))
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: Rows

    /// One of the three ways to get an image: a symbol, a title, a line under it, a shortcut.
    private struct ActionRow: View {
        let symbol: String
        let title: String
        let detail: String
        var shortcut: String?
        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.callout)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovering = $0 }
        }
    }

    /// One recent image: its icon, name and folder.
    private struct RecentRow: View {
        let url: URL
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.folder(of: url))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(url.path)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Remove from Recent") { RecentFiles.shared.remove(url) }
            }
        }

        private static func folder(of url: URL) -> String {
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }
}

// MARK: Menu and image windows

/// Window ▸ Welcome to Mancora.
struct WelcomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Welcome to Mancora") { openWindow(id: "welcome") }
        }
    }
}

/// What an image window does as it opens: the welcome window, which is for when there is nothing
/// to look at, gives way to it (in the screenshot run it stays, as the run's way to open windows),
/// and the file it opens is remembered as a recent one.
struct ImageWindowOpening: ViewModifier {
    let request: OpenRequest?
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !Screenshots.isActive { dismissWindow(id: "welcome") }
            }
            .onChange(of: request, initial: true) {
                if let url = request?.url { RecentFiles.shared.note(url) }
            }
    }
}
