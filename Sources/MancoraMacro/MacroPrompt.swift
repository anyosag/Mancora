/// A dialog a macro shows, for ``MacroSession/onPrompt`` to put in front of
/// a person: `Dialog.create` ... `Dialog.show`, `getNumber`, `getString`,
/// `getBoolean`, `waitForUser`, and the folder and file choosers of
/// `getDirectory(title)`, `File.openDialog` and `open()`.
public struct MacroPrompt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A dialog of fields (ImageJ's `GenericDialog`), with OK and Cancel
        /// buttons, plus No when ``MacroPrompt/yesNoButtons`` is set.
        case dialog
        /// `getBoolean`: ``MacroPrompt/message`` with Yes, No and Cancel
        /// buttons, labeled ``MacroPrompt/yesNoButtons``.
        case question
        /// `waitForUser`: ``MacroPrompt/message`` with an OK button.
        case waitForUser
        /// A folder chooser; answer with ``Answer/path(_:)``.
        case directory
        /// A file chooser for opening; answer with ``Answer/path(_:)``.
        case openFile
    }

    /// A field of a dialog, holding its value: the default when asked, and
    /// what the person chose in the answer.
    public enum Field: Sendable, Equatable {
        case number(label: String, value: Double, decimalPlaces: Int, columns: Int, units: String?)
        case slider(label: String, minimum: Double, maximum: Double, value: Double, step: Double)
        case string(label: String, value: String, columns: Int)
        case directory(label: String, value: String)
        case file(label: String, value: String)
        case checkbox(label: String, value: Bool)
        /// `Dialog.addCheckboxGroup`: labels laid out in `rows` by `columns` (column by column).
        case checkboxGroup(rows: Int, columns: Int, labels: [String], values: [Bool])
        case choice(label: String, items: [String], value: String)
        case radioButtons(label: String, items: [String], rows: Int, columns: Int, value: String)
        /// A choice of the open images, by title.
        case imageChoice(label: String, titles: [String], value: String)
        case message(String, fontSize: Int?, color: String?)
        /// `Dialog.addHelp`: a URL or HTML text the Help button shows.
        case help(String)
        /// `Dialog.addImage`: the image file shown in the dialog.
        case image(path: String)
    }

    public struct Buttons: Sendable, Equatable {
        public var yes: String
        public var no: String

        public init(yes: String, no: String) {
            self.yes = yes
            self.no = no
        }
    }

    /// What the person did.
    public enum Answer: Sendable, Equatable {
        /// OK (or Yes), with the fields as the person left them.
        case ok([Field])
        /// No, in a dialog with Yes, No and Cancel buttons.
        case no([Field])
        /// Cancel: ImageJ then stops the macro (most prompts) or returns the default.
        case cancel
        /// The folder or file chosen in a chooser.
        case path(String)
    }

    public var kind: Kind
    public var title: String
    /// The text of a question or of `waitForUser`.
    public var message: String
    public var fields: [Field]
    /// The Yes and No buttons' labels: `getBoolean`'s, or `Dialog.enableYesNoCancel`'s.
    public var yesNoButtons: Buttons?
    /// `Dialog.createNonBlocking`: the macro's images stay usable while it's shown.
    public var nonBlocking: Bool

    public init(
        kind: Kind, title: String, message: String = "", fields: [Field] = [], yesNoButtons: Buttons? = nil,
        nonBlocking: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.fields = fields
        self.yesNoButtons = yesNoButtons
        self.nonBlocking = nonBlocking
    }
}
