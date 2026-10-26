import MancoraCore
import Testing

@testable import MancoraCommands

/// Process ▸ FFT without ImageJ: the transform kept with the spectrum, and
/// the cases left to ImageJ.
@Suite("FFT commands")
struct FFTCommandTests {
    func context(width: Int, height: Int) throws -> CommandContext {
        let pixels = (0..<(width * height)).map { Float(($0 * 37) % 251) / 7 }
        var context = CommandContext()
        let stack = try ImageStack(width: width, height: height, planes: [.gray32Float(pixels)])
        context.add(try Hyperstack(title: "f.tif", stack: stack))
        return context
    }

    @Test func theInverseRestoresTheImage() throws {
        var context = try context(width: 20, height: 12)
        guard case .gray32Float(let before)? = context.current?.currentPlane else { throw CommandError.noImage("test") }
        try CommandRegistry.standard.run("FFT", in: &context)
        let fft = try #require(context.current)
        #expect(fft.title == "FFT of f.tif")
        #expect(fft.image.width == 32 && fft.image.height == 32 && fft.image.pixelType == .gray8)
        #expect(fft.image.frequencyDomain?.originalWidth == 20)
        try CommandRegistry.standard.run("Inverse FFT", in: &context)
        let inverse = try #require(context.current)
        #expect(inverse.title == "Inverse FFT of f.tif")
        guard case .gray32Float(let after) = inverse.currentPlane else { throw CommandError.noImage("test") }
        #expect(after.count == before.count)
        for (a, b) in zip(after, before) { #expect(abs(a - b) < 1e-3) }
    }

    /// ImageJ shows a message when the spectrum was changed without black
    /// or white pixels to filter by; that is left to ImageJ.
    @Test func anEditWithoutBlackOrWhiteIsLeftToImageJ() throws {
        var context = try context(width: 16, height: 16)
        try CommandRegistry.standard.run("FFT", in: &context)
        try context.withCurrent("test") { (open: inout OpenImage) throws(CommandError) in
            open.image.modifyPlane(at: 0) { plane in
                if case .gray8(var p) = plane {
                    p[5] = p[5] == 1 ? 2 : 1
                    plane = .gray8(p)
                }
            }
        }
        #expect(throws: CommandError.notNative("Inverse FFT")) {
            try CommandRegistry.standard.run("Inverse FFT", in: &context)
        }
    }

    /// ImageJ's error messages, which the bridge can't capture (a "Macro Error" dialog).
    @Test func errors() throws {
        var context = try context(width: 10, height: 8)
        #expect(throws: CommandError.failed(command: "Inverse FFT", detail: "Frequency domain image required")) {
            try CommandRegistry.standard.run("Inverse FFT", in: &context)
        }
        #expect(throws: CommandError.failed(command: "Swap Quadrants", detail: "Image must be square")) {
            try CommandRegistry.standard.run("Swap Quadrants", in: &context)
        }
    }

    @Test func swappingQuadrantsTwiceChangesNothing() throws {
        var context = try context(width: 10, height: 10)
        let before = context.current?.currentPlane
        try CommandRegistry.standard.run("Swap Quadrants", in: &context)
        #expect(context.current?.currentPlane != before)
        try CommandRegistry.standard.run("Swap Quadrants", in: &context)
        #expect(context.current?.currentPlane == before)
    }
}
