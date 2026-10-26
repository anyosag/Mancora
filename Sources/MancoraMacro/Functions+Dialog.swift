// Dialogs: the Dialog.* functions, getNumber, getString, getBoolean,
// waitForUser and the folder and file choosers, ported from ImageJ 1.54p's
// Functions.java with the parts of GenericDialog, DirectoryChooser and
// OpenDialog they rely on.
//
// A macro given options (MacroSession.macroOptions) reads its fields from
// them, as GenericDialog does in macro mode. Otherwise a person answers
// through MacroSession.onPrompt; with nobody to ask, fields keep their
// defaults and choosers stop the macro.

import Foundation
import MancoraCommands

/// The parts of ImageJ's `GenericDialog` a macro reads: the fields in the
/// order they were added, their defaults and their macro-option keys.
final class MacroDialog {
    struct NumberField {
        var key: String
        /// The text the field starts with, and the value it stands for.
        var text: String
        var defaultValue: Double
        var answer: Double?
    }

    struct StringField {
        var key: String
        var text: String
    }

    struct CheckboxField {
        var key: String
        var state: Bool
    }

    struct ChoiceField {
        var key: String
        var items: [String]
        var selected: Int
        /// Image IDs, for a choice of images.
        var imageIDs: [Int]?
    }

    struct RadioField {
        var key: String
        var items: [String]
        var selected: String
    }

    let title: String
    /// `Macro.getOptions()` when the dialog was made: in macro mode it's never shown.
    let options: MacroOptions?
    var nonBlocking = false
    var yesNoButtons: MacroPrompt.Buttons?
    private(set) var fields: [MacroPrompt.Field] = []
    private var labels: [String] = []
    var numbers: [NumberField] = []
    var strings: [StringField] = []
    var checkboxes: [CheckboxField] = []
    var choices: [ChoiceField] = []
    var radios: [RadioField] = []
    var numberIndex = 0, stringIndex = 0, checkboxIndex = 0, choiceIndex = 0, radioIndex = 0
    var wasCanceled = false
    var wasOKed = false
    /// The open images' titles and IDs, taken when the first image choice is added.
    private var windows: (titles: [String], ids: [Int])?

    init(title: String, options: String?) {
        self.title = title
        self.options = options.map { MacroOptions($0 + " ") }
    }

    var isMacro: Bool { options != nil }

    /// `saveLabel`: the field's key (`Macro.trimKey`), made unique with `_0`, `_1`...
    @discardableResult
    private func saveLabel(_ labelIn: String) -> String {
        var label = javaTrim(labelIn)
        if !label.isEmpty { label = MacroOptions.key(forLabel: label) }
        if !label.isEmpty && labels.contains(label) {
            label += "_0"
            var n = 1
            while labels.contains(label) {
                label = javaSubstring(label, 0, javaLastIndexOf(label, "_")) + "_\(n)"
                n += 1
            }
        }
        labels.append(label)
        return label
    }

    // MARK: Adding fields

    func addNumber(_ label: String, _ value: Double, decimalPlaces digitsIn: Int, columns: Int, units: String?) {
        var digits = digitsIn
        var scientific = false
        if digits < 0 {
            digits = -digits
            scientific = true
        }
        var text = scientific ? ImageJFormat.resultsTableD2S(value, -digits) : ImageJFormat.d2s(value, digits)
        if value.isNaN { text = "" }
        numbers.append(NumberField(key: saveLabel(label), text: text, defaultValue: value))
        fields.append(.number(label: label, value: value, decimalPlaces: digitsIn, columns: columns, units: units))
    }

    /// `addSlider(label, min, max, default)`: hundredths for a short range of fractions.
    func addSlider(_ label: String, _ minimumIn: Double, _ maximumIn: Double, _ valueIn: Double) {
        let value = min(max(valueIn, minimumIn), maximumIn)
        var digits = 0
        var scale = 1.0
        if maximumIn - minimumIn <= 5
            && (!isJavaInt(minimumIn) || !isJavaInt(maximumIn) || !isJavaInt(value))
        {
            scale = 50
            digits = 2
        }
        addSlider(label, minimumIn, maximumIn, value * scale, scale: scale, digits: digits, step: 1 / scale)
    }

