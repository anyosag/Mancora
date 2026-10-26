import Testing

/// Image ▸ Transform: the flips, the 90-degree rotations and Flip Z, and
/// Image ▸ Stacks ▸ Tools ▸ Reverse.
@Suite("ImageJ parity: transforms", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct TransformParityTests {
    typealias Step = ParityCase.Step

    /// Non-square pixels and an origin on the calibrated stack.
    static let calibrate = Step(
        command: "Properties...",
        options: "channels=1 slices=3 frames=1 unit=µm pixel_width=0.25 pixel_height=0.5 voxel_depth=1.5 origin=10,5")

    static func calibrated(_ command: String, _ options: String = "") -> ParityCase {
        ParityCase(steps: [calibrate, Step(command: command, options: options)], inputs: [.calibrated])
    }

    @Test func flips() async throws {
        try await Parity.check([
            ParityCase("Flip Horizontally", on: .gray8),
            ParityCase("Flip Horizontally", on: .gray16Oval),
            ParityCase("Flip Horizontally", on: .rgb),
            ParityCase("Flip Horizontally", on: .stack8),
            ParityCase("Flip Horizontally", "stack", on: .stack8),
            ParityCase("Flip Horizontally", on: .gray32Rect),
            ParityCase("Flip Horizontally", on: .hyperstack),
            ParityCase("Flip Horizontally", on: .gray8Line),
            ParityCase("Flip Horizontally", on: .edgeROI),
            Self.calibrated("Flip Horizontally", "stack"),
            Self.calibrated("Flip Horizontally"),
            ParityCase("Flip Vertically", on: .gray16),
            ParityCase("Flip Vertically", on: .polygonROI),
            ParityCase("Flip Vertically", on: .rgbRect),
            ParityCase("Flip Vertically", "stack", on: .stack16),
            ParityCase("Flip Vertically", "stack", on: .stack32Polygon),
            Self.calibrated("Flip Vertically"),
            ParityCase("Flip Vertically", "stack", on: .fixtureHyperstack),
        ])
    }

    @Test func rotations() async throws {
        try await Parity.check([
            ParityCase("Rotate 90 Degrees Right", on: .gray8),
            ParityCase("Rotate 90 Degrees Right", on: .gray16Oval),
            ParityCase("Rotate 90 Degrees Right", on: .gray32),
            ParityCase("Rotate 90 Degrees Right", on: .rgb),
            ParityCase("Rotate 90 Degrees Right", on: .stack16),
            ParityCase("Rotate 90 Degrees Right", on: .hyperstack),
            ParityCase("Rotate 90 Degrees Right", on: .fixtureHyperstack),
            ParityCase("Rotate 90 Degrees Right", on: .fixtureFire),
            Self.calibrated("Rotate 90 Degrees Right"),
            ParityCase("Rotate 90 Degrees Left", on: .gray8),
            ParityCase("Rotate 90 Degrees Left", on: .rgbPolygon),
            ParityCase("Rotate 90 Degrees Left", on: .stack32),
            ParityCase("Rotate 90 Degrees Left", on: .calibrated),
            Self.calibrated("Rotate 90 Degrees Left"),
        ])
    }

    @Test func reverse() async throws {
        try await Parity.check([
            ParityCase("Flip Z", on: .stack8),
            ParityCase("Flip Z", on: .stack16),
            ParityCase("Flip Z", on: .stack32),
            Self.calibrated("Flip Z"),
            ParityCase("Reverse", on: .stack16),
            ParityCase("Reverse", on: .stack8Oval),
            ParityCase(
                steps: [Step(command: "Properties...", options: "channels=1 slices=1 frames=5 frame=[0.5 sec]"),
                        Step(command: "Reverse", options: "")],
                inputs: [.stack32]),
        ])
    }
}
