import Testing

/// Every native command against ImageJ 1.54p. Each suite starts one helper
/// and runs its cases through it.
@Suite("ImageJ parity", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ParityTests {
    @Test func lookupTables() async throws {
        try await Parity.check([
            ParityCase("Fire", on: .gray8),
            ParityCase("Grays", on: .fixtureFire),
            ParityCase("Ice", on: .gray16),
            ParityCase("Spectrum", on: .gray32),
            ParityCase("3-3-2 RGB", on: .stack8),
            ParityCase("Red/Green", on: .gray8),
            ParityCase("Cyan", on: .hyperstack),
            ParityCase("Invert LUT", on: .gray8),
            ParityCase("Invert LUT", on: .gray16),
            ParityCase("Invert LUT", on: .fixtureFire),
            ParityCase("Invert LUT", on: .hyperstack),
            ParityCase("Magenta", on: .fixtureHyperstack),
            ParityCase("Grays", on: .fixtureHyperstack),
        ])
    }

    @Test func enhanceContrast() async throws {
        try await Parity.check([
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .gray8),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .gray16),
            ParityCase("Enhance Contrast...", "saturated=1", on: .gray32),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .stack16),
            ParityCase("Enhance Contrast...", "saturated=2 use", on: .stack16),
            ParityCase("Enhance Contrast...", "saturated=0.5 use", on: .stack32),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .hyperstack),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .fixtureHyperstack),
        ])
    }

    @Test func imageCommands() async throws {
        try await Parity.check([
            ParityCase("Rename...", "title=renamed.tif", on: .gray16),
            ParityCase("Duplicate...", "title=copy", on: .gray8),
            ParityCase("Duplicate...", " ", on: .rgb),
            ParityCase("Duplicate...", "duplicate range=2-4", on: .stack16),
            ParityCase("Duplicate...", "title=one", on: .stack8),
            ParityCase("Duplicate...", "duplicate channels=2 slices=2-3 frames=1", on: .hyperstack),
            ParityCase("Duplicate...", "duplicate", on: .calibrated),
            ParityCase("Duplicate...", "duplicate range=3", on: .stack32),
            ParityCase("Duplicate...", "duplicate range=4-9", on: .stack8),
            ParityCase("Duplicate...", "duplicate range=4-2", on: .stack16),
            ParityCase("Duplicate...", "duplicate slices=5", on: .hyperstack),
            ParityCase("Duplicate...", "title=current", on: .hyperstack),
            ParityCase("Duplicate...", "title=current", on: .fixtureHyperstack),
            ParityCase("Duplicate...", "duplicate frames=2", on: .fixtureHyperstack),
        ])
    }

    @Test func calibration() async throws {
        try await Parity.check([
            ParityCase("Set Scale...", "distance=10 known=2.5 unit=µm", on: .gray16),
            ParityCase("Set Scale...", "distance=20 known=1 pixel=2 unit=mm", on: .stack8),
            ParityCase("Set Scale...", "distance=0 known=0 unit=pixel", on: .calibrated),
            ParityCase("Set Scale...", "distance=4 known=1 unit=um", on: .gray8),
            ParityCase(
                "Properties...", "channels=1 slices=5 frames=1 pixel_width=0.5 pixel_height=0.75 voxel_depth=2 unit=µm",
                on: .stack16),
            ParityCase("Properties...", "channels=1 slices=1 frames=5 frame=[0.5 sec]", on: .stack8),
            ParityCase("Properties...", "channels=1 slices=1 frames=5 frame=2min", on: .stack16),
            ParityCase("Properties...", "channels=1 slices=1 frames=1 unit=nm pixel_width=3 pixel_height=3 voxel_depth=3 origin=4,5", on: .gray16),
            ParityCase("Properties...", "channels=1 slices=3 frames=1 unit=none", on: .calibrated),
        ])
    }
}
