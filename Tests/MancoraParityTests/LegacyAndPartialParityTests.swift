import Testing

/// Image Calculator on one slice, Make Substack's delete, Convert to Mask
/// on RGB, per-axis units in Properties, the old command names `IJ.run`
/// still accepts, against ImageJ 1.54p.
@Suite("ImageJ parity: partial commands and old names", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct LegacyAndPartialParityTests {
    @Test func imageCalculatorOnOneSlice() async throws {
        try await Parity.check([
            ParityCase("Image Calculator...", "image1=stack16.tif operation=Add image2=gray16.tif", on: .gray16, .stack16),
            ParityCase("Image Calculator...", "image1=stack16.tif operation=Subtract image2=gray16.tif create", on: .gray16, .stack16),
            ParityCase("Image Calculator...", "image1=stack8.tif operation=Multiply image2=gray8.tif create 32-bit", on: .gray8, .stack8),
            ParityCase("Image Calculator...", "image1=stack32.tif operation=Divide image2=gray32.tif", on: .gray32, .stack32),
            ParityCase("Image Calculator...", "image1=stack8.tif operation=AND image2=binary.tif", on: .binary, .stack8),
        ])
        try await MacroParity.check([
            MacroParityCase("calculator on slice 3", #"""
                selectImage("stack16.tif");
                setSlice(3);
                run("Image Calculator...", "image1=stack16.tif operation=Difference image2=gray16.tif");
                getMinAndMax(min, max);
                print(min, max);
                """#, on: .gray16, .stack16),
            MacroParityCase("calculator with a stack's current slice as image 2", #"""
                selectImage("stack16.tif");
                setSlice(2);
                run("Image Calculator...", "image1=gray16.tif operation=Max image2=stack16.tif create");
                """#, on: .gray16, .stack16),
        ])
    }

    @Test func makeSubstackDeleting() async throws {
        try await MacroParity.check([
            MacroParityCase("delete a range", #"run("Make Substack...", "slices=2-4 delete");"#, on: .stack16),
            MacroParityCase("delete a list", #"run("Make Substack...", "slices=1,3,5 delete");"#, on: .stack8),
            MacroParityCase("delete out of order", #"run("Make Substack...", "slices=5,2 delete");"#, on: .stack32),
            MacroParityCase("delete with an increment", #"run("Make Substack...", "slices=1-5-2 delete");"#, on: .stack16),
            MacroParityCase("delete without a substack", #"run("Make Substack...", "slices=2-3 delete do_not");"#, on: .stack8),
            MacroParityCase("delete from a time series", #"""
                run("Properties...", "channels=1 slices=1 frames=5");
                run("Make Substack...", "slices=2-3 delete");
                """#, on: .stack16),
        ])
    }

    @Test func convertToMaskOnRGB() async throws {
        try await Parity.check([
            ParityCase("Convert to Mask", on: .rgb),
            ParityCase("Make Binary", on: .rgb),
            ParityCase("Convert to Mask", on: .rgbOval),
        ])
    }

    @Test func perAxisUnits() async throws {
        try await MacroParity.check([
            MacroParityCase("Properties keeps the y and z units", #"""
                Stack.setYUnit("nm");
                Stack.setZUnit("mm");
                run("Properties...", "channels=1 slices=3 frames=1 pixel_width=0.5 pixel_height=0.25 voxel_depth=2");
                Stack.getUnits(x, y, z, t, v);
                print(x, y, z, t, v);
                """#, on: .calibrated),
            MacroParityCase("a new unit replaces them", #"""
                Stack.setYUnit("nm");
                run("Properties...", "channels=1 slices=3 frames=1 unit=mm pixel_width=0.5 pixel_height=0.25 voxel_depth=2");
                Stack.getUnits(x, y, z, t, v);
                print(x, y, z, t, v);
                """#, on: .calibrated),
        ])
    }

    /// `IJ.run` maps commands' old names (`IJ.convert`).
    @Test func oldCommandNames() async throws {
        try await MacroParity.check([
            MacroParityCase("RGB Split", #"run("RGB Split");"#, on: .rgb),
            MacroParityCase("Enhance Contrast", #"run("Enhance Contrast", "saturated=0.35");"#, on: .gray16),
            MacroParityCase("Statistics...", #"run("Statistics...");"#, on: .stack8),
            MacroParityCase("Threshold", #"setThreshold(80, 200);\#nrun("Threshold");"#, on: .gray8),
            MacroParityCase("RGB Merge...", #"run("RGB Merge...", "c1=gray8.tif c2=binary.tif create");"#, on: .gray8, .binary),
        ])
    }

}
