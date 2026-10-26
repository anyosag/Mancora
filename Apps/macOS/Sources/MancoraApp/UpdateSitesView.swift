import Foundation
import MancoraBridge
import MancoraCore
import MancoraFiji
import MancoraPlugins
import MancoraUpdate
import Observation
import SwiftUI

/// Plugins ▸ Manage Update Sites: the update sites of the installation the
/// Java bridge runs in: Fiji's own once Fiji is installed (applied through
/// `FijiManager`, which updates a copy and swaps it in, so a running Fiji is
/// never changed under it), else the folder a plain ImageJ keeps its plugins in.
/// As in Fiji's updater, enabling a site plans its files for installation and
/// disabling one plans their removal; nothing changes on disk until Apply.
@Observable
final class AppUpdateSites {
    static let shared = AppUpdateSites()

    nonisolated struct Site: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        let url: String
        var isActive: Bool
        /// What the site offers, in a line, when the site or Mancora says.
        var summary: String? = nil
    }

    private(set) var sites: [Site] = []
    private(set) var changes: [PluginManager.Change] = []
    private(set) var conflicts: [String] = []
    private(set) var warnings: [String] = []
    private(set) var isBusy = false
    private(set) var hasChecked = false
    /// What happened to Fiji when the last changes were applied.
    private(set) var notice: String?
    var errorMessage: String?
    /// Sites to disable or remove at the next Apply.
    private(set) var pendingDisable: Set<String> = []
    private(set) var pendingRemove: Set<String> = []
    /// A made-up list is shown (the screenshot run's).
    private(set) var isPreview = false

    /// The sites are Fiji's own: Fiji is installed.
    var usesFiji: Bool { isPreview || FijiState.shared.isInstalled }

    /// The installation whose `db.xml.gz` holds the sites.
    var root: URL { FijiState.shared.isInstalled && !isPreview ? FijiManager.shared.root : BridgeHome.standard().root }

    nonisolated static func client() -> URLSessionHTTPClient {
        URLSessionHTTPClient(userAgent: "Mancora/\(MancoraVersion.number)")
    }

    func reload() {
        guard !isPreview else { return }
        do {
            let manager = try PluginManager(root: root)
            sites = manager.sites.map { site in
                Site(name: site.name, url: site.url, isActive: site.isActive, summary: Self.summary(of: site))
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The site's own description, else what Mancora knows of a well-known site.
    private static func summary(of site: UpdateSite) -> String? {
        if let text = site.siteDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        return KnownSites.all.first { $0.name == site.name }?.description
    }

    /// Fiji's sites as a new Fiji has them, for the screenshot run: nothing is read or written.
    func showPreview() {
        isPreview = true
        let enabled: Set<String> = ["ImageJ", "Fiji", "Java-8"]
        sites = KnownSites.all.map { known in
            Site(name: known.name, url: known.url, isActive: enabled.contains(known.name), summary: known.description)
        }
        errorMessage = nil
    }

    func endPreview() {
        isPreview = false
        sites = []
        reload()
    }

    func isShownActive(_ site: Site) -> Bool { site.isActive && !pendingDisable.contains(site.name) }

    func setActive(_ site: Site, _ active: Bool) {
        guard !isPreview else { return }
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
            notice = nil
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
        if usesFiji {
            await applyToFiji(bridge: bridge)
            return
        }
        await work(apply: true)
        if errorMessage == nil { await bridge.stop() }
    }

    /// Fiji's way: the changes are made to a copy of the installation, which is swapped in now or,
    /// if a helper is running, before the next one starts.
    private func applyToFiji(bridge: AppBridge) async {
        isBusy = true
        notice = nil
        defer { isBusy = false }
        let disable = pendingDisable, removals = pendingRemove
        do {
            let outcome = try await FijiManager.shared.applyUpdates(siteChanges: { manager in
                for name in disable { try manager.setActive(name, false) }
                for name in removals { try manager.removeSite(name) }
            })
            changes = []
            conflicts = []
            warnings = []
            pendingDisable = []
            pendingRemove = []
            hasChecked = false
            errorMessage = nil
            switch outcome {
            case .upToDate:
                notice = "Fiji is up to date."
            case .applied:
                notice = "Fiji was updated. Its plugins load the next time it starts."
            case .staged:
                notice = "Fiji was updated. The changes are installed as Fiji restarts."
            }
            reload()
            if outcome != .upToDate {
                // A helper running keeps the update waiting; a new one takes it in, and its menus.
                Task { await bridge.restart() }
            }
        } catch {
            errorMessage = FijiText.describe(error)
        }
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
            header
            Table(model.sites.filter { !model.pendingRemove.contains($0.name) }, selection: $selection) {
                TableColumn("Enabled") { site in
                    Toggle("", isOn: Binding(get: { model.isShownActive(site) }, set: { model.setActive(site, $0) }))
                        .labelsHidden()
                        .accessibilityLabel(site.name)
                }
                .width(56)
                TableColumn("Name", value: \.name)
                    .width(min: 90, ideal: 120)
                TableColumn("Description") { site in
                    Text(site.summary ?? "")
                        .lineLimit(1)
                        .help(site.summary ?? "")
                }
                .width(min: 160, ideal: 260)
                TableColumn("URL") { site in
                    Text(site.url)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
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
        .frame(minWidth: 700, minHeight: 420)
        .onAppear { model.reload() }
        .sheet(isPresented: $showsAdd) {
            AddUpdateSiteView { name, url in model.add(name: name, url: url) }
        }
    }

    @ViewBuilder private var header: some View {
        if model.usesFiji {
            Text("Fiji’s update sites provide its plugins and libraries. Turn a site on to install what it offers; Apply Changes puts the changes into Fiji, and it keeps them up to date.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Update sites install ImageJ plugins into \(model.root.path), which the Java bridge runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
