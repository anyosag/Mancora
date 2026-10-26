import MancoraCore
import Testing

@testable import MancoraCommands

@Suite("Macro options")
struct MacroOptionsTests {
    @Test func keysComeFromLabels() {
        #expect(MacroOptions.key(forLabel: "Sigma (Radius):") == "sigma")
        #expect(MacroOptions.key(forLabel: "Projection type") == "projection")
        #expect(MacroOptions.key(forLabel: "Stop:") == "stop")
    }

    /// `ij.Macro.getValue`.
    @Test func values() {
        let o = MacroOptions("sigma=2 stack projection=[Max Intensity] note='a b' nested=[x [y] z] last=9")
        #expect(o.value(forLabel: "Sigma (Radius):") == "2")
        #expect(o.value(forLabel: "Projection type") == "Max Intensity")
        #expect(o.value(forLabel: "note") == "a b")
        #expect(o.value(forLabel: "nested") == "x [y] z")
        #expect(o.value(forLabel: "last") == "9")  // the trailing space is implied
        #expect(o.value(forLabel: "missing") == nil)
        // A key must not follow a letter: "xsigma=" is not "sigma=".
        #expect(MacroOptions("xsigma=5 sigma=2").value(forLabel: "sigma") == "2")
        #expect(MacroOptions("xsigma=5").value(forLabel: "sigma") == nil)
        #expect(MacroOptions("open=[unclosed").value(forLabel: "open") == nil)
        #expect(MacroOptions("sigma=2.5").number(forLabel: "sigma", default: 1) == 2.5)
        #expect(MacroOptions("sigma=abc").number(forLabel: "sigma", default: 1) == 1)
    }

    /// `GenericDialog.isMatch`.
    @Test func flags() {
        #expect(MacroOptions("stack").flag(forLabel: "Stack"))
        #expect(MacroOptions("sigma=2 stack").flag(forLabel: "stack"))
        #expect(!MacroOptions("stack=3").flag(forLabel: "stack"))
        #expect(!MacroOptions("title=[my stack image]").flag(forLabel: "stack"))
        #expect(!MacroOptions("sigma=2").flag(forLabel: "stack"))
        #expect(MacroOptions("title=[a b] stack").flag(forLabel: "stack"))
    }

