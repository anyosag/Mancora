import Testing

/// Analyze ▸ Measure on lines, points and angles, Summarize, Redirect,
/// Measure Stack and Statistics, and Fill, Clear and Draw on lines and
/// points, against ImageJ 1.54p. Macros make the selections.
@Suite("ImageJ parity: measuring every selection", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct SelectionMeasureParityTests {
    static let everything = MeasurementParityTests.everything

    /// `run("Set Measurements...", options)`, then `code`.
    static func measuring(_ name: String, with options: String = everything, _ code: String, on inputs: ParityInput...) -> MacroParityCase {
        var c = MacroParityCase(name, "run(\"Set Measurements...\", \"\(options)\");\n" + code + "\n")
        c.inputs = inputs
        return c
    }

    @Test func straightLines() async throws {
        let line = "makeLine(5, 6, 40, 30);\nrun(\"Measure\");"
        try await MacroParity.check([
            Self.measuring("line, 8-bit", line, on: .gray8),
            Self.measuring("line, 16-bit", line, on: .gray16),
            Self.measuring("line, 32-bit", line, on: .gray32),
            Self.measuring("line, RGB", line, on: .rgb),
            Self.measuring("line, calibrated stack", line, on: .calibrated),
            // (Mancora keeps selections as .roi data, whose coordinates are floats.)
            Self.measuring("subpixel line", "makeLine(5.5, 6.25, 40.75, 30.125);\nrun(\"Measure\");", on: .gray16),
            Self.measuring("line to the edge", "makeLine(-3, 40, 70, 2);\nrun(\"Measure\");", on: .gray8),
            Self.measuring("vertical line", "makeLine(20, 3, 20, 44);\nrun(\"Measure\");", on: .gray32),
            Self.measuring("line, length only", with: "perimeter display redirect=None decimal=3", line, on: .calibrated),
            Self.measuring("line, defaults", with: "area mean min redirect=None decimal=3", line + "\n" + line, on: .gray8),
            Self.measuring("line, limited", with: "area mean min limit redirect=None decimal=3",
                           "setThreshold(60, 200);\n" + line, on: .gray8),
            Self.measuring("line, limited 16-bit", with: "area mean min median limit redirect=None decimal=3",
                           "setThreshold(1500, 3000);\n" + line, on: .gray16),
            Self.measuring("line, inverted y", with: "centroid bounding invert redirect=None decimal=3", line, on: .calibrated),
            // A wide line is measured as its rotated rectangle.
            Self.measuring("wide line", "makeLine(5, 6, 40, 30, 5);\nrun(\"Measure\");", on: .gray16),
            Self.measuring("wide line, limited", with: "area mean min median limit redirect=None decimal=3",
                           "setThreshold(60, 200);\nmakeLine(50, 6, 10, 40, 3);\nrun(\"Measure\");", on: .gray8),
            Self.measuring("wide line, calibrated", "makeLine(5.5, 6, 40, 30.25, 4);\nrun(\"Measure\");", on: .calibrated),
            // A line in a TIFF.
            ParityCase.measure(Self.everything, on: .gray8Line).asMacro("TIFF line"),
            ParityCase.measure(Self.everything, on: .rgbLine).asMacro("TIFF line, RGB"),
        ])
    }

    @Test func polylinesAndFreelines() async throws {
        try await MacroParity.check([
            Self.measuring("polyline", #"""
                makeSelection("polyline", newArray(5, 30, 50, 20), newArray(5, 40, 10, 30));
                run("Measure");
                """#, on: .gray16),
            Self.measuring("polyline, two points", #"""
                makeSelection("polyline", newArray(5, 45), newArray(5, 35));
                run("Measure");
                """#, on: .gray8),
            Self.measuring("freeline", #"""
                makeSelection("freeline", newArray(5, 8, 12, 18, 25, 30), newArray(10, 14, 15, 13, 20, 22));
                run("Measure");
                """#, on: .gray32),
            Self.measuring("polyline, length only", with: "perimeter redirect=None decimal=3", #"""
                makeSelection("polyline", newArray(5, 30, 50, 20), newArray(5, 40, 10, 30));
                run("Measure");
                """#, on: .calibrated),
        ])
    }

    @Test func pointsAndAngles() async throws {
        try await MacroParity.check([
            Self.measuring("point", "makePoint(20, 15);\nrun(\"Measure\");", on: .gray16),
            Self.measuring("subpixel point", "makePoint(20.4, 15.6);\nrun(\"Measure\");", on: .gray8),
            Self.measuring("points", #"""
                makeSelection("point", newArray(3, 20, 40), newArray(4, 30, 12));
                run("Measure");
                """#, on: .gray32),
            Self.measuring("points on a stack", #"""
                setSlice(3);
                makeSelection("point", newArray(3, 20), newArray(4, 30));
                run("Measure");
                """#, on: .calibrated),
            Self.measuring("point, RGB", "makePoint(20, 15);\nrun(\"Measure\");", on: .rgb),
            Self.measuring("angle", #"""
                makeSelection("angle", newArray(10, 30, 50), newArray(40, 10, 35));
                run("Measure");
                """#, on: .gray8),
            Self.measuring("angle, defaults", with: "area mean min redirect=None decimal=3", #"""
                makeSelection("angle", newArray(10, 30, 12), newArray(40, 10, 5));
                run("Measure");
                """#, on: .calibrated),
            ParityCase.measure(Self.everything, on: .gray8Point).asMacro("TIFF point"),
        ])
    }

    @Test func summarizeAndRedirect() async throws {
        try await MacroParity.check([
            Self.measuring("summarize", with: "area mean standard min display redirect=None decimal=3", #"""
                run("Measure");
                makeOval(10, 10, 20, 15);
                run("Measure");
                makeRectangle(30, 5, 20, 30);
                run("Measure");
                run("Summarize");
                run("Summarize");
                """#, on: .gray16),
            // A new measurement takes the summary rows away first.
            Self.measuring("measure after summarize", with: "area mean display redirect=None decimal=3", #"""
                run("Measure");
                makeLine(5, 6, 40, 30);
                run("Measure");
                run("Summarize");
                run("Select None");
                run("Measure");
                """#, on: .gray8),
            Self.measuring("redirect", with: "area mean min centroid display redirect=gray16.tif decimal=3", #"""
                selectImage("gray8.tif");
                makeOval(10, 10, 20, 15);
                run("Measure");
                run("Select None");
                run("Measure");
                run("Set Measurements...", "area mean min redirect=None decimal=3");
                """#, on: .gray16, .gray8),
        ])
    }

    @Test func measureStack() async throws {
        try await MacroParity.check([
            Self.measuring("Measure Stack", with: "area mean min redirect=None decimal=3", #"""
                run("Measure Stack...");
                """#, on: .stack16),
            Self.measuring("Measure Stack, calibrated", with: "area mean min display redirect=None decimal=3", #"""
                makeOval(10, 10, 20, 15);
                run("Measure Stack...");
                """#, on: .calibrated),
            Self.measuring("Measure Stack, hyperstack", with: "area mean redirect=None decimal=3", #"""
                run("Measure Stack...", "channels slices frames order=czt(default)");
                """#, on: .hyperstack),
            Self.measuring("Measure Stack, hyperstack slices", with: "area mean redirect=None decimal=3", #"""
                Stack.setPosition(2, 1, 2);
                run("Measure Stack...", "slices frames order=tzc");
                """#, on: .hyperstack),
        ])
    }

    @Test func stackStatistics() async throws {
        try await MacroParity.check([
            MacroParityCase("Statistics, 8-bit", "run(\"Statistics\");", on: .stack8),
            MacroParityCase("Statistics, 16-bit", "run(\"Statistics\");", on: .stack16),
            MacroParityCase("Statistics, 32-bit", "run(\"Statistics\");", on: .stack32),
            MacroParityCase("Statistics, RGB", "run(\"Statistics\");", on: .stackRGB),
            MacroParityCase("Statistics, calibrated", "makeRectangle(5, 5, 30, 20);\nrun(\"Statistics\");", on: .calibrated),
            MacroParityCase("Statistics in an oval", "makeOval(5, 5, 30, 20);\nrun(\"Statistics\");", on: .stack8),
            MacroParityCase("Statistics, thresholded", "setThreshold(60, 150);\nrun(\"Statistics\");", on: .stack8),
            MacroParityCase("Statistics, thresholded 16-bit", "setThreshold(1000, 2500);\nrun(\"Statistics\");", on: .stack16),
            MacroParityCase("Statistics, thresholded 32-bit", "setThreshold(0, 1.5);\nrun(\"Statistics\");", on: .stack32),
            MacroParityCase("Statistics, one image", "run(\"Statistics\");", on: .gray16),
        ])
    }

    @Test func fillClearAndDraw() async throws {
        try await MacroParity.check([
            MacroParityCase("Fill a line", "makeLine(5, 6, 40, 30);\nrun(\"Fill\", \"slice\");", on: .gray8),
            MacroParityCase("Fill a line, RGB", "setForegroundColor(255, 0, 0);\nmakeLine(-5, 6, 70, 30);\nrun(\"Fill\", \"slice\");", on: .rgb),
            MacroParityCase("Fill a line with a value", "setColor(1000);\nmakeLine(5, 40, 50, 3);\nrun(\"Fill\", \"slice\");", on: .gray16),
            MacroParityCase("Fill a polyline", #"""
                makeSelection("polyline", newArray(5, 30, 50, 20), newArray(5, 40, 10, 30));
                run("Fill", "stack");
                """#, on: .stack16),
            MacroParityCase("Clear a line", "makeLine(5, 6, 40, 30);\nrun(\"Clear\", \"slice\");", on: .gray32),
            MacroParityCase("Clear Outside a point", "makePoint(5, 6);\nrun(\"Clear Outside\", \"slice\");", on: .gray8),
            MacroParityCase("Draw a line", "makeLine(5, 6, 40, 30);\nrun(\"Draw\", \"slice\");", on: .gray8),
            MacroParityCase("Draw points", #"""
                makeSelection("point", newArray(3, 20, 40), newArray(4, 30, 12));
                run("Draw", "slice");
                """#, on: .gray16),
            MacroParityCase("Draw a rectangle", "makeRectangle(5, 6, 30, 20);\nrun(\"Draw\", \"slice\");", on: .rgb),
            MacroParityCase("Draw a polygon", #"""
                makePolygon(5, 5, 40, 8, 52, 30, 20, 41);
                run("Draw", "stack");
                """#, on: .stack8),
            MacroParityCase("Draw an angle", #"""
                makeSelection("angle", newArray(10, 30, 50), newArray(40, 10, 35));
                run("Draw", "slice");
                """#, on: .gray32),
        ])
    }
}

extension ParityCase {
    /// The steps as a macro case, on the same input.
    func asMacro(_ name: String) -> MacroParityCase {
        var c = MacroParityCase(name, macro)
        c.inputs = inputs
        return c
    }
}
