import AppKit
import SwiftUI

@main
struct MancoraApp: App {
    @State private var model = ViewerModel()

    init() {
        // `Mancora --smoke-test image.tif` checks that the packaged app
        // launches and can decode and render an image, then exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--smoke-test"), i + 1 < args.count {
            exit(ViewerModel.smokeTest(path: args[i + 1]) ? 0 : 1)
        }
        // Run from `swift run` there is no app bundle; make it a regular app
        // so it gets a Dock icon, a menu bar and keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mancora") {
            ViewerView(model: model)
                .frame(minWidth: 640, minHeight: 480)
                .onOpenURL { model.open($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
