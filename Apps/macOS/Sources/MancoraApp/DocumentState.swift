import AppKit
import SwiftUI

/// Unsaved changes, as ImageJ handles them: a changed image shows it in its
/// window's close button, and closing the window or quitting asks first.
struct ChangeTracking: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let changed = model.isChanged
        let model = model
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isDocumentEdited = changed
            if !(window.delegate is CloseQuestion) {
                let question = CloseQuestion(original: window.delegate, model: model)
                context.coordinator.question = question  // the window keeps its delegate weakly
                window.delegate = question
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var question: CloseQuestion?
    }
}

/// The window's delegate while it shows an image: it asks before closing
/// a changed image, and passes everything else to SwiftUI's own delegate.
final class CloseQuestion: NSObject, NSWindowDelegate {
    // Read from the Objective-C runtime's forwarding, on the main thread.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    weak var model: ViewerModel?

    init(original: (any NSWindowDelegate)?, model: ViewerModel) {
        self.original = original
        self.model = model
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let model, model.isChanged, !ChangeQuestions.mayClose(model) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}

enum ChangeQuestions {
    /// ImageJ's "Save changes to “title”?": Save, Don't Save or Cancel.
    @MainActor
    static func mayClose(_ model: ViewerModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(model.image?.title ?? "Untitled")”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = model.fileURL, ["tif", "tiff"].contains(url.pathExtension.lowercased()) {
                return model.saveNow(to: url)
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.tiff]
            let base = ((model.image?.title ?? "") as NSString).deletingPathExtension
            panel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + ".tif"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return model.saveNow(to: url)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Quitting with changed images asks once, as Fiji does.
    @MainActor
    static func mayQuit() -> Bool {
        let changed = AppSession.shared.imageViewers.filter(\.isChanged)
        guard !changed.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText =
            changed.count == 1
            ? "“\(changed[0].image?.title ?? "Untitled")” has unsaved changes."
            : "\(changed.count) images have unsaved changes."
        alert.informativeText = "Quit anyway? The changes will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ChangeQuestions.mayQuit() } ? .terminateNow : .terminateCancel
    }
}
