import Testing

/// Image ▸ Scale, Image ▸ Adjust ▸ Size and Image ▸ Transform ▸ Rotate,
/// Translate and Bin against ImageJ 1.54p: every interpolation method on
/// every pixel type, up- and downscaling, stacks, hyperstacks, calibrated
/// images, selections and images one pixel wide or high.
///
/// ImageJ's plugins remember their last settings, so every case names all
/// the options it relies on.
@Suite("ImageJ parity: geometry", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct GeometryParityTests {
    typealias Step = ParityCase.Step
    static let types: [ParityInput] = [.gray8, .gray16, .gray32, .rgb]
    static let methods = ["None", "Bilinear", "Bicubic"]

    /// Float results: ImageJ's arithmetic is reproduced exactly, so only
    /// the last bits of `sin` and `cos` can differ.
    static let tolerance = 1e-9

    static func steps(_ steps: [(String, String)], on input: ParityInput) -> ParityCase {
        ParityCase(steps: steps.map { Step(command: $0.0, options: $0.1) }, inputs: [input], tolerance: tolerance)
    }

    // MARK: Scale

    @Test func scaleToNewWindow() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in Self.methods {
                cases.append(ParityCase("Scale...", "x=0.5 y=0.5 interpolation=\(method) average create", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Scale...", "x=2 y=1.7 interpolation=\(method) create", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Scale...", "x=0.37 y=0.6 interpolation=\(method) create", on: input, tolerance: Self.tolerance))
            }
            cases.append(ParityCase("Scale...", "x=0.3 y=1.5 interpolation=Bicubic average create", on: input, tolerance: Self.tolerance))
        }
        cases += [
            ParityCase("Scale...", "width=30 height=20 interpolation=Bilinear average create", on: .gray16),
            ParityCase("Scale...", "x=- y=- width=100 height=0 interpolation=Bicubic create title=bigger", on: .gray8),
            ParityCase("Scale...", "x=- y=- width=- height=31 interpolation=Bilinear create", on: .gray32, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolate create title=[half size]", on: .gray8),
            ParityCase("Scale...", "x=0.5 y=0.5 create", on: .gray16),
            ParityCase("Scale...", "x=0.25 y=0.25 interpolation=None average create", on: .fixtureFire),
        ]
        try await Parity.check(cases)
    }

    @Test func scaleInPlace() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in Self.methods {
                cases.append(ParityCase("Scale...", "x=0.6 y=0.45 interpolation=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Scale...", "x=1.6 y=1.3 interpolation=\(method)", on: input, tolerance: Self.tolerance))
            }
            cases.append(ParityCase("Scale...", "x=1.5 y=0.8 interpolation=Bilinear fill", on: input, tolerance: Self.tolerance))
        }
        cases += [
            // Black in an inverted LUT is entry 255.
            Self.steps([("Invert LUT", ""), ("Scale...", "x=0.5 y=0.5 interpolation=Bilinear fill")], on: .gray8),
            Self.steps([("Invert LUT", ""), ("Scale...", "x=0.7 y=0.7 interpolation=Bicubic")], on: .gray8),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear process", on: .stack8),
            ParityCase("Scale...", "x=0.7 y=0.6 interpolation=Bicubic process", on: .stack16),
            ParityCase("Scale...", "x=1.4 y=1.4 interpolation=None process", on: .stack32),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear", on: .stack16),
            ParityCase("Scale...", "x=0.8 y=0.8 interpolation=Bilinear fill process", on: .stackRGB),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bicubic", on: .hyperstack),
            ParityCase("Scale...", "x=0.5 y=2 interpolation=Bilinear", on: .column8),
        ]
        try await Parity.check(cases)
    }

    @Test func scaleStacks() async throws {
        try await Parity.check([
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear average process create", on: .stack8),
            ParityCase("Scale...", "x=1.5 y=1.5 interpolation=Bicubic process create", on: .stack16),
            ParityCase("Scale...", "x=0.4 y=0.7 interpolation=None average process create", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bicubic average process create", on: .stackRGB),
            // Without "process", only the current slice goes to the new window.
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear create", on: .stack16),
            // Z scaling: depth or z factor, up and down.
            ParityCase("Scale...", "x=1.0 y=1.0 z=2 interpolation=Bilinear process create", on: .stack8),
            ParityCase("Scale...", "x=0.5 y=0.5 z=0.6 interpolation=Bilinear average process create", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=- y=- z=- width=30 height=23 depth=3 interpolation=Bicubic average process create", on: .stack16),
            ParityCase("Scale...", "x=0.5 y=0.5 z=1.5 interpolation=None process create", on: .stackRGB),
            ParityCase("Scale...", "x=0.5 y=0.5 z=2 interpolation=Bilinear average process create", on: .calibrated),
            ParityCase("Scale...", "x=0.5 y=0.5 z=1.0 interpolation=Bilinear average process create", on: .calibrated),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear average create", on: .hyperstack),
            ParityCase("Scale...", "x=0.5 y=0.5 z=2 interpolation=Bilinear process create", on: .hyperstack),
            ParityCase("Scale...", "x=0.6 y=0.6 interpolation=Bicubic average create", on: .fixtureHyperstack),
        ])
    }

    @Test func scaleSelectionsAndCalibration() async throws {
        try await Parity.check([
            ParityCase("Scale...", "x=2 y=2 interpolation=Bilinear create", on: .rectangleROI),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bicubic average create", on: .ovalROI),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear", on: .ovalROI),
            ParityCase("Scale...", "x=1.5 y=1.5 interpolation=Bilinear", on: .polygonROI, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=0.7 y=0.7 interpolation=None create", on: .edgeROI),
            ParityCase("Scale...", "x=0.5 y=0.5 interpolation=Bilinear average create", on: .freehandROI),
            Self.steps(
                [("Properties...", "channels=1 slices=1 frames=1 unit=µm pixel_width=0.3 pixel_height=0.4 voxel_depth=1 origin=12,7"),
                 ("Scale...", "x=0.5 y=0.25 interpolation=Bilinear average create")],
                on: .gray16),
            Self.steps([("Enhance Contrast...", "saturated=5"), ("Scale...", "x=0.5 y=0.5 interpolation=Bilinear average create")], on: .gray8),
            Self.steps([("Enhance Contrast...", "saturated=5"), ("Scale...", "x=0.5 y=0.5 interpolation=Bicubic average create")], on: .gray16),
            Self.steps([("Fire", ""), ("Scale...", "x=1.5 y=1.5 interpolation=Bicubic create")], on: .gray32),
        ])
    }

    @Test func scaleThinImages() async throws {
        try await Parity.check([
            ParityCase("Scale...", "x=2 y=3 interpolation=Bilinear create", on: .column8),
            ParityCase("Scale...", "x=1 y=0.5 interpolation=Bilinear average create", on: .column8),
            ParityCase("Scale...", "x=3 y=2 interpolation=Bicubic create", on: .row16),
            ParityCase("Scale...", "x=0.5 y=1 interpolation=Bilinear average create", on: .row16),
            ParityCase("Scale...", "x=1.7 y=4 interpolation=None create", on: .row16),
            ParityCase("Scale...", "x=2.5 y=2 interpolation=Bilinear create", on: .row32, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=0.4 y=1 interpolation=Bicubic average create", on: .row32, tolerance: Self.tolerance),
            ParityCase("Scale...", "x=3 y=1.5 interpolation=Bilinear create", on: .columnRGB),
        ])
    }

    // MARK: Size

    @Test func size() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in Self.methods {
                cases.append(ParityCase("Size...", "width=30 height=23 average interpolation=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Size...", "width=97 height=70 interpolation=\(method)", on: input, tolerance: Self.tolerance))
            }
        }
        cases += [
            ParityCase("Size...", "width=40 height=40 interpolation=Bilinear", on: .gray16),
            ParityCase("Size...", "width=100 constrain interpolation=Bicubic", on: .gray32, tolerance: Self.tolerance),
            ParityCase("Size...", "height=20 constrain average interpolation=None", on: .rgb),
            ParityCase("Size...", "width=50 height=40 interpolation=Bilinear", on: .rectangleROI),
            ParityCase("Size...", "width=30 height=20 average interpolation=Bicubic", on: .ovalROI),
            ParityCase("Size...", "width=30 height=23 depth=5 average interpolation=Bilinear", on: .stack8),
            ParityCase("Size...", "width=40 height=30 depth=8 interpolation=Bilinear", on: .stack16),
            ParityCase("Size...", "width=61 height=47 depth=3 average interpolation=Bicubic", on: .stack8),
            ParityCase("Size...", "width=61 height=47 depth=2 average interpolation=None", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Size...", "width=31 height=24 depth=7 interpolation=Bicubic", on: .stackRGB),
            ParityCase("Size...", "width=30 height=23 depth=6 interpolation=Bilinear", on: .calibrated),
            ParityCase("Size...", "width=30 height=20 depth=3 time=2 interpolation=Bilinear", on: .hyperstack),
            ParityCase("Size...", "width=61 height=47 depth=5 time=3 average interpolation=Bilinear", on: .hyperstack),
            ParityCase("Size...", "width=61 height=47 depth=3 interpolation=Bilinear", on: .gray8),
            ParityCase("Size...", "width=1 height=94 interpolation=Bilinear", on: .column8),
            ParityCase("Size...", "width=3 height=20 average interpolation=Bilinear", on: .column8),
            ParityCase("Size...", "width=122 height=3 interpolation=Bicubic", on: .row16),
            ParityCase("Size...", "width=20 height=1 average interpolation=Bicubic", on: .row32, tolerance: Self.tolerance),
            ParityCase("Size...", "width=2 height=60 interpolation=Bilinear", on: .columnRGB),
        ]
        try await Parity.check(cases)
    }

    // MARK: Rotate

    @Test func rotate() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in Self.methods {
                cases.append(ParityCase("Rotate... ", "angle=15 grid=1 interpolation=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Rotate... ", "angle=-37.5 grid=1 interpolation=\(method) fill", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Rotate... ", "angle=30 grid=1 interpolation=\(method) enlarge", on: input, tolerance: Self.tolerance))
            }
            cases.append(ParityCase("Rotate... ", "angle=-20 grid=1 interpolation=Bicubic fill enlarge", on: input, tolerance: Self.tolerance))
        }
        cases += [
            ParityCase("Rotate... ", "angle=90 grid=1 interpolation=Bilinear", on: .gray16),
            ParityCase("Rotate... ", "angle=360 grid=1 interpolation=Bilinear", on: .gray8),
            ParityCase("Rotate... ", "angle=0 grid=1 interpolation=Bicubic", on: .gray32, tolerance: Self.tolerance),
            ParityCase("Rotate... ", "angle=180 grid=1 interpolation=None", on: .gray16),
            ParityCase("Rotate... ", "angle=15 interpolate", on: .gray8),
            ParityCase("Rotate... ", "angle=15", on: .gray16),
            ParityCase("Rotate... ", "angle=10 grid=1 interpolation=Bilinear stack", on: .stack8),
            ParityCase("Rotate... ", "angle=10 grid=1 interpolation=Bilinear", on: .stack16),
            ParityCase("Rotate... ", "angle=25 grid=1 interpolation=Bicubic enlarge stack", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Rotate... ", "angle=-12 grid=1 interpolation=Bilinear fill enlarge stack", on: .stackRGB),
            ParityCase("Rotate... ", "angle=12 grid=1 interpolation=Bicubic", on: .hyperstack),
            ParityCase("Rotate... ", "angle=40 grid=1 interpolation=Bilinear enlarge", on: .hyperstack),
            ParityCase("Rotate... ", "angle=20 grid=1 interpolation=Bilinear", on: .rectangleROI),
            ParityCase("Rotate... ", "angle=20 grid=1 interpolation=Bicubic", on: .ovalROI),
            ParityCase("Rotate... ", "angle=-45 grid=1 interpolation=Bilinear fill", on: .polygonROI, tolerance: Self.tolerance),
            ParityCase("Rotate... ", "angle=33 grid=1 interpolation=None", on: .edgeROI),
            // With a selection there is nothing to enlarge.
            ParityCase("Rotate... ", "angle=33 grid=1 interpolation=None enlarge", on: .ovalROI),
            Self.steps([("Invert LUT", ""), ("Rotate... ", "angle=20 grid=1 interpolation=Bilinear fill")], on: .gray8),
            Self.steps([("Invert LUT", ""), ("Rotate... ", "angle=20 grid=1 interpolation=Bicubic fill enlarge")], on: .gray16),
            Self.steps([("Enhance Contrast...", "saturated=10"), ("Rotate... ", "angle=20 grid=1 interpolation=Bilinear fill enlarge")], on: .gray32),
            ParityCase("Rotate... ", "angle=25 grid=1 interpolation=None", on: .column8),
            ParityCase("Rotate... ", "angle=8 grid=1 interpolation=None enlarge", on: .row16),
        ]
        try await Parity.check(cases)
    }

    // MARK: Translate

    @Test func translate() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in Self.methods {
                cases.append(ParityCase("Translate...", "x=10 y=-5 interpolation=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Translate...", "x=2.5 y=1.25 interpolation=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Translate...", "x=-3.7 y=4.2 interpolation=\(method)", on: input, tolerance: Self.tolerance))
            }
        }
        cases += [
            ParityCase("Translate...", "x=70 y=0 interpolation=None", on: .gray8),
            ParityCase("Translate...", "x=5 y=5 interpolation=None stack", on: .stack8),
            ParityCase("Translate...", "x=1.5 y=-0.5 interpolation=Bilinear stack", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Translate...", "x=-2.25 y=3.5 interpolation=Bicubic stack", on: .stackRGB),
            ParityCase("Translate...", "x=4 y=4 interpolation=Bilinear", on: .stack16),
            ParityCase("Translate...", "x=3 y=2.5 interpolation=Bilinear", on: .hyperstack),
            ParityCase("Translate...", "x=5 y=3 interpolation=None", on: .rectangleROI),
            ParityCase("Translate...", "x=-4.5 y=2 interpolation=Bicubic", on: .ovalROI),
            ParityCase("Translate...", "x=0.5 y=3 interpolation=Bilinear", on: .column8),
            ParityCase("Translate...", "x=7 y=0 interpolation=None", on: .row16),
        ]
        try await Parity.check(cases)
    }

    // MARK: Bin

    @Test func bin() async throws {
        var cases: [ParityCase] = []
        for input in Self.types {
            for method in ["Average", "Median", "Min", "Max", "Sum"] {
                cases.append(ParityCase("Bin...", "x=2 y=2 bin=\(method)", on: input, tolerance: Self.tolerance))
                cases.append(ParityCase("Bin...", "x=3 y=4 bin=\(method)", on: input, tolerance: Self.tolerance))
            }
        }
        cases += [
            ParityCase("Bin...", "x=5 y=1 bin=Average", on: .gray16),
            ParityCase("Bin...", "x=2 y=2 z=2 bin=Average", on: .stack8),
            ParityCase("Bin...", "x=1 y=1 z=5 bin=Max", on: .stack16),
            ParityCase("Bin...", "x=2 y=2 z=2 bin=Median", on: .stack32, tolerance: Self.tolerance),
            ParityCase("Bin...", "x=2 y=2 z=2 bin=Sum", on: .stack8),
            ParityCase("Bin...", "x=2 y=2 z=3 bin=Sum", on: .stack16),
            ParityCase("Bin...", "x=3 y=3 z=2 bin=Sum", on: .stackRGB),
            ParityCase("Bin...", "x=2 y=2 z=2 bin=Min", on: .stackRGB),
            ParityCase("Bin...", "x=2 y=2 bin=Average", on: .stack16),
            ParityCase("Bin...", "x=2 y=2 z=3 bin=Average", on: .calibrated),
            ParityCase("Bin...", "x=2 y=2 z=1 bin=Average", on: .hyperstack),
            ParityCase("Bin...", "x=2 y=3 z=2 bin=Max", on: .hyperstack),
            ParityCase("Bin...", "x=2 y=2 z=1 bin=Sum", on: .hyperstack),
            ParityCase("Bin...", "x=1 y=4 bin=Average", on: .column8),
            ParityCase("Bin...", "x=4 y=1 bin=Median", on: .row16),
            ParityCase("Bin...", "x=2 y=2 bin=Average", on: .rectangleROI),
            Self.steps([("Invert LUT", ""), ("Bin...", "x=2 y=2 bin=Average")], on: .gray8),
            Self.steps([("Invert LUT", ""), ("Bin...", "x=3 y=3 bin=Median")], on: .gray8),
        ]
        try await Parity.check(cases)
    }
}
