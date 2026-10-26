import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import Testing

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
        try CommandRegistry.standard.run(parityCase.command, options: MacroOptions(parityCase.options), in: &context)
        guard let current = context.current else { return ["Mancora left no image open"] }
        let native = try roundTrip(current.image)
        let nativeIsNew = !before.contains(current.id)

        let result = try await bridge.run(parityCase.command, options: parityCase.options, images: inputs)
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
        return differences
    }

    /// `image` as it reads back after being saved the way ImageJ saves it.
    static func roundTrip(_ image: Hyperstack) throws -> Hyperstack {
        var copy = try TIFFImporter.decode(TIFFExporter.encode(image), title: image.title)
        copy.title = image.title
        return copy
    }
}

/// One command, its macro options and the images it runs on (the last is current).
struct ParityCase: Sendable, CustomStringConvertible {
    var command: String
    var options = ""
    var inputs: [ParityInput]
    /// For float pixels and results: the largest difference allowed,
    /// relative to the value (absolute below 1).
    var tolerance = 1e-5
    var comparesResults = false

    init(_ command: String, _ options: String = "", on inputs: ParityInput..., tolerance: Double = 1e-5, results: Bool = false) {
        self.command = command
        self.options = options
        self.inputs = inputs
        self.tolerance = tolerance
        self.comparesResults = results
    }

    var description: String {
        let on = inputs.map(\.rawValue).joined(separator: ", ")
        return options.isEmpty ? "\"\(command)\" on \(on)" : "\"\(command)\" \"\(options)\" on \(on)"
    }
}

/// Test images: small, odd-sized and filled from a fixed seed so every run
/// is the same, plus the ImageJ-written fixtures.
enum ParityInput: String, Sendable {
    case gray8, gray16, gray32, rgb, stack8, stack16, stack32, hyperstack, calibrated
    case fixtureHyperstack = "ij-hyperstack-16bit.tif"
    case fixtureFire = "ij-8bit-fire.tif"

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
        case .hyperstack:
            made = try Self.make("hyperstack.tif", .gray16, channels: 2, slices: 3, frames: 2, composite: true)
        case .calibrated:
            var image = try Self.make("calibrated.tif", .gray16, slices: 3)
            image.calibration.pixelWidth = 0.25
            image.calibration.pixelHeight = 0.25
            image.calibration.pixelDepth = 1.5
            image.calibration.unit = "µm"
            made = image
        case .fixtureHyperstack, .fixtureFire:
            return try TIFFImporter.read(path: Parity.url("Tests/Fixtures/tiff/" + rawValue).path)
        }
        return try Parity.roundTrip(made)
    }

    static let width = 61, height = 47

    static func make(
        _ title: String, _ type: PixelType, channels: Int = 1, slices: Int = 1, frames: Int = 1, composite: Bool = false
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
