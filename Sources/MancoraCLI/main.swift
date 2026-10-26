// `mancora`: headless command-line access to Mancora's core.
//
//   mancora info [--virtual] <image.tif>   describe an image (--virtual reads planes on demand)
//   mancora convert <in.tif> <out.tif>     re-save a TIFF the way ImageJ writes them
//   mancora lut <file.lut>                 describe a LUT file
//   mancora luts                           list the built-in LUTs
//   mancora update [--download <dir>]      check for a newer release
//   mancora bridge <setup|info|commands|run|macro|open> …   ImageJ and its plugins in a Java helper
//   mancora update-sites <list|add|enable|disable|status|update> …   Fiji update sites for the bridge
//   mancora [--headless] -macro <macro.ijm> [arg]   run a macro, as ImageJ's -macro and -batch do
//   mancora [--headless] -eval "<code>"             run macro code and print what it returns
//   mancora --version

import Foundation
import MancoraBridge
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraMacro
import MancoraSupport
import MancoraUpdate

let usage = """
    usage: mancora info [--virtual] [--scan] <image.tif>
           mancora convert <in.tif> <out.tif> [--big-endian]
           mancora lut <file.lut>
           mancora luts
           mancora update [--download <directory>]
           mancora bridge setup                       install ImageJ for the Java bridge
           mancora bridge info | commands [--plugins]
           mancora bridge run "<command>" "<options>" <in.tif> [<out.tif>]
           mancora bridge macro <macro.ijm> [<in.tif> …]
           mancora bridge open <file> [<out.tif>]     open any format ImageJ or Bio-Formats reads
           mancora update-sites <command> …           Fiji update sites (see mancora update-sites help)
           mancora [--headless] -macro <macro.ijm> [<argument>]   (also -batch, or macro)
           mancora [--headless] -eval "<macro code>"
           mancora --version
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ image: Hyperstack) -> String {
    let cal = image.calibration
    var lines = [
        "title: \(image.title)",
        "size: \(image.width) × \(image.height)",
        "type: \(image.pixelType.rawValue) (\(image.pixelType.bitDepth)-bit)",
        "planes: \(image.stack.count) (\(image.dimensions))",
        "mode: \(image.compositeMode.rawValue)",
    ]
    if cal.isSpatiallyCalibrated {
        lines.append("pixel size: \(cal.pixelWidth) × \(cal.pixelHeight) × \(cal.pixelDepth) \(cal.unit)")
    }
    if cal.frameInterval > 0 { lines.append("frame interval: \(cal.frameInterval) \(cal.timeUnit)") }
    if case .straightLine(let intercept, let slope)? = cal.valueFunction {
        lines.append("value calibration: \(intercept) + \(slope) × raw")
    }
    for (c, display) in image.channels.enumerated() {
        let range = display.displayRange
        lines.append("channel \(c + 1): LUT \(display.lut.name), display \(range.lowerBound)–\(range.upperBound)")
    }
    return lines.joined(separator: "\n")
}

var args = Array(CommandLine.arguments.dropFirst())
// Fiji's --headless changes nothing here: Mancora's command line never shows windows.
if args.first == "--headless" { args.removeFirst() }
switch (args.first, args.count) {
case ("-macro", 2...3), ("-batch", 2...3), ("macro", 2...3):
    await runMacroFile(args[1], argument: args.count == 3 ? args[2] : nil)
case ("-eval", 2):
    await runMacro(args[1], argument: nil, path: nil, printReturn: true)
case ("info", 2...4):
    let flags = Set(args.dropFirst().dropLast())
    guard flags.isSubset(of: ["--virtual", "--scan"]) else { fail(usage) }
    do {
        let started = Date()
        let image = try TIFFImporter.read(path: args[args.count - 1], options: .init(virtual: flags.contains("--virtual")))
        print(describe(image))
        print("opened in \(milliseconds(since: started)) ms\(image.stack.isVirtual ? " (virtual)" : "")")
        if flags.contains("--scan") {
            // Touch every plane, as scrolling through the whole stack would.
            let scanStart = Date()
            var range: ClosedRange<Double>?
            for k in 0..<image.stack.count {
                let plane = try image.stack.loadPlane(at: k)
                if let r = plane.valueRange() {
                    range = range.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
                }
            }
            let shown = range.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "none"
            print("scanned \(image.stack.count) planes in \(milliseconds(since: scanStart)) ms; values \(shown)")
        }
    } catch {
        fail("mancora: \(error)")
    }
case ("lut", 2):
    do {
        let lut = try LUTReader.read(path: args[1])
        print("\(lut.name): 256 colors, first #\(hex(lut.argb(0))), last #\(hex(lut.argb(255)))")
    } catch {
        fail("mancora: \(error)")
    }
case ("convert", 3), ("convert", 4):
    guard args.count == 3 || args[3] == "--big-endian" else { fail(usage) }
    do {
        let image = try TIFFImporter.read(path: args[1])
        try TIFFExporter.write(image, to: args[2], options: .init(bigEndian: args.count == 4))
    } catch {
        fail("mancora: \(error)")
    }
case ("update", 1), ("update", 3):
    guard args.count == 1 || args[1] == "--download" else { fail(usage) }
    await checkForUpdate(downloadTo: args.count == 3 ? args[2] : nil)
case ("bridge", 2...):
    await bridgeCommand(Array(args.dropFirst()))
case ("update-sites", 1...):
    await updateSitesCommand(Array(args.dropFirst()))
case ("luts", 1):
    for lut in LUT.builtIn { print(lut.name) }
case ("--version", 1), ("version", 1):
    print("mancora \(MancoraVersion.number)")
default:
    fail(usage)
}

func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func hex(_ argb: UInt32) -> String {
    let digits = String(argb & 0xFF_FFFF, radix: 16, uppercase: true)
    return String(repeating: "0", count: 6 - digits.count) + digits
}

/// Reports whether a newer release has an installer for this platform and,
/// with a directory, downloads it there (verified against SHA256SUMS.txt).
func checkForUpdate(downloadTo directory: String?) async {
    guard let current = SemanticVersion(MancoraVersion.number) else { fail("mancora: bad version \(MancoraVersion.number)") }
    let checker = UpdateChecker(
        currentVersion: current, client: URLSessionHTTPClient(userAgent: "mancora/\(MancoraVersion.number)"))
    do {
        guard let update = try await checker.availableUpdate() else {
            print("Mancora \(current) is up to date.")
            return
        }
        print("Mancora \(update.version) is available (you have \(current)): \(update.release.pageURL.absoluteString)")
        guard let directory else {
            print("Run `mancora update --download <directory>` to fetch \(update.installer.name).")
            return
        }
        let data = try await checker.download(update)
        let path = URL(fileURLWithPath: directory).appendingPathComponent(update.installer.name)
        try data.write(to: path)
        print("Downloaded and verified \(path.path) (SHA-256 \(hexString(SHA256.hash([UInt8](data))))).")
    } catch {
        fail("mancora: update check failed: \(error)")
    }
}

// MARK: Java bridge

/// `Resources/Bridge` next to the executable (installed layouts) or in the
/// source tree (development builds).
func bridgeResources() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    var candidates = [exe.appendingPathComponent("Bridge"), exe.appendingPathComponent("../share/mancora/Bridge")]
    var dir = exe
    for _ in 0..<6 {
        candidates.append(dir.appendingPathComponent("Resources/Bridge"))
        dir = dir.deletingLastPathComponent()
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("MancoraBridgeHelper.java").path) }
}

func bridgeCommand(_ args: [String]) async {
    guard let resources = bridgeResources() else { fail("mancora: can't find the bridge helper (Resources/Bridge)") }
    let configuration: Bridge.Configuration
    do {
        configuration = try Bridge.Configuration.standard(resources: resources)
    } catch {
        fail("mancora: \(error)")
    }
    if args.first == "setup" {
        do {
            try await configuration.home.installImageJ(client: URLSessionHTTPClient(userAgent: "mancora/\(MancoraVersion.number)"))
            print("ImageJ \(BridgeHome.imageJVersion) is installed in \(configuration.home.root.path)")
            print("Java \(configuration.java.majorVersion): \(configuration.java.executable.path)")
        } catch {
            fail("mancora: \(error)")
        }
        return
    }
    let bridge = Bridge(configuration: configuration)
    do {
        switch (args.first, args.count) {
        case ("info", 1):
            let hello = try await bridge.start()
            print("ImageJ \(hello.imagej) on Java \(hello.java) (helper pid \(hello.pid))")
            print("home: \(configuration.home.root.path)")
        case ("commands", 1), ("commands", 2):
            let pluginsOnly = args.count == 2 && args[1] == "--plugins"
            for command in try await bridge.commands() where !pluginsOnly || command.isPlugin {
                print("\(command.name)\t\(command.className)")
            }
        case ("run", 4), ("run", 5):
            let input = try TIFFImporter.read(path: args[3])
            let result = try await bridge.run(args[1], options: args[2], images: [input])
            printBridgeResult(result)
            if args.count == 5 {
                guard let first = result.images.first else { fail("mancora: the command produced no image") }
                try TIFFExporter.write(first.image, to: args[4])
                print("saved \(first.title) to \(args[4])")
            }
        case ("open", 2), ("open", 3):
            let result = try await bridge.open(args[1])
            if !result.log.isEmpty { print(result.log, terminator: result.log.hasSuffix("\n") ? "" : "\n") }
            for (k, opened) in result.images.enumerated() {
                print("\(opened.title) (read by \(result.value ?? "ImageJ"))")
                print(describe(opened.image))
                if args.count == 3 {
                    let path = result.images.count == 1 ? args[2] : args[2].replacingOccurrences(of: ".tif", with: "-\(k + 1).tif")
                    try TIFFExporter.write(opened.image, to: path)
                    print("saved to \(path)")
                }
            }
        case ("macro", 2...):
            let code = try String(contentsOfFile: args[1], encoding: .utf8)
            let images = try args.dropFirst(2).map { path throws(MancoraIOError) in try TIFFImporter.read(path: path) }
            let result = try await bridge.runMacro(code, images: images)
            printBridgeResult(result)
            for (k, image) in result.images.enumerated() {
                let path = "macro-output-\(k + 1).tif"
                try TIFFExporter.write(image.image, to: path)
                print("saved \(image.title) to \(path)")
            }
        default:
            fail(usage)
        }
    } catch {
        await bridge.stop()
        fail("mancora: \(error)")
    }
    await bridge.stop()
}

func printBridgeResult(_ result: BridgeRunResult) {
    if !result.log.isEmpty { print(result.log, terminator: result.log.hasSuffix("\n") ? "" : "\n") }
    if !result.results.isEmpty {
        print(result.results.columns.joined(separator: "\t"))
        for row in result.results.rows {
            print(row.map { cell in
                switch cell {
                case .number(let v): v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
                case .text(let t): t
                case .empty: ""
                }
            }.joined(separator: "\t"))
        }
    }
    if let value = result.value { print("macro returned: \(value)") }
}

/// `-macro path [arg]`: the path as given, or in ImageJ's macros folder.
func runMacroFile(_ name: String, argument: String?) async {
    var path = name
    if !FileManager.default.fileExists(atPath: path) {
        let home = BridgeHome.standard().root.appendingPathComponent("macros").appendingPathComponent(name).path
        if FileManager.default.fileExists(atPath: home) { path = home }
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("mancora: macro or script not found: \(name)")
    }
    await runMacro(String(decoding: data, as: UTF8.self), argument: argument, path: path, printReturn: false)
}

/// Runs a macro natively, or in ImageJ through the Java bridge when it uses
/// something only ImageJ has (and the bridge is set up).
func runMacro(_ code: String, argument: String?, path: String?, printReturn: Bool) async {
    let registry = CommandRegistry.standard
    let needsImageJ = MacroSupport.unsupported(in: code, registry: registry)
    if !needsImageJ.isEmpty, let resources = bridgeResources(),
        let configuration = try? Bridge.Configuration.standard(resources: resources),
        configuration.home.hasImageJ
    {
        let bridge = Bridge(configuration: configuration)
        do {
            let result = try await bridge.runMacro(code, argument: argument ?? "")
            await bridge.stop()
            if !result.log.isEmpty { print(result.log, terminator: "") }
            if printReturn, let value = result.value { print(value, terminator: "") }
            return
        } catch {
            await bridge.stop()
            fail("mancora: \(error)")
        }
    }
    let session = MacroSession(registry: registry)
    session.onLog = { line in print(line) }
    do {
        let value = try session.run(code, argument: argument, path: path)
        if printReturn, let value { print(value, terminator: "") }
    } catch {
        var message = "Macro Error: \(error)"
        if !needsImageJ.isEmpty {
            message += "\n(\(needsImageJ.joined(separator: ", ")) needs ImageJ: run `mancora bridge setup` to install it.)"
        }
        fail(message)
    }
}