    /// `addSlider(label, min, max, default, stepSize)`.
    func addSlider(_ label: String, _ minimum: Double, _ maximum: Double, _ valueIn: Double, step stepIn: Double) {
        let step = stepIn <= 0 ? 1 : stepIn
        var digits = Self.digits(step)
        if digits == 1 && label == "Angle:" { digits = 2 }
        var scale = 1.0 / abs(step)
        if scale <= 0 { scale = 1 }
        let value = min(max(valueIn, minimum), maximum)
        addSlider(label, minimum, maximum, value * scale, scale: scale, digits: digits, step: step)
    }

    private func addSlider(
        _ label: String, _ minimum: Double, _ maximum: Double, _ scaledValue: Double, scale: Double, digits: Int,
        step: Double
    ) {
        let value = scaledValue / scale
        numbers.append(NumberField(key: saveLabel(label), text: ImageJFormat.d2s(value, digits), defaultValue: value))
        fields.append(.slider(label: label, minimum: minimum, maximum: maximum, value: value, step: step))
    }

    /// GenericDialog's `digits(stepSize)`: the decimals a step needs.
    static func digits(_ d: Double) -> Int {
        if isJavaInt(d) { return 0 }
        let s = javaString(d)
        var ePos = javaIndexOf(s, "E")
        if ePos == -1 { ePos = javaIndexOf(s, "e") }
        let dotPos = javaIndexOf(s, ".")
        if ePos == -1 { return javaSubstring(s, dotPos + 1).utf16.count }
        var digits = 0
        let number = javaSubstring(s, dotPos + 1, ePos)
        if number != "0" { digits += number.utf16.count }
        return digits - (Int(javaSubstring(s, ePos + 1)) ?? 0)
    }

    func addString(_ label: String, _ text: String, columns: Int) {
        strings.append(StringField(key: saveLabel(label), text: text))
        fields.append(.string(label: label, value: text, columns: columns))
    }

    /// A directory field: a string field, plus the panel holding its Browse button, which takes a key too.
    func addDirectory(_ label: String, _ pathIn: String) {
        let path = Functions.addSeparator(pathIn)
        strings.append(StringField(key: saveLabel(label), text: path))
        saveLabel(label)
        fields.append(.directory(label: label, value: path))
    }

    func addFile(_ label: String, _ path: String) {
        strings.append(StringField(key: saveLabel(label), text: path))
        saveLabel(label)
        fields.append(.file(label: label, value: path))
    }

    func addCheckbox(_ label: String, _ state: Bool) {
        checkboxes.append(CheckboxField(key: saveLabel(label), state: state))
        fields.append(.checkbox(label: label, value: state))
    }

    /// `addCheckboxGroup`: checkboxes laid out column by column; empty labels leave a gap.
    func addCheckboxGroup(rows: Int, columns: Int, labels groupLabels: [String], states: [Bool]) {
        var i1 = 0
        var added: [String] = [], values: [Bool] = []
        rowLoop: for row in 0..<max(rows, 0) {
            for col in 0..<max(columns, 0) {
                let i2 = col * rows + row
                if i2 >= groupLabels.count { break }
                let label = groupLabels[i1]
                if !label.isEmpty {
                    checkboxes.append(CheckboxField(key: saveLabel(label), state: states[i1]))
                    added.append(label)
                    values.append(states[i1])
                }
                i1 += 1
                if i1 >= groupLabels.count { break rowLoop }
            }
        }
        fields.append(.checkboxGroup(rows: rows, columns: columns, labels: added, values: values))
    }

    func addChoice(_ label: String, _ items: [String], _ defaultItem: String?) {
        let selected = defaultItem.flatMap { items.firstIndex(of: $0) } ?? 0
        choices.append(ChoiceField(key: saveLabel(label), items: items, selected: selected))
        fields.append(.choice(label: label, items: items, value: items.isEmpty ? "" : items[selected]))
    }

