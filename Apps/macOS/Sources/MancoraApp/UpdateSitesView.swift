import Foundation
import MancoraBridge
import MancoraCore
import MancoraPlugins
import MancoraUpdate
import Observation
import SwiftUI

/// Plugins ▸ Manage Update Sites: Fiji's update sites for the Java bridge's
/// folder. As in Fiji's updater, enabling a site plans its files for
/// installation and disabling one plans their removal; nothing changes on
/// disk until Apply.
@Observable
final class AppUpdateSites {
    nonisolated struct Site: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        let url: String
        var isActive: Bool
    }

    private(set) var sites: [Site] = []
    private(set) var changes: [PluginManager.Change] = []
    private(set) var conflicts: [String] = []
    private(set) var warnings: [String] = []
    private(set) var isBusy = false
    private(set) var hasChecked = false
    var errorMessage: String?
    /// Sites to disable or remove at the next Apply.
    private(set) var pendingDisable: Set<String> = []
    private(set) var pendingRemove: Set<String> = []

    let root = BridgeHome.standard().root

    nonisolated static func client() -> URLSessionHTTPClient {
        URLSessionHTTPClient(userAgent: "Mancora/\(MancoraVersion.number)")
    }

    func reload() {
        do {
            let manager = try PluginManager(root: root)
            sites = manager.sites.map { Site(name: $0.name, url: $0.url, isActive: $0.isActive) }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func isShownActive(_ site: Site) -> Bool { site.isActive && !pendingDisable.contains(site.name) }

    func setActive(_ site: Site, _ active: Bool) {
        if active {
            pendingDisable.remove(site.name)
            guard !site.isActive else { return }
            edit { try $0.setActive(site.name, true) }
        } else if site.isActive {
            pendingDisable.insert(site.name)
            hasChecked = false
        }
    }

    func add(name: String, url: String?) {
        edit { try $0.addSite(name: name, url: url?.isEmpty == false ? url : nil) }
    }

    func remove(_ site: Site) {
        pendingRemove.insert(site.name)
        hasChecked = false
    }

    /// Changes the site list on disk (adding and enabling only plan installs).
    private func edit(_ change: (PluginManager) throws -> Void) {
        do {
            let manager = try PluginManager(root: root)
            try change(manager)
            try manager.save()
            hasChecked = false
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Reads the sites and lists what Apply would change.
    func check() async {
        await work(apply: false)
    }

    /// Downloads, verifies and installs; then the bridge restarts to load the plugins.
    func apply(bridge: AppBridge) async {
        await work(apply: true)
        if errorMessage == nil { await bridge.stop() }
    }

    private func work(apply: Bool) async {
        isBusy = true
        defer { isBusy = false }
        let root = root, disable = pendingDisable, removals = pendingRemove
        let outcome = await Task.detached { () -> Result<Outcome, AppError> in
            do {
                let manager = try PluginManager(root: root)
                let client = AppUpdateSites.client()
                try await manager.refresh(client: client)
                for name in disable { try manager.setActive(name, false) }
                for name in removals { try manager.removeSite(name) }
                let (changes, conflicts) = manager.plan()
                if apply { try await manager.apply(client: client) }
                return .success(Outcome(changes: changes, conflicts: conflicts.map(\.description), warnings: manager.warnings))
            } catch {
                return .failure(AppError(message: "\(error)"))
            }
        }.value
        switch outcome {
        case .success(let result):
            changes = apply ? [] : result.changes
            conflicts = result.conflicts
            warnings = result.warnings
            hasChecked = !apply
            if apply {
                pendingDisable = []
                pendingRemove = []
            }
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.message
        }
        reload()
    }

    nonisolated struct Outcome: Sendable {
        let changes: [PluginManager.Change]
        let conflicts: [String]
        let warnings: [String]
    }

    nonisolated struct AppError: Error, Sendable {
        let message: String
    }
}

struct UpdateSitesView: View {
    @Bindable var model: AppUpdateSites
    let bridge: AppBridge
    @State private var showsAdd = false
    @State private var selection: AppUpdateSites.Site.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update sites install ImageJ plugins into \(model.root.path), which the Java bridge runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Table(model.sites.filter { !model.pendingRemove.contains($0.name) }, selection: $selection) {
                TableColumn("Enabled") { site in
                    Toggle("", isOn: Binding(get: { model.isShownActive(site) }, set: { model.setActive(site, $0) }))
                        .labelsHidden()
                }
                .width(56)
                TableColumn("Name", value: \.name)
                TableColumn("URL", value: \.url)
            }
            .frame(minHeight: 160)
            HStack {
                Button("Add Site…") { showsAdd = true }
                Button("Remove") {
                    if let site = model.sites.first(where: { $0.id == selection }) { model.remove(site) }
                }
                .disabled(selection == nil)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Check for Changes") { Task { await model.check() } }
                    .disabled(model.isBusy)
                Button("Apply Changes") { Task { await model.apply(bridge: bridge) } }
                    .disabled(model.isBusy || !model.hasChecked || (model.changes.isEmpty && model.pendingDisable.isEmpty && model.pendingRemove.isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(model.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            ForEach(model.conflicts, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            if model.hasChecked {
                if model.changes.isEmpty {
                    Text("Everything is up to date.").foregroundStyle(.secondary)
                } else {
                    List(model.changes, id: \.filename) { change in
                        HStack {
                            Text(change.kind.rawValue.capitalized).frame(width: 72, alignment: .leading)
                            Text(change.filename)
                            Spacer()
                            Text(change.site ?? "").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .frame(minHeight: 140)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { model.reload() }
        .sheet(isPresented: $showsAdd) {
            AddUpdateSiteView { name, url in model.add(name: name, url: url) }
        }
    }
}

struct AddUpdateSiteView: View {
    let add: (String, String?) -> Void
    @State private var name = ""
    @State private var url = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Picker("Known site", selection: $name) {
                Text("Other…").tag("")
                ForEach(KnownSites.all, id: \.name) { site in Text(site.name).tag(site.name) }
            }
            .onChange(of: name) { _, chosen in
                if let known = KnownSites.url(for: chosen) { url = known }
            }
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    add(name, url)
                    dismiss()
                }
                .disabled(name.isEmpty || (url.isEmpty && KnownSites.url(for: name) == nil))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
