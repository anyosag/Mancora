import MancoraCore
import MancoraIO
import Testing

extension ParityInput {
    /// `"<input>+<selection>"`: the input before the `+`, with the named
    /// selection (ImageJ reads it from the TIFF).
    func withSelection() throws -> Hyperstack {
        let parts = rawValue.split(separator: "+").map(String.init)
        guard parts.count == 2, let base = ParityInput(rawValue: parts[0]) else {
            preconditionFailure("\(rawValue) isn't <input>+<selection>")
        }
        var image = try base.image()
        image.encodedROI = RoiCodec.encode(Self.selection(parts[1]))
        return image
    }

    static func selection(_ name: String) -> Roi {
        switch name {
        case "rect": return roi(for: .rectangleROI)
        case "oval": return roi(for: .ovalROI)
        case "polygon": return roi(for: .polygonROI)
        case "freehand": return roi(for: .freehandROI)
        case "subpixel": return roi(for: .subpixelPolygonROI)
        // Ends one pixel short of the right and bottom edges (61×47), where
        // ImageJ's 3×3 filters also write the last column and row.
        case "nearEdge": return Roi(.rectangle(.integer(x: 30, y: 20, width: 30, height: 26)))
        case "line": return Roi(.line(.init(x1: 5, y1: 6, x2: 40, y2: 30)))
        case "point": return Roi(.points(.init(.integer([Roi.IntPoint(x: 20, y: 15)]))))
        default: preconditionFailure("no selection \(name)")
        }
    }
}

