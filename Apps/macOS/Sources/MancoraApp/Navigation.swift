import AppKit
import MancoraCore
import SwiftUI

/// Moving through a stack and zooming from the keyboard, as ImageJ's
/// `ImageJ.keyPressed` does on an image window.
extension ViewerModel {
    /// Next Slice [>] (`step` 1) and Previous Slice [<] (-1): ImageJ's
    /// `Animator.nextSlice`. A hyperstack moves its channel first (its z,
    /// or its frame, with Control or Alt), then z, then t; a plain stack
    /// moves one plane, or ten with Alt.
    func step(_ delta: Int, alt: Bool = false, control: Bool = false) {
        guard let image else { return }
        let d = image.dimensions
        let hyperstack = d.channels > 1 || [d.slices, d.frames].filter { $0 > 1 }.count > 1
        func clamp(_ v: Int, _ count: Int) -> Int { min(max(v, 0), count - 1) }
        if hyperstack && d.channels > 1 && !((d.slices > 1 || d.frames > 1) && (control || alt)) {
            channel = clamp(channel + delta, d.channels)
        } else if hyperstack && d.slices > 1 && !(d.frames > 1 && alt) {
            slice = clamp(slice + delta, d.slices)
        } else if hyperstack && d.frames > 1 {
            frame = clamp(frame + delta, d.frames)
        } else {
            let plane = clamp(currentPlaneIndex + delta * (alt ? 10 : 1), image.stack.count)
            (channel, slice, frame) = d.position(ofPlane: plane)
        }
        positionChanged()
    }

    /// The arrow keys: ← → move through a stack without a selection (or
    /// with Shift), ↑ ↓ zoom without one; with a selection they nudge it a
    /// pixel (`Roi.nudge`).
    func arrow(_ key: KeyEquivalent, shift: Bool, control: Bool) -> Bool {
        guard let image else { return false }
        let roi = selection
        let stackKey = image.stack.count > 1 && (roi == nil || shift)
        let zoomKey = roi == nil || shift || control
        switch key {
        case .rightArrow where stackKey: step(1)
        case .leftArrow where stackKey: step(-1)
        case .downArrow where zoomKey: zoom(by: 0.5)
        case .upArrow where zoomKey: zoom(by: 2)
        default:
            guard let roi else { return false }
            let (dx, dy): (Int32, Int32) =
                switch key {
                case .leftArrow: (-1, 0)
                case .rightArrow: (1, 0)
                case .upArrow: (0, -1)
                default: (0, 1)
                }
            setSelection(roi.translated(dx: dx, dy: dy))
        }
        return true
    }
}

/// The key handling for an image window's canvas.
struct NavigationKeys: ViewModifier {
    let model: ViewerModel

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: CharacterSet(charactersIn: ",.<>+=-")) { press in
                let alt = press.modifiers.contains(.option), control = press.modifiers.contains(.control)
                switch press.characters {
                case ",", "<": model.step(-1, alt: alt, control: control)
                case ".", ">": model.step(1, alt: alt, control: control)
                case "+", "=": model.zoom(by: 2)
                case "-": model.zoom(by: 0.5)
                default: return .ignored
                }
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                model.arrow(press.key, shift: press.modifiers.contains(.shift), control: press.modifiers.contains(.control))
                    ? .handled : .ignored
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                // Backspace clears the selection's pixels (Edit ▸ Clear), as in ImageJ.
                guard press.modifiers.isEmpty, model.selection != nil, let bridge = model.bridge else { return .ignored }
                Task { _ = await model.perform("Clear", bridge: bridge) }
                return .handled
            }
    }
}