    func addImageChoice(_ label: String, _ defaultImage: String?, images: [(title: String, id: Int)]) {
        if windows == nil { windows = (images.map(\.title), images.map(\.id)) }
        let titles = windows?.titles ?? []
        let selected = defaultImage.flatMap { titles.firstIndex(of: $0) } ?? 0
        choices.append(ChoiceField(key: saveLabel(label), items: titles, selected: selected, imageIDs: windows?.ids))
        fields.append(.imageChoice(label: label, titles: titles, value: titles.isEmpty ? "" : titles[selected]))
    }

    func addRadioButtons(_ labelIn: String, _ items: [String], rows: Int, columns: Int, _ defaultItem: String) {
        // Without a label the group is "rbg" and its number.
        let label = labelIn.isEmpty ? "rbg\(radios.count + 1)" : labelIn
        radios.append(RadioField(key: saveLabel(label), items: items, selected: items.contains(defaultItem) ? defaultItem : "null"))
        fields.append(.radioButtons(label: labelIn, items: items, rows: rows, columns: columns, value: defaultItem))
    }

    func addMessage(_ text: String, fontSize: Int?, color: String?) {
        fields.append(.message(text, fontSize: fontSize, color: color))
    }

    func addHelp(_ url: String) { fields.append(.help(url)) }
    func addImage(_ path: String) { fields.append(.image(path: path)) }

    // MARK: Answers

    /// What the dialog looks like, for a prompt handler.
    var prompt: MacroPrompt {
        MacroPrompt(kind: .dialog, title: title, fields: fields, yesNoButtons: yesNoButtons, nonBlocking: nonBlocking)
    }

    /// Takes the values of the fields a person filled in.
    func take(_ answered: [MacroPrompt.Field]) {
        var n = 0, s = 0, c = 0, ch = 0, r = 0
        for field in answered {
            switch field {
            case .number(_, let value, _, _, _), .slider(_, _, _, let value, _):
                if n < numbers.count { numbers[n].answer = value }
                n += 1
            case .string(_, let value, _), .directory(_, let value), .file(_, let value):
                if s < strings.count { strings[s].text = value }
                s += 1
            case .checkbox(_, let value):
                if c < checkboxes.count { checkboxes[c].state = value }
                c += 1
            case .checkboxGroup(_, _, _, let values):
                for value in values {
                    if c < checkboxes.count { checkboxes[c].state = value }
                    c += 1
                }
            case .choice(_, _, let value), .imageChoice(_, _, let value):
                if ch < choices.count, let i = choices[ch].items.firstIndex(of: value) { choices[ch].selected = i }
                ch += 1
            case .radioButtons(_, _, _, _, let value):
                if r < radios.count { radios[r].selected = value }
                r += 1
            case .message, .help, .image:
                break
            }
        }
    }
}

extension Functions {
    // MARK: - Dialog.*

