import AppKit
import Foundation
import MancoraBridge
import MancoraCore
import MancoraUpdate
import Observation

/// The app's Java bridge: ImageJ and its plugins in a helper process,
/// set up on first use (find Java, install ImageJ, start the helper).
@Observable
final class AppBridge {
    enum State: Equatable {
        case idle
        case starting
        case ready(imagej: String, java: String)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var commands: [BridgeCommand] = []
    @ObservationIgnored private var bridge: Bridge?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Commands that come from plugin jars rather than ImageJ itself.
    var pluginCommands: [BridgeCommand] { commands.filter(\.isPlugin) }

    /// The helper and command table: inside Mancora.app, or in the source
    /// tree when run with `swift run`.
    static let resources: URL? = {
        if let bundled = Bundle.main.url(forResource: "Bridge", withExtension: nil) { return bundled }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Bridge")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("MancoraBridgeHelper.java").path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    /// Finds Java, installs ImageJ if needed and starts the helper.
    func start() async {
        if isReady || state == .starting { return }
        state = .starting
        do {
            guard let resources = Self.resources else { throw BridgeError.imageJMissing(path: "Resources/Bridge") }
            let configuration = try Bridge.Configuration.standard(resources: resources)
            try await configuration.home.installImageJ(
                client: URLSessionHTTPClient(userAgent: "Mancora/\(MancoraVersion.number)"))
            let bridge = Bridge(configuration: configuration)
            let hello = try await bridge.start()
            commands = try await bridge.commands()
            self.bridge = bridge
            state = .ready(imagej: hello.imagej, java: hello.java)
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Runs an ImageJ command (or macro) on `image`; the bridge restarts the
    /// helper by itself if it has died.
    /// Runs a command with several images open, the last one active.
    func run(_ command: String, options: String = "", images: [Hyperstack]) async throws -> BridgeRunResult {
        if !isReady { await start() }
        guard let bridge else { throw BridgeError.helperExited(status: -1) }
        return try await bridge.run(command, options: options, images: images)
    }

    func run(_ command: String, options: String = "", on image: Hyperstack?) async throws -> BridgeRunResult {
        if !isReady { await start() }
        guard let bridge else { throw BridgeError.helperExited(status: -1) }
        return try await bridge.run(command, options: options, images: image.map { [$0] } ?? [])
    }

    func runMacro(_ code: String, on image: Hyperstack?) async throws -> BridgeRunResult {
        try await runMacro(code, images: image.map { [$0] } ?? [])
    }

    /// Runs a macro on `images`, the last one current.
    func runMacro(_ code: String, images: [Hyperstack]) async throws -> BridgeRunResult {
        if !isReady { await start() }
        guard let bridge else { throw BridgeError.helperExited(status: -1) }
        return try await bridge.runMacro(code, images: images)
    }

    /// The dialogs `command` would show for `image`, to ask for its options natively.
    func describeDialog(_ command: String, images: [Hyperstack]) async throws -> BridgeDialogs {
        if !isReady { await start() }
        guard let bridge else { throw BridgeError.helperExited(status: -1) }
        return try await bridge.describeDialog(command, images: images)
    }

    /// Opens a file Mancora can't read in ImageJ (or Bio-Formats, if installed).
    func open(_ path: String) async throws -> BridgeRunResult {
        if !isReady { await start() }
        guard let bridge else { throw BridgeError.helperExited(status: -1) }
        return try await bridge.open(path)
    }

    func stop() async {
        await bridge?.stop()
        bridge = nil
        state = .idle
    }
}

enum BridgeFileName {
    /// A file name that keeps `title` (ImageJ titles images after their file).
    static func safe(_ title: String) -> String {
        let cleaned = String(title.map { "/:\\".contains($0) ? "_" : $0 })
        let name = cleaned.isEmpty ? "Untitled" : cleaned
        return name.lowercased().hasSuffix(".tif") || name.lowercased().hasSuffix(".tiff") ? name : name + ".tif"
    }
}
