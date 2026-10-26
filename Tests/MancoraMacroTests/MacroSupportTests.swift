import MancoraCommands
import MancoraCore
import Testing

@testable import MancoraMacro

/// What ``MacroSupport`` finds before a macro runs: everything that would
/// otherwise stop a native run half-way, so the macro runs in ImageJ.
@Suite("Macro support")
struct MacroSupportTests {
    func found(_ code: String, answersPrompts: Bool = false) -> [String] {
        MacroSupport.unsupported(in: code, registry: .standard, answersPrompts: answersPrompts)
    }

    @Test func callTargets() {
        #expect(found(#"call("ij.Prefs.set", "a", "1"); s = call("ij.IJ.pad", 3, 2); call("java.lang.System.gc");"#).isEmpty)
        #expect(found(#"x = call("ij3d.ImageJ3DViewer.add", "a"); call("ij.Prefs.get", "a", "");"#)
            == [#"call("ij3d.ImageJ3DViewer.add")"#])
    }

    @Test func roiManagerCommands() {
        #expect(found(#"roiManager("Add"); roiManager("Select", 0); n = roiManager("count");"#).isEmpty)
        #expect(found(#"roiManager("Combine"); roiManager("interpolate rois");"#)
            == [#"roiManager("Combine")"#, #"roiManager("interpolate rois")"#])
    }

    @Test func evalLanguagesAndScripts() {
        #expect(found(#"eval("print(1);"); eval("js", "IJ.log(1)"); runMacro("/tmp/a.ijm"); runMacro("/tmp/b.py");"#)
            == [#"eval("js")"#, #"runMacro("b.py")"#])
    }

    @Test func fileFormats() {
        let code = #"""
            saveAs("Tiff", "/tmp/a.tif"); saveAs("PNG", "/tmp/a.png"); saveAs("Results", "/tmp/r.csv");
            save("/tmp/b.tif"); save(dir + "c.jpg"); save(dir + name);
            open("/tmp/a.tif"); open(dir + "x.png"); open(path); saveAs("/tmp/d.gif");
            """#
        #expect(found(code) == [#"saveAs("PNG")"#, #"save("c.jpg")"#, #"open("x.png")"#, #"save("d.gif")"#])
        #expect(found(#"saveAs("Tiff");"#) == [#"saveAs("Tiff") with a save dialog"#])
    }

    @Test func dialogsAndWindows() {
        let code = #"""
            a = getDirectory("temp"); b = getDir("Choose a Directory"); c = getDirectory("home");
            d = getInfo(); e = getInfo("window.contents"); f = getInfo("image.title"); open();
            """#
        #expect(found(code) == [#"getDir("Choose a Directory")"#, "getInfo()", #"getInfo("window.contents")"#, "open()"])
        // A session that can ask a person chooses folders natively.
        #expect(found(code, answersPrompts: true) == ["getInfo()", #"getInfo("window.contents")"#])
        #expect(found(#"p = getDirectory("preferences");"#, answersPrompts: true) == [#"getDirectory("preferences")"#])
    }

    @Test func optionsThatChangeResults() {
        #expect(found(#"setOption("InvertY", true); setOption("Changes", false); setOption("changes", 0);"#).isEmpty)
        #expect(found(#"setOption("Changes", true); setZCoordinate(2); setRGBWeights(1, 1, 1);"#)
            == [#"setOption("Changes")"#, "setZCoordinate", "setRGBWeights"])
    }

    @Test func saveFormatsFollowImageJ() {
        #expect(Functions.SaveFormat("Tiff") == .tiff)
        #expect(Functions.SaveFormat("Text Image") == .textImage)
        #expect(Functions.SaveFormat("XY Coordinates") == .xyCoordinates)
        #expect(Functions.SaveFormat("csv") == .unsupported)
        #expect(Functions.saveFormat(forPath: "/tmp/a") == .tiff)
        #expect(Functions.saveFormat(forPath: "/tmp/a.roi") == .selection)
        #expect(Functions.updateExtension("/tmp/a.png", ".tif") == "/tmp/a.tif")
        #expect(Functions.updateExtension("/tmp/a.12", ".tif") == "/tmp/a.12.tif")
        #expect(Functions.updateExtension("/tmp/a.longext", ".tif") == "/tmp/a.longext.tif")
    }
}

/// Table helpers that follow ResultsTable.
@Suite("Macro tables")
struct MacroTableTests {
    @Test func applyMacroVariableNames() {
        #expect(Functions.variableNames(["Area", "%Area", "1st", "Area", "Area"]) == ["Area", "_Area", "_1st", "Area_0", "Area_1"])
    }

    @Test func readsImageJsTables() throws {
        let csv = " ,Label,Area,Note\n1,a,1.5,\"x, y\"\n2,b,2,z\n"
        let rt = try Functions.readTable(csv, path: "/tmp/Results.csv")
        #expect(rt.columns == ["Area", "Note"])
        #expect(rt.labels == ["a", "b"])
        #expect(rt.value("Note", row: 0) == .text("x, y"))
        #expect(rt.number("Area", row: 1) == 2)
        let numeric = try Functions.readTable("1\t2\n3\t4\n", path: "/tmp/t.txt")
        #expect(numeric.columns == ["C1", "C2"])
        #expect(numeric.count == 2)
        #expect(javaSplit("a,,b,,", ",") == ["a", "", "b"])
    }

    @Test func sessionTablesAndFrontWindow() throws {
        let session = MacroSession()
        try session.run(#"""
            Table.create("One"); Table.set("A", 0, 1);
            Table.create("Two"); Table.set("B", 0, 2);
            print(Table.title, Table.size("One"));
            selectWindow("One");
            print(Table.title, Table.getString("A", 0));
            """#)
        #expect(session.logLines == ["Two 1", "One 1"])
    }
}