    @Test func recording() {
        var r = OptionsRecorder()
        r.value("Sigma (Radius):", "2")
        r.value("Projection type", "Max Intensity")
        r.flag("Stack", true)
        r.flag("Scaled", false)
        #expect(r.options.text == "sigma=2 projection=[Max Intensity] stack")

        var macro = MacroRecorder()
        macro.record("Gaussian Blur...", options: r.options)
        macro.record("Invert LUT")
        macro.record("Rename...", options: MacroOptions("title=[say \"hi\"]"))
        #expect(macro.macro == """
            run("Gaussian Blur...", "sigma=2 projection=[Max Intensity] stack");
            run("Invert LUT");
            run("Rename...", "title=[say \\"hi\\"]");

            """)
        #expect(MacroRecorder.escape("tab\tthere") == "tab\\011there")
    }
}

@Suite("Commands")
struct CommandTests {
    func image(_ title: String, planes: Int = 1, dims: HyperstackDimensions? = nil) throws -> Hyperstack {
        let stack = try ImageStack(
            width: 4, height: 2, planes: (0..<planes).map { k in .gray16((0..<8).map { UInt16($0 * 100 + k) }) })
        return try Hyperstack(title: title, stack: stack, dimensions: dims)
    }

    @Test func unknownCommandsAreReportedLikeImageJ() throws {
        var context = CommandContext()
        #expect(throws: CommandError.unrecognized("Nope")) {
            try CommandRegistry.standard.run("Nope", in: &context)
        }
        #expect(throws: CommandError.noImage("Fire")) { try CommandRegistry.standard.run("Fire", in: &context) }
    }

    @Test func lutsApplyToTheCurrentChannel() throws {
        var context = CommandContext()
        context.add(try image("a.tif", planes: 2, dims: HyperstackDimensions(channels: 2)))
        let registry = CommandRegistry.standard
        try registry.run("Fire", in: &context)
        #expect(context.current?.image.channels[0].lut.name == "Fire")
        #expect(context.current?.image.channels[1].lut.name == "Green")
        try registry.run("Invert LUT", in: &context)
        #expect(context.current?.image.channels[0].lut.hasSameColors(as: LUT.fire.inverted()) == true)
    }

    @Test func duplicateNamesAndRanges() throws {
        var context = CommandContext()
        context.add(try image("blobs.gif", planes: 6, dims: HyperstackDimensions(channels: 2, slices: 3)))
        let registry = CommandRegistry.standard
        try registry.run("Duplicate...", in: &context)  // the current plane only
        #expect(context.current?.title == "blobs-1.gif")
        #expect(context.current?.image.stack.count == 1)
        try context.select(title: "blobs.gif")
        try registry.run("Duplicate...", options: MacroOptions("title=sub duplicate channels=2 slices=2-3"), in: &context)
        let sub = try #require(context.current)
        #expect(sub.title == "sub")
        #expect(sub.image.dimensions == HyperstackDimensions(channels: 1, slices: 2))
        // Plane (c=2, z=2) of the original is plane index 3.
        #expect(sub.image.stack[0] == context.images[0].image.stack[3])
        #expect(throws: CommandError.self) {
            try context.select(title: "blobs.gif")
            try registry.run("Duplicate...", options: MacroOptions("duplicate slices=5"), in: &context)
        }
        try registry.run("Close All", in: &context)
        #expect(context.images.isEmpty && context.current == nil)
    }

    @Test func uniqueNames() {
        #expect(BuiltInCommands.uniqueName("blobs.gif", among: ["blobs.gif"]) == "blobs-1.gif")
        #expect(BuiltInCommands.uniqueName("blobs.gif", among: ["blobs.gif", "blobs-1.gif"]) == "blobs-2.gif")
        #expect(BuiltInCommands.uniqueName("a-1.tif", among: ["a-1.tif"]) == "a-2.tif")
        #expect(BuiltInCommands.uniqueName("a-0.tif", among: ["a-0.tif"]) == "a-0-1.tif")
        #expect(BuiltInCommands.uniqueName("noext", among: []) == "noext-1")
    }

    @Test func propertiesAndScale() throws {
        var context = CommandContext()
        context.add(try image("p.tif", planes: 6))
        let registry = CommandRegistry.standard
        try registry.run(
            "Properties...",
            options: MacroOptions("channels=2 slices=3 frames=1 unit=um pixel_width=0.25 pixel_height=0.5 voxel_depth=2 frame=[0.5min] origin=3,4"),
            in: &context)
        var cal = try #require(context.current).image.calibration
        #expect(context.current?.image.dimensions == HyperstackDimensions(channels: 2, slices: 3))
        #expect((cal.unit, cal.pixelWidth, cal.pixelHeight, cal.pixelDepth) == ("µm", 0.25, 0.5, 2))
        #expect((cal.frameInterval, cal.timeUnit) == (0.5, "min"))
        #expect((cal.xOrigin, cal.yOrigin, cal.invertY) == (3, 4, false))
        #expect(throws: CommandError.self) {
            try registry.run("Properties...", options: MacroOptions("channels=4 slices=1 frames=1"), in: &context)
        }
        // unit=none resets the spatial calibration.
        try registry.run("Properties...", options: MacroOptions("unit=none pixel_width=1"), in: &context)
        #expect(try #require(context.current).image.calibration.unit == "pixel")

        try registry.run("Set Scale...", options: MacroOptions("distance=100 known=10 pixel=1 unit=um"), in: &context)
        cal = try #require(context.current).image.calibration
        #expect((cal.unit, cal.pixelWidth, cal.pixelHeight, cal.pixelDepth) == ("µm", 0.1, 0.1, 0.1))
        try registry.run("Set Scale...", options: MacroOptions("distance=0 known=0 unit=pixel"), in: &context)
        #expect(try #require(context.current).image.calibration.unit == "pixel")
        #expect(BuiltInCommands.spacedInterval("0.5min") == "0.5 min")
        #expect(BuiltInCommands.spacedInterval("2 sec") == "2 sec")
    }
}
