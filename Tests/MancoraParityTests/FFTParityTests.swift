import Testing

/// Process ▸ FFT (FFT, Inverse FFT, Redisplay Power Spectrum, Swap
/// Quadrants) against ImageJ 1.54p: the power spectrum's bytes, the
/// inverse transform's pixels, and the filtering done by black or white
/// marks on the spectrum.
@Suite("ImageJ parity: FFT", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct FFTParityTests {
    @Test func powerSpectrum() async throws {
        try await MacroParity.check([
            MacroParityCase("8-bit, padded", #"run("FFT");"#, on: .gray8),
            MacroParityCase("16-bit, padded", #"run("FFT");"#, on: .gray16),
            MacroParityCase("32-bit, padded", #"run("FFT");"#, on: .gray32),
            MacroParityCase("RGB brightness", #"run("FFT");"#, on: .rgb),
            MacroParityCase("a stack's slice, calibrated", #"setSlice(2);\#nrun("FFT");"#, on: .calibrated),
            MacroParityCase("a square selection", #"makeRectangle(3, 5, 32, 32);\#nrun("FFT");"#, on: .gray32),
            MacroParityCase("an oval's bounds", #"run("FFT");"#, on: .gray8Oval),
            MacroParityCase("a line selection", #"run("FFT");"#, on: .gray8Line),
        ])
    }

    @Test func inverse() async throws {
        let roundTrip = #"run("FFT");\#nrun("Inverse FFT");"#
        try await MacroParity.check([
            MacroParityCase("8-bit", roundTrip, on: .gray8),
            MacroParityCase("16-bit", roundTrip, on: .gray16),
            MacroParityCase("32-bit", roundTrip, on: .gray32),
            MacroParityCase("RGB", roundTrip, on: .rgb),
            MacroParityCase("unpadded", #"makeRectangle(0, 0, 32, 32);\#n"# + roundTrip, on: .gray16),
            MacroParityCase("FFT of an FFT", #"run("FFT");\#nrun("FFT");"#, on: .gray8),
            MacroParityCase("filtering out", #"""
                run("FFT");
                setColor(0);
                makeOval(20, 29, 5, 5);
                fill();
                makeRectangle(40, 10, 6, 3);
                fill();
                run("Inverse FFT");
                """#, on: .gray16),
            MacroParityCase("passing", #"""
                run("FFT");
                setColor(255);
                makeOval(26, 26, 12, 12);
                fill();
                run("Inverse FFT");
                """#, on: .gray32),
            MacroParityCase("redisplay", #"""
                run("FFT");
                setColor(0);
                makeRectangle(0, 0, 10, 10);
                fill();
                run("Select None");
                run("Redisplay Power Spectrum");
                """#, on: .gray8),
            MacroParityCase("measuring a point", #"""
                run("FFT");
                makePoint(40, 20);
                run("Measure");
                """#, on: .gray8),
        ])
    }

    @Test func swapQuadrants() async throws {
        try await MacroParity.check([
            MacroParityCase("even", #"makeRectangle(2, 2, 40, 40);\#nrun("Crop");\#nrun("Swap Quadrants");"#, on: .rgb),
            MacroParityCase("odd, a stack", #"makeRectangle(0, 0, 41, 41);\#nrun("Crop");\#nrun("Swap Quadrants");"#, on: .stack16),
        ])
    }
}
