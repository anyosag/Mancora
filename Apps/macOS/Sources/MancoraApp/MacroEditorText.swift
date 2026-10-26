import AppKit
import MancoraMacro
import SwiftUI

/// The editor's text: an `NSTextView` in a scroll view, as ImageJ's Editor
/// has a text area. The model keeps what the window knows about it.
struct MacroTextEditor: NSViewRepresentable {
    let model: MacroEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let model = model
        let textView = MacroTextView.make()
        textView.delegate = context.coordinator
        textView.onEvaluateLine = { [weak model] in model?.evaluateLine() }
        let scrollView = MacroScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        model.attach(textView)
        // Typing can start at once.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: MacroEditorModel

        init(model: MacroEditorModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MacroTextView else { return }
            textView.highlightSyntax()
            textView.markError(line: nil)
            model.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MacroTextView else { return }
            model.selectionDidChange(in: textView)
        }
    }
}

/// A scroll view that keeps its text view at least as tall as itself, so a click anywhere in the window is in the text.
final class MacroScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let textView = documentView as? NSTextView, textView.minSize.height != contentSize.height {
            textView.minSize = NSSize(width: 0, height: contentSize.height)
        }
    }
}

/// A plain-text view for ImageJ macros: monospaced, with none of the
/// substitutions that spoil code (smart quotes and dashes), and with the
/// macro language colored. The colors are the layout manager's temporary
/// attributes, so they never touch the text, its undo or its changes.
final class MacroTextView: NSTextView {
    /// ImageJ's Evaluate Line key, ⌘Y.
    var onEvaluateLine: (() -> Void)?
    // The text system's other objects, which nothing else in the stack is sure to keep alive.
    private var keptStorage: NSTextStorage?
    private var keptLayout: NSLayoutManager?

    static let keywords = MancoraMacro.vocabulary.keywords
    static let functions = MancoraMacro.vocabulary.functions
    /// Past this many characters the text isn't colored, to keep typing quick.
    private static let highlightLimit = 500_000

    /// A text view on its own TextKit 1 stack (the layout manager is what colors the text),
    /// that scrolls sideways instead of wrapping lines.
    static func make() -> MacroTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let big = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: big, height: big))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let textView = MacroTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.keptStorage = storage
        textView.keptLayout = layout
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: big, height: big)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Code, not prose.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        return textView
    }

    /// Replaces the text with a file's (or an empty one): nothing to undo back to.
    func show(_ text: String) {
        string = text
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        highlightSyntax()
        markError(line: nil)
    }

    /// Puts the caret at the start of line `line` and marks the line, as ImageJ does for a macro error.
    func show(errorAtLine line: Int) {
        guard let range = MacroSyntax.lineRange(ofLine: line, in: string) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        markError(line: line)
    }

    /// Tints the line of an error, or (with nil) removes the tint.
    func markError(line: Int?) {
        guard let layoutManager else { return }
        let text = string
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.utf16.count))
        guard let line, let range = MacroSyntax.lineRange(ofLine: line, in: text), range.length > 0 else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.2), forCharacterRange: range)
    }

    /// Colors comments, strings, numbers, keywords and built-in functions.
    func highlightSyntax() {
        guard let layoutManager else { return }
        let text = string
        let all = NSRange(location: 0, length: text.utf16.count)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard all.length <= Self.highlightLimit else { return }
        for span in MacroSyntax.spans(in: text, keywords: Self.keywords, functions: Self.functions) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Self.color(of: span.kind), forCharacterRange: span.range)
        }
    }

    private static func color(of kind: MacroSyntax.Kind) -> NSColor {
        switch kind {
        case .comment: .systemGreen
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPurple
        case .function: .systemTeal
        }
    }

    /// ⌘Y is Evaluate Line, as in ImageJ's editor. The menu bar gives that key to Edit ▸ Selection ▸
    /// Properties, but a window's views see key equivalents before the menu does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "y"
        {
            onEvaluateLine?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
