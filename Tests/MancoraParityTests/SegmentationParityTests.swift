import Testing

/// Process ▸ Subtract Background, against ImageJ 1.54p.
@Suite("ImageJ parity: background", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct BackgroundParityTests {
    static func subtract(_ options: String, on input: ParityInput) -> ParityCase {
        ParityCase("Subtract Background...", options, on: input, tolerance: 1e-9)
    }

    @Test func rollingBall() async throws {
        try await Parity.check([
            Self.subtract("rolling=50", on: .blobs8),
            Self.subtract("rolling=10", on: .blobs8),
            Self.subtract("rolling=4", on: .blobs8),
            Self.subtract("rolling=0.5", on: .blobs8),
            Self.subtract("rolling=25 light", on: .blobsLight),
            Self.subtract("rolling=50 white", on: .blobsLight),
            Self.subtract("rolling=25", on: .blobsInverted),
            Self.subtract("rolling=25 light", on: .blobsInverted),
            Self.subtract("rolling=20", on: .blobs16),
            Self.subtract("rolling=120", on: .blobs16),
            Self.subtract("rolling=35 light", on: .blobs16),
            Self.subtract("rolling=15", on: .blobs32),
            Self.subtract("rolling=40 disable", on: .blobs32),
            Self.subtract("rolling=8 light", on: .blobs32),
            Self.subtract("rolling=6", on: .gray8),
            Self.subtract("rolling=12", on: .gray32),
        ])
    }

    @Test func slidingParaboloid() async throws {
        try await Parity.check([
            Self.subtract("rolling=50 sliding", on: .blobs8),
            Self.subtract("rolling=10 sliding", on: .blobs8),
            Self.subtract("rolling=15 sliding disable", on: .blobs16),
            Self.subtract("rolling=30 light sliding", on: .blobsLight),
            Self.subtract("rolling=30 sliding", on: .blobsInverted),
            Self.subtract("rolling=200 sliding", on: .blobs16),
            Self.subtract("rolling=5 sliding", on: .blobs32),
            Self.subtract("rolling=20 light sliding disable", on: .blobs32),
            Self.subtract("rolling=9 sliding", on: .gray16),
        ])
    }

    @Test func createBackground() async throws {
        try await Parity.check([
            Self.subtract("rolling=50 create", on: .blobs8),
            Self.subtract("rolling=20 light create", on: .blobsLight),
            Self.subtract("rolling=30 create sliding", on: .blobs32),
            Self.subtract("rolling=15 create", on: .blobs16),
            Self.subtract("rolling=10 create sliding disable", on: .blobs16),
            Self.subtract("rolling=40 create", on: .blobs32),
        ])
    }

    @Test func colors() async throws {
        try await Parity.check([
            Self.subtract("rolling=50", on: .blobsRGB),
            Self.subtract("rolling=20 separate", on: .blobsRGB),
            Self.subtract("rolling=20 light separate sliding", on: .blobsRGB),
            Self.subtract("rolling=30 create", on: .blobsRGB),
            Self.subtract("rolling=12 create separate", on: .blobsRGB),
            Self.subtract("rolling=10 sliding disable", on: .blobsRGB),
            Self.subtract("rolling=8", on: .rgb),
        ])
    }

    @Test func stacks() async throws {
        try await Parity.check([
            Self.subtract("rolling=25 stack", on: .blobsStack8),
            Self.subtract("rolling=25", on: .blobsStack8),
            Self.subtract("rolling=30 sliding stack", on: .blobsStack16),
            Self.subtract("rolling=12 light stack", on: .blobsStack32),
            Self.subtract("rolling=12 create stack", on: .blobsStack32),
            Self.subtract("rolling=10 stack", on: .stack16),
            Self.subtract("rolling=20 sliding", on: .stack32),
            Self.subtract("rolling=20 stack", on: .calibrated),
            // A composite is processed whole (unless "slice") and keeps its channels' ranges.
            Self.subtract("rolling=10", on: .hyperstack),
            Self.subtract("rolling=10 slice", on: .hyperstack),
            Self.subtract("rolling=20 sliding", on: .fixtureHyperstack),
        ])
    }

    @Test func otherImages() async throws {
        try await Parity.check([
            Self.subtract("rolling=20", on: .fixtureFire),
            Self.subtract("rolling=20 sliding", on: .edgeROI),
            Self.subtract("rolling=30", on: .blobsROI),
            Self.subtract("rolling=15 light sliding", on: .blobsOvalROI),
        ])
    }
}

/// Process ▸ Find Maxima, against ImageJ 1.54p.
@Suite("ImageJ parity: maxima", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct MaximaParityTests {
    typealias Step = ParityCase.Step

    static func maxima(_ options: String, on input: ParityInput) -> ParityCase {
        ParityCase("Find Maxima...", options, on: input, tolerance: 1e-9, results: true, selection: true)
    }

    @Test func imageOutputs() async throws {
        try await Parity.check([
            Self.maxima("prominence=10 output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=40 output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=20 strict output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=10 exclude output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=10 strict exclude output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=0 output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=10 light output=[Single Points]", on: .blobsLight),
            Self.maxima("prominence=30 output=[Maxima Within Tolerance]", on: .blobs8),
            Self.maxima("prominence=5 output=[Maxima Within Tolerance]", on: .blobs8),
            Self.maxima("prominence=20 output=[Segmented Particles]", on: .blobs8),
            Self.maxima("prominence=8 output=[Segmented Particles]", on: .blobs8),
            Self.maxima("prominence=20 exclude output=[Segmented Particles]", on: .blobs8),
            Self.maxima("prominence=25 light output=[Segmented Particles]", on: .blobsLight),
            Self.maxima("noise=10 exclude output=[Single Points]", on: .blobs8),
            Self.maxima("prominence=10 output=[Single Points]", on: .gray8),
        ])
    }

    @Test func otherTypes() async throws {
        try await Parity.check([
            Self.maxima("prominence=500 output=[Single Points]", on: .blobs16),
            Self.maxima("prominence=1000 strict exclude output=[Single Points]", on: .blobs16),
            Self.maxima("prominence=800 output=[Segmented Particles]", on: .blobs16),
            Self.maxima("prominence=600 light output=[Maxima Within Tolerance]", on: .blobs16),
            Self.maxima("prominence=0.3 output=[Single Points]", on: .blobs32),
            Self.maxima("prominence=0.1 exclude output=[Maxima Within Tolerance]", on: .blobs32),
            Self.maxima("prominence=0.5 light output=[Segmented Particles]", on: .blobs32),
            Self.maxima("prominence=0.4 output=[Segmented Particles]", on: .blobs32),
            Self.maxima("prominence=15 output=[Single Points]", on: .blobsRGB),
            Self.maxima("prominence=20 light output=[Segmented Particles]", on: .blobsRGB),
            Self.maxima("prominence=10 output=[Single Points]", on: .blobsInverted),
            Self.maxima("prominence=10 light output=[Segmented Particles]", on: .blobsInverted),
            Self.maxima("prominence=10 output=[Single Points]", on: .blobsStack8),
            Self.maxima("prominence=300 output=[Maxima Within Tolerance]", on: .blobsStack16),
            Self.maxima("prominence=0.2 output=[Single Points]", on: .stack32),
            Self.maxima("prominence=100 output=[Segmented Particles]", on: .calibrated),
            Self.maxima("prominence=100 output=[Single Points]", on: .hyperstack),
            Self.maxima("prominence=100 output=Count", on: .fixtureHyperstack),
            Self.maxima("prominence=20 output=[Segmented Particles]", on: .fixtureFire),
        ])
    }

    /// Area selections limit the search (by their mask) and the points
    /// reported (by `Roi.contains`); segmentation removes them.
    @Test func selections() async throws {
        try await Parity.check([
            Self.maxima("prominence=10 output=[Point Selection]", on: .blobsROI),
            Self.maxima("prominence=10 output=Count", on: .blobsROI),
            Self.maxima("prominence=10 exclude output=List", on: .blobsROI),
            Self.maxima("prominence=10 output=[Single Points]", on: .blobsROI),
            Self.maxima("prominence=10 output=[Segmented Particles]", on: .blobsROI),
            Self.maxima("prominence=400 output=[Single Points]", on: .blobsOvalROI),
            Self.maxima("prominence=400 output=[Maxima Within Tolerance]", on: .blobsOvalROI),
            Self.maxima("prominence=500 output=List", on: .blobsOvalROI),
            Self.maxima("prominence=20 output=[Point Selection]", on: .roundedROI),
            Self.maxima("prominence=20 output=[Point Selection]", on: .ovalROI),
            Self.maxima("prominence=0.1 output=[Point Selection]", on: .polygonROI),
            Self.maxima("prominence=0.1 output=[Single Points]", on: .polygonROI),
            Self.maxima("prominence=100 output=Count", on: .freehandROI),
            Self.maxima("prominence=100 light output=List", on: .tracedROI),
            Self.maxima("prominence=100 output=[Maxima Within Tolerance]", on: .subpixelPolygonROI),
        ])
    }

    @Test func pointsListsAndCounts() async throws {
        let labels = Step(command: "Set Measurements...", options: "area mean min display redirect=None decimal=3")
        let clear = Step(command: "Clear Results", options: "")
        try await Parity.check([
            Self.maxima("prominence=10 output=Count", on: .blobs8),
            Self.maxima("prominence=10 output=List", on: .blobs8),
            Self.maxima("prominence=5 output=[Point Selection]", on: .blobs8),
            Self.maxima("prominence=60 output=[Point Selection]", on: .blobs8),
            Self.maxima("prominence=200 output=[Point Selection]", on: .blobs8),
            Self.maxima("prominence=10 exclude output=List", on: .blobs8),
            Self.maxima("prominence=10 strict light output=Count", on: .blobsLight),
            Self.maxima("prominence=500 output=Count", on: .blobs16),
            Self.maxima("prominence=0.2 output=List", on: .blobs32),
            Self.maxima("prominence=0.2 light output=[Point Selection]", on: .blobs32),
            Self.maxima("prominence=20 light output=Count", on: .blobsRGB),
            Self.maxima("prominence=12 output=List", on: .blobsInverted),
            ParityCase(
                steps: [Step(command: "Find Maxima...", options: "prominence=10 output=Count"),
                        Step(command: "Find Maxima...", options: "prominence=30 exclude output=Count")],
                inputs: [.blobs8], tolerance: 1e-9, results: true),
            // (Set Measurements alone leaves ImageJ's table with empty columns
            // that Count would slot in between; Clear Results drops them.)
            ParityCase(
                steps: [labels, clear, Step(command: "Find Maxima...", options: "prominence=10 output=Count")],
                inputs: [.blobsStack16], tolerance: 1e-9, results: true),
            ParityCase(
                steps: [labels, clear, Step(command: "Find Maxima...", options: "prominence=0.2 output=Count")],
                inputs: [.blobsStack32], tolerance: 1e-9, results: true),
            ParityCase(
                steps: [labels, Step(command: "Measure", options: ""),
                        Step(command: "Find Maxima...", options: "prominence=0.2 light output=Count")],
                inputs: [.blobsStack32], tolerance: 1e-9, results: true),
            ParityCase(
                steps: [labels, Step(command: "Measure", options: ""),
                        Step(command: "Find Maxima...", options: "prominence=10 output=Count")],
                inputs: [.namedROI], tolerance: 1e-9, results: true),
        ])
    }
}

/// Process ▸ Binary ▸ Distance Map, Ultimate Points, Watershed and Voronoi,
/// with each EDM output of Process ▸ Binary ▸ Options, against ImageJ 1.54p.
@Suite("ImageJ parity: EDM", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct EDMParityTests {
    typealias Step = ParityCase.Step
    static let commands = ["Distance Map", "Ultimate Points", "Watershed", "Voronoi"]
    /// The EDM output and Black background are static in ImageJ's helper: put them back.
    static let reset = Step(command: "Options...", options: "iterations=1 count=1 black edm=Overwrite do=Nothing")

    static func withOutput(_ output: String, _ steps: [Step], on input: ParityInput, black: Bool = true) -> ParityCase {
        let options = "iterations=1 count=1" + (black ? " black" : "") + " edm=\(output) do=Nothing"
        return ParityCase(
            steps: [Step(command: "Options...", options: options)] + steps + [reset], inputs: [input], tolerance: 1e-9)
    }

    @Test func overwrite() async throws {
        try await Parity.check(
            [ParityInput.blobsMask, .binary, .blobsMaskInverted].flatMap { input in
                Self.commands.map { ParityCase($0, on: input, tolerance: 1e-9) }
            } + [
                ParityCase("Watershed", "stack", on: .blobsMaskStack),
                ParityCase("Distance Map", "stack", on: .blobsMaskStack),
                ParityCase("Ultimate Points", "stack", on: .binaryStack),
                ParityCase("Voronoi", on: .blobsMaskStack),
                // EDMs ignore selections.
                ParityCase("Watershed", on: .binaryOvalROI),
                ParityCase("Distance Map", on: .binaryRectangleROI),
            ])
    }

    @Test(arguments: ["8-bit", "16-bit", "32-bit"])
    func newImages(output: String) async throws {
        try await Parity.check(
            Self.commands.filter { $0 != "Watershed" }.flatMap { command in
                [ParityInput.blobsMask, .blobsMaskInverted].map { Self.withOutput(output, [Step(command: command, options: "")], on: $0) }
            } + [
                Self.withOutput(output, [Step(command: "Distance Map", options: "stack")], on: .blobsMaskStack),
                Self.withOutput(output, [Step(command: "Voronoi", options: "stack")], on: .binaryStack),
                Self.withOutput(output, [Step(command: "Ultimate Points", options: "")], on: .blobsMaskStack),
                Self.withOutput(output, [Step(command: "Ultimate Points", options: "stack")], on: .binaryStack),
                Self.withOutput(output, [Step(command: "Watershed", options: "")], on: .blobsMask),
            ])
    }

    @Test func whiteBackground() async throws {
        try await Parity.check(
            Self.commands.flatMap { command in
                [ParityInput.blobsMask, .blobsMaskInverted].map {
                    Self.withOutput("Overwrite", [Step(command: command, options: "")], on: $0, black: false)
                }
            } + [
                Self.withOutput("32-bit", [Step(command: "Distance Map", options: "")], on: .blobsMask, black: false),
                Self.withOutput("16-bit", [Step(command: "Voronoi", options: "")], on: .blobsMaskInverted, black: false),
            ])
    }

    @Test func maximaOfDistanceMaps() async throws {
        let maxima = { (options: String) in Step(command: "Find Maxima...", options: options) }
        try await Parity.check([
            Self.withOutput("32-bit", [Step(command: "Distance Map", options: ""), maxima("prominence=0.5 output=[Segmented Particles]")], on: .blobsMask),
            Self.withOutput("32-bit", [Step(command: "Distance Map", options: ""), maxima("prominence=1 output=[Single Points]")], on: .blobsMask),
            Self.withOutput("32-bit", [Step(command: "Voronoi", options: ""), maxima("prominence=2 output=[Single Points]")], on: .binary),
        ])
    }
}

/// Find Maxima from macros: above a threshold set by `setThreshold`, after
/// Convert to Mask's invisible threshold, and the point selection read back.
@Suite("ImageJ parity: maxima in macros", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct MaximaMacroParityTests {
    static let points = """
        run("Find Maxima...", "prominence=10 output=[Point Selection]");
        getSelectionCoordinates(x, y);
        print(selectionType() + " " + x.length);
        for (i = 0; i < x.length; i++) print(x[i] + "," + y[i]);
        """

    @Test func macros() async throws {
        try await MacroParity.check([
            MacroParityCase(
                "above a threshold, 8-bit",
                "setThreshold(60, 255);\nrun(\"Find Maxima...\", \"prominence=10 above output=Count\");", on: .blobs8),
            MacroParityCase(
                "above a threshold, 16-bit",
                "setThreshold(3000, 65535);\nrun(\"Find Maxima...\", \"prominence=300 above output=[Single Points]\");",
                on: .blobs16),
            MacroParityCase(
                "above a threshold, segmented 32-bit",
                "setThreshold(0.5, 10);\nrun(\"Find Maxima...\", \"prominence=0.2 above output=[Segmented Particles]\");",
                on: .blobs32),
            MacroParityCase(
                "above a threshold, within tolerance",
                "setThreshold(90, 255);\nrun(\"Find Maxima...\", \"prominence=5 above strict output=[Maxima Within Tolerance]\");",
                on: .blobs8),
            MacroParityCase(
                "after Convert to Mask",
                "run(\"Convert to Mask\");\nrun(\"Find Maxima...\", \"prominence=10 above output=Count\");", on: .blobs8),
            MacroParityCase("point selection", Self.points, on: .blobs8),
            MacroParityCase("point selection, inverted LUT", Self.points, on: .blobsInverted),
            MacroParityCase(
                "list and count",
                "run(\"Find Maxima...\", \"prominence=15 output=List\");\nprint(nResults);\nrun(\"Find Maxima...\", \"prominence=15 output=Count\");\nprint(getResult(\"Count\", nResults - 1));",
                on: .blobs16),
        ])
    }
}
