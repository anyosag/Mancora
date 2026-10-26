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
            // The histogram is the selection's.
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .rectangleROI),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .ovalROI),
            ParityCase("Enhance Contrast...", "saturated=1", on: .polygonROI),
            ParityCase("Enhance Contrast...", "saturated=0.35", on: .edgeROI),
            // A composite has no "Use stack histogram"; saturation is limited to 0–100%.
            ParityCase("Enhance Contrast...", "saturated=0.35 use", on: .hyperstack),
            ParityCase("Enhance Contrast...", "saturated=150", on: .gray16),
        ])
    }

    /// Enhance Contrast with Normalize, which "Process all" implies.
    @Test func normalize() async throws {
        try await Parity.check([
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .gray8),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .gray16),
            ParityCase("Enhance Contrast...", "saturated=1 normalize", on: .gray32),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .stack8),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize process_all", on: .stack16),
            ParityCase("Enhance Contrast...", "saturated=0.35 process_all use", on: .stack32),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize_all", on: .stack8),
            // Only the selection, unless "Update all when normalizing" (32-bit: all).
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .ovalROI),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize update", on: .ovalROI),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .rectangleROI),
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .polygonROI),
            // Composites aren't normalized.
            ParityCase("Enhance Contrast...", "saturated=0.35 normalize", on: .hyperstack),
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
            // An area selection crops the copy to its bounds within the image.
            ParityCase("Duplicate...", "title=copy", on: .rectangleROI),
            ParityCase("Duplicate...", "title=copy", on: .ovalROI),
            ParityCase("Duplicate...", "title=copy", on: .edgeROI),
            ParityCase("Duplicate...", "title=copy", on: .polygonROI),
            ParityCase("Duplicate...", "title=copy", on: .roundedROI),
            ParityCase("Duplicate...", "title=copy", on: .freehandROI),
            ParityCase("Duplicate...", "title=copy", on: .namedROI),
            ParityCase(
                steps: [.init(command: "Properties...", options: "channels=1 slices=1 frames=1 unit=nm pixel_width=3 pixel_height=3 voxel_depth=3 origin=4,5"),
                        .init(command: "Duplicate...", options: "title=copy")],
                inputs: [.rectangleROI]),
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
            // Decimal places are cast to int as Java casts them, then limited to 0–9.
            .measure("area mean redirect=None decimal=1e20", on: .gray8),
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
            ParityCase("Gaussian Blur...", "sigma=12", on: .gray16),
            // The dialog listener takes a negative sigma as given: nothing is blurred.
            ParityCase("Gaussian Blur...", "sigma=-2", on: .gray8),
        ])
    }

    /// Filters that support masking change only the selection, reading the
    /// image around it.
    @Test func selections() async throws {
        try await Parity.check([
            ParityCase("Gaussian Blur...", "sigma=2", on: .rectangleROI),
            ParityCase("Gaussian Blur...", "sigma=2", on: .ovalROI),
            ParityCase("Gaussian Blur...", "sigma=1.5", on: .polygonROI),
            ParityCase("Gaussian Blur...", "sigma=9", on: .edgeROI),
            // Downscaled lines start where the kernel starts reading.
            ParityCase("Gaussian Blur...", "sigma=12", on: .rectangleROI),
            ParityCase("Gaussian Blur...", "sigma=12", on: .ovalROI),
            ParityCase("Mean...", "radius=2", on: .ovalROI),
            ParityCase("Median...", "radius=1", on: .rectangleROI),
            ParityCase("Variance...", "radius=2", on: .rectangleROI),
            ParityCase("Remove Outliers...", "radius=2 threshold=20 which=Bright", on: .ovalROI),
            ParityCase("Despeckle", on: .edgeROI),
            ParityCase("Smooth", on: .ovalROI),
            ParityCase("Sharpen", on: .polygonROI),
            ParityCase("Find Edges", on: .edgeROI),
            ParityCase("Convolve...", "text1=[1 2 1 2 4 2 1 2 1] normalize", on: .ovalROI),
            // With a selection, Convolver keeps the display range.
            ParityCase("Convolve...", "text1=[0 1 0\n1 1 1\n0 1 0]", on: .rectangleROI),
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
            // makeLineRadii squares a negative radius (without the 1.5 and 2.5 adjustments).
            ParityCase("Mean...", "radius=-1.6", on: .gray8),
            ParityCase("Median...", "radius=-2.6", on: .gray16),
            ParityCase("Median...", "radius=0.5", on: .gray8),
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
            // One line: the largest odd square of the values (here the first 9, then 25).
            ParityCase("Convolve...", "text1=[1 2 1 2 4 2 1 2 1 7] normalize", on: .gray8),
            ParityCase("Convolve...", "text1=[1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1]", on: .gray32),
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
                    // Numbers are cast as Java casts them, then limited to 1–100.
                    ParityCase(
                        steps: [.init(command: "Options...", options: "iterations=1e20 count=1 black do=Erode"), reset],
                        inputs: [.binary]),
                ])
    }

    /// Erode and dilate change the selection's bounds at each iteration and
    /// its mask at the end; Fill Holes fills the whole image but the mask's
    /// bounds; Skeletonize ignores the selection.
    @Test func binaryWithinSelections() async throws {
        typealias Step = ParityCase.Step
        let reset = Step(command: "Options...", options: "iterations=1 count=1 black do=Nothing")
        let iterations = Step(command: "Options...", options: "iterations=3 count=2 black do=Nothing")
        let white = Step(command: "Options...", options: "iterations=1 count=1 do=Nothing")
        try await Parity.check(
            ["Erode", "Dilate", "Fill Holes", "Skeletonize", "Outline"].map { ParityCase($0, on: .binaryOvalROI) }
                + ["Open", "Outline"].map { ParityCase($0, on: .binaryRectangleROI) }
                + [
                    ParityCase(steps: [iterations, Step(command: "Erode", options: ""), reset], inputs: [.binaryOvalROI]),
                    ParityCase(steps: [iterations, Step(command: "Close-", options: ""), reset], inputs: [.binaryRectangleROI]),
                    ParityCase(steps: [white, Step(command: "Outline", options: ""), reset], inputs: [.binaryOvalROI]),
                    ParityCase(steps: [white, Step(command: "Erode", options: ""), reset], inputs: [.binaryOvalROI]),
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
                + [ParityInput.gray8, .gray16, .gray32, .fixtureFire, .stack8].map { ParityCase("RGB Color", on: $0) }
                // "RGB Color" forgets the name of the LUT it was drawn through.
                + [ParityInput.gray8, .gray16, .stack8].map {
                    ParityCase(steps: [.init(command: "Fire", options: ""), .init(command: "RGB Color", options: "")], inputs: [$0])
                })
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
            // One slice of a stack is the image's processor, whose display range Min, Max and Abs reset.
            ParityCase("Max...", "value=2000", on: .stack16),
            ParityCase("Min...", "value=1000", on: .stack16),
            ParityCase("Abs", on: .stack32),
            ParityCase("Min...", "value=0", on: .stack32),
        ])
    }

    /// Process ▸ Math and Invert change only the selection; a display range
    /// reset sees its bounds changed, before the mask restores the rest.
    @Test func mathWithinSelections() async throws {
        try await Parity.check([
            ParityCase("Add...", "value=25", on: .ovalROI),
            ParityCase("Add...", "value=25", on: .rectangleROI),
            ParityCase("Multiply...", "value=1.5", on: .polygonROI),
            ParityCase("Min...", "value=1500", on: .rectangleROI),
            ParityCase("Max...", "value=1", on: .polygonROI),
            ParityCase("Invert", on: .rectangleROI),
            ParityCase("Invert", on: .polygonROI),
            ParityCase("Invert", on: .ovalROI),
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
            // A slice number beyond the stack is ignored (cast to int as Java casts).
            ParityCase("Z Project...", "start=1e20 projection=[Max Intensity]", on: .stack8),
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

    /// A stack's processors have its LUT: an inverted one swaps the side each
    /// slice's own threshold takes.
    @Test func invertedLUTStacks() async throws {
        let invert = ParityCase.Step(command: "Invert LUT", options: "")
        func mask(_ options: String, on input: ParityInput) -> ParityCase {
            ParityCase(steps: [invert, .init(command: "Convert to Mask", options: options)], inputs: [input])
        }
        try await Parity.check([
            mask("method=Otsu background=Light calculate", on: .stack8),
            mask("method=Otsu background=Light calculate", on: .stack16),
            mask("method=Default background=Default calculate black", on: .stack8),
            mask("method=Huang background=Dark calculate black", on: .stack32),
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
