// `mancora`: headless command-line access to Mancora's core.
//
//   mancora info <image.tif>               describe an image
//   mancora convert <in.tif> <out.tif>     re-save a TIFF the way ImageJ writes them
//   mancora lut <file.lut>                 describe a LUT file
//   mancora luts                           list the built-in LUTs
//   mancora update [--download <dir>]      check for a newer release
//   mancora --version

import Foundation
import MancoraCore
import MancoraIO
import MancoraSupport
import MancoraUpdate

let usage = """
    usage: mancora info <image.tif>
           mancora convert <in.tif> <out.tif> [--big-endian]
           mancora lut <file.lut>
           mancora luts
           mancora update [--download <directory>]
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

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("info", 2):
    do {
        print(describe(try TIFFImporter.read(path: args[1])))
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
case ("luts", 1):
    for lut in LUT.builtIn { print(lut.name) }
case ("--version", 1), ("version", 1):
    print("mancora \(MancoraVersion.number)")
default:
    fail(usage)
}

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
