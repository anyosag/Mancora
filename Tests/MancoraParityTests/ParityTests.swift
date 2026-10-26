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

    @Test func selections() async throws {
        try await Parity.check(
            [ParityInput.rectangleROI, .roundedROI, .ovalROI, .polygonROI, .subpixelPolygonROI, .freehandROI, .tracedROI,
             .edgeROI, .namedROI]
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

/// Image ▸ Type, Process ▸ Math, Image Calculator and the stack and channel tools.
@Suite("ImageJ parity: types, math and stacks", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ProcessParityTests {
    @Test func types() async throws {
        try await Parity.check(
            [ParityInput.gray16, .gray32, .rgb, .stack16, .hyperstack, .calibrated, .fixtureHyperstack, .fixtureFire]
                .map { ParityCase("8-bit", on: $0) }
                + [ParityInput.gray8, .gray32, .stack32, .rgb].map { ParityCase("16-bit", on: $0) }
                + [ParityInput.gray8, .gray16, .rgb, .hyperstack, .fixtureHyperstack].map { ParityCase("32-bit", on: $0) }
                + [ParityInput.gray8, .gray16, .gray32, .fixtureFire, .stack8].map { ParityCase("RGB Color", on: $0) })
    }

    @Test func math() async throws {
        try await Parity.check([
            ParityCase("Add...", "value=25", on: .gray8),
            ParityCase("Add...", "value=1000 stack", on: .stack16),
            ParityCase("Add...", "value=0.5", on: .gray32),
            ParityCase("Add...", "value=7", on: .stack8),
            ParityCase("Subtract...", "value=10", on: .rgb),
            ParityCase("Multiply...", "value=1.5", on: .gray16),
            ParityCase("Divide...", "value=3", on: .gray32),
            ParityCase("Divide...", "value=0", on: .gray8),
            ParityCase("Min...", "value=100", on: .gray8),
            ParityCase("Max...", "value=2000", on: .gray16),
            ParityCase("Min...", "value=0", on: .gray32),
            ParityCase("Gamma...", "value=0.7", on: .gray16),
            ParityCase("Gamma...", "value=1.5", on: .gray8),
            ParityCase("Set...", "value=7", on: .gray32),
            ParityCase("Log", on: .gray8), ParityCase("Log", on: .gray16), ParityCase("Log", on: .gray32),
            ParityCase("Exp", on: .gray32), ParityCase("Square", on: .gray16), ParityCase("Square Root", on: .gray32),
            ParityCase("Reciprocal", on: .gray32), ParityCase("Abs", on: .gray32),
            ParityCase("AND...", "value=11110000", on: .gray8),
            ParityCase("XOR...", "value=1010", on: .gray16),
            ParityCase("Invert", on: .gray8), ParityCase("Invert", on: .gray16), ParityCase("Invert", on: .gray32),
            ParityCase("Invert", on: .rgb), ParityCase("Invert", "stack", on: .stack16), ParityCase("Invert", on: .stack8),
        ])
    }

    @Test func imageCalculator() async throws {
        try await Parity.check([
            ParityCase("Image Calculator...", "image1=gray8.tif operation=Add image2=binary.tif create", on: .gray8, .binary),
            ParityCase("Image Calculator...", "image1=gray16.tif operation=Multiply image2=gray8.tif create", on: .gray8, .gray16),
            ParityCase("Image Calculator...", "image1=gray32.tif operation=Divide image2=gray8.tif create 32-bit", on: .gray8, .gray32),
            ParityCase("Image Calculator...", "image1=gray8.tif operation=AND image2=binary.tif", on: .binary, .gray8),
            ParityCase("Image Calculator...", "image1=gray8.tif operation=Difference image2=gray16.tif create 32-bit", on: .gray16, .gray8),
            ParityCase("Image Calculator...", "image1=stack8.tif operation=Average image2=gray8.tif create stack", on: .gray8, .stack8),
        ])
    }

    @Test func stacksAndChannels() async throws {
        try await Parity.check([
            ParityCase("Z Project...", "projection=[Max Intensity]", on: .stack16),
            ParityCase("Z Project...", "start=2 stop=4 projection=[Average Intensity]", on: .stack8),
            ParityCase("Z Project...", "projection=[Sum Slices]", on: .stack32),
            ParityCase("Z Project...", "projection=[Standard Deviation]", on: .stack16),
            ParityCase("Z Project...", "projection=Median", on: .stack8),
            ParityCase("Z Project...", "projection=[Max Intensity] all", on: .hyperstack),
            ParityCase("Z Project...", "projection=[Min Intensity]", on: .hyperstack),
            ParityCase("Z Project...", "projection=[Max Intensity] all", on: .fixtureHyperstack),
            ParityCase("Split Channels", on: .hyperstack),
            ParityCase("Split Channels", on: .rgb),
            ParityCase("Split Channels", on: .fixtureHyperstack),
            ParityCase("Merge Channels...", "c1=gray8.tif c2=binary.tif create", on: .gray8, .binary),
            ParityCase("Merge Channels...", "c1=gray8.tif c2=binary.tif", on: .gray8, .binary),
            ParityCase("Merge Channels...", "c3=gray8.tif c6=binary.tif create keep", on: .gray8, .binary),
            ParityCase("Make Substack...", "slices=2-4", on: .stack16),
            ParityCase("Make Substack...", "slices=1,3,5", on: .stack8),
            // (One channel of a composite stays a one-channel composite in both;
            // ImageJ's FileSaver then saves it with a gray LUT, Mancora with its color.)
            ParityCase("Make Substack...", "channels=1-2 slices=2 frames=1-2", on: .hyperstack),
            ParityCase("Reduce Dimensionality...", "channels slices keep", on: .hyperstack),
            ParityCase("Reduce Dimensionality...", "frames", on: .hyperstack),
            ParityCase("Arrange Channels...", "new=21", on: .hyperstack),
            ParityCase("Arrange Channels...", "new=2", on: .fixtureHyperstack),
        ])
    }
}

/// Process ▸ Binary ▸ Convert to Mask, which runs ImageJ's 17 automatic
/// threshold methods on stacks.
@Suite("ImageJ parity: thresholds", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ThresholdParityTests {
    @Test func convertToMask() async throws {
        try await Parity.check(
            [ParityInput.gray8, .gray16, .gray32, .stack8, .stack16, .fixtureFire, .hyperstack].map {
                ParityCase("Convert to Mask", on: $0)
            } + [
                ParityCase("Make Binary", on: .gray8),
                ParityCase("Convert to Mask", "method=Default background=Default black", on: .stack8),
                ParityCase("Convert to Mask", "method=Default background=Default only black", on: .stack8),
                ParityCase("Convert to Mask", "method=Otsu background=Dark calculate black create", on: .stack16),
            ])
    }

    @Test(arguments: [ParityInput.stack8, .stack16, .stack32])
    func everyMethod(on input: ParityInput) async throws {
        try await Parity.check(
            AutoThresholderMethods.all.flatMap { method in
                ["Dark", "Light"].map { background in
                    ParityCase("Convert to Mask", "method=\(method) background=\(background) calculate black", on: input)
                }
            })
    }
}

enum AutoThresholderMethods {
    static let all = [
        "Default", "Huang", "Intermodes", "IsoData", "IJ_IsoData", "Li", "MaxEntropy", "Mean", "MinError", "Minimum",
        "Moments", "Otsu", "Percentile", "RenyiEntropy", "Shanbhag", "Triangle", "Yen",
    ]
}

/// Analyze ▸ Analyze Particles.
@Suite("ImageJ parity: particles", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ParticleParityTests {
    typealias Step = ParityCase.Step
    static let everything = MeasurementParityTests.everything

    static func particles(
        _ options: String, on input: ParityInput, measure: String = "area mean min redirect=None decimal=3",
        before: [Step] = []
    ) -> ParityCase {
        ParityCase(
            steps: before + [Step(command: "Set Measurements...", options: measure),
                             Step(command: "Analyze Particles...", options: options)],
            inputs: [input], tolerance: 1e-9, results: true)
    }

    @Test func binaryImages() async throws {
        try await Parity.check([
            Self.particles("display clear", on: .binary),
            Self.particles("display clear", on: .binary, measure: Self.everything),
            Self.particles("size=20-Infinity display clear exclude", on: .binary, measure: Self.everything),
            Self.particles("size=0-15 display clear include", on: .binary),
            Self.particles("circularity=0.50-1.00 display clear", on: .binary, measure: Self.everything),
            Self.particles("display clear four", on: .binary, measure: Self.everything),
            Self.particles("display clear record", on: .binary),
            Self.particles("show=Masks display clear", on: .binary),
            Self.particles("display clear stack", on: .binaryStack, measure: Self.everything),
            Self.particles("show=Masks display clear stack", on: .binaryStack),
            Self.particles("display clear summarize", on: .binary),
        ])
    }

    @Test func thresholdedImages() async throws {
        let mask = Step(command: "Convert to Mask", options: "")
        try await Parity.check([
            Self.particles("display clear", on: .gray8, measure: Self.everything, before: [mask]),
            Self.particles("display clear include", on: .gray16, measure: Self.everything, before: [mask]),
            Self.particles("size=0.5-Infinity display clear", on: .freehandROI, measure: Self.everything, before: [mask]),
            Self.particles("size=10-Infinity pixel display clear exclude", on: .namedROI, before: [mask]),
        ])
    }

    @Test func withinSelections() async throws {
        try await Parity.check([
            Self.particles("display clear", on: .binaryRectangleROI, measure: Self.everything),
            Self.particles("display clear exclude", on: .binaryRectangleROI),
            Self.particles("display clear", on: .binaryOvalROI, measure: Self.everything),
            Self.particles("display clear include summarize", on: .binaryOvalROI),
        ])
    }
}
