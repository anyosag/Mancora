import Testing

@testable import MancoraMacro

/// Dialogs with nobody to ask, and through a prompt handler. ImageJ itself
/// would wait for a person here, so the parity suite can only check the
/// macro-options form; these follow GenericDialog's defaults instead.
@Suite("Macro dialogs")
struct DialogTests {
    static let dialog = #"""
        Dialog.create("Settings");
        Dialog.addNumber("Count:", 3);
        Dialog.addString("Name:", "first");
        Dialog.addCheckbox("Fast", true);
        Dialog.addChoice("Mode:", newArray("Mean", "Median"), "Median");
        Dialog.addRadioButtonGroup("Color", newArray("red", "green"), 1, 2, "green");
        Dialog.addSlider("Size", 0, 5, 1.5);
        Dialog.show();
        print(Dialog.getNumber(), Dialog.getString(), Dialog.getCheckbox(), Dialog.getChoice(), Dialog.getRadioButton(),
            Dialog.getNumber(), Dialog.getYesNoCancel());
        """#

    @Test func defaultsWithNobodyToAsk() throws {
        let session = MacroSession()
        try session.run(Self.dialog)
        #expect(session.logLines == ["3.0 first 1 Median green 1.5 yes"])
        try session.run(#"print(getNumber("n", 2.5), getString("s", "x"), getBoolean("ok?")); waitForUser("go on");"#)
        #expect(session.logLines.last == "2.5 x 1")
    }

    @Test func macroOptionsWin() throws {
        let session = MacroSession()
        var asked = 0
        session.onPrompt = { _ in
            asked += 1
            return .cancel
        }
        // In macro mode checkboxes are off unless named, whatever their default.
        try session.run(Self.dialog, options: "count=9 name=[a b] mode=Mean")
        #expect(session.logLines == ["9.0 a b 0 Mean green 1.5 yes"])
        #expect(asked == 0)
        #expect(session.macroOptions == nil)
    }

    @Test func promptHandlerAnswers() throws {
        let session = MacroSession()
        var seen: MacroPrompt?
        session.onPrompt = { prompt in
            switch prompt.kind {
            case .dialog:
                seen = prompt
                var fields = prompt.fields
                fields[0] = .number(label: "Count:", value: 11, decimalPlaces: 0, columns: 6, units: nil)
                fields[2] = .checkbox(label: "Fast", value: false)
                fields[3] = .choice(label: "Mode:", items: ["Mean", "Median"], value: "Mean")
                return .ok(fields)
            case .question: return .no([])
            case .directory: return .path("/tmp/picked")
            default: return .ok([])
            }
        }
        try session.run(Self.dialog + #"print(getBoolean("Sure?")); print(getDirectory("Pick one"));"#)
        #expect(session.logLines == ["11.0 first 0 Mean green 1.5 yes", "0", "/tmp/picked/"])
        #expect(seen?.title == "Settings")
        #expect(seen?.fields.count == 6)
    }

    @Test func cancelStopsTheMacro() throws {
        let session = MacroSession()
        session.onPrompt = { _ in .cancel }
        try session.run(#"print("before"); Dialog.create("x"); Dialog.show(); print("after");"#)
        #expect(session.logLines == ["before"])
        // getNumber returns its default and the macro stops after the statement.
        try session.run(#"n = getNumber("n", 4); print(n); print("never");"#)
        #expect(session.logLines == ["before"])
    }

    @Test func choosersStopWithoutAnAnswer() throws {
        let session = MacroSession()
        try session.run(#"print("a"); d = getDirectory("Choose a Directory"); print("b");"#)
        #expect(session.logLines == ["a"])
    }
}
