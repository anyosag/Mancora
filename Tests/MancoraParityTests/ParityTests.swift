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

/// Analyze ▸ Measure, with every measurement ImageJ makes without a selection.
@Suite("ImageJ parity: measurements", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct MeasurementParityTests {
    static let everything =
        "area mean standard modal min centroid center perimeter bounding fit shape feret's integrated median "
        + "skewness kurtosis area_fraction stack display redirect=None decimal=3"

    @Test func defaultsOnEveryType() async throws {
        try await Parity.check(
            [ParityInput.gray8, .gray16, .gray32, .rgb, .stack8, .calibrated, .fixtureFire, .fixtureHyperstack].map {
                ParityCase.measure("area mean min redirect=None decimal=3", on: $0)
            })
    }

    @Test func everythingOnEveryType() async throws {
        try await Parity.check(
            [ParityInput.gray8, .gray16, .gray32, .rgb, .stack16, .stack32, .hyperstack, .calibrated, .fixtureHyperstack]
                .map { ParityCase.measure(Self.everything, on: $0, tolerance: 1e-9) })
    }

    @Test func optionsThatChangeTheNumbers() async throws {
        try await Parity.check([
            .measure("centroid center bounding invert redirect=None decimal=3", on: .calibrated),
            .measure("area mean limit redirect=None decimal=3", on: .gray8),
            .measure("area mean limit redirect=None decimal=3", on: .gray32),
            .measure("circularity slice display redirect=None decimal=3", on: .stack8),
            .measure("area display redirect=None decimal=3", on: .gray16, then: [.init(command: "Measure", options: "")]),
            .measure("area mean redirect=None decimal=3", on: .gray8, then: [.init(command: "Clear Results", options: "")]),
        ])
    }
}

/// Process ▸ Filters, Noise and Binary, and the 3×3 filters.
@Suite("ImageJ parity: filters", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct FilterParityTests {
    @Test func gaussianBlur() async throws {
        try await Parity.check([
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray8),
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray16),
            ParityCase("Gaussian Blur...", "sigma=2.5", on: .gray32),
            ParityCase("Gaussian Blur...", "sigma=1", on: .rgb),
            ParityCase("Gaussian Blur...", "sigma=1.5 stack", on: .stack16),
            ParityCase("Gaussian Blur...", "sigma=1.5", on: .stack8),
            ParityCase("Gaussian Blur...", "sigma=0.5 scaled stack", on: .calibrated),
            ParityCase("Gaussian Blur...", "radius=5", on: .gray8),
            ParityCase("Gaussian Blur...", "sigma=3", on: .hyperstack),
        ])
    }

    @Test func rankFilters() async throws {
        try await Parity.check([
            ParityCase("Mean...", "radius=2", on: .gray8),
            ParityCase("Minimum...", "radius=1", on: .gray16),
            ParityCase("Maximum...", "radius=3", on: .gray32),
            ParityCase("Variance...", "radius=2", on: .gray16),
            ParityCase("Variance...", "radius=1.5", on: .gray32),
            ParityCase("Variance...", "radius=2", on: .gray8),
            ParityCase("Median...", "radius=2", on: .rgb),
            ParityCase("Median...", "radius=1 stack", on: .stack8),
            ParityCase("Remove Outliers...", "radius=2 threshold=20 which=Bright", on: .gray8),
            ParityCase("Remove Outliers...", "radius=3 threshold=100 which=Dark", on: .gray16),
            ParityCase("Remove NaNs...", "radius=2", on: .gray32),
            ParityCase("Despeckle", on: .gray8),
            ParityCase("Despeckle", on: .rgb),
            ParityCase("Despeckle", "stack", on: .stack16),
        ])
    }

    @Test func threeByThreeAndConvolve() async throws {
        try await Parity.check([
            ParityCase("Smooth", on: .gray8),
            ParityCase("Smooth", on: .gray32),
            ParityCase("Sharpen", on: .gray16),
            ParityCase("Sharpen", on: .rgb),
            ParityCase("Find Edges", on: .gray8),
            ParityCase("Find Edges", on: .gray32),
            ParityCase("Find Edges", "stack", on: .stack16),
            ParityCase("Convolve...", "text1=[-1 -1 -1\n-1 8 -1\n-1 -1 -1] normalize", on: .gray8),
            ParityCase("Convolve...", "text1=[1 2 1 2 4 2 1 2 1] normalize", on: .gray32),
            ParityCase("Convolve...", "text1=[0 1 0\n1 1 1\n0 1 0]", on: .gray16),
            ParityCase("Convolve...", "text1=[1 1 1\n1 1 1\n1 1 1] normalize stack", on: .stack8),
        ])
    }

    @Test func binary() async throws {
        // Binary Options are static in ImageJ's helper: put them back to ImageJ's defaults.
        let reset = ParityCase.Step(command: "Options...", options: "iterations=1 count=1 black do=Nothing")
        try await Parity.check(
            ["Erode", "Dilate", "Open", "Close-", "Outline", "Fill Holes", "Skeletonize"].map { ParityCase($0, on: .binary) }
                + [
                    ParityCase("Erode", "stack", on: .binaryStack),
                    ParityCase("Outline", "stack", on: .binaryStack),
                    ParityCase("Outline", on: .binaryStack),
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=2 count=3 black do=Nothing"),
                                .init(command: "Dilate", options: ""), reset],
                        inputs: [.binary]),
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=3 count=2 pad do=Erode"), reset],
                        inputs: [.binary]),
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=1 count=1 black do=[Fill Holes]"), reset],
                        inputs: [.binary]),
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=1 count=1 black do=Outline"), reset],
                        inputs: [.binary]),
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=1 count=1 black do=Skeletonize"), reset],
                        inputs: [.binary]),
                ])
    }
}
