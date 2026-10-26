import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import Testing

#if canImport(Glibc)
import Glibc
#endif

@testable import MancoraBridge

/// Runs commands natively and in ImageJ 1.54p (through the bridge helper)
/// and compares what each leaves behind: pixels, exactly for integer images
/// and within a tolerance for float, plus everything ImageJ saves with them
/// (title, calibration, display ranges, LUTs, labels, info) and the results
/// table.
///
/// Both sides are compared as saved TIFFs: ImageJ's output comes back as one,
/// and Mancora's is saved with ``TIFFExporter`` (which writes what ImageJ's
/// FileSaver would) and read back, so state a TIFF can't hold doesn't count.
enum Parity {
    static let repoRoot: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)
        return parts.joined(separator: "/")
    }()

    static func url(_ relative: String) -> URL { URL(fileURLWithPath: repoRoot + "/" + relative) }

    /// Parity needs ImageJ's jar (`MANCORA_TEST_IJ_JAR`), a JDK and, on
    /// Linux, a display or Xvfb (ImageJ builds its dialogs even when a macro
    /// fills them in).
    static let imageJJar = ProcessInfo.processInfo.environment["MANCORA_TEST_IJ_JAR"]
    static let java = JavaRuntime.discover()
    static var available: Bool { imageJJar != nil && java?.compiler != nil && hasDisplay }

    static var hasDisplay: Bool {
        #if os(Linux)
        let env = ProcessInfo.processInfo.environment
        return !(env["DISPLAY"] ?? "").isEmpty || Bridge.findOnPath("Xvfb", environment: env) != nil
        #else
        return true
        #endif
    }

    /// One home for every bridge the suite starts, so the helper compiles once.
    static let home: BridgeHome = {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-parity-\(UUID().uuidString)"))
        try? home.createFolders()
        if let jar = imageJJar { try? FileManager.default.copyItem(at: URL(fileURLWithPath: jar), to: home.imageJJar) }
        return home
    }()

    /// Runs `cases` against one helper, recording a test issue for every difference.
    static func check(_ cases: [ParityCase], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var config = Bridge.Configuration(
            java: java!, home: home, helperSource: url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 300
        config.maximumHeapMegabytes = 512  // several suites run helpers at once
        let bridge = Bridge(configuration: config)
        do {
            _ = try await bridge.start()
            for parityCase in cases {
                let differences = try await compare(parityCase, bridge: bridge)
                for difference in differences {
                    Issue.record("\(parityCase): \(difference)", sourceLocation: sourceLocation)
                }
            }
        } catch {
            await bridge.stop()
            throw error
        }
        await bridge.stop()
    }

    /// The differences between Mancora's and ImageJ's results for one case.
    static func compare(_ parityCase: ParityCase, bridge: Bridge) async throws -> [String] {
        let inputs = try parityCase.inputs.map { try $0.image() }

        var context = CommandContext()
        for input in inputs { context.add(input) }
        let before = context.images.map(\.id)
        for step in parityCase.steps {
            try CommandRegistry.standard.run(step.command, options: MacroOptions(step.options), in: &context)
        }
        guard let current = context.current else { return ["Mancora left no image open"] }
        let native = try roundTrip(current.image)
        let nativeIsNew = !before.contains(current.id)

        let result: BridgeRunResult
        if parityCase.steps.count == 1, let step = parityCase.steps.first {
            result = try await bridge.run(step.command, options: step.options, images: inputs)
        } else {
            result = try await bridge.runMacro(parityCase.macro, images: inputs)
        }
        let imageJ: Hyperstack
        let imageJIsNew: Bool
        if let created = result.images.last(where: { $0.replacesInput == nil }) {
            (imageJ, imageJIsNew) = (created.image, true)
        } else if let changed = result.images.last(where: { $0.replacesInput == inputs.count - 1 }) {
            (imageJ, imageJIsNew) = (changed.image, false)
        } else {
            (imageJ, imageJIsNew) = (inputs[inputs.count - 1], false)
        }

        var differences: [String] = []
        if nativeIsNew != imageJIsNew {
            differences.append(nativeIsNew ? "Mancora made a new image; ImageJ didn't" : "ImageJ made a new image; Mancora didn't")
        }
        differences += ImageComparison.differences(native, imageJ, tolerance: parityCase.tolerance)
        if parityCase.comparesResults {
            differences += ImageComparison.differences(context.results, result.results, tolerance: parityCase.tolerance)
        }
        if parityCase.comparesSelection {
            differences += ImageComparison.selectionDifferences(native, imageJ)
        }
        return differences
    }

    /// `image` as it reads back after being saved the way ImageJ saves it.
    static func roundTrip(_ image: Hyperstack) throws -> Hyperstack {
        var copy = try TIFFImporter.decode(TIFFExporter.encode(image), title: image.title)
        copy.title = image.title
        return copy
    }
}