    /// `Dialog.*`, a string function: numbers and checkboxes come back as text.
    func doDialog() throws(MacroSignal) -> String? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == STRING_FUNCTION || interp.token == NUMERIC_FUNCTION
            || interp.token == PREDEFINED_FUNCTION)
        {
            try interp.error("Function name expected: ")
        }
        let name = interp.tokenString ?? ""
        if name == "create" || name == "createNonBlocking" {
            let gd = MacroDialog(title: try getStringArg(), options: session.macroOptions)
            gd.nonBlocking = name == "createNonBlocking"
            dialog = gd
            return nil
        }
        guard let gd = dialog else {
            try interp.error("No dialog created with Dialog.create()")
            return nil
        }
        switch name {
        case "addString":
            let label = try getFirstString()
            let defaultString = try getNextString()
            var columns = 8
            if interp.nextToken() == ch(",") { columns = jIntI(try getNextArg()) }
            try interp.getRightParen()
            gd.addString(label, defaultString, columns: columns)
        case "addDirectory", "addFile":
            let label = try getFirstString()
            let path = try getNextString()
            if interp.nextToken() == ch(",") { _ = try getNextArg() }
            try interp.getRightParen()
            if name == "addDirectory" { gd.addDirectory(label, path) } else { gd.addFile(label, path) }
        case "addImageChoice":
            let label = try getFirstString()
            var defaultImage: String?
            if interp.nextToken() == ch(",") { defaultImage = try getLastString() } else { try interp.getRightParen() }
            if session.context.images.isEmpty { try interp.error("No images") }
            gd.addImageChoice(label, defaultImage, images: session.context.images.map { ($0.title, $0.id) })
        case "addNumber":
            var columns = 6
            var units: String?
            let prompt = try getFirstString()
            let defaultNumber = try getNextArg()
            var decimalPlaces = isJavaInt(defaultNumber) ? 0 : 3
            if interp.nextToken() == ch(",") {
                decimalPlaces = jIntI(try getNextArg())
                columns = jIntI(try getNextArg())
                units = try getLastString()
            } else {
                try interp.getRightParen()
            }
            gd.addNumber(prompt, defaultNumber, decimalPlaces: decimalPlaces, columns: columns, units: units)
        case "addSlider":
            let label = try getFirstString()
            let minimum = try getNextArg()
            let maximum = try getNextArg()
            let value = try getNextArg()
            var step = 0.0
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                step = try interp.getExpression()
            }
            try interp.getRightParen()
            if step == 0 { gd.addSlider(label, minimum, maximum, value) } else { gd.addSlider(label, minimum, maximum, value, step: step) }
        case "addCheckbox":
            let label = try getFirstString()
            gd.addCheckbox(label, try getLastArg() == 1)
        case "addCheckboxGroup":
            let rows = jIntI(try getFirstArg())
            let columns = jIntI(try getNextArg())
            try interp.getComma()
            let labels = try getStringArray()
            try interp.getComma()
            let states = try getNumericArray()
            try interp.getRightParen()
            if labels.count != states.count { try interp.error("labels.length!=states.length") }
            gd.addCheckboxGroup(rows: rows, columns: columns, labels: labels, states: states.map { $0 == 1 })
        case "addRadioButtonGroup":
            let label = try getFirstString()
            try interp.getComma()
            let items = try getStringArray()
            let rows = jIntI(try getNextArg())
            let columns = jIntI(try getNextArg())
            let defaultItem = try getLastString()
            gd.addRadioButtons(label, items, rows: rows, columns: columns, defaultItem)
        case "addMessage":
            let message = try getFirstString()
            var fontSize: Int?
            var color: String?
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                fontSize = jIntI(try interp.getExpression())
                if interp.nextToken() == ch(",") {
                    try interp.getComma()
                    color = try getString()
                }
            }
            try interp.getRightParen()
            gd.addMessage(message, fontSize: fontSize, color: color)
        case "addHelp":
            gd.addHelp(try getStringArg())
        case "addChoice":
            let prompt = try getFirstString()
            try interp.getComma()
            let items = try getStringArray()
            var defaultChoice: String?
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                defaultChoice = try getString()
            } else {
                guard let first = items.first else { try interp.fail("Dialog error") }
                defaultChoice = first
            }
            try interp.getRightParen()
            gd.addChoice(prompt, items, defaultChoice)
        case "setInsets":
            _ = try getFirstArg()
            _ = try getNextArg()
            _ = try getLastArg()
        case "addImage":
            gd.addImage(try getStringArg())
        case "addToSameRow":
            try interp.getParens()
        case "enableYesNoCancel":
            let yes = try getFirstString()
            gd.yesNoButtons = MacroPrompt.Buttons(yes: yes, no: try getLastString())
        case "setLocation":
            _ = try getFirstArg()
            _ = try getLastArg()
        case "getLocation":
            // The dialog is never on a screen.
            let x = try getFirstVariable()
            let y = try getLastVariable()
            x.setValue(0)
            y.setValue(0)
        case "show":
            try interp.getParens()
            if try showDialog(gd) {
                interp.finishUp()
                throw .exit(message: nil)
            }
        case "getString":
            try interp.getParens()
            return try nextString(gd)
        case "getNumber":
            try interp.getParens()
            return javaString(try nextNumber(gd))
        case "getCheckbox":
            try interp.getParens()
            return try nextBoolean(gd) ? "1" : "0"
        case "getChoice":
            try interp.getParens()
            return try nextChoice(gd)
        case "getImageChoice":
            try interp.getParens()
            return try nextImageTitle(gd)
        case "getRadioButton":
            try interp.getParens()
            return try nextRadioButton(gd)
        case "getYesNoCancel":
            try interp.getParens()
            return gd.wasCanceled ? "cancel" : gd.wasOKed || gd.isMacro ? "yes" : "no"
        default:
            try interp.error("Unrecognized Dialog function " + name)
        }
        return nil
    }

    /// `GenericDialog.showDialog()`: whether the person canceled. In macro
    /// mode nobody is asked; with nobody to ask, the defaults are OK'd.
    @discardableResult
    func showDialog(_ gd: MacroDialog) throws(MacroSignal) -> Bool {
        if gd.isMacro { return false }
        switch session.ask(gd.prompt) {
        case .ok(let fields)?:
            gd.take(fields)
            gd.wasOKed = true
        case .no(let fields)?:
            gd.take(fields)
        case .cancel?:
            gd.wasCanceled = true
        case .path?, nil:
            gd.wasOKed = true
        }
        return gd.wasCanceled
    }

    /// `getNextNumber()`: in macro mode the option's number, or a variable named by it.
    func nextNumber(_ gd: MacroDialog) throws(MacroSignal) -> Double {
        if gd.numbers.isEmpty { return -1 }
        guard gd.numberIndex < gd.numbers.count else { try interp.fail("Dialog error") }
        let field = gd.numbers[gd.numberIndex]
        gd.numberIndex += 1
        guard let options = gd.options else { return field.answer ?? field.defaultValue }
        var text = options.value(forLabel: field.key) ?? field.text
        if text == field.text { return field.defaultValue }
        if javaStartsWith(text, "0x") { return Double(javaParseInt(javaSubstring(text, 2), radix: 16) ?? 0) }
        if let d = javaParseDouble(text) { return d }
        // Is the value a macro variable?
        if javaStartsWith(text, "&") { text = javaSubstring(text, 1) }
        let value = interp.variable(named: text)?.getValue() ?? .nan
        if value.isNaN {
            try interp.fail("Numeric value expected in run() function\n \n" + "\t Dialog box title: \"" + gd.title + "\"\n"
                + "\t Key: \"" + javaToLowerCase(field.key) + "\"\n" + "\t Value or variable name: \"" + text + "\"")
        }
        return value
    }

    /// `getNextString()`: in macro mode `&name` (and a few other forms) is a variable's value.
    func nextString(_ gd: MacroDialog) throws(MacroSignal) -> String {
        if gd.strings.isEmpty { return "" }
        guard gd.stringIndex < gd.strings.count else { try interp.fail("Dialog error") }
        let field = gd.strings[gd.stringIndex]
        gd.stringIndex += 1
        guard let options = gd.options else { return field.text }
        var text = options.value(forLabel: field.key) ?? field.text
        let first = field.text.unicodeScalars.first
        let numberExpected = first.map { ("0"..."9").contains($0) || $0 == "-" } ?? false
        if javaStartsWith(text, "&") || numberExpected || javaStartsWith(javaToLowerCase(field.key), text) {
            if javaStartsWith(text, "&") { text = javaSubstring(text, 1) }
            if let s = interp.variableAsString(named: text) { text = s }
        }
        return text
    }

    /// `getNextBoolean()`: in macro mode, whether the key is among the options.
    func nextBoolean(_ gd: MacroDialog) throws(MacroSignal) -> Bool {
        if gd.checkboxes.isEmpty { return false }
        guard gd.checkboxIndex < gd.checkboxes.count else { try interp.fail("Dialog error") }
        let field = gd.checkboxes[gd.checkboxIndex]
        gd.checkboxIndex += 1
        guard let options = gd.options else { return field.state }
        return options.flag(forLabel: field.key)
    }

    /// `getNextChoice()`: in macro mode the option's value, which needn't be one of the items.
    func nextChoice(_ gd: MacroDialog) throws(MacroSignal) -> String {
        if gd.choices.isEmpty { return "" }
        guard gd.choiceIndex < gd.choices.count else { try interp.fail("Dialog error") }
        let field = gd.choices[gd.choiceIndex]
        gd.choiceIndex += 1
        let item = field.items.isEmpty ? "null" : field.items[field.selected]
        guard let options = gd.options else { return item }
        let value = options.value(forLabel: field.key) ?? item
        return javaStartsWith(value, "&") ? choiceVariable(value) : value
    }

    /// `getNextImage()`: the image an image choice names, by `getNextChoiceIndex`.
    func nextImageTitle(_ gd: MacroDialog) throws(MacroSignal) -> String {
        if gd.choices.isEmpty { return "" }
        guard gd.choiceIndex < gd.choices.count else { try interp.fail("Dialog error") }
        let field = gd.choices[gd.choiceIndex]
        gd.choiceIndex += 1
        var index = field.items.isEmpty ? -1 : field.selected
        if let options = gd.options, !field.items.isEmpty {
            let oldItem = field.items[field.selected]
            var item = options.value(forLabel: field.key) ?? oldItem
            if javaStartsWith(item, "&") { item = choiceVariable(item) }
            if let i = field.items.firstIndex(of: item) {
                index = i
            } else if item != oldItem, interp.variable(named: item)?.getString() == nil {
                try interp.fail("\"\(item)\" is not a valid choice for \"\(field.key)\"")
            }
        }
        guard index >= 0, let ids = field.imageIDs, index < ids.count,
            let open = session.context.images.first(where: { $0.id == ids[index] })
        else { return "" }
        return open.title
    }

    /// `getNextRadioButton()`.
    func nextRadioButton(_ gd: MacroDialog) throws(MacroSignal) -> String? {
        guard !gd.radios.isEmpty else { return nil }
        guard gd.radioIndex < gd.radios.count else { try interp.fail("Dialog error") }
        let field = gd.radios[gd.radioIndex]
        gd.radioIndex += 1
        guard let options = gd.options else { return field.selected }
        return options.value(forLabel: field.key) ?? field.selected
    }

    /// `getChoiceVariable("&name")`: the variable's text, or its number.
    private func choiceVariable(_ itemIn: String) -> String {
        let item = javaSubstring(itemIn, 1)
        if let s = interp.variable(named: item)?.getString() { return s }
        let value = interp.variable(named: item)?.getValue() ?? .nan
        if value.isNaN { return item }
        return isJavaInt(value) ? String(jInt(value)) : javaString(value)
    }

    // MARK: - Prompts

    /// The title of the dialogs `getNumber` and `getString` show: the macro's name, without " Options".
    private var promptTitle: String {
        var title = interp.macroName ?? ""
        if javaEndsWith(title, " Options") { title = javaSubstring(title, 0, title.utf16.count - 8) }
        return title
    }

    func getNumber() throws(MacroSignal) -> Double {
        let prompt = try getFirstString()
        let defaultValue = try getLastArg()
        let gd = MacroDialog(title: promptTitle, options: session.macroOptions)
        gd.addNumber(prompt, defaultValue, decimalPlaces: isJavaInt(defaultValue) ? 0 : 2, columns: 6, units: nil)
        if try showDialog(gd) {
            interp.done = true
            return defaultValue
        }
        return try nextNumber(gd)
    }

    func getStringDialog() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        let prompt = try getString()
        try interp.getComma()
        let defaultString = try getString()
        try interp.getRightParen()
        let gd = MacroDialog(title: promptTitle, options: session.macroOptions)
        gd.addString(prompt, defaultString, columns: 20)
        if try showDialog(gd) {
            interp.done = true
            return ""
        }
        return try nextString(gd)
    }

    /// `getBoolean(prompt)`: Yes when nobody can answer (no options are read).
    func getBoolean() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        let prompt = try getString()
        var buttons = MacroPrompt.Buttons(yes: "  Yes  ", no: "  No  ")
        if interp.nextToken() == ch(",") {
            buttons.yes = try getNextString()
            buttons.no = try getNextString()
        }
        try interp.getRightParen()
        switch session.ask(MacroPrompt(kind: .question, title: promptTitle, message: prompt, yesNoButtons: buttons)) {
        case .cancel?:
            interp.done = true
            return 0
        case .no?:
            return 0
        default:
            return 1
        }
    }

    /// `waitForUser(title, message)`: waits for OK; nothing to wait for without a person.
    func waitForUser() throws(MacroSignal) {
        var title = "Action Required"
        var text = "   Click \"OK\" to continue     "
        if interp.nextToken() == ch("(") {
            title = try getFirstString()
            if interp.nextToken() == ch(",") {
                text = try getLastString()
            } else {
                text = title
                title = "Action Required"
                try interp.getRightParen()
            }
        }
        if session.ask(MacroPrompt(kind: .waitForUser, title: title, message: text)) == .cancel {
            throw .exit(message: nil)
        }
    }

    /// `DirectoryChooser(title)`: the folder the options give under the
    /// title's key, or a person's choice; with neither the macro stops, as
    /// ImageJ's `Macro.abort()` stops it when the chooser is canceled.
    func chooseDirectory(_ title: String) throws(MacroSignal) -> String {
        var directory = session.macroOptions.flatMap { MacroOptions($0 + " ").value(forLabel: title) }
        if directory == nil, case .path(let path)? = session.ask(MacroPrompt(kind: .directory, title: title)) {
            directory = path
        }
        guard let directory else { throw .exit(message: nil) }
        return Self.addSeparator(directory)
    }

    /// `OpenDialog(title, null)`: the file the options give under the
    /// title's key (or "path"), or a person's choice, as directory and name;
    /// `nil` when canceled.
    func chooseFile(_ title: String) -> (directory: String, name: String)? {
        var path: String?
        if let options = session.macroOptions.map({ MacroOptions($0 + " ") }) {
            path = options.value(forLabel: title)
            if path == nil || path == "" { path = options.value(forLabel: "path") }
            if let p = path, !javaContains(p, "."), !FileManager.default.fileExists(atPath: p) {
                // lookupPathVariable: a variable holding the path.
                let name = javaStartsWith(p, "&") ? javaSubstring(p, 1) : p
                if let s = interp.variable(named: name)?.getString() { path = s }
            }
        }
        if path == nil || path == "", case .path(let chosen)? = session.ask(MacroPrompt(kind: .openFile, title: title)) {
            path = chosen
        }
        guard let path, !path.isEmpty else { return nil }
        // decodePath
        var i = javaLastIndexOf(path, "/")
        if i == -1 { i = javaLastIndexOf(path, "\\") }
        let file = i > 0 ? (javaSubstring(path, 0, i + 1), javaSubstring(path, i + 1)) : ("", path)
        session.lastDirectory = file.0
        session.lastName = file.1
        return file
    }

    /// `File.openDialog(title)`: the chosen path; the macro stops when nothing was chosen.
    func openDialog() throws(MacroSignal) -> String {
        let title = try getStringArg()
        guard let file = chooseFile(title) else { throw .exit(message: nil) }
        return file.directory + file.name
    }

    /// `IJ.addSeparator(path)`.
    static func addSeparator(_ path: String) -> String {
        if !path.isEmpty && !(javaEndsWith(path, separator) || javaEndsWith(path, "/")) { return path + "/" }
        return path
    }
}

extension Interpreter {
    /// `getVariableAsString(name)`: a string variable's text, or a number as Java prints it.
    func variableAsString(named name: String) -> String? {
        guard let v = variable(named: name) else { return nil }
        if let s = v.getString() { return s }
        let value = v.getValue()
        return value.isNaN ? nil : javaString(value)
    }
}
