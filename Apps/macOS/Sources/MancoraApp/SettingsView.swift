import Observation
import SwiftUI

// Mancora ▸ Settings (⌘,): a General pane for the app itself, and Fiji's.

enum SettingsTab: Hashable {
    case general
    case fiji
}

/// The pane in front, which the screenshot run sets to show Fiji's.
@Observable
final class SettingsSelection {
    static let shared = SettingsSelection()
    var tab = SettingsTab.general
}

struct SettingsView: View {
    @Bindable var updater: AppUpdater
    let bridge: AppBridge
    @Bindable private var selection = SettingsSelection.shared

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsView(updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            FijiSettingsView(bridge: bridge)
                .tabItem { Label("Fiji", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.fiji)
        }
    }
}

struct GeneralSettingsView: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) })
                )
            } footer: {
                Text("Mancora looks for a newer release on GitHub at most once a day.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 150)
    }
}
