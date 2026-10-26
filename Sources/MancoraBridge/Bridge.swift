public import Foundation
public import MancoraCore
public import MancoraFiji
import MancoraIO
import MancoraPlugins
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
    /// A macro's or script's return value.
    public let value: String?
    /// The message of the error that stopped the macro, as ImageJ's "Macro Error" dialog shows it, and its line.
    public var macroError: String? = nil
    public var macroErrorLine: Int? = nil
    /// A SciJava module's or script's outputs that aren't images, by name.
    public var outputValues: [String: BridgeValue] = [:]
    /// The exception that stopped a script, e.g. `groovy.lang.MissingPropertyException: …` (its trace is in the log).
    public var scriptError: String? = nil
}

/// Runs ImageJ, its plugins and Bio-Formats in a supervised Java helper
/// process (`Resources/Bridge/MancoraBridgeHelper.java`): inside Fiji when
/// one is installed (``Configuration/fiji``), plain ImageJ otherwise.
///
/// Images go to the helper as TIFF files and come back the same way, so a
/// crash in Java (or the helper being killed) never loses Mancora's data:
/// the bridge starts a new helper and retries the request once.
public actor Bridge {
    public struct Configuration: Sendable {
        /// The Java for plain ImageJ; in Fiji, Fiji's bundled Java is used.
        public var java: JavaRuntime
        /// Plain ImageJ's folder (``BridgeHome``); the compiled helper is kept there in either mode.
        public var home: BridgeHome
        /// Run inside this Fiji instead: its bundled Java and class path, with
        /// ImageJ2 and its legacy layer, so ImageJ 1.x is Fiji's own `ij.jar`
        /// and SciJava's commands and scripts run too
        /// (`MancoraFijiBridge.java`, beside the helper). A staged update is
        /// swapped in before each helper starts, and updates wait while one runs.
        public var fiji: FijiManager?
        /// Whether requests show ImageJ's dialogs and windows for someone to
        /// use, rather than closing them (batch, as tests run): a plugin's own
        /// window (TrackMate's, Labkit's) stays up, and on macOS the helper gets
        /// a Dock icon. A request's `interactive` argument overrides it. With
        /// only a virtual display (Xvfb), every request is batch.
        public var interactive = false
        /// The helper's name in the Dock (macOS), when interactive.
        public var dockName = "Fiji"
        /// The helper's Dock icon (macOS), when interactive; Fiji's own if `nil`.
        public var dockIcon: URL?
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
        /// `Resources/Bridge` folder) and the standard home: in the installed
        /// Fiji (``FijiManager/shared``) unless `preferFiji` is false or none
        /// is installed, else plain ImageJ on the first Java found.
        public static func standard(resources: URL, preferFiji: Bool = true) throws(BridgeError) -> Configuration {
            let helper = resources.appendingPathComponent("MancoraBridgeHelper.java")
            let table = resources.appendingPathComponent("imagej-commands.tsv")
            let commandTable = FileManager.default.fileExists(atPath: table.path) ? table : nil
            if preferFiji, FijiManager.shared.isInstalled, let java = FijiManager.shared.installation.javaExecutable,
                let runtime = JavaRuntime.probe(java)
            {
                var configuration = Configuration(java: runtime, home: .standard(), helperSource: helper, commandTable: commandTable)
                configuration.fiji = .shared
                return configuration
            }
            guard let java = JavaRuntime.discover() else { throw .noJava }
            return Configuration(java: java, home: .standard(), helperSource: helper, commandTable: commandTable)
        }

        /// `MancoraFijiBridge.java`, beside the helper.
        public var fijiHelperSource: URL {
            helperSource.deletingLastPathComponent().appendingPathComponent("MancoraFijiBridge.java")
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

    /// Every entry of ImageJ's menus, in order (Fiji's, in Fiji: ImageJ 1.x
    /// commands, SciJava commands and scripts, with separators), for an
    /// app's menus. ``BridgeMenuItem/command`` is what ``run(_:options:images:interactive:)`` takes.
    public func menus() async throws -> [BridgeMenuItem] {
        try await call("menus", NoParams?.none, as: MenusResult.self, retry: true).menus
    }

    /// Runs an ImageJ command with an options string (as recorded by
    /// ImageJ's macro recorder) on `images`, the last one being active. In
    /// Fiji that includes every SciJava command and script in its menus.
    ///
    /// `interactive` (by default ``Configuration/interactive``) shows the
    /// command's dialogs and windows for someone to use; with empty options
    /// its dialog then asks. Images a plugin's own window goes on using stay
    /// open in the helper (``openImages()`` fetches them).
    public func run(_ command: String, options: String = "", images: [Hyperstack] = [], interactive: Bool? = nil) async throws
        -> BridgeRunResult
    {
        try await withImages(images, method: "run") { inputs, titles, outputDir in
            RunParams(command: command, options: options, inputs: inputs, titles: titles, outputDir: outputDir, interactive: interactive)
        }
    }

    /// Runs ImageJ macro code with `images` open, the last one active.
    public func runMacro(_ code: String, argument: String = "", images: [Hyperstack] = [], interactive: Bool? = nil)
        async throws -> BridgeRunResult
    {
        try await withImages(images, method: "macro") { inputs, titles, outputDir in
            MacroParams(code: code, argument: argument, inputs: inputs, titles: titles, outputDir: outputDir, interactive: interactive)
        }
    }

    /// Runs a SciJava module in Fiji: `command` is a command's class
    /// (`net.imagej.plugins.commands.app.AboutImageJ`), a module identifier
    /// (`command:<class>`, `script:<path>`), a menu path
    /// (`"Plugins > Tracking > TrackMate"`) or a menu label. `parameters`
    /// set its inputs by name, converted as SciJava converts them (an image
    /// input takes an open image's title); image inputs left unset take the
    /// active image, the last of `images`. Image outputs come back as
    /// images, others in ``BridgeRunResult/outputValues``. An ImageJ 1.x
    /// command found this way runs as ``run(_:options:images:interactive:)``
    /// would, with the parameters as its options.
    ///
    /// A batch run never asks for anything: inputs left unset keep their
    /// defaults. An interactive one asks for them in SciJava's dialog.
    public func runCommand(
        _ command: String, parameters: [String: BridgeValue] = [:], images: [Hyperstack] = [], interactive: Bool? = nil
    ) async throws -> BridgeRunResult {
        try await withImages(images, method: "module") { inputs, titles, outputDir in
            ModuleParams(
                command: command, parameters: parameters, inputs: inputs, titles: titles, outputDir: outputDir, interactive: interactive)
        }
    }

    /// Runs a script in any language Fiji has (``scriptLanguages()``: a
    /// name, alias or extension such as `groovy`, `python`, `js`, `ijm`)
    /// through SciJava's script service, with `#@` parameters set from
    /// `parameters` and `images` open, the last one active. The return
    /// value comes back as ``BridgeRunResult/value``, `#@output`s as
    /// ``BridgeRunResult/outputValues`` (images as images), what the script
    /// printed in the log, and an exception that stopped it as
    /// ``BridgeRunResult/scriptError``.
    public func runScript(
        _ code: String, language: String, parameters: [String: BridgeValue] = [:], images: [Hyperstack] = [],
        interactive: Bool? = nil
    ) async throws -> BridgeRunResult {
        try await withImages(images, method: "script") { inputs, titles, outputDir in
            ScriptParams(
                language: language, code: code, parameters: parameters, inputs: inputs, titles: titles, outputDir: outputDir,
                interactive: interactive)
        }
    }

    /// The script languages Fiji has.
    public func scriptLanguages() async throws -> [BridgeScriptLanguage] {
        try await call("languages", NoParams?.none, as: LanguagesResult.self, retry: true).languages
    }

    /// The images open in the helper: those interactive requests left shown
    /// for a plugin's window, as that window has changed them.
    public func openImages() async throws -> BridgeRunResult {
        try await withImages([], method: "images") { _, _, outputDir in ImagesParams(outputDir: outputDir) }
    }

    /// Opens a file in a format Mancora doesn't read, as ImageJ (with Fiji's
    /// extra file types) or Bio-Formats does when installed. The result's
    /// value names the reader: "ImageJ" or "Bio-Formats".
    public func open(_ path: String) async throws -> BridgeRunResult {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        return try await withImages([], method: "open") { _, _, outputDir in OpenParams(path: absolute, outputDir: outputDir) }
    }

    /// The dialogs `command` shows for `images` (the last one active), so a
    /// native dialog can ask for its options. Empty for commands without one.
    public func describeDialog(_ command: String, images: [Hyperstack] = []) async throws -> BridgeDialogs {
        let request = workRoot.appendingPathComponent("request-\(nextID)")
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: request) }
        var inputs: [String] = []
        for (k, image) in images.enumerated() {
            let folder = request.appendingPathComponent("input-\(k)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent(Self.fileName(for: image.title)).path
            try TIFFExporter.write(image, to: path)
            inputs.append(path)
        }
        return try await call(
            "dialog", DialogParams(command: command, inputs: inputs, outputDir: request.path), as: BridgeDialogs.self, retry: true)
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
        _ images: [Hyperstack], method: String, params: (_ inputs: [String], _ titles: [String], _ outputDir: String) -> P
    ) async throws -> BridgeRunResult {
        let request = workRoot.appendingPathComponent("request-\(nextID)")
        let outputs = request.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: request) }
        var inputs: [String] = []
        for (k, image) in images.enumerated() {
            // Named after its title as far as a file name can be (ImageJ keeps the
            // file name too); the helper gives the image its title as it is.
            let folder = request.appendingPathComponent("input-\(k)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent(Self.fileName(for: image.title)).path
            try TIFFExporter.write(image, to: path)
            inputs.append(path)
        }
        let result = try await call(method, params(inputs, images.map(\.title), outputs.path), as: RunResult.self, retry: true)
        var produced: [BridgeImage] = []
        for output in result.outputs {
            var image = try TIFFImporter.read(path: output.path)
            image.title = output.title
            produced.append(
                BridgeImage(image: image, title: output.title, replacesInput: output.replaces.flatMap(inputs.firstIndex(of:))))
        }
        return BridgeRunResult(
            images: produced, results: result.results, log: result.log, value: result.value,
            macroError: result.macroError, macroErrorLine: result.macroErrorLine, outputValues: result.values ?? [:],
            scriptError: result.scriptError)
    }

    private func call<P: Encodable, R: Decodable>(_ method: String, _ params: P?, as type: R.Type, retry: Bool)
        async throws -> R
    {
        do {
            return try await attempt(method, params, as: type)
        } catch BridgeError.helperExited where retry {
            // The helper died (or was killed): try once more on a new one, which
            // another request that was waiting on it may have started already.
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
        }
        defer { timer.cancel() }
        let data: Data
        do {
            data = try await connection.send(id: id, line: line)
        } catch let error as BridgeError {
            switch error {
            case .timedOut, .helperExited:
                // A helper that timed out is still busy with the request, and
                // answers in order: stop it, so the next request gets a new one.
                connection.terminate()
                // Forget this helper only, not one another request has started since.
                if self.connection === connection { self.connection = nil }
            default: break
            }
            throw error
        }
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
        // In Fiji: a staged update goes in first, and the installation is held while the helper runs.
        let lease = try await configuration.fiji?.prepareForLaunch()
        let started: HelperConnection
        do {
            let launch = try helperLaunch(fiji: lease?.installation)
            var onExit: (@Sendable () -> Void)?
            if let lease { onExit = { lease.release() } }
            started = try HelperConnection(launch, onExit: onExit)
        } catch {
            lease?.release()
            throw error
        }
        recentLaunches.append(now)
        launchCount += 1
        connection = started
        return started
    }

    /// The java command line, compiling the helper into the home folder
    /// first if needed: plain ImageJ from the home folder, or in `fiji`.
    func helperLaunch(fiji: FijiInstallation? = nil) throws -> HelperLaunch {
        let config = configuration
        let home = config.home
        if fiji == nil, !FileManager.default.fileExists(atPath: home.imageJJar.path) {
            throw BridgeError.imageJMissing(path: home.imageJJar.path)
        }
        try home.createFolders()
        let classes = try compiledHelper(fiji: fiji)
        var environment = config.environment
        var display = HelperDisplay.own
        #if os(Linux)
        // Java names files in the locale's encoding (sun.jnu.encoding): outside a
        // UTF-8 locale it can't open a path, or an input titled, beyond ASCII.
        if !Self.isUTF8Locale(environment) { environment["LC_ALL"] = "C.UTF-8" }
        if ((environment["DISPLAY"] ?? "") + (environment["WAYLAND_DISPLAY"] ?? "")).isEmpty {
            if config.useVirtualDisplay, let name = startVirtualDisplay() {
                environment["DISPLAY"] = name
                display = .virtual
            } else {
                display = .headless
            }
        }
        #endif
        var arguments = Self.javaArguments(config, fiji: fiji, classes: classes, display: display)
        let java = fiji?.javaExecutable ?? config.java.executable
        if JavaRuntime.isWindows, fiji != nil {
            // Fiji's class path outgrows Windows' command line: Java reads it from a file.
            arguments = ["@" + (try Self.argumentFile(arguments, in: classes).path)]
        }
        return HelperLaunch(executable: java, arguments: arguments, environment: environment)
    }

    /// Where the helper's windows go (Linux): the session's display, a virtual one (Xvfb) no one sees, or none.
    enum HelperDisplay: Sendable { case own, virtual, headless }

    /// The helper's Java options, class path and main class. In Fiji, the
    /// options Fiji's launcher gives (``FijiInstallation/javaOptions(maximumHeapMegabytes:javaMajorVersion:)``)
    /// and Fiji's class path, then `MancoraFijiBridge`, which starts ImageJ2.
    static func javaArguments(
        _ config: Configuration, fiji: FijiInstallation?, classes: URL, display: HelperDisplay, macOS: Bool = isMacOS
    ) -> [String] {
        let home = config.home
        var arguments: [String] = []
        let classPath: [URL]
        if let fiji {
            let major = fiji.version.java.flatMap { Int($0.prefix { $0.isNumber }) } ?? config.java.majorVersion
            arguments += fiji.javaOptions(maximumHeapMegabytes: config.maximumHeapMegabytes, javaMajorVersion: major)
            classPath = fiji.classPath()
        } else {
            if let heap = config.maximumHeapMegabytes { arguments.append("-Xmx\(heap)m") }
            arguments += ["-Dplugins.dir=\(home.root.path)", "-Dij.dir=\(home.root.path)", "-Dfile.encoding=UTF-8"]
            if FileManager.default.fileExists(atPath: home.nativeLibraries.path) {
                arguments.append("-Djava.library.path=\(home.nativeLibraries.path)")
            }
            if let table = config.commandTable { arguments.append("-Dmancora.commands=\(table.path)") }
            classPath = home.classPath()
        }
        if config.interactive { arguments.append("-Dmancora.interactive=true") }
        if macOS {
            if config.interactive {
                // Its windows are someone's to use: a Dock icon and menu bar, named.
                arguments += ["-Xdock:name=\(config.dockName)", "-Dapple.awt.application.name=\(config.dockName)"]
                if let icon = config.dockIcon ?? fiji?.icon { arguments.append("-Xdock:icon=\(icon.path)") }
            } else {
                arguments.append("-Dapple.awt.UIElement=true")  // no Dock icon or menu bar for the helper
            }
        }
        switch display {
        case .own: break
        case .virtual: arguments.append("-Dmancora.virtualDisplay=true")
        case .headless: arguments.append("-Djava.awt.headless=true")
        }
        let separator = JavaRuntime.isWindows ? ";" : ":"
        arguments += ["-cp", (classPath + [classes]).map(\.path).joined(separator: separator)]
        arguments.append(fiji == nil ? "MancoraBridgeHelper" : "MancoraFijiBridge")
        return arguments
    }

    static var isMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// A Java argument file (`java @file`, `javac @file`): one argument a
    /// line, quoted, with forward slashes (which Java takes on Windows too).
    static func argumentFile(_ arguments: [String], in folder: URL) throws -> URL {
        let text = arguments.map { argument in
            "\"" + argument.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: "\n")
        let file = folder.appendingPathComponent("arguments-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: file)
        return file
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
    ///
    /// In Fiji, `MancoraFijiBridge.java` too, against Fiji's class path with
    /// Fiji's JDK, in `<home>/helper/fiji-<hash>/`: the hash covers the jars'
    /// names, so an update that changes them compiles it again.
    func compiledHelper(fiji: FijiInstallation? = nil) throws -> URL {
        let config = configuration
        var sources = [config.helperSource]
        var classPath = [config.home.imageJJar]
        var key = Array(BridgeHome.imageJVersion.utf8)
        var compiler = config.java.compiler
        var prefix = ""
        if let fiji {
            sources.append(config.fijiHelperSource)
            classPath = fiji.classPath()
            key = Array(("Fiji\n" + classPath.map(\.lastPathComponent).joined(separator: "\n")).utf8)
            compiler = fiji.javaCompiler ?? config.java.compiler
            prefix = "fiji-"
        }
        var bytes: [UInt8] = []
        for source in sources { bytes += [UInt8](try Data(contentsOf: source)) }
        let hash = prefix + hexString(SHA256.hash(bytes + key)).prefix(16)
        let main = fiji == nil ? "MancoraBridgeHelper" : "MancoraFijiBridge"
        let folder = config.home.root.appendingPathComponent("helper").appendingPathComponent(hash)
        let compiled = folder.appendingPathComponent(main + ".class")
        if FileManager.default.fileExists(atPath: compiled.path) { return folder }
        guard let javac = compiler else { throw BridgeError.noCompiler }
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".\(hash)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let process = Process()
        process.executableURL = javac
        let separator = JavaRuntime.isWindows ? ";" : ":"
        let arguments = ["-encoding", "UTF-8", "-nowarn", "-cp", classPath.map(\.path).joined(separator: separator), "-d", staging.path]
            + sources.map(\.path)
        // Fiji's class path is long: javac reads it from a file, kept out of the compiled folder.
        process.arguments = fiji == nil ? arguments : ["@" + (try Self.argumentFile(arguments, in: staging.deletingLastPathComponent()).path)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if fiji != nil, let file = process.arguments?.first?.dropFirst() { try? FileManager.default.removeItem(atPath: String(file)) }
        let staged = staging.appendingPathComponent(main + ".class")
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

    /// A file name like `title`, valid on every platform: separators and
    /// other reserved characters become `_`, and a name that is empty, `.`,
    /// `..` or longer than file systems allow becomes `Untitled.tif`.
    static func fileName(for title: String) -> String {
        let cleaned = String(title.map { "/\\:*?\"<>|\0".contains($0) || $0.isNewline ? "_" : $0 })
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", cleaned.utf8.count <= 255 else { return "Untitled.tif" }
        return cleaned
    }

    /// Whether the locale `environment` selects for character types (`LC_ALL`,
    /// else `LC_CTYPE`, else `LANG`) is a UTF-8 one.
    static func isUTF8Locale(_ environment: [String: String]) -> Bool {
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let lowered = locale.lowercased()
        return lowered.contains("utf-8") || lowered.contains("utf8")
    }

    static func findOnPath(_ tool: String, environment: [String: String]) -> URL? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
