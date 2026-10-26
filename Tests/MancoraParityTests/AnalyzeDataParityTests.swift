import Foundation
import MancoraCommands
import MancoraCore
import MancoraMacro
import MancoraProcess
import Testing

@testable import MancoraBridge

/// `CommandContext.plotProfile()` and `histogram()` against the plots
/// ImageJ 1.54p's Analyze ▸ Plot Profile and Analyze ▸ Histogram make: the
/// selection is made by a macro on both sides, and ImageJ's plot values
/// (`Plot.getValues`) must equal Mancora's data, as the floats the plot
/// holds.
@Suite("Plot Profile and Histogram data match ImageJ's plots", .enabled(if: Parity.available), .serialized)
struct AnalyzeDataMacroParityTests {
    enum Plot {
        case profile(alt: Bool)
        /// Analyze ▸ Histogram's `bins=`, `x_min=` and `x_max=` (both 0: the pixel value range).
        case histogram(bins: Int, min: Double, max: Double)
    }

    struct Case: CustomStringConvertible {
        var name: String
        var setup: String
        var inputs: [ParityInput]
        var plot: Plot
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "line", setup: "makeLine(5, 7, 50, 30);", inputs: [.gray8], plot: .profile(alt: false)),
        Case(name: "wide line, calibrated", setup: "makeLine(3.5, 40.25, 57.75, 2.5, 6);", inputs: [.calibrated], plot: .profile(alt: false)),
        Case(
            name: "non-square pixels",
            setup: #"run("Properties...", "unit=micron pixel_width=0.5 pixel_height=0.25 voxel_depth=1"); makeLine(5, 7, 50, 30);"#,
            inputs: [.gray32], plot: .profile(alt: false)),
        Case(name: "polyline", setup: "makeLine(5, 5, 20, 30, 45, 10, 55, 40);", inputs: [.rgb], plot: .profile(alt: false)),
        Case(name: "rectangle", setup: "makeRectangle(10, 5, 20, 15);", inputs: [.gray16], plot: .profile(alt: false)),
        Case(
            name: "rectangle rows",
            setup: #"run("Properties...", "unit=micron pixel_width=0.5 pixel_height=0.25 voxel_depth=1"); makeRectangle(10, 5, 20, 15); setKeyDown("alt");"#,
            inputs: [.gray16], plot: .profile(alt: true)),
        Case(name: "wide freeline", setup: "", inputs: [.freelineROI], plot: .profile(alt: false)),
        Case(name: "8-bit histogram", setup: "makeOval(12, 9, 33, 21);", inputs: [.gray8], plot: .histogram(bins: 256, min: 0, max: 0)),
        Case(name: "RGB histogram", setup: "", inputs: [.rgb], plot: .histogram(bins: 256, min: 0, max: 0)),
        Case(name: "16-bit histogram", setup: "", inputs: [.gray16], plot: .histogram(bins: 256, min: 0, max: 0)),
        Case(name: "16-bit bins and range", setup: "makeRectangle(10, 5, 20, 15);", inputs: [.gray16], plot: .histogram(bins: 50, min: 1000, max: 2000)),
        Case(name: "calibrated 16-bit", setup: "", inputs: [.functionCalibrated16], plot: .histogram(bins: 40, min: 50, max: 150)),
        Case(name: "32-bit histogram", setup: "", inputs: [.gray32], plot: .histogram(bins: 100, min: 0, max: 0)),
        Case(name: "32-bit range", setup: "", inputs: [.gray32], plot: .histogram(bins: 64, min: -1, max: 1)),
    ]

    @Test func plotValues() async throws {
        var config = Bridge.Configuration(
            java: Parity.java!, home: Parity.home, helperSource: Parity.url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: Parity.url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 300
        let bridge = Bridge(configuration: config)
        _ = try await bridge.start()
        for testCase in Self.cases {
            do {
                if let difference = try await Self.compare(testCase, bridge: bridge) { Issue.record("\(testCase): \(difference)") }
            } catch {
                Issue.record("\(testCase): \(error)")
            }
        }
        await bridge.stop()
    }

    static func compare(_ testCase: Case, bridge: Bridge) async throws -> String? {
        let inputs = try testCase.inputs.map { try $0.image() }
        let session = MacroSession()
        for input in inputs { _ = session.add(input) }
        try session.run(testCase.setup)
        let native: (x: [Double], y: [Double])
        let command: String
        switch testCase.plot {
        case .profile(let alt):
            let data = try session.context.plotProfile(altKeyDown: alt)
            native = (data.xValues, data.yValues)
            command = #"run("Plot Profile");"#
        case .histogram(let bins, let min, let max):
            let data = try session.context.histogram(bins: bins, histMin: min, histMax: max)
            native = (data.binStarts, data.counts.map(Double.init))
            let options = min == 0 && max == 0 ? "bins=\(bins) use y_max=Auto" : "bins=\(bins) x_min=\(min) x_max=\(max) y_max=Auto"
            // Bins wider than one value are only read from the histogram's window,
            // which batch mode doesn't show.
            command = bins == 256 && min == 0 && max == 0 && testCase.inputs != [.gray32]
                ? #"setBatchMode(false); run("Histogram");"# : #"setBatchMode(false); run("Histogram", "\#(options)");"#
        }
        let macro = testCase.setup + "\n" + command + #"""

            Plot.getValues(x, y);
            for (i = 0; i < x.length; i++) print(d2s(x[i], -9) + " " + d2s(y[i], -9));
            """#
        let result = try await bridge.runMacro(macro, images: inputs)
        if let error = result.macroError { return "ImageJ: \(error)" }
        let lines = result.log.split(separator: "\n")
        let imageJ = lines.map { line -> (Float, Float) in
            let parts = line.split(separator: " ")
            return (Float(Double(parts[0]) ?? .nan), Float(Double(parts.count > 1 ? parts[1] : "") ?? .nan))
        }
        if imageJ.count != native.x.count { return "\(native.x.count) values, ImageJ \(imageJ.count)" }
        for (i, (x, y)) in imageJ.enumerated() {
            let ours = (Float(native.x[i]), Float(native.y[i]))
            if x != ours.0 || !(y == ours.1 || (y.isNaN && ours.1.isNaN)) {
                return "value \(i): Mancora (\(ours.0), \(ours.1)), ImageJ (\(x), \(y))"
            }
        }
        return nil
    }
}
