public import Foundation
public import MancoraCore
import MancoraIO
import MancoraSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An image a bridge command produced.
public struct BridgeImage: Sendable {
    public let image: Hyperstack
    /// ImageJ's title for it.
    public let title: String
    /// The index of the input it replaces, when the command changed an input
    /// in place (most filters); `nil` for a new image.
    public let replacesInput: Int?
}

/// What a command or macro left behind in ImageJ.
public struct BridgeRunResult: Sendable {
    public let images: [BridgeImage]
    public let results: BridgeResults
    /// Everything ImageJ logged meanwhile.
    public let log: String
    /// A macro's return value.
    public let value: String?
    /// The message of the error that stopped the macro, as ImageJ's "Macro Error" dialog shows it, and its line.
    public var macroError: String? = nil
    public var macroErrorLine: Int? = nil
}

/// Runs ImageJ, its plugins and Bio-Formats in a supervised Java helper
/// process (`Resources/Bridge/MancoraBridgeHelper.java`).
///
/// Images go to the helper as TIFF files and come back the same way, so a
/// crash in Java (or the helper being killed) never loses Mancora's data:
/// the bridge starts a new helper and retries the request once.
public actor Bridge {
    public struct Configuration: Sendable {
        public var java: JavaRuntime
        public var home: BridgeHome
        /// `MancoraBridgeHelper.java`, compiled once into the home folder.
        public var helperSource: URL
        /// ImageJ's command table for headless runs (`imagej-commands.tsv`).
        public var commandTable: URL?
        /// The helper's heap limit (`-Xmx`), in megabytes.
        public var maximumHeapMegabytes: Int?
        /// On Linux without a display, give the helper a virtual one (Xvfb)
        /// when it's installed: ImageJ 1.x builds dialogs even when a macro
        /// supplies every option, which AWT refuses to do headless.
        public var useVirtualDisplay = true
        /// How long one request may take.
        public var timeoutSeconds: Double = 3600
        /// Restarts allowed within a minute before the bridge gives up.
        public var maximumRestartsPerMinute = 5
        public var environment: [String: String] = ProcessInfo.processInfo.environment

        public init(java: JavaRuntime, home: BridgeHome, helperSource: URL, commandTable: URL? = nil) {
            self.java = java
            self.home = home
            self.helperSource = helperSource
            self.commandTable = commandTable
        }

        /// The bundled helper and command table in `resources` (an app's
        /// `Resources/Bridge` folder), the first Java found, and the standard home.
        public static func standard(resources: URL) throws(BridgeError) -> Configuration {
            guard let java = JavaRuntime.discover() else { throw .noJava }
            let table = resources.appendingPathComponent("imagej-commands.tsv")
            return Configuration(
                java: java, home: .standard(), helperSource: resources.appendingPathComponent("MancoraBridgeHelper.java"),
                commandTable: FileManager.default.fileExists(atPath: table.path) ? table : nil)
        }
    }

    public let configuration: Configuration
    private var connection: HelperConnection?
    private var nextID = 1
    private var recentLaunches: [Date] = []
    private let workRoot: URL
    /// The Xvfb server the helper draws its (never shown) dialogs on, when there's no display.
    private var virtualDisplay: (process: Process, name: String)?
    /// How many helper processes have been started, including restarts.
    public private(set) var launchCount = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bridge-\(UUID().uuidString)")
        #if !os(Windows)
        // Writing to a helper that just died must fail with an error, not end Mancora.
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    /// The running helper's process ID, if it's running.
    public var helperProcessIdentifier: Int32? {
        connection?.isRunning == true ? connection?.processIdentifier : nil
    }

    /// Starts the helper (compiling it first if needed) and says hello.
    @discardableResult
    public func start() async throws -> BridgeHello {
        try await call("hello", NoParams?.none, as: BridgeHello.self, retry: false)
    }

    /// Every command ImageJ and the installed plugins provide, sorted by name.
    public func commands() async throws -> [BridgeCommand] {
        try await call("commands", NoParams?.none, as: CommandsResult.self, retry: true).commands
    }

    /// Runs an ImageJ command with an options string (as recorded by
    /// ImageJ's macro recorder) on `images`, the last one being active.
    public func run(_ command: String, options: String = "", images: [Hyperstack] = []) async throws -> BridgeRunResult {
        try await withImages(images, method: "run") { inputs, outputDir in
            RunParams(command: command, options: options, inputs: inputs, outputDir: outputDir)
        }
    }

    /// Runs ImageJ macro code with `images` open, the last one active.
    public func runMacro(_ code: String, argument: String = "", images: [Hyperstack] = []) async throws -> BridgeRunResult {
        try await withImages(images, method: "macro") { inputs, outputDir in
            MacroParams(code: code, argument: argument, inputs: inputs, outputDir: outputDir)
        }
    }

    /// Opens a file in a format Mancora doesn't read, as ImageJ (with Fiji's
    /// extra file types) or Bio-Formats does when installed. The result's
    /// value names the reader: "ImageJ" or "Bio-Formats".
    public func open(_ path: String) async throws -> BridgeRunResult {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        return try await withImages([], method: "open") { _, outputDir in OpenParams(path: absolute, outputDir: outputDir) }
    }

    /// Asks the helper to exit, and stops it if it doesn't.
    public func stop() async {
        if let connection, connection.isRunning {
            _ = try? await call("shutdown", NoParams?.none, as: EmptyResult.self, retry: false)
            connection.terminate()
        }
        connection = nil
        if let display = virtualDisplay { Self.stopVirtualDisplay(display.process, name: display.name, removingFiles: true) }
        virtualDisplay = nil
        try? FileManager.default.removeItem(at: workRoot)
    }

    /// Children inherit the signal mask of the thread that starts them, and
    /// Swift's concurrency threads block SIGTERM, so Xvfb is killed outright
    /// and its socket and lock file removed for it.
    private static func stopVirtualDisplay(_ process: Process, name: String, removingFiles: Bool) {
        guard process.isRunning else { return }
        #if os(Windows)
        process.terminate()
        #else
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        guard removingFiles else { return }
        let number = name.dropFirst()
        try? FileManager.default.removeItem(atPath: "/tmp/.X11-unix/X\(number)")
        try? FileManager.default.removeItem(atPath: "/tmp/.X\(number)-lock")
        #endif
    }

    /// Makes the helper exit without answering (for testing recovery).
    public func crashHelperForTesting() async {
        _ = try? await call("crash", NoParams?.none, as: EmptyResult.self, retry: false)
    }

    // MARK: Requests

    private struct EmptyResult: Decodable {}

    private func withImages<P: Encodable>(
        _ images: [Hyperstack], method: String, params: (_ inputs: [String], _ outputDir: String) -> P
    ) async throws -> BridgeRunResult {
        let request = workRoot.appendingPathComponent("request-\(nextID)")
        let outputs = request.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: request) }
        var inputs: [String] = []
        for (k, image) in images.enumerated() {
            // ImageJ titles images after their file, so keep each image's title.
            let folder = request.appendingPathComponent("input-\(k)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent(Self.fileName(for: image.title)).path
            try TIFFExporter.write(image, to: path)
            inputs.append(path)
        }
        let result = try await call(method, params(inputs, outputs.path), as: RunResult.self, retry: true)
        var produced: [BridgeImage] = []
        for output in result.outputs {
            var image = try TIFFImporter.read(path: output.path)
            image.title = output.title
            produced.append(
                BridgeImage(image: image, title: output.title, replacesInput: output.replaces.flatMap(inputs.firstIndex(of:))))
        }
        return BridgeRunResult(
            images: produced, results: result.results, log: result.log, value: result.value,
            macroError: result.macroError, macroErrorLine: result.macroErrorLine)
    }

    private func call<P: Encodable, R: Decodable>(_ method: String, _ params: P?, as type: R.Type, retry: Bool)
        async throws -> R
    {
        do {
            return try await attempt(method, params, as: type)
        } catch BridgeError.helperExited where retry {
            // The helper died (or was killed): start a new one and try once more.
            connection = nil
            return try await attempt(method, params, as: type)
        }
    }

    private func attempt<P: Encodable, R: Decodable>(_ method: String, _ params: P?, as type: R.Type) async throws -> R {
        let connection = try await running()
        let id = nextID
        nextID += 1
        let line = try JSONEncoder().encode(BridgeRequest(id: id, method: method, params: params))
        let timeout = configuration.timeoutSeconds
        let timer = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            connection.fail(id: id, with: BridgeError.timedOut(seconds: timeout))
            // A helper that doesn't answer may never answer again: the next request starts a new one.
            connection.terminate()
        }
        defer { timer.cancel() }
        let data = try await connection.send(id: id, line: line)
        let header: ResponseHeader
        do {
            header = try JSONDecoder().decode(ResponseHeader.self, from: data)
        } catch {
            throw BridgeError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = header.error { throw BridgeError.helper(error, log: header.log ?? "") }
        do {
            return try JSONDecoder().decode(Response<R>.self, from: data).result
        } catch {
            throw BridgeError.invalidResponse("\(error)")
        }
    }

    // MARK: The helper process

    private func running() async throws -> HelperConnection {
        if let connection, connection.isRunning { return connection }
        let now = Date()
        recentLaunches = recentLaunches.filter { now.timeIntervalSince($0) < 60 }
        guard recentLaunches.count < configuration.maximumRestartsPerMinute else {
            throw BridgeError.helperExited(status: -1)
        }
        let launch = try helperLaunch()
        let started = try HelperConnection(launch)
        recentLaunches.append(now)
        launchCount += 1
        connection = started
        return started
    }

    /// The java command line, compiling the helper into the home folder first if needed.
    func helperLaunch() throws -> HelperLaunch {
        let config = configuration
        let home = config.home
        guard FileManager.default.fileExists(atPath: home.imageJJar.path) else {
            throw BridgeError.imageJMissing(path: home.imageJJar.path)
        }
        try home.createFolders()
        let classes = try compiledHelper()
        let separator = JavaRuntime.isWindows ? ";" : ":"
        let classPath = (home.classPath().map(\.path) + [classes.path]).joined(separator: separator)
        var arguments: [String] = []
        if let heap = config.maximumHeapMegabytes { arguments.append("-Xmx\(heap)m") }
        arguments += ["-Dplugins.dir=\(home.root.path)", "-Dij.dir=\(home.root.path)", "-Dfile.encoding=UTF-8"]
        if FileManager.default.fileExists(atPath: home.nativeLibraries.path) {
            arguments.append("-Djava.library.path=\(home.nativeLibraries.path)")
        }
        if let table = config.commandTable { arguments.append("-Dmancora.commands=\(table.path)") }
        #if os(macOS)
        arguments.append("-Dapple.awt.UIElement=true")  // no Dock icon or menu bar for the helper
        #endif
        var environment = config.environment
        #if os(Linux)
        let display = (environment["DISPLAY"] ?? "") + (environment["WAYLAND_DISPLAY"] ?? "")
        if display.isEmpty {
            if config.useVirtualDisplay, let name = startVirtualDisplay() {
                environment["DISPLAY"] = name
            } else {
                arguments.append("-Djava.awt.headless=true")
            }
        }
        #endif
        arguments += ["-cp", classPath, "MancoraBridgeHelper"]
        return HelperLaunch(executable: config.java.executable, arguments: arguments, environment: environment)
    }

    /// Starts Xvfb on a free display number (once; helpers that restart
    /// reuse it) and returns its name, e.g. `":99"`, or `nil` without Xvfb.
    func startVirtualDisplay() -> String? {
        if let display = virtualDisplay, display.process.isRunning { return display.name }
        guard let xvfb = Self.findOnPath("Xvfb", environment: configuration.environment) else { return nil }
        let sockets = "/tmp/.X11-unix"
        for number in 99..<199 where !FileManager.default.fileExists(atPath: "\(sockets)/X\(number)")
            && !FileManager.default.fileExists(atPath: "/tmp/.X\(number)-lock")
        {
            let process = Process()
            process.executableURL = xvfb
            process.arguments = [":\(number)", "-screen", "0", "1280x1024x24", "-nolisten", "tcp"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            // Wait (up to 5 s) for the server's socket before handing it to
            // Java, and make sure the server is ours: another bridge may have
            // taken the number first, and Xvfb's lock file names the winner.
            let lock = "/tmp/.X\(number)-lock"
            for _ in 0..<100 where process.isRunning {
                let owner = (try? String(contentsOfFile: lock, encoding: .utf8))
                    .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let owner, owner != process.processIdentifier { break }
                if owner != nil, FileManager.default.fileExists(atPath: "\(sockets)/X\(number)") {
                    virtualDisplay = (process, ":\(number)")
                    return ":\(number)"
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Lost a race for this number, or Xvfb failed: try the next one.
            Self.stopVirtualDisplay(process, name: ":\(number)", removingFiles: false)
        }
        return nil
    }

    /// `<home>/helper/<hash of the source>/`, compiled with `javac` once.
    /// Each compile writes a folder of its own and renames it into place,
    /// so bridges starting together never run a half-written helper.
    func compiledHelper() throws -> URL {
        let config = configuration
        let source = try Data(contentsOf: config.helperSource)
        let hash = hexString(SHA256.hash([UInt8](source) + Array(BridgeHome.imageJVersion.utf8))).prefix(16)
        let folder = config.home.root.appendingPathComponent("helper").appendingPathComponent(String(hash))
        let compiled = folder.appendingPathComponent("MancoraBridgeHelper.class")
        if FileManager.default.fileExists(atPath: compiled.path) { return folder }
        guard let javac = config.java.compiler else { throw BridgeError.noCompiler }
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".\(hash)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let process = Process()
        process.executableURL = javac
        process.arguments = [
            "-encoding", "UTF-8", "-nowarn", "-cp", config.home.imageJJar.path, "-d", staging.path,
            config.helperSource.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let staged = staging.appendingPathComponent("MancoraBridgeHelper.class")
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: staged.path) else {
            throw BridgeError.compileFailed(String(decoding: output, as: UTF8.self))
        }
        // Another bridge may have renamed its copy (the same one) into place first.
        if (try? FileManager.default.moveItem(at: staging, to: folder)) == nil,
            !FileManager.default.fileExists(atPath: compiled.path)
        {
            // A folder without the helper, left by an interrupted compile.
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: staging, to: folder)
        }
        return folder
    }

    /// A file name that keeps `title` as ImageJ will show it.
    static func fileName(for title: String) -> String {
        let cleaned = String(title.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "_" : $0 })
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled.tif" : cleaned
    }

    static func findOnPath(_ tool: String, environment: [String: String]) -> URL? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
