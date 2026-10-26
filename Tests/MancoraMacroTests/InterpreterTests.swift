import Foundation
import MancoraCommands
import MancoraCore
import Testing

@testable import MancoraMacro

/// The interpreter on every platform. The expected output is ImageJ
/// 1.54p's: the parity suite (Tests/MancoraParityTests) checks the same
/// macros against ImageJ itself, but only where Java is available.
@Suite("Macro interpreter")
struct InterpreterTests {
    /// The Log window's lines after running `code` in a new session.
    func log(_ code: String, session: MacroSession = MacroSession()) throws -> [String] {
        try session.run(code)
        return session.logLines
    }

    @Test func numbersAndStrings() throws {
        let lines = try log(#"""
            str = "Hello World";
            print(str.length, lengthOf(str), str.toUpperCase(), toLowerCase(str));
            print(str.indexOf("World"), indexOf(str, "o"), indexOf(str, "o", 5), lastIndexOf(str, "o"));
            print(substring(str, 6), substring(str, 0, 5), str.substring(3, 4));
            print(replace(str, "o", "0"), replace(str, "l+", "L"), str.replace("World", "There"));
            print(d2s(PI, 4), d2s(2.5, 0), d2s(3.5, 0), d2s(-2.5, 0), d2s(1234.5678, -2), d2s(0.125, 2));
            print(toHex(255), toHex(-1), toBinary(10), toBinary(0));
            print(1/3, 2/3*1000, 1e-10, 123456789012, NaN, 0.1+0.2, 1/0, -1/0);
            print("abc" + 1 + 2.5);
            """#)
        #expect(lines == [
            "11 11 HELLO WORLD hello world",
            "6 4 7 7",
            "World Hello l",
            "Hell0 W0rld HeLo WorLd Hello There",
            "3.1416 3 4 -3 1.23E3 0.12",
            "ff ffffffff 1010 0",
            "0.3333 666.6667 1.0000E-10 1.2346E11 NaN 0.3 Infinity -Infinity",
            "abc3.5",
        ])
    }

    @Test func controlFlowAndFunctions() throws {
        let lines = try log(#"""
            function fact(n) { if (n <= 1) return 1; return n*fact(n-1); }
            for (i=0; i<5; i++) { if (i==1) continue; if (i==4) break; print("i=" + i); }
            n = 0; while (n < 5) n++; print(n);
            do { n--; } while (n > 2); print(n);
            print(fact(10));
            a = newArray(3, 1, 2); Array.sort(a); Array.print(a);
            """#)
        #expect(lines == ["i=0", "i=2", "i=3", "5", "2", "3628800", "1, 2, 3"])
    }

    @Test func tokenizerQuirks() throws {
        // Hex constants, exponents, comments and a block comment with an empty line.
        let lines = try log("print(0x1F, 1e5, 2E3, 1.5e-3); /* a\n\nb */ print(\"x\"); // end")
        #expect(lines == ["31 100000 2000 0.0015", "x"])
    }

    @Test func errorsHaveImageJsMessageAndLine() {
        #expect(throws: MacroError.self) { try MacroSession().run("print(1);\ny = x + 1;") }
        do {
            try MacroSession().run("print(1);\ny = x + 1;")
        } catch {
            #expect(error.message == "Undefined variable")
            #expect(error.lineNumber == 2)
        }
    }

    /// The macOS app runs macros on a cooperative thread, whose stack is 512 KB:
    /// recursion must still get as far as in ImageJ, which stops it with
    /// "Stack overflow" once its variable stack is full.
    @Test func recursionOnASmallThreadStack() {
        final class Outcome: @unchecked Sendable {
            var lines: [String] = []
            var error: MacroError?
        }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let session = MacroSession()
            do throws(MacroError) {
                try session.run("function depth(n) { if (n == 0) return 0; return 1 + depth(n - 1); }\nprint(depth(600));")
                try session.run("function f(n) { return f(n + 1); }\nf(0);")
            } catch {
                outcome.error = error
            }
            outcome.lines = session.logLines
            finished.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        finished.wait()
        #expect(outcome.lines == ["600"])
        #expect(outcome.error?.message == "Stack overflow")
        #expect(outcome.error?.lineNumber == 1)
    }

    @Test func returnValueAndArgument() throws {
        let value = try MacroSession().run("return getArgument() + \"!\";", argument: "hi")
        #expect(value == "hi!")
    }

    @Test func imagesPixelsAndSelections() throws {
        let session = MacroSession()
        let lines = try log(#"""
            newImage("ramp", "8-bit ramp", 20, 10, 1);
            setPixel(3, 4, 300);
            print(getTitle(), getWidth(), getHeight(), bitDepth(), getPixel(3, 4), getPixel(10, 2));
            makeRectangle(0, 0, 10, 10);
            getStatistics(area, mean, min, max);
            print(area, mean, min, max, selectionType());
            run("Select None");
            print(selectionType(), nImages);
            """#, session: session)
        #expect(lines == ["ramp 20 10 8 255 128", "100 59.37 0 255 0", "-1 1"])
    }

    @Test func formatting() throws {
        #expect(try JavaFormatter.format("%.1f|%5.2f|%08.3f|%e", [0.15, 2.25, -3.14159, 12345.678])
            == "0.2| 2.25|-003.142|1.234568e+04")
        #expect(javaString(0.1 + 0.2) == "0.30000000000000004")
        #expect(javaString(1e7) == "1.0E7")
    }

    @Test func unsupportedFunctionsAreFound() {
        let found = MacroSupport.unsupported(
            in: "makeText(\"a\",2,3); Overlay.addSelection(); run(\"Bio-Formats Importer\", \"\"); print(1);",
            registry: .standard)
        #expect(found == ["makeText", "Overlay", "run(\"Bio-Formats Importer\")"])
        #expect(MacroSupport.unsupported(in: "run(\"Gaussian Blur...\", \"sigma=2\"); x = Math.sqrt(4);", registry: .standard).isEmpty)
    }
}
