import MancoraCommands
import MancoraCore
import MancoraProcess
import Testing

/// Analyze ▸ Plot Profile's and Analyze ▸ Histogram's data for the current image.
@Suite("Plot Profile and Histogram data")
struct AnalyzeDataTests {
    /// 4×2 16-bit: 0 100 200 300 / 400 500 600 700.
    func context(_ roi: Roi? = nil, type: PixelType = .gray16) throws -> CommandContext {
        let plane: Plane =
            type == .gray8 ? .gray8((0..<8).map { UInt8($0 * 10) }) : .gray16((0..<8).map { UInt16($0 * 100) })
        var image = try Hyperstack(title: "ramp.tif", stack: ImageStack(width: 4, height: 2, planes: [plane]))
        image.calibration.pixelWidth = 0.5
        image.calibration.unit = "micron"
        var context = CommandContext()
        context.add(image)
        if let roi { try context.withCurrent("") { (open: inout OpenImage) throws(CommandError) in open.roi = roi } }
        return context
    }

    @Test func plotProfile() throws {
        let line = Roi(.line(Roi.Line(x1: 0, y1: 1, x2: 3, y2: 1)))
        let data = try context(line).plotProfile()
        #expect(data.yValues == [400, 500, 600, 700])
        #expect(data.xValues == [0, 0.5, 1, 1.5])
        #expect(data.xLabel == "Distance (microns)" && data.yLabel == "Gray Value")
        // Rectangles: columns, or rows with Vertical profile or Alt.
        var context = try context(Roi(.rectangle(.integer(x: 0, y: 0, width: 4, height: 2))))
        #expect(try context.plotProfile().yValues == [200, 300, 400, 500])
        #expect(try context.plotProfile(altKeyDown: true).yValues == [150, 550])
        context.settings.verticalProfile = true
        #expect(try context.plotProfile().yValues == [150, 550])
        // Interpolation off: the nearest pixel.
        context = try self.context(Roi(.line(Roi.Line(x1: 0, y1: 0.25, x2: 3, y2: 0.25))))
        #expect(try context.plotProfile().yValues == [100, 200, 300, 400])
        context.settings.interpolateLineProfiles = false
        #expect(try context.plotProfile().yValues == [0, 100, 200, 300])
    }

    @Test func plotProfileNeedsALineOrRectangle() throws {
        #expect(throws: CommandError.noImage("Plot Profile")) { try CommandContext().plotProfile() }
        let detail = "Line or rectangular selection required."
        #expect(throws: CommandError.failed(command: "Plot Profile", detail: detail)) { try context().plotProfile() }
        let oval = Roi(.oval(.integer(x: 0, y: 0, width: 3, height: 2)))
        #expect(throws: CommandError.failed(command: "Plot Profile", detail: detail)) { try context(oval).plotProfile() }
    }

    @Test func histogram() throws {
        let data = try context().histogram(bins: 8)
        #expect(data.counts == [1, 1, 1, 1, 1, 1, 1, 1])
        #expect(data.histMin == 0 && data.histMax == 700 && data.binWidth == 87.625)
        #expect(data.count == 8 && data.mean == 350)
        // The selection's pixels; a line selection measures the whole image.
        let rect = Roi(.rectangle(.integer(x: 1, y: 0, width: 2, height: 2)))
        #expect(try context(rect).histogram().count == 4)
        #expect(try context(Roi(.line(Roi.Line(x1: 0, y1: 0, x2: 3, y2: 1)))).histogram().count == 8)
        // 8-bit images with other bins use ImageJ's StackStatistics, not ported yet.
        #expect(try context(type: .gray8).histogram().counts[70] == 1)
        #expect(throws: CommandError.notNative("Histogram")) { try context(type: .gray8).histogram(bins: 10) }
    }
}