/// Filters, Math and Invert within selections: rectangles (inside the
/// image, partly outside it, and ending next to its edge), ovals and
/// polygons, on every type and on stacks; lines and points count as no
/// selection.
@Suite("ImageJ parity: filters in selections", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct SelectionFilterParityTests {
    @Test func gaussianBlur() async throws {
        try await Parity.check([
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray8Rect),
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray8Oval),
            ParityCase("Gaussian Blur...", "sigma=1.5", on: .gray16Oval),
            ParityCase("Gaussian Blur...", "sigma=2.5", on: .polygonROI),
            ParityCase("Gaussian Blur...", "sigma=12", on: .gray32Oval),
            ParityCase("Gaussian Blur...", "sigma=10", on: .gray8NearEdge),
            ParityCase("Gaussian Blur...", "sigma=1", on: .rgbPolygon),
            ParityCase("Gaussian Blur...", "sigma=1.5 stack", on: .stack16Rect),
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray8Line),
            ParityCase("Gaussian Blur...", "sigma=2", on: .gray8Point),
            ParityCase("Gaussian Blur...", "sigma=2", on: .edgeROI),
            ParityCase("Gaussian Blur...", "sigma=0.5 scaled stack", on: .calibratedOval),
            ParityCase("Gaussian Blur...", "sigma=2", on: .hyperstackOval),
            ParityCase("Gaussian Blur...", "sigma=3", on: .gray32Subpixel),
        ])
    }

    @Test func rankFilters() async throws {
        try await Parity.check([
            ParityCase("Mean...", "radius=2", on: .gray8Oval),
            ParityCase("Mean...", "radius=3", on: .gray32Oval),
            ParityCase("Mean...", "radius=2", on: .gray8Line),
            ParityCase("Mean...", "radius=2", on: .edgeROI),
            ParityCase("Minimum...", "radius=1", on: .gray16NearEdge),
            ParityCase("Maximum...", "radius=3", on: .gray32Rect),
            ParityCase("Variance...", "radius=2", on: .rectangleROI),
            ParityCase("Variance...", "radius=1.5", on: .gray32Oval),
            ParityCase("Median...", "radius=2", on: .rgbOval),
            ParityCase("Median...", "radius=2.5", on: .gray32Subpixel),
            ParityCase("Median...", "radius=1 stack", on: .stack8Oval),
            ParityCase("Remove Outliers...", "radius=2 threshold=20 which=Bright", on: .gray8Polygon),
            ParityCase("Remove Outliers...", "radius=3 threshold=100 which=Dark", on: .gray16Freehand),
            ParityCase("Remove NaNs...", "radius=2", on: .polygonROI),
            ParityCase("Despeckle", on: .rgbRect),
            ParityCase("Despeckle", "stack", on: .stack16Rect),
            ParityCase("Variance...", "radius=1 stack", on: .stack32Polygon),
        ])
    }

    @Test func threeByThreeAndConvolve() async throws {
        try await Parity.check([
            ParityCase("Smooth", on: .gray8Rect),
            ParityCase("Smooth", on: .gray8NearEdge),
            ParityCase("Smooth", on: .gray8Oval),
            ParityCase("Smooth", on: .gray32Oval),
            ParityCase("Smooth", on: .gray16NearEdge),
            ParityCase("Smooth", on: .rgbNearEdge),
            ParityCase("Smooth", on: .edgeROI),
            ParityCase("Smooth", on: .gray8Line),
            ParityCase("Sharpen", on: .gray16Oval),
            ParityCase("Sharpen", on: .gray8NearEdge),
            ParityCase("Sharpen", on: .rgbNearEdge),
            ParityCase("Sharpen", on: .rgbOval),
            ParityCase("Sharpen", on: .gray32NearEdge),
            ParityCase("Find Edges", on: .gray8NearEdge),
            ParityCase("Find Edges", on: .rgbNearEdge),
            ParityCase("Find Edges", on: .rgbPolygon),
            ParityCase("Find Edges", on: .polygonROI),
            ParityCase("Find Edges", "stack", on: .stack16Rect),
            ParityCase("Find Edges", on: .roundedROI),
            ParityCase("Convolve...", "text1=[-1 -1 -1\n-1 8 -1\n-1 -1 -1] normalize", on: .gray8Oval),
            ParityCase("Convolve...", "text1=[1 2 1 2 4 2 1 2 1] normalize", on: .gray32Rect),
            ParityCase("Convolve...", "text1=[0 1 0\n1 1 1\n0 1 0]", on: .roundedROI),
            ParityCase("Convolve...", "text1=[1 1 1\n1 1 1\n1 1 1] normalize stack", on: .stack8Oval),
            ParityCase("Convolve...", "text1=[1 2 1 2 4 2 1 2 1] normalize", on: .gray8Line),
            ParityCase("Convolve...", "text1=[1 2 3 2 1\n] normalize", on: .rgbPolygon),
            ParityCase("Convolve...", "text1=[-1 0 1\n-2 0 2\n-1 0 1]", on: .gray16NearEdge),
        ])
    }

    @Test func binary() async throws {
        // Binary Options are static in ImageJ's helper: put them back to ImageJ's defaults.
        let reset = ParityCase.Step(command: "Options...", options: "iterations=1 count=1 black do=Nothing")
        try await Parity.check(
            ["Erode", "Dilate", "Open", "Close-", "Outline", "Fill Holes", "Skeletonize"].flatMap { command in
                [ParityInput.binaryOvalROI, .binaryPolygon, .binaryNearEdge, .binaryRectangleROI].map { ParityCase(command, on: $0) }
            } + [
                ParityCase("Erode", "stack", on: .binaryStackOval),
                ParityCase("Outline", "stack", on: .binaryStackOval),
                ParityCase("Outline", on: .binaryStackOval),
                ParityCase("Fill Holes", "stack", on: .binaryStackOval),
                ParityCase(
                    steps: [.init(command: "Options...", options: "iterations=2 count=3 black do=Nothing"),
                            .init(command: "Dilate", options: ""), reset],
                    inputs: [.binaryPolygon]),
                ParityCase(
                    steps: [.init(command: "Options...", options: "iterations=3 count=2 pad do=Erode"), reset],
                    inputs: [.binaryNearEdge]),
                ParityCase(
                    steps: [.init(command: "Options...", options: "iterations=1 count=1 do=Outline"), reset],
                    inputs: [.binaryOvalROI]),
                ParityCase(
                    steps: [.init(command: "Options...", options: "iterations=1 count=1 do=Outline"), reset],
                    inputs: [.binaryNearEdge]),
            ])
    }

    @Test func math() async throws {
        try await Parity.check([
            ParityCase("Add...", "value=25", on: .gray8Oval),
            ParityCase("Add...", "value=1000 stack", on: .stack16Rect),
            ParityCase("Add...", "value=7", on: .stack8Oval),
            ParityCase("Add...", "value=25", on: .gray8Line),
            ParityCase("Subtract...", "value=10", on: .rgbPolygon),
            ParityCase("Multiply...", "value=1.5", on: .roundedROI),
            ParityCase("Divide...", "value=3", on: .gray32Oval),
            ParityCase("Min...", "value=1500", on: .gray16Oval),
            ParityCase("Max...", "value=2000", on: .gray16Polygon),
            ParityCase("Max...", "value=1", on: .gray32Rect),
            ParityCase("Gamma...", "value=1.5", on: .gray8Polygon),
            ParityCase("Set...", "value=7", on: .gray32Oval),
            ParityCase("Log", on: .gray16Oval),
            ParityCase("Square Root", on: .gray32Oval),
            ParityCase("Reciprocal", on: .polygonROI),
            ParityCase("Abs", on: .gray32Subpixel),
            ParityCase("AND...", "value=11110000", on: .gray8Rect),
            ParityCase("Invert", on: .gray8Oval),
            ParityCase("Invert", on: .gray16Oval),
            ParityCase("Invert", on: .gray32Rect),
            ParityCase("Invert", on: .rgbOval),
            ParityCase("Invert", on: .edgeROI),
            ParityCase("Invert", "stack", on: .stack16Rect),
            ParityCase("Invert", on: .rgbLine),
            ParityCase("Invert", "stack", on: .calibratedOval),
            ParityCase("Invert", on: .hyperstackOval),
        ])
    }
}
