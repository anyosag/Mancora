import Testing

/// Image ▸ Type's color-space stacks and RGB Color from them, and Image ▸
/// Hyperstacks and Image ▸ Color's conversions, against ImageJ 1.54p.
@Suite("ImageJ parity: color spaces", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct ColorSpaceParityTests {
    typealias M = StackMacros

    /// Lab goes through `pow`, which Java and the C library may round
    /// differently in the last bit.
    static let lab = 1e-6

    @Test func singleImages() async throws {
        try await MacroParity.check([
            M.make("RGB Stack", #"run("RGB Stack"); state(); titles();"#, on: .rgb),
            M.make("HSB Stack", #"run("HSB Stack"); state();"#, on: .rgb),
            M.make("HSB (32-bit)", #"run("HSB (32-bit)"); state();"#, on: .rgb),
            M.make("Lab Stack", #"run("Lab Stack"); state(); titles();"#, on: .rgb, tolerance: Self.lab),
            M.make("a thin RGB image to HSB", #"run("HSB Stack"); state();"#, on: .columnRGB),
        ])
    }

    /// RGB Color recombines the three planes of a color-space stack.
    @Test func backToRGB() async throws {
        try await MacroParity.check([
            M.make("RGB Stack and back", #"run("RGB Stack"); run("RGB Color"); state();"#, on: .rgb),
            M.make("HSB Stack and back", #"run("HSB Stack"); run("RGB Color"); state();"#, on: .rgb),
            M.make("HSB (32-bit) and back", #"run("HSB (32-bit)"); run("RGB Color"); state();"#, on: .rgb),
            M.make(
                "Lab Stack and back", #"run("Lab Stack"); setSlice(1); run("Add...", "value=5 slice"); run("RGB Color"); state();"#,
                on: .rgb, tolerance: Self.lab),
            M.make(
                "changed hue",
                #"run("HSB Stack"); setSlice(1); run("Add...", "value=40 slice"); run("RGB Color"); state();"#, on: .rgb),
            M.make(
                "planes labeled as colors",
                #"""
                run("Delete Slice"); run("Delete Slice");
                setSlice(1); setMetadata("Label", "Red"); setSlice(2); setMetadata("Label", "x"); setSlice(3); setMetadata("Label", "y");
                run("RGB Color"); state();
                """#, on: .stack8),
            M.make(
                "inverted planes labeled as colors",
                #"""
                setSlice(1); setMetadata("Label", "Red"); run("Invert LUT");
                run("RGB Color"); state();
                """#, on: .binaryStack),
        ])
    }

    @Test func rgbStacks() async throws {
        try await MacroParity.check([
            M.make("RGB Stack", #"setSlice(2); run("RGB Stack"); state(); titles();"#, on: .stackRGB),
            M.make("HSB Stack", #"run("HSB Stack"); state(); titles();"#, on: .stackRGB),
            M.make("HSB (32-bit)", #"run("HSB (32-bit)"); state();"#, on: .stackRGB),
            M.make("labeled", #"setSlice(3); setMetadata("Label", "three"); run("HSB Stack"); state();"#, on: .stackRGB),
            M.make("HSB Stack and back", #"run("HSB Stack"); run("RGB Color", "slices"); state();"#, on: .stackRGB),
        ])
    }

    @Test func compositesToRGB() async throws {
        try await MacroParity.check([
            M.make(
                "RGB Color of channels", #"run("Reduce Dimensionality...", "channels"); run("RGB Color"); state(); titles();"#,
                on: .hyperstack),
            M.make(
                "RGB Color of channels in color",
                #"run("Reduce Dimensionality...", "channels"); Stack.setDisplayMode("color"); Stack.setChannel(2); run("RGB Color"); state(); titles();"#,
                on: .hyperstack),
            M.make("RGB Color of a hyperstack", #"Stack.setPosition(1, 2, 2); run("RGB Color", " "); state(); titles();"#, on: .hyperstack),
            M.make("RGB Color of every slice and frame", #"run("RGB Color", "slices frames"); state(); titles();"#, on: .hyperstack),
            M.make(
                "RGB Color, keep",
                #"Stack.setDisplayMode("grayscale"); run("RGB Color", "frames keep"); state(); titles();"#, on: .fixtureHyperstack),
        ])
    }
}

@Suite("ImageJ parity: hyperstacks", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct HyperstackParityTests {
    typealias M = StackMacros

    @Test func stackToHyperstack() async throws {
        let six = #"run("Add Slice"); "#
        try await MacroParity.check([
            M.make(
                "time series",
                #"run("Stack to Hyperstack...", "order=xyczt(default) channels=1 slices=1 frames=5 display=Color"); state();"#,
                on: .stack16),
            M.make(
                "channels and slices",
                six + #"run("Stack to Hyperstack...", "order=xyczt(default) channels=2 slices=3 frames=1 display=Composite"); state(); titles();"#,
                on: .stack8),
            M.make(
                "slices then channels",
                six + #"run("Stack to Hyperstack...", "order=xyzct channels=3 slices=2 frames=1 display=Grayscale"); state();"#,
                on: .stack16),
            M.make(
                "every order",
                six + #"""
                setSlice(1); setMetadata("Label", "one"); setSlice(4); setMetadata("Label", "four");
                setSlice(1); run("Stack to Hyperstack...", "order=xytzc channels=1 slices=3 frames=2 display=Color"); state();
                """#, on: .stack32),
            M.make(
                "frames first",
                six + #"run("Stack to Hyperstack...", "order=xytcz channels=2 slices=1 frames=3 display=Color"); state();"#,
                on: .stack8),
            M.make(
                "RGB",
                #"run("Stack to Hyperstack...", "order=xyczt(default) channels=1 slices=2 frames=2 display=Color"); state();"#,
                on: .stackRGB),
            M.make(
                "RGB to channels",
                #"run("Stack to Hyperstack...", "order=xyczt(default) channels=1 slices=4 frames=1 display=Color convert"); state();"#,
                on: .stackRGB),
        ])
    }

    @Test func hyperstackToStack() async throws {
        try await Parity.check([
            ParityCase(
                steps: [.init(command: "Reduce Dimensionality...", options: "channels"), .init(command: "Hyperstack to Stack", options: "")],
                inputs: [.hyperstack]),
            ParityCase("Hyperstack to Stack", on: .stack16),
        ])
    }

    @Test func makeSubset() async throws {
        try await MacroParity.check([
            M.make("hyperstack", #"run("Make Subset...", "channels=1-2 slices=2 frames=1-2"); state(); titles();"#, on: .hyperstack),
            M.make("stack", #"run("Make Subset...", "slices=2-4"); state(); titles();"#, on: .stack16),
        ])
    }

    @Test func makeComposite() async throws {
        try await MacroParity.check([
            M.make("RGB", #"run("Make Composite"); state(); titles();"#, on: .rgb),
            M.make("RGB stack", #"setSlice(3); run("Make Composite"); state(); titles();"#, on: .stackRGB),
            M.make("three slices", #"run("Delete Slice"); run("Delete Slice"); run("Make Composite", "display=Composite"); state();"#, on: .stack16),
            M.make("three 8-bit slices in color", #"run("Delete Slice"); run("Delete Slice"); run("Make Composite", "display=Color"); state();"#, on: .stack8),
            M.make("three binary slices in grayscale", #"run("Make Composite", "display=Grayscale"); state();"#, on: .binaryStack),
            M.make("a composite", #"Stack.setDisplayMode("color"); run("Make Composite"); state();"#, on: .hyperstack),
        ])
    }

    /// The Channels tool's Invert LUTs, which runs the `InvertAllLuts` macro.
    @Test func invertLUTs() async throws {
        try await MacroParity.check([
            M.make("gray", #"run("Invert LUTs"); state(); print(Property.get("CompositeProjection"));"#, on: .gray8),
            M.make("fire", #"run("Invert LUTs"); state();"#, on: .fixtureFire),
            M.make("a 16-bit stack", #"setSlice(3); run("Invert LUTs"); state();"#, on: .stack16),
            M.make("a composite", #"Stack.setChannel(2); run("Invert LUTs"); state(); print(Property.get("CompositeProjection"));"#, on: .hyperstack),
            // (ImageJ counts an image whose pixels didn't change as unchanged, so they change too.)
            M.make(
                "twice",
                #"run("Invert LUTs"); run("Invert LUTs"); run("Add...", "value=1 stack"); state(); print(Property.get("CompositeProjection"));"#,
                on: .hyperstack),
            M.make("in color", #"Stack.setDisplayMode("color"); run("Invert LUTs"); state();"#, on: .fixtureHyperstack),
        ])
    }

    @Test func stackToRGB() async throws {
        try await MacroParity.check([
            M.make("three 8-bit slices", #"run("Delete Slice"); run("Delete Slice"); run("Stack to RGB"); state(); titles();"#, on: .stack8),
            M.make("two 16-bit slices", #"run("Reduce...", "reduction=3"); run("Stack to RGB"); state(); titles();"#, on: .stack16),
            M.make("inverted", #"run("Delete Slice"); run("Delete Slice"); run("Invert LUT"); run("Stack to RGB"); state();"#, on: .stack8),
            M.make("channels", #"run("Reduce Dimensionality...", "channels"); run("Stack to RGB"); state(); titles();"#, on: .hyperstack),
            M.make(
                "channels in grayscale",
                #"run("Reduce Dimensionality...", "channels"); Stack.setDisplayMode("grayscale"); Stack.setChannel(2); run("Stack to RGB"); state(); titles();"#,
                on: .hyperstack),
            M.make("a hyperstack", #"Stack.setPosition(1, 3, 1); run("Stack to RGB", "slices"); state(); titles();"#, on: .hyperstack),
            M.make(
                "a hyperstack in color, kept",
                #"Stack.setDisplayMode("color"); Stack.setPosition(2, 1, 2); run("Stack to RGB", "slices frames keep"); state(); titles();"#,
                on: .hyperstack),
            M.make("the fixture", #"run("Stack to RGB", "frames"); state(); titles();"#, on: .fixtureHyperstack),
        ])
    }
}
