import Testing

/// Image ▸ Crop, Image ▸ Adjust ▸ Canvas Size, and Duplicate's crop to the
/// selection. Measuring afterwards checks where the selection ends up.
@Suite("ImageJ parity: crop, canvas size and duplicate", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct CropParityTests {
    typealias Step = ParityCase.Step

    /// `steps`, then Measure with the selection's area, position and bounds.
    static func measured(_ steps: [Step], on input: ParityInput) -> ParityCase {
        ParityCase(
            steps: steps + [Step(command: "Set Measurements...", options: "area mean centroid bounding redirect=None decimal=3"),
                            Step(command: "Measure", options: "")],
            inputs: [input], tolerance: 1e-9, results: true)
    }

    /// Gives the calibrated stack an origin, which cropping moves.
    static let origin = Step(
        command: "Properties...",
        options: "channels=1 slices=3 frames=1 unit=µm pixel_width=0.25 pixel_height=0.5 voxel_depth=1.5 origin=10,5")

    @Test func crop() async throws {
        try await Parity.check([
            ParityCase("Crop", on: .gray8Rect),
            ParityCase("Crop", on: .rgbPolygon),
            ParityCase("Crop", on: .stack8Oval),
            ParityCase("Crop", on: .stack32Polygon),
            ParityCase("Crop", on: .hyperstackOval),
            ParityCase("Crop", on: .calibratedRect),
            ParityCase("Crop", on: .edgeROI),
            ParityCase("Crop", on: .roundedROI),
            ParityCase(steps: [Self.origin, Step(command: "Crop", options: "")], inputs: [.calibratedOval]),
            Self.measured([Step(command: "Crop", options: "")], on: .gray16Oval),
            Self.measured([Step(command: "Crop", options: "")], on: .polygonROI),
            Self.measured([Step(command: "Crop", options: "")], on: .gray32Subpixel),
            Self.measured([Step(command: "Crop", options: "")], on: .gray16Freehand),
            Self.measured([Step(command: "Crop", options: "")], on: .tracedROI),
        ])
    }

    @Test func canvasSize() async throws {
        try await Parity.check([
            ParityCase("Canvas Size...", "width=80 height=60 position=Center", on: .gray8),
            ParityCase("Canvas Size...", "width=80 height=60 position=Top-Left", on: .gray16),
            ParityCase("Canvas Size...", "width=50 height=40 position=Bottom-Right", on: .gray32),
            ParityCase("Canvas Size...", "width=70 height=70 position=Center-Right zero", on: .rgb),
            ParityCase("Canvas Size...", "width=70 height=50 position=Bottom-Center", on: .stack16),
            ParityCase("Canvas Size...", "width=65 height=51 position=Center", on: .hyperstack),
            ParityCase("Canvas Size...", "width=64 height=44 position=Top-Right", on: .calibrated),
            ParityCase("Canvas Size...", "width=64 height=44 position=Center-Left zero", on: .stack32),
            ParityCase("Canvas Size...", "width=70 height=50 position=Center", on: .gray16Oval),
            ParityCase(
                steps: [Step(command: "Invert LUT", options: ""),
                        Step(command: "Canvas Size...", options: "width=70 height=56 position=Bottom-Left")],
                inputs: [.gray8]),
            ParityCase("Canvas Size...", "width=70 height=56 position=Center", on: .rgb),
            Self.measured([Step(command: "Canvas Size...", options: "width=61 height=47 position=Center")], on: .gray8Oval),
            // The fill follows the LUT and display range: the inverted LUT's
            // entry for black is the top of the range.
            ParityCase(
                steps: [Step(command: "Invert LUT", options: ""),
                        Step(command: "Canvas Size...", options: "width=70 height=56 position=Center")],
                inputs: [.gray16]),
            ParityCase(
                steps: [Step(command: "Invert LUT", options: ""),
                        Step(command: "Canvas Size...", options: "width=70 height=56 position=Top-Center")],
                inputs: [.stack32]),
            ParityCase(
                steps: [Step(command: "Enhance Contrast...", options: "saturated=5"),
                        Step(command: "Canvas Size...", options: "width=70 height=56 position=Center")],
                inputs: [.gray8]),
        ])
    }

    /// Display ranges set before cropping, rotating or reversing stay.
    /// (Enhance Contrast stretches to the selection in ImageJ, which
    /// Mancora's doesn't yet, so it runs on images without one here; Max
    /// resets a single image's range to its new pixel range.)
    @Test func changedDisplayRanges() async throws {
        let stretch = Step(command: "Enhance Contrast...", options: "saturated=5")
        try await Parity.check([
            ParityCase(steps: [Step(command: "Max...", options: "value=3000"), Step(command: "Crop", options: "")], inputs: [.gray16Oval]),
            ParityCase(steps: [Step(command: "Max...", options: "value=1.5"), Step(command: "Duplicate...", options: "title=c")], inputs: [.gray32Rect]),
            ParityCase(steps: [stretch, Step(command: "Duplicate...", options: "duplicate range=2-3")], inputs: [.stack16]),
            ParityCase(steps: [stretch, Step(command: "Rotate 90 Degrees Right", options: "")], inputs: [.gray8]),
            ParityCase(steps: [stretch, Step(command: "Rotate 90 Degrees Left", options: "")], inputs: [.stack32]),
            ParityCase(steps: [stretch, Step(command: "Flip Z", options: "")], inputs: [.stack16]),
            ParityCase(steps: [stretch, Step(command: "Flip Horizontally", options: "stack")], inputs: [.stack8]),
        ])
    }

    @Test func duplicateCrops() async throws {
        try await Parity.check([
            ParityCase("Duplicate...", "title=crop", on: .gray8Rect),
            ParityCase("Duplicate...", "title=crop", on: .rgbPolygon),
            ParityCase("Duplicate...", "duplicate range=2-4", on: .stack16Rect),
            ParityCase("Duplicate...", "title=one", on: .stack8Oval),
            ParityCase("Duplicate...", "duplicate", on: .stack32Polygon),
            ParityCase("Duplicate...", "duplicate channels=1-2 slices=2-3 frames=1", on: .hyperstackOval),
            ParityCase("Duplicate...", "title=current", on: .hyperstackOval),
            ParityCase("Duplicate...", "duplicate", on: .calibratedRect),
            ParityCase("Duplicate...", "title=edge", on: .edgeROI),
            ParityCase("Duplicate...", "title=line", on: .gray8Line),
            ParityCase(steps: [Self.origin, Step(command: "Duplicate...", options: "duplicate")], inputs: [.calibratedOval]),
            ParityCase(steps: [Self.origin, Step(command: "Duplicate...", options: "duplicate ignore")], inputs: [.calibratedOval]),
            Self.measured([Step(command: "Duplicate...", options: "title=crop")], on: .gray16Oval),
            Self.measured([Step(command: "Duplicate...", options: "title=whole ignore")], on: .gray8Oval),
            Self.measured([Step(command: "Duplicate...", options: "title=crop")], on: .gray32Subpixel),
            Self.measured([Step(command: "Duplicate...", options: "duplicate")], on: .stack8Oval),
        ])
    }
}
