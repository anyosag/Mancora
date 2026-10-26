import Foundation
import MancoraCommands
import MancoraCore
import Testing

@testable import MancoraMacro

/// `open`, `save`, `saveAs` and `Table.open`/`Table.save` on the native
/// file formats. The parity suite runs the same macros in ImageJ.
@Suite("Macro file functions")
struct FileMacroTests {
    let dir: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-macro-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url.path + "/"
    }

    func run(_ code: String, session: MacroSession = MacroSession()) throws -> MacroSession {
        try session.run("dir = \"\(dir)\";\n" + code)
        return session
    }

    func text(_ name: String) throws -> String { try String(contentsOfFile: dir + name, encoding: .utf8) }

    @Test func imageZipsOpenAsImages() throws {
        // The reported bug: open() of an image zip did nothing.
        let session = try run(#"""
            newImage("cells", "16-bit ramp", 40, 30, 3);
            saveAs("ZIP", dir + "cells");
            print(getTitle());
            close();
            open(dir + "cells.zip");
            print(getTitle() + " " + nSlices + " " + bitDepth());
            """#)
        #expect(session.logLines == ["cells.tif", "cells.tif 3 16"])
    }

    @Test func pngAndGifRoundTripAndTitles() throws {
        let session = try run(#"""
            newImage("ramp", "8-bit ramp", 30, 20, 1);
            saveAs("PNG", dir + "ramp.tif");
            print(getTitle());
            saveAs("Gif", dir + "ramp");
            print(getTitle());
            save(dir + "copy.png");
            print(getTitle());
            open(dir + "ramp.png"); print(getTitle() + " " + getPixel(15, 3));
            open(dir + "ramp.gif"); print(getTitle() + " " + getPixel(15, 3));
            """#)
        // PNG takes the file's name as title, GIF leaves it, save() restores it.
        #expect(session.logLines == ["ramp.png", "ramp.png", "ramp.png", "ramp.png 128", "ramp.gif 128"])
        #expect(FileManager.default.fileExists(atPath: dir + "copy.png"))
    }

    @Test func resultsAreTabsUnlessCSV() throws {
        _ = try run(#"""
            newImage("a", "8-bit ramp", 64, 64, 1);
            makeRectangle(0, 0, 32, 32); run("Measure");
            makeRectangle(32, 0, 32, 32); run("Measure");
            setResult("Label", 0, "left, top");
            saveAs("Results", dir + "r.xls");
            saveAs("Results", dir + "r.csv");
            """#)
        let xls = try text("r.xls"), csv = try text("r.csv")
        #expect(xls.hasPrefix(" \tLabel\tArea\tMean\tMin\tMax\n1\tleft, top\t1024\t"))
        #expect(csv.hasPrefix(" ,Label,Area,Mean,Min,Max\n1,left; top,1024,"))
        #expect(!xls.replacing("left, top", with: "").contains(","))
    }

    @Test func tablesOpenAndSave() throws {
        try Data("Name,Value\n\"a,b\",3\nc,4.5\n".utf8).write(to: URL(fileURLWithPath: dir + "t.csv"))
        let session = try run(#"""
            Table.open(dir + "t.csv");
            print(Table.size("t.csv") + " " + Table.getString("Name", 0, "t.csv") + " " + Table.get("Value", 1, "t.csv"));
            Table.save(dir + "t.tsv", "t.csv");
            Table.showRowNumbers(true, "t.csv");
            Table.save(dir + "numbered.csv", "t.csv");
            open(dir + "t.csv");
            print(Table.title);
            """#)
        #expect(session.logLines.first == "2 a,b 4.5")
        // A column with a fraction shows every number with 3 decimals.
        #expect(try text("t.tsv") == "Name\tValue\na,b\t3.000\nc\t4.500\n")
        #expect(try text("numbered.csv") == " ,Name,Value\n1,\"a,b\",3.000\n2,c,4.500\n")
    }

    @Test func unsupportedFormatsSayTheBridgeRunsThem() {
        #expect(throws: (any Error).self) {
            try run(#"newImage("a", "RGB", 4, 4, 1); saveAs("Jpeg", dir + "a.jpg");"#)
        }
        #expect(throws: (any Error).self) {
            try run(#"newImage("a", "8-bit", 4, 4, 1); saveAs("Something", dir + "a.xyz");"#)
        }
        #expect(throws: (any Error).self) { try run(#"open(dir + "missing.tif");"#) }
    }

    @Test func staticAnalysisKnowsTheTableFunctions() {
        let code = "Table.open(\"x.csv\"); Table.save(\"y.csv\"); Table.showRowNumbers(true);"
        #expect(MacroSupport.unsupported(in: code, registry: .standard).isEmpty)
    }
}
