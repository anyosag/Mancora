import Testing

/// Process ▸ Filters' Unsharp Mask, Top Hat and 3D filters, binary Median,
/// NaN Background and the Shadows, against ImageJ 1.54p.
@Suite("ImageJ parity: more filters", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ExtraFilterParityTests {
    typealias Step = ParityCase.Step

    @Test func unsharpMask() async throws {
        try await Parity.check([
            ParityCase("Unsharp Mask...", "radius=1 mask=0.60", on: .gray8),
            ParityCase("Unsharp Mask...", "radius=2 mask=0.40", on: .gray16),
            ParityCase("Unsharp Mask...", "radius=1.5 mask=0.75", on: .gray32),
            ParityCase("Unsharp Mask...", "radius=1 mask=0.60", on: .rgb),
            ParityCase("Unsharp Mask...", "radius=3 mask=0.50 stack", on: .stack16),
            ParityCase("Unsharp Mask...", "radius=12 mask=0.60", on: .gray16),
            // An old macro's radius is 2.5 sigmas.
            ParityCase("Unsharp Mask...", "gaussian=5 mask=0.60", on: .gray8),
            // Within selections, reading the image around them.
            ParityCase("Unsharp Mask...", "radius=2 mask=0.60", on: .ovalROI),
            ParityCase("Unsharp Mask...", "radius=2 mask=0.60", on: .rectangleROI),
            ParityCase("Unsharp Mask...", "radius=4 mask=0.60", on: .polygonROI),
            ParityCase("Unsharp Mask...", "radius=2 mask=0.60", on: .edgeROI),
        ])
    }

    @Test func topHat() async throws {
        try await Parity.check([
            ParityCase("Top Hat...", "radius=2", on: .gray8),
            ParityCase("Top Hat...", "radius=3 light", on: .gray16),
            ParityCase("Top Hat...", "radius=2 don't", on: .gray32),
            ParityCase("Top Hat...", "radius=2.5", on: .gray32),
            ParityCase("Top Hat...", "radius=1.5 light", on: .rgb),
            ParityCase("Top Hat...", "radius=2 stack", on: .stack8),
            ParityCase("Top Hat...", "radius=2 light don't stack", on: .stack16),
            ParityCase("Top Hat...", "radius=3", on: .ovalROI),
            ParityCase("Top Hat...", "radius=3 light", on: .rectangleROI),
            ParityCase("Top Hat...", "radius=4", on: .edgeROI),
            ParityCase("Top Hat...", "radius=2 don't", on: .polygonROI),
            // An inverted LUT swaps the background.
            ParityCase(steps: [Step(command: "Invert LUT", options: ""), Step(command: "Top Hat...", options: "radius=2")],
                       inputs: [.gray8]),
        ])
    }

    @Test func gaussianBlur3D() async throws {
        try await Parity.check([
            ParityCase("Gaussian Blur 3D...", "x=2 y=2 z=2", on: .stack8),
            ParityCase("Gaussian Blur 3D...", "x=1 y=1.5 z=1", on: .stack16),
            ParityCase("Gaussian Blur 3D...", "x=2 y=2 z=0.7", on: .stack32),
            ParityCase("Gaussian Blur 3D...", "x=0 y=0 z=1.5", on: .stack16),
            ParityCase("Gaussian Blur 3D...", "x=1 y=1 z=10", on: .stack8),
            ParityCase("Gaussian Blur 3D...", "x=1 y=1 z=1", on: .stackRGB),
            ParityCase("Gaussian Blur 3D...", "x=2 y=2 z=2", on: .gray8),
            ParityCase("Gaussian Blur 3D...", "x=1 y=1 z=1", on: .hyperstack),
            ParityCase("Gaussian Blur 3D...", "x=1 y=1 z=1", on: .calibrated),
            // The selection is removed.
            ParityCase("Gaussian Blur 3D...", "x=2 y=2 z=2", on: .stack8Oval),
        ])
    }

    @Test func filters3D() async throws {
        try await Parity.check(
            ["Median 3D...", "Mean 3D...", "Minimum 3D...", "Maximum 3D...", "Variance 3D..."].flatMap { name in
                [
                    ParityCase(name, "x=2 y=2 z=2", on: .stack8),
                    ParityCase(name, "x=1 y=1.5 z=1", on: .stack16),
                    ParityCase(name, "x=1 y=1 z=2", on: .stack32),
                ]
            } + [
                ParityCase("Median 3D...", "x=1 y=1 z=1", on: .stackRGB),
                ParityCase("Mean 3D...", "x=1 y=1 z=1", on: .stackRGB),
                ParityCase("Median 3D...", "x=1 y=1 z=1", on: .gray8),
                ParityCase("Maximum 3D...", "x=2 y=0 z=1", on: .calibrated),
                ParityCase("Mean 3D...", "x=1 y=1 z=1", on: .stack8Oval),
                // A single-channel hyperstack is one volume; channels are filtered one by one.
                ParityCase(
                    steps: [Step(command: "Properties...", options: "channels=1 slices=2 frames=2"),
                            Step(command: "Median 3D...", options: "x=1 y=1 z=1")],
                    inputs: [.stackRGB]),
                ParityCase(
                    steps: [Step(command: "Properties...", options: "channels=2 slices=6 frames=1"),
                            Step(command: "Mean 3D...", options: "x=1 y=1 z=1")],
                    inputs: [.hyperstack]),
                ParityCase(
                    steps: [Step(command: "Properties...", options: "channels=2 slices=1 frames=6"),
                            Step(command: "Variance 3D...", options: "x=1 y=1 z=1")],
                    inputs: [.hyperstack]),
            ])
    }

    @Test func binaryMedian() async throws {
        try await Parity.check([
            ParityCase("Median", "radius=3", on: .binary),
            ParityCase("Median", "radius=1.5 stack", on: .binaryStack),
            ParityCase("Median", "radius=2", on: .binaryOvalROI),
            ParityCase("Median", "radius=2", on: .binaryRectangleROI),
        ])
    }

    @Test func shadows() async throws {
        let directions = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
        try await Parity.check(
            directions.map { ParityCase($0, on: .gray8) }
                + [
                    ParityCase("North", on: .gray16), ParityCase("Southwest", on: .gray32), ParityCase("East", on: .rgb),
                    ParityCase("South", "stack", on: .stack16), ParityCase("Northwest", on: .ovalROI),
                    ParityCase("West", on: .gray8NearEdge), ParityCase("Northeast", on: .rgbRect),
                    ParityCase("Southeast", on: .gray32Oval),
                ])
    }

    /// NaN Background needs a threshold, which a macro sets.
    @Test func nanBackground() async throws {
        try await MacroParity.check([
            MacroParityCase("NaN Background", #"""
                setThreshold(0.2, 1.5);
                run("NaN Background");
                getMinAndMax(min, max);
                getThreshold(lower, upper);
                print(min, max, lower, upper);
                """#, on: .gray32),
            MacroParityCase("NaN Background in a selection", #"""
                print(selectionType(), getPixel(0, 0), getPixel(30, 20));
                setThreshold(0, 1.8);
                getThreshold(lower, upper);
                print(lower, upper);
                run("NaN Background");
                print(getPixel(0, 0), getPixel(30, 20));
                """#, on: .gray32Oval),
            MacroParityCase("NaN Background on a stack", #"""
                setThreshold(0.5, 2);
                run("NaN Background", "stack");
                getMinAndMax(min, max);
                print(min, max);
                """#, on: .stack32),
        ])
    }

    /// Noise is reproducible once a macro seeds ImageJ's generator, which
    /// every noise filter then shares.
    @Test func noise() async throws {
        func seeded(_ name: String, _ code: String, on input: ParityInput) -> MacroParityCase {
            MacroParityCase(name, "random(\"seed\", 7);\n" + code + "\ngetMinAndMax(min, max);\nprint(min, max);\n", on: input)
        }
        try await MacroParity.check([
            seeded("Add Noise, 8-bit", #"run("Add Noise");"#, on: .gray8),
            seeded("Add Noise, 16-bit", #"run("Add Noise");"#, on: .gray16),
            seeded("Add Noise, 32-bit", #"run("Add Noise");"#, on: .gray32),
            seeded("Add Noise, RGB", #"run("Add Noise");"#, on: .rgb),
            seeded("Add Specified Noise", #"run("Add Specified Noise...", "standard=60");"#, on: .gray8),
            seeded("Add Specified Noise, stack", #"run("Add Specified Noise...", "standard=10 stack");"#, on: .stack16),
            seeded("Add Noise, one slice", #"run("Add Noise", "slice");"#, on: .stack32),
            seeded("Add Noise in an oval", #"run("Add Noise");"#, on: .ovalROI),
            seeded("Add Noise in a rectangle", #"run("Add Noise");"#, on: .gray16Polygon),
            seeded("Add Noise on a line", #"run("Add Noise");"#, on: .gray8Line),
            // The stream continues from one filter to the next; the deviation is kept.
            seeded("Noise twice", #"""
                run("Add Specified Noise...", "standard=5");
                run("Add Specified Noise...", " ");
                run("Add Noise");
                """#, on: .gray32),
            // The seed is cast to int.
            MacroParityCase("Seed beyond int", #"""
                random("seed", 3000000000);
                run("Add Noise");
                """#, on: .gray8),
        ])
    }
}
