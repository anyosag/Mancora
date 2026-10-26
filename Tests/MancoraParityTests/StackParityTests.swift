import Testing

/// Image ▸ Stacks and Image ▸ Stacks ▸ Tools against ImageJ 1.54p, run as
/// macros so every image made or changed, which image is current and which
/// closed (the macro prints them) are all compared.
enum StackMacros {
    /// Prints what a command left: the open images, the current one, its
    /// dimensions, current plane (by number and a pixel) and slice label.
    /// (ImageJ's `Stack.getPosition` can lag behind the plane shown when a
    /// stack changes size, which Mancora doesn't model.)
    static let state = #"""
        function state() {
            Stack.getDimensions(w, h, c, z, t);
            print(nImages + " open; " + getTitle() + " " + w + "x" + h + " c" + c + " z" + z + " t" + t
                + " at " + getSliceNumber() + " (" + getPixel(w/2, h/2) + ") label '" + getInfo("slice.label") + "'");
        }
        function titles() {
            id = getImageID();
            s = "";
            for (i = 1; i <= nImages; i++) { selectImage(i); s = s + getTitle() + "|"; }
            print(s);
            selectImage(id);
        }

        """#

    static func make(_ name: String, _ body: String, on inputs: ParityInput..., tolerance: Double = 1e-9) -> MacroParityCase {
        var c = MacroParityCase(name, state + body, tolerance: tolerance)
        c.inputs = inputs
        return c
    }
}

@Suite("ImageJ parity: stack editing", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct StackEditingParityTests {
    typealias M = StackMacros

    @Test func addAndDeleteSlices() async throws {
        try await MacroParity.check([
            M.make("add after the current slice", #"setSlice(3); run("Add Slice"); state(); run("Add Slice"); state();"#, on: .stack8),
            M.make("add to a single image", #"run("Add Slice"); state();"#, on: .gray16),
            M.make("add to RGB", #"run("Add Slice"); state();"#, on: .rgb),
            M.make("add to a calibrated stack", #"setSlice(1); run("Add Slice"); state();"#, on: .calibrated),
            M.make("delete the current slice", #"setSlice(4); run("Delete Slice"); state();"#, on: .stack16),
            M.make("delete the first slice", #"setSlice(1); run("Delete Slice"); state();"#, on: .stack32),
            M.make("delete the last slice", #"setSlice(5); run("Delete Slice"); state();"#, on: .stack8),
            M.make(
                "delete down to one labeled slice",
                #"""
                setSlice(1); setMetadata("Label", "first"); setSlice(2); setMetadata("Label", "second");
                run("Delete Slice"); run("Delete Slice"); run("Delete Slice"); run("Delete Slice"); state();
                """#, on: .stack8),
            M.make("delete from a stack of RGB", #"setSlice(2); run("Delete Slice"); state();"#, on: .stackRGB),
        ])
    }

    @Test func addAndDeleteInHyperstacks() async throws {
        try await MacroParity.check([
            M.make("add a slice", #"Stack.setPosition(2, 2, 1); run("Add Slice", "add=slice"); state();"#, on: .hyperstack),
            M.make("prepend a slice", #"Stack.setPosition(1, 3, 2); run("Add Slice", "add=slice prepend"); state();"#, on: .hyperstack),
            M.make("add a frame", #"Stack.setPosition(1, 2, 1); run("Add Slice", "add=frame"); state();"#, on: .hyperstack),
            M.make("prepend a frame", #"Stack.setPosition(2, 1, 2); run("Add Slice", "add=frame prepend"); state();"#, on: .hyperstack),
            M.make("add a channel", #"Stack.setPosition(1, 2, 2); run("Add Slice", "add=channel"); state();"#, on: .hyperstack),
            M.make("prepend a channel", #"Stack.setPosition(2, 2, 2); run("Add Slice", "add=channel prepend"); state();"#, on: .hyperstack),
            M.make("add the default", #"Stack.setPosition(1, 1, 1); run("Add Slice", " "); state();"#, on: .fixtureHyperstack),
            M.make("delete a slice", #"Stack.setPosition(2, 2, 1); run("Delete Slice", "delete=slice"); state();"#, on: .hyperstack),
            M.make("delete a frame", #"Stack.setPosition(1, 3, 2); run("Delete Slice", "delete=frame"); state();"#, on: .hyperstack),
            M.make("delete, saying only delete", #"Stack.setPosition(1, 2, 2); run("Delete Slice", "delete"); state();"#, on: .hyperstack),
            M.make("delete with other options", #"Stack.setPosition(2, 3, 1); run("Delete Slice", "x"); state();"#, on: .hyperstack),
            M.make(
                "add and delete channels",
                #"""
                Stack.setPosition(2, 1, 1); run("Add Slice", "add=channel"); state();
                Stack.setPosition(1, 1, 1); run("Delete Slice", "delete=channel"); state();
                """#, on: .fixtureHyperstack),
        ])
    }

    @Test func movingBetweenSlices() async throws {
        try await MacroParity.check([
            M.make(
                "next and previous",
                #"""
                run("Next Slice [>]"); state(); run("Next Slice [>]"); state();
                run("Previous Slice [<]"); state(); run("Previous Slice [<]"); run("Previous Slice [<]"); state();
                setSlice(5); run("Next Slice [>]"); state();
                """#, on: .stack8),
            M.make(
                "next and previous in a hyperstack",
                #"""
                Stack.setPosition(2, 1, 1); run("Next Slice [>]"); state(); run("Next Slice [>]"); state();
                Stack.setPosition(1, 1, 1); run("Previous Slice [<]"); state();
                """#, on: .hyperstack),
            M.make("set slice without a window", #"setSlice(2); run("Set Slice...", "slice=4"); state();"#, on: .stack16),
        ])
    }

    @Test func labels() async throws {
        try await MacroParity.check([
            M.make("set a label", #"setSlice(2); run("Set Label...", "label=second"); state(); setSlice(1); state();"#, on: .stack16),
            M.make("set a label with spaces", #"setSlice(3); run("Set Label...", "label=[third slice]"); state();"#, on: .stack8),
            M.make("set a single image's label", #"run("Set Label...", "label=one"); state();"#, on: .gray8),
            M.make(
                "clear a label", #"setSlice(2); setMetadata("Label", "x"); run("Set Label...", "label=[]"); state();"#,
                on: .stack32),
            M.make(
                "remove labels",
                #"setSlice(2); setMetadata("Label", "a"); setSlice(4); setMetadata("Label", "b"); run("Remove Slice Labels"); state();"#,
                on: .stack16),
            M.make("remove a single image's label", #"run("Set Label...", "label=one"); run("Remove Slice Labels"); state();"#, on: .gray16),
        ])
    }

    @Test func stackToImages() async throws {
        try await MacroParity.check([
            M.make("unlabeled slices", #"run("Stack to Images"); state(); titles();"#, on: .stack16),
            M.make(
                "labeled slices",
                #"""
                setSlice(1); setMetadata("Label", "first.tif"); setSlice(2); setMetadata("Label", "a/b");
                setSlice(3); setMetadata("Label", "third\nmore info"); setSlice(4); setMetadata("Label", "c:d");
                run("Stack to Images"); state(); titles();
                """#, on: .stack8),
            M.make("RGB", #"run("Stack to Images"); state(); titles();"#, on: .stackRGB),
            M.make("calibrated", #"run("Stack to Images"); state(); titles();"#, on: .calibrated),
            M.make("a composite of channels", #"run("Reduce Dimensionality...", "channels"); run("Stack to Images"); state(); titles();"#, on: .hyperstack),
            M.make("with another image open", #"run("Stack to Images"); state(); titles();"#, on: .gray8, .stack32),
        ])
    }

    @Test func reduce() async throws {
        try await MacroParity.check([
            M.make("by two", #"setSlice(4); run("Reduce...", "reduction=2"); state();"#, on: .stack8),
            M.make("by three", #"run("Reduce...", "reduction=3"); state();"#, on: .stack16),
            M.make("calibrated", #"run("Reduce...", "reduction=2"); state();"#, on: .calibrated),
            M.make("hyperstack frames", #"run("Reduce...", "reduction=2"); state();"#, on: .hyperstack),
            M.make("hyperstack slices", #"Stack.setPosition(2, 3, 2); run("Reduce...", "reduction=2 reduce"); state();"#, on: .hyperstack),
        ])
    }
}

@Suite("ImageJ parity: joining stacks", .enabled(if: Parity.available, "needs MANCORA_TEST_IJ_JAR, a JDK and a display or Xvfb"))
struct StackJoiningParityTests {
    typealias M = StackMacros

    @Test func imagesToStack() async throws {
        try await MacroParity.check([
            M.make("no options", #"run("Images to Stack"); state(); titles();"#, on: .gray8, .binary),
            M.make("titles as labels", #"run("Images to Stack", "name=joined title=[] use"); state(); titles();"#, on: .gray8, .binary),
            M.make("keep", #"run("Images to Stack", "name=Stack title=[] keep"); state(); titles();"#, on: .gray8, .binary),
            M.make("a title filter", #"run("Images to Stack", "name=Stack title=gray use"); state(); titles();"#, on: .gray8, .binary, .gray16),
            M.make("8- and 16-bit", #"run("Images to Stack", "name=Stack title=[] use"); state(); titles();"#, on: .gray8, .gray16),
            M.make("16- and 32-bit", #"run("Images to Stack", "name=Stack title=[] use"); state();"#, on: .gray16, .gray32),
            M.make("8-bit and RGB", #"run("Images to Stack", "name=Stack title=[] use"); state();"#, on: .fixtureFire, .rgb),
            M.make("stacks are left alone", #"run("Images to Stack", "name=Stack title=[] use"); state(); titles();"#, on: .gray8, .stack8, .binary),
            M.make(
                "sizes differ, copied to the center",
                #"run("Images to Stack", "method=[Copy (center)] name=Stack title=[] use"); state();"#, on: .gray8, .column8),
            M.make(
                "sizes differ, copied to the top left",
                #"run("Images to Stack", "method=[Copy (top-left)] name=Stack title=[] use"); state();"#, on: .gray16, .row16),
            M.make(
                "sizes differ, scaled to the largest",
                #"run("Images to Stack", "method=[Scale (largest)] name=Stack title=[] use"); state();"#, on: .gray8, .binary,
                .column8),
            M.make(
                "sizes differ, scaled to the smallest, bicubic",
                #"run("Images to Stack", "method=[Scale (smallest)] name=Stack title=[] bicubic use"); state();"#,
                on: .row16, .gray16),
            M.make(
                "info joins the label",
                #"selectImage(1); setMetadata("Info", "about one"); run("Images to Stack", "name=Stack title=[] use"); state();"#,
                on: .gray8, .binary),
            M.make(
                "an inverted LUT among others",
                #"selectImage(1); run("Invert LUT"); run("Images to Stack", "name=Stack title=[] use"); state();"#,
                on: .gray8, .binary),
        ])
    }

    @Test func combine() async throws {
        try await MacroParity.check([
            M.make("side by side", #"run("Combine...", "stack1=gray8.tif stack2=binary.tif"); state(); titles();"#, on: .gray8, .binary),
            M.make("vertically", #"run("Combine...", "stack1=gray8.tif stack2=binary.tif combine"); state();"#, on: .gray8, .binary),
            M.make("stacks of different depths", #"run("Combine...", "stack1=gray16.tif stack2=stack16.tif"); state();"#, on: .gray16, .stack16),
            M.make("different heights", #"run("Combine...", "stack1=gray8.tif stack2=column8.tif"); state();"#, on: .gray8, .column8),
            M.make("different widths, vertically", #"run("Combine...", "stack1=row16.tif stack2=gray16.tif combine"); state();"#, on: .gray16, .row16),
            M.make(
                "a white background",
                #"setBackgroundColor(255, 255, 255); run("Combine...", "stack1=stackRGB.tif stack2=columnRGB.tif"); state();"#,
                on: .stackRGB, .columnRGB),
            M.make("hyperstacks", #"run("Duplicate...", "title=copy duplicate"); run("Combine...", "stack1=hyperstack.tif stack2=copy"); state();"#, on: .hyperstack),
            M.make("calibrated", #"run("Combine...", "stack1=calibrated.tif stack2=stack16.tif combine"); state();"#, on: .calibrated, .stack16),
        ])
    }

    @Test func concatenate() async throws {
        try await MacroParity.check([
            M.make("two stacks", #"run("Concatenate...", "  title=joined image1=stack16.tif image2=calibrated.tif"); state(); titles();"#, on: .stack16, .calibrated),
            M.make("as 4D", #"run("Concatenate...", "  title=joined open image1=stack8.tif image2=binaryStack.tif"); state();"#, on: .stack8, .binaryStack),
            M.make("as 4D, different depths", #"run("Concatenate...", "  title=t open image1=stack16.tif image2=calibrated.tif"); state();"#, on: .stack16, .calibrated),
            M.make("two images as frames", #"run("Concatenate...", "  title=pair open image1=gray8.tif image2=binary.tif"); state();"#, on: .gray8, .binary),
            M.make("keep", #"run("Concatenate...", "  title=kept keep image1=gray8.tif image2=binary.tif image3=[-- None --]"); state(); titles();"#, on: .gray8, .binary),
            M.make("all open", #"run("Concatenate...", "all_open title=all"); state(); titles();"#, on: .gray8, .binary, .stack8),
            M.make("old keys", #"run("Concatenate...", "stack1=gray8.tif stack2=binary.tif title=old"); state();"#, on: .gray8, .binary),
            M.make("different sizes", #"run("Concatenate...", "  title=c image1=gray16.tif image2=row16.tif"); state();"#, on: .gray16, .row16),
            M.make("hyperstacks", #"run("Duplicate...", "title=copy duplicate"); run("Concatenate...", "  title=h image1=hyperstack.tif image2=copy"); state();"#, on: .hyperstack),
            M.make(
                "hyperstacks of slices",
                #"""
                run("Reduce Dimensionality...", "channels slices keep"); rename("a");
                run("Duplicate...", "title=b duplicate"); run("Concatenate...", "  title=z image1=a image2=b"); state(); titles();
                """#, on: .hyperstack),
        ])
    }

    @Test func insert() async throws {
        try await MacroParity.check([
            M.make("an image into a stack", #"run("Insert...", "source=binary.tif destination=stack8.tif x=5 y=7"); state(); titles();"#, on: .stack8, .binary),
            M.make("a stack into a shorter stack", #"run("Insert...", "source=stack16.tif destination=calibrated.tif x=-10 y=20"); state();"#, on: .stack16, .calibrated),
            M.make("a thin image", #"run("Insert...", "source=column8.tif destination=gray8.tif x=30 y=0"); state();"#, on: .gray8, .column8),
        ])
    }

    @Test func groupedZProject() async throws {
        try await MacroParity.check([
            M.make("whole stack", #"run("Grouped Z Project...", "projection=[Max Intensity] group=5"); state(); titles();"#, on: .stack16),
            M.make("groups of two", #"run("Add Slice"); run("Grouped Z Project...", "projection=[Average Intensity] group=2"); state();"#, on: .stack8),
            M.make("groups of three, sum", #"run("Add Slice"); run("Grouped Z Project...", "projection=[Sum Slices] group=3"); state();"#, on: .stack32),
            M.make("calibrated", #"run("Grouped Z Project...", "projection=[Standard Deviation] group=3"); state();"#, on: .calibrated),
            M.make("one per slice", #"run("Grouped Z Project...", "projection=Median group=1"); state();"#, on: .stackRGB),
            M.make(
                "a time series",
                #"run("Properties...", "channels=1 slices=1 frames=5"); run("Add Slice"); run("Grouped Z Project...", "projection=[Max Intensity] group=3"); state();"#,
                on: .stack16),
        ])
    }
}
