import AppKit
import SwiftUI

@main
struct MancoraApp: App {
    @State private var model = ViewerModel()

    init() {
        // Run from `swift run` there is no app bundle; make it a regular app
        // so it gets a Dock icon, a menu bar and keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mancora") {
            ViewerView(model: model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
