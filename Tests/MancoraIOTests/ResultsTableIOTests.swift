import MancoraCore
import Testing

@testable import MancoraIO

@Suite("Results table files")
struct ResultsTableIOTests {
    static func table() -> ResultsTable {
        var rt = ResultsTable()
        for i in 0..<2 {
            let row = rt.addRow(label: i == 0 ? "cell, one" : nil)
            rt.set("Area", row: row, Double(10 + i))
            rt.set("Mean", row: row, 2.5 * Double(i + 1))
            rt.set("Note", row: row, .text(i == 0 ? "a,b" : ""))
        }
        return rt
    }

    @Test func csvHasCommasQuotesAndRowNumbers() {
        let text = ResultsTableIO.encode(Self.table(), csv: true, rowNumbers: true, format: ResultsTableIO.defaultFormat)
        #expect(text == " ,Label,Area,Mean,Note\n1,cell; one,10,2.500,\"a,b\"\n2,,11,5,\"\"\n")
    }

    @Test func everythingElseHasTabsAndNoQuotes() {
        let text = ResultsTableIO.encode(Self.table(), csv: false, rowNumbers: false, format: ResultsTableIO.defaultFormat)
        #expect(text == "Label\tArea\tMean\tNote\ncell, one\t10\t2.500\ta,b\n\t11\t5\t\n")
        #expect(ResultsTableIO.isCSV("x.csv") && ResultsTableIO.isCSV("x.CSV"))
        #expect(!ResultsTableIO.isCSV("x.xls") && !ResultsTableIO.isCSV("x.tsv") && !ResultsTableIO.isCSV("x.Csv"))
    }

    @Test func emptyTablesHaveNoHeading() {
        #expect(ResultsTableIO.encode(ResultsTable(), csv: true, rowNumbers: true, format: ResultsTableIO.defaultFormat) == "")
    }

    @Test func opensImageJsResultsFiles() throws {
        let rt = try ResultsTableIO.decode(" ,Label,Area,Mean\n1,blobs.gif,433,255\n2,blobs.gif,185,NaN\n", csv: true)
        #expect(rt.count == 2)
        #expect(rt.labels == ["blobs.gif", "blobs.gif"])
        #expect(rt.columns == ["Area", "Mean"])
        #expect(rt.number("Area", row: 1) == 185)
        #expect(rt.number("Mean", row: 1).isNaN)
    }

    @Test func quotedCommasAndText() throws {
        let rt = try ResultsTableIO.decode("Name,Value\n\"a,b\",3\nplain,x\n", csv: true)
        #expect(rt.value("Name", row: 0) == .text("a,b"))
        #expect(rt.value("Value", row: 0) == .number(3))
        #expect(rt.value("Value", row: 1) == .text("x"))
        // Without a " " column, a "Label" column is an ordinary text column.
        let labelled = try ResultsTableIO.decode("Label\tArea\nx\t5\n", csv: false)
        #expect(labelled.labels == [nil])
        #expect(labelled.value("Label", row: 0) == .text("x"))
    }

    @Test func numericHeadingsAreData() throws {
        let rt = try ResultsTableIO.decode("1\t2\n3\t4\n", csv: false)
        #expect(rt.columns == ["C1", "C2"])
        #expect(rt.count == 2)
        #expect(rt.number("C2", row: 1) == 4)
    }

    @Test func lineEndingsByteOrderMarksAndShortRows() throws {
        let rt = try ResultsTableIO.decode("\u{FEFF}X,Y\r\n1,2\r\n3\r\n", csv: true)
        #expect(rt.columns == ["X", "Y"])
        #expect(rt.number("Y", row: 0) == 2)
        #expect(rt.number("Y", row: 1).isNaN)
        #expect(throws: MancoraIOError.self) { try ResultsTableIO.decode("\n", csv: true) }
        #expect(try ResultsTableIO.decode("", csv: true).isEmpty)
    }

    @Test func roundTrips() throws {
        let rt = Self.table()
        for csv in [true, false] {
            let back = try ResultsTableIO.decode(
                ResultsTableIO.encode(rt, csv: csv, rowNumbers: true, format: ResultsTableIO.defaultFormat), csv: csv)
            #expect(back.columns == rt.columns)
            #expect(back.number("Area", row: 1) == 11)
            #expect(back.value("Note", row: 0) == .text("a,b"))
            #expect(back.labels.first == (csv ? "cell; one" : "cell, one"))
        }
    }

    @Test func titlesAndParsing() {
        #expect(ResultsTableIO.title(forPath: "/data/Results.csv") == "Results")
        #expect(ResultsTableIO.title(forPath: "/data/blobs.xls") == "blobs.xls")
        let parse = ResultsTableIO.defaultParse
        #expect(parse(" 1.5 ") == 1.5 && parse("2e3") == 2000 && parse("-7f") == -7 && parse(".5") == 0.5)
        #expect(parse("NaN")?.isNaN == true && parse("-Infinity") == -.infinity)
        #expect(parse("") == nil && parse("abc") == nil && parse("+-1") == nil && parse("1,5") == nil)
    }
}
