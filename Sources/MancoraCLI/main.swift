// `mancora`: headless command-line access to Mancora's core.
//
//   mancora info <image.tif>   describe an image
//   mancora lut <file.lut>     describe a LUT file
//   mancora luts               list the built-in LUTs

import Foundation
import MancoraCore
import MancoraIO

let usage = """
    usage: mancora info <image.tif>
           mancora lut <file.lut>
           mancora luts
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
case ("luts", 1):
    for lut in LUT.builtIn { print(lut.name) }
default:
    fail(usage)
}

func hex(_ argb: UInt32) -> String {
    let digits = String(argb & 0xFF_FFFF, radix: 16, uppercase: true)
    return String(repeating: "0", count: 6 - digits.count) + digits
}