/// One command (or several, as a macro runs them), with macro options, and
/// the images it runs on (the last is current).
struct ParityCase: Sendable, CustomStringConvertible {
    struct Step: Sendable {
        var command: String
        var options: String
    }

    var steps: [Step]
    var inputs: [ParityInput]
    /// For float pixels and results: the largest difference allowed,
    /// relative to the value (absolute below 1).
    var tolerance = 1e-5
    var comparesResults = false
    /// Whether the selections (as the saved TIFFs carry them) must match too.
    var comparesSelection = false

    init(
        _ command: String, _ options: String = "", on inputs: ParityInput..., tolerance: Double = 1e-5,
        results: Bool = false, selection: Bool = false
    ) {
        self.init(
            steps: [Step(command: command, options: options)], inputs: inputs, tolerance: tolerance, results: results,
            selection: selection)
    }

    init(steps: [Step], inputs: [ParityInput], tolerance: Double = 1e-5, results: Bool = false, selection: Bool = false) {
        self.steps = steps
        self.inputs = inputs
        self.tolerance = tolerance
        self.comparesResults = results
        self.comparesSelection = selection
    }

    /// `Set Measurements...` with `measurements`, then `Measure`.
    static func measure(_ measurements: String, on input: ParityInput, then more: [Step] = [], tolerance: Double = 1e-9) -> ParityCase {
        ParityCase(
            steps: [Step(command: "Set Measurements...", options: measurements), Step(command: "Measure", options: "")] + more,
            inputs: [input], tolerance: tolerance, results: true)
    }

    /// The steps as ImageJ macro code.
    var macro: String {
        var recorder = MacroRecorder()
        for step in steps { recorder.record(step.command, options: MacroOptions(step.options)) }
        return recorder.macro
    }

    var description: String {
        let on = inputs.map(\.rawValue).joined(separator: ", ")
        let what = steps.map { $0.options.isEmpty ? "\"\($0.command)\"" : "\"\($0.command)\" \"\($0.options)\"" }
        return what.joined(separator: ", then ") + " on \(on)"
    }
}

/// Test images: small, odd-sized and filled from a fixed seed so every run
/// is the same, plus the ImageJ-written fixtures.
enum ParityInput: String, Sendable {
    case gray8, gray16, gray32, rgb, stack8, stack16, stack32, hyperstack, calibrated, binary, binaryStack
    // Images with a selection, which ImageJ reads from the TIFF.
    case rectangleROI, roundedROI, ovalROI, polygonROI, subpixelPolygonROI, freehandROI, tracedROI, edgeROI, namedROI
    case binaryRectangleROI, binaryOvalROI
    // "<input>+<selection>": an input above with a selection (see `withSelection`).
    case gray8Rect = "gray8+rect", gray8Oval = "gray8+oval", gray8Polygon = "gray8+polygon"
    case gray8NearEdge = "gray8+nearEdge", gray8Line = "gray8+line", gray8Point = "gray8+point"
    case gray16Oval = "gray16+oval", gray16NearEdge = "gray16+nearEdge", gray16Polygon = "gray16+polygon"
    case gray32Rect = "gray32+rect", gray32Oval = "gray32+oval", gray32NearEdge = "gray32+nearEdge"
    case rgbRect = "rgb+rect", rgbOval = "rgb+oval", rgbPolygon = "rgb+polygon", rgbNearEdge = "rgb+nearEdge"
    case stack8Oval = "stack8+oval", stack16Rect = "stack16+rect", stack32Polygon = "stack32+polygon"
    case binaryPolygon = "binary+polygon", binaryNearEdge = "binary+nearEdge", binaryStackOval = "binaryStack+oval"
    case calibratedOval = "calibrated+oval", calibratedRect = "calibrated+rect", hyperstackOval = "hyperstack+oval"
    case gray16Freehand = "gray16+freehand", gray32Subpixel = "gray32+subpixel", rgbLine = "rgb+line"
    // Odd shapes for geometry: one pixel wide or high, and an RGB stack.
    case column8, row16, row32, columnRGB, stackRGB
    case fixtureHyperstack = "ij-hyperstack-16bit.tif"
    case fixtureFire = "ij-8bit-fire.tif"
    // Blobs-like images for background subtraction, maxima and EDMs (see BlobImages).
    case blobs8, blobs16, blobs32, blobsRGB, blobsLight, blobsInverted, blobsStack8, blobsStack16, blobsStack32
    case blobsROI, blobsOvalROI, blobsMask, blobsMaskInverted, blobsMaskStack

    func image() throws -> Hyperstack {
        let made: Hyperstack
        switch self {
        case .gray8: made = try Self.make("gray8.tif", .gray8)
        case .gray16: made = try Self.make("gray16.tif", .gray16)
        case .gray32: made = try Self.make("gray32.tif", .gray32Float)
        case .rgb: made = try Self.make("rgb.tif", .rgb8)
        case .stack8: made = try Self.make("stack8.tif", .gray8, slices: 5)
        case .stack16: made = try Self.make("stack16.tif", .gray16, slices: 5)
        case .stack32: made = try Self.make("stack32.tif", .gray32Float, slices: 5)
        case .column8: made = try Self.make("column8.tif", .gray8, width: 1)
        case .row16: made = try Self.make("row16.tif", .gray16, height: 1)
        case .row32: made = try Self.make("row32.tif", .gray32Float, height: 1)
        case .columnRGB: made = try Self.make("columnRGB.tif", .rgb8, width: 1)
        case .stackRGB: made = try Self.make("stackRGB.tif", .rgb8, slices: 4)
        case .hyperstack:
            made = try Self.make("hyperstack.tif", .gray16, channels: 2, slices: 3, frames: 2, composite: true)
        case .calibrated:
            var image = try Self.make("calibrated.tif", .gray16, slices: 3)
            image.calibration.pixelWidth = 0.25
            image.calibration.pixelHeight = 0.25
            image.calibration.pixelDepth = 1.5
            image.calibration.unit = "µm"
            made = image
        case .binary, .binaryStack, .binaryRectangleROI, .binaryOvalROI:
            // 0 and 255 only, for Process ▸ Binary.
            var image = try Self.make(rawValue + ".tif", .gray8, slices: self == .binaryStack ? 3 : 1)
            if self == .binaryRectangleROI { image.encodedROI = RoiCodec.encode(Self.roi(for: .edgeROI)) }
            if self == .binaryOvalROI { image.encodedROI = RoiCodec.encode(Self.roi(for: .ovalROI)) }
            for index in 0..<image.stack.count {
                guard case .gray8(let p) = image.stack[index] else { continue }
                try image.setPlane(.gray8(p.map { $0 > 120 ? 255 : 0 }), at: index)
            }
            made = image
        case .rectangleROI, .roundedROI, .ovalROI, .polygonROI, .subpixelPolygonROI, .freehandROI, .tracedROI, .edgeROI,
            .namedROI:
            var image = try Self.make(rawValue + ".tif", self == .ovalROI ? .gray8 : self == .polygonROI ? .gray32Float : .gray16)
            if self == .freehandROI || self == .namedROI {
                image.calibration.pixelWidth = 0.4
                image.calibration.pixelHeight = 0.4
                image.calibration.unit = "µm"
            }
            image.encodedROI = RoiCodec.encode(Self.roi(for: self))
            made = image
        case .fixtureHyperstack, .fixtureFire:
            return try TIFFImporter.read(path: Parity.url("Tests/Fixtures/tiff/" + rawValue).path)
        case .blobs8, .blobs16, .blobs32, .blobsRGB, .blobsLight, .blobsInverted, .blobsStack8, .blobsStack16,
            .blobsStack32, .blobsROI, .blobsOvalROI, .blobsMask, .blobsMaskInverted, .blobsMaskStack:
            made = try BlobImages.image(for: self)
        default:
            made = try withSelection()
        }
        return try Parity.roundTrip(made)
    }

    static let width = 61, height = 47

    static func roi(for input: ParityInput) -> Roi {
        func ints(_ points: [(Int32, Int32)]) -> Roi.Vertices { .integer(points.map { Roi.IntPoint(x: $0.0, y: $0.1) }) }
        switch input {
        case .roundedROI: return Roi(.rectangle(.integer(x: 8, y: 6, width: 30, height: 22), cornerDiameter: 9))
        case .ovalROI: return Roi(.oval(.integer(x: 12, y: 9, width: 33, height: 21)))
        case .polygonROI:
            return Roi(.polygon(.init(.polygon, ints([(5, 5), (40, 8), (52, 30), (20, 41), (9, 25)]))))
        case .subpixelPolygonROI:
            let points = [(4.5, 6.25), (44.75, 3.5), (55.1, 38.2), (12.3, 40.9)].map { Roi.FloatPoint(x: Float($0.0), y: Float($0.1)) }
            return Roi(.polygon(.init(.polygon, .subpixel(points))))
        case .freehandROI:
            let points = (0..<40).map { k -> (Int32, Int32) in
                let a = Double(k) / 40 * 2 * Double.pi
                return (Int32(30 + 18 * cos(a) + 3 * cos(5 * a)), Int32(23 + 14 * sin(a)))
            }
            return Roi(.polygon(.init(.freehand, ints(points))))
        case .tracedROI:
            return Roi(.polygon(.init(.traced, ints([(10, 10), (30, 10), (30, 20), (40, 20), (40, 35), (10, 35)]))))
        case .edgeROI: return Roi(.rectangle(.integer(x: 40, y: 30, width: 40, height: 30)))
        case .namedROI:
            var roi = Roi(.oval(.integer(x: 5, y: 5, width: 25, height: 36)))
            roi.name = "cell 1"
            return roi
        default: return Roi(.rectangle(.integer(x: 10, y: 7, width: 25, height: 19)))
        }
    }

    static func make(
        _ title: String, _ type: PixelType, channels: Int = 1, slices: Int = 1, frames: Int = 1, composite: Bool = false,
        width: Int = Self.width, height: Int = Self.height
    ) throws -> Hyperstack {
        var random = SeededRandom(seed: UInt64(title.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) }))
        let count = width * height
        let planes = (0..<(channels * slices * frames)).map { index -> Plane in
            // A gradient with a bright blob and noise: something for filters,
            // thresholds and histograms to work on.
            func value(_ i: Int) -> Double {
                let x = Double(i % width), y = Double(i / width)
                let dx = x - Double(width) * 0.6, dy = y - Double(height) * 0.4
                let blob = exp(-(dx * dx + dy * dy) / 90)
                return 0.15 + 0.35 * x / Double(width) + 0.45 * blob + 0.05 * random.unit() + 0.02 * Double(index % 3)
            }
            switch type {
            case .gray8: return .gray8((0..<count).map { UInt8(clamping: Int(value($0) * 250)) })
            case .gray16: return .gray16((0..<count).map { UInt16(clamping: Int(200 + value($0) * 3600)) })
            case .gray32Float: return .gray32Float((0..<count).map { Float(value($0) * 4 - 1.5) })
            case .rgb8:
                return .rgb8((0..<count).map { i in
                    let v = value(i)
                    let r = UInt32(clamping: Int(v * 250)), g = UInt32(clamping: Int((1 - v) * 200)), b = UInt32(random.next() % 256)
                    return 0xFF00_0000 | r << 16 | g << 8 | b
                })
            }
        }
        let stack = try ImageStack(width: width, height: height, planes: planes)
        return try Hyperstack(
            title: title, stack: stack, dimensions: HyperstackDimensions(channels: channels, slices: slices, frames: frames),
            compositeMode: composite ? .composite : .color)
    }
}

/// SplitMix64: small, fast and the same on every platform.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
