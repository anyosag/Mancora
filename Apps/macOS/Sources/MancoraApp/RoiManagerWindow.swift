import AppKit
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraMacro
import SwiftUI
import UniformTypeIdentifiers

/// Analyze ▸ Tools ▸ ROI Manager: one list of selections for every image,
/// which macros share, as in ImageJ.
extension AppSession {
    /// Add [t]: the current image's selection, named after its position as
    /// ImageJ names it, and tied to the plane it was made on.
    func addToManager(from viewer: ViewerModel?) throws(ManagerError) {
        guard let viewer, let image = viewer.image else { throw .message("There are no images open.") }
        guard var roi = viewer.selection else { throw .message("The active image does not have a selection.") }
        let d = image.dimensions
        if image.stack.count > 1 && roi.position == .none {
            let isHyperstack = [d.channels, d.slices, d.frames].filter { $0 > 1 }.count > 1
            roi.position =
                isHyperstack
                ? .hyperstack(
                    channel: d.channels > 1 ? viewer.channel + 1 : 0, slice: d.slices > 1 ? viewer.slice + 1 : 0,
                    frame: d.frames > 1 ? viewer.frame + 1 : 0)
                : .stack(viewer.currentPlaneIndex + 1)
        }
        let name = roi.name ?? Self.managerLabel(roi, image: image, sliceNumber: viewer.currentPlaneIndex + 1)
        roi.name = name
        roiManager.entries.append(.init(name: name, roi: roi))
        AppRecorder.shared.recordLine("roiManager(\"Add\");")
    }

    /// Update: the selected entry takes the image's current selection.
    func updateManager(from viewer: ViewerModel?) throws(ManagerError) {
        guard roiManager.selected.count == 1, let i = roiManager.selected.first else {
            throw .message("Exactly one item in the list must be selected.")
        }
        guard var roi = viewer?.selection else { throw .message("The active image does not have a selection.") }
        roi.name = roiManager.entries[i].name
        roi.position = roiManager.entries[i].roi.position
        roiManager.entries[i].roi = roi
        AppRecorder.shared.recordLine("roiManager(\"Update\");")
    }

    /// Delete: the selected entries, or all of them.
    func deleteFromManager() {
        if roiManager.selected.isEmpty {
            roiManager = RoiManagerList()
        } else {
            let remove = Set(roiManager.selected)
            roiManager.entries = roiManager.entries.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
            roiManager.selected = []
        }
        AppRecorder.shared.recordLine("roiManager(\"Delete\");")
    }

    func renameInManager(_ name: String) throws(ManagerError) {
        guard roiManager.selected.count == 1, let i = roiManager.selected.first else {
            throw .message("Exactly one item in the list must be selected.")
        }
        roiManager.entries[i].name = name
        roiManager.entries[i].roi.name = name
        AppRecorder.shared.recordLine("roiManager(\"Rename\", \"\(MacroRecorder.escape(name))\");")
    }

    /// Clicking entries selects them; one selected entry becomes the image's
    /// selection, at its plane.
    func selectInManager(_ indexes: [Int], viewer: ViewerModel?) {
        roiManager.selected = indexes
        guard indexes.count == 1, let i = indexes.first, roiManager.entries.indices.contains(i) else { return }
        let roi = roiManager.entries[i].roi
        viewer?.show(roi)
        AppRecorder.shared.recordLine("roiManager(\"Select\", \(i));")
    }

    /// Measure: each selected entry (or every one) on the current image.
    func measureManager(on viewer: ViewerModel?) throws(ManagerError) {
        guard let viewer else { throw .message("There are no images open.") }
        let indexes = roiManager.selected.isEmpty ? Array(roiManager.entries.indices) : roiManager.selected
        guard !indexes.isEmpty else { throw .message("The ROI Manager is empty") }
        try viewer.measure(indexes.map { roiManager.entries[$0].roi })
        AppRecorder.shared.recordLine("roiManager(\"Measure\");")
    }

    func openInManager(_ url: URL) throws(ManagerError) {
        do {
            if url.pathExtension.lowercased() == "zip" {
                for entry in try RoiSet.read(path: url.path) { roiManager.entries.append(.init(name: entry.name, roi: entry.roi)) }
            } else {
                var roi = try RoiCodec.decode(Array(try Data(contentsOf: url)))
                let name = roi.name ?? url.deletingPathExtension().lastPathComponent
                roi.name = name
                roiManager.entries.append(.init(name: name, roi: roi))
            }
        } catch {
            throw .message("\(error)")
        }
        AppRecorder.shared.recordLine("roiManager(\"Open\", \"\(MacroRecorder.escape(url.path))\");")
    }

    /// Save: the selected entries (or all) as a `RoiSet.zip`, or one as a `.roi` file.
    func saveManager(to url: URL) throws(ManagerError) {
        let indexes = roiManager.selected.isEmpty ? Array(roiManager.entries.indices) : roiManager.selected
        let entries = indexes.map { RoiSet.Entry(name: roiManager.entries[$0].name, roi: roiManager.entries[$0].roi) }
        do {
            if url.pathExtension.lowercased() == "roi", let only = entries.first, entries.count == 1 {
                try Data(RoiCodec.encode(only.roi)).write(to: url)
            } else {
                try Data(RoiSet.encode(entries)).write(to: url)
            }
        } catch {
            throw .message("\(error)")
        }
        AppRecorder.shared.recordLine("roiManager(\"Save\", \"\(MacroRecorder.escape(url.path))\");")
    }

    /// `RoiManager.getLabel`: "yyyy-xxxx" from the selection's center, with
    /// the slice first for stacks.
    static func managerLabel(_ roi: Roi, image: Hyperstack, sliceNumber: Int) -> String {
        let r = roi.bounds
        let xc = max(r.x + r.width / 2, 0)
        let yc = max(r.y + r.height / 2, 0)
        var digits = max(4, String(xc).count, String(yc).count)
        if digits == 4 && (image.stack.count >= 10000 || image.height >= 10000) { digits = 5 }
        func padded(_ n: Int) -> String { String(("000000" + String(n)).suffix(digits)) }
        let label = padded(yc) + "-" + padded(xc)
        return image.stack.count > 1 ? padded(sliceNumber) + "-" + label : label
    }

    /// The manager's ROIs that belong on a plane, for Show All.
    func managerRois(on image: Hyperstack, channel: Int, slice: Int, frame: Int) -> [(index: Int, roi: Roi)] {
        let plane = image.dimensions.planeIndex(channel: channel, slice: slice, frame: frame) + 1
        return roiManager.entries.enumerated().compactMap { i, entry in
            switch entry.roi.position {
            case .none: return (i, entry.roi)
            case .stack(let n): return n == plane ? (i, entry.roi) : nil
            case .hyperstack(let c, let z, let t):
                let matches = (c == 0 || c == channel + 1) && (z == 0 || z == slice + 1) && (t == 0 || t == frame + 1)
                return matches ? (i, entry.roi) : nil
            }
        }
    }

    enum ManagerError: Error {
        case message(String)

        var text: String {
            switch self {
            case .message(let m): m
            }
        }
    }
}

extension ViewerModel {
    /// The plane shown, as an index into the stack.
    var currentPlaneIndex: Int {
        image.map { $0.dimensions.planeIndex(channel: channel, slice: slice, frame: frame) } ?? 0
    }

    /// Makes `roi` the selection and moves to its plane, as choosing it in
    /// the ROI Manager does.
    func show(_ roi: Roi) {
        guard let image else { return }
        let d = image.dimensions
        switch roi.position {
        case .none: break
        case .stack(let n):
            if n >= 1 && n <= image.stack.count {
                (channel, slice, frame) = d.position(ofPlane: n - 1)
            }
        case .hyperstack(let c, let z, let t):
            if c > 0 { channel = min(c, d.channels) - 1 }
            if z > 0 { slice = min(z, d.slices) - 1 }
            if t > 0 { frame = min(t, d.frames) - 1 }
        }
        storeSelection(roi)
        positionChanged()
    }

    /// Measures each ROI at its plane, natively, into the session's results.
    func measure(_ rois: [Roi]) throws(AppSession.ManagerError) {
        guard let image else { throw .message("There are no images open.") }
        let session = AppSession.shared
        var context = CommandContext()
        context.results = session.results
        context.tables = session.tables
        context.settings = session.settings
        context.add(image)
        let d = image.dimensions
        let (c0, z0, t0) = (channel, slice, frame)
        do throws(CommandError) {
            for roi in rois {
                try context.withCurrent("Measure") { (open: inout OpenImage) in
                    (open.channel, open.slice, open.frame) = (c0, z0, t0)
                    switch roi.position {
                    case .none: break
                    case .stack(let n):
                        if n >= 1 && n <= open.image.stack.count { (open.channel, open.slice, open.frame) = d.position(ofPlane: n - 1) }
                    case .hyperstack(let c, let z, let t):
                        if c > 0 { open.channel = min(c, d.channels) - 1 }
                        if z > 0 { open.slice = min(z, d.slices) - 1 }
                        if t > 0 { open.frame = min(t, d.frames) - 1 }
                    }
                    open.roi = roi
                }
                try CommandRegistry.standard.run("Measure", options: MacroOptions(""), in: &context)
            }
        } catch {
            throw .message("\(error)")
        }
        session.absorb(context)
    }
}

// MARK: Window

extension Roi {
    /// The SF Symbol for the ROI's type in the ROI Manager's list.
    var roiManagerSymbol: String {
        switch shape {
        case .rectangle:
            return "rectangle"
        case .oval:
            return "oval"
        case .polygon(let polygon):
            switch polygon.kind {
            case .polygon: return "pentagon"
            case .freehand: return "hand.draw"
            case .traced: return "wand.and.rays"
            case .polyline: return "waveform.path"
            case .freeline: return "scribble"
            case .angle: return "angle"
            }
        case .line(let line):
            return line.arrow == nil ? "line.diagonal" : "line.diagonal.arrow"
        case .points:
            return "smallcircle.filled.circle"
        case .opaque(let opaque):
            switch opaque.kind {
            case .composite: return "square.on.circle"
            case .text: return "textformat"
            case .image: return "photo"
            }
        }
    }

    /// The plane a ROI is tied to, as the list says it, or `nil` for a ROI on every plane.
    var roiManagerPosition: String? {
        switch position {
        case .none:
            return nil
        case .stack(let n):
            return "Slice \(n)"
        case .hyperstack(let c, let z, let t):
            var parts: [String] = []
            if c > 0 { parts.append("C\(c)") }
            if z > 0 { parts.append("Z\(z)") }
            if t > 0 { parts.append("T\(t)") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}

/// One row of the ROI Manager's list: the ROI's type, its name, and the plane it belongs to.
private struct RoiRow: View {
    let entry: RoiManagerList.Entry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.roi.roiManagerSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(entry.name)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            if let position = entry.roi.roiManagerPosition {
                Text(position)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The ROI Manager: a list of the selections, with + and − and an actions menu under it,
/// and Show All in the toolbar.
struct RoiManagerView: View {
    @Bindable var session: AppSession
    @State private var message: String?
    @State private var renaming = false
    @State private var newName = ""

    private var viewer: ViewerModel? { session.currentViewer }

    var body: some View {
        VStack(spacing: 0) {
            roiList
            Divider()
            bottomBar
        }
        .frame(minWidth: 300, minHeight: 260)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $session.showsAllRois) {
                    Label("Show All", systemImage: "eye").labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .help("Show All: draw every ROI in the list on the image")
            }
        }
        .onChange(of: session.showsAllRois) {
            AppRecorder.shared.recordLine("roiManager(\"Show \(session.showsAllRois ? "All" : "None")\");")
        }
        .alert("ROI Manager", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $renaming) {
            RoiRenameSheet(name: $newName, cancel: { renaming = false }, commit: commitRename)
        }
    }

    // MARK: List

    private var roiList: some View {
        List(
            selection: Binding(
                get: { Set(session.roiManager.selected) },
                set: { session.selectInManager($0.sorted(), viewer: viewer) })
        ) {
            ForEach(Array(session.roiManager.entries.enumerated()), id: \.offset) { i, entry in
                RoiRow(entry: entry).tag(i)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        // A double click on a row renames it.
        .contextMenu(forSelectionType: Int.self, menu: { _ in EmptyView() }, primaryAction: { items in renameRow(items) })
        .overlay {
            if session.roiManager.entries.isEmpty {
                ContentUnavailableView(
                    "No ROIs", systemImage: "square.dashed",
                    description: Text("Make a selection on an image, then click + to add it."))
            }
        }
    }

    private func renameRow(_ items: Set<Int>) {
        guard items.count == 1, let i = items.first, session.roiManager.entries.indices.contains(i) else { return }
        // The first click of the double click has selected the row; rename acts on the selection.
        if session.roiManager.selected != [i] { session.roiManager.selected = [i] }
        beginRename()
    }

    // MARK: Bottom bar

    /// + and − and the other actions, in the style of the lists in System Settings.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                attempt { () throws(AppSession.ManagerError) in try session.addToManager(from: viewer) }
            } label: {
                Label("Add [t]", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Add the image's selection to the list [t]")
            Button {
                session.deleteFromManager()
            } label: {
                Label("Delete", systemImage: "minus")
                    .labelStyle(.iconOnly)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Delete the selected ROIs, or all of them if none is selected")
            Menu {
                Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                    attempt { () throws(AppSession.ManagerError) in try session.updateManager(from: viewer) }
                }
                Button("Rename…", systemImage: "pencil") { beginRename() }
                Button("Measure", systemImage: "ruler") {
                    attempt { () throws(AppSession.ManagerError) in try session.measureManager(on: viewer) }
                }
                Button("Deselect", systemImage: "xmark.circle") { deselect() }
                Divider()
                Button("Open…", systemImage: "folder") { open() }
                Button("Save…", systemImage: "square.and.arrow.down") { save() }
            } label: {
                Label("More Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Update, Rename, Measure, Deselect, Open and Save")
            Spacer()
            Text(summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var summary: String {
        let total = session.roiManager.count
        let selected = session.roiManager.selected.count
        if total == 0 { return "" }
        if selected > 0 { return "\(selected) of \(total) selected" }
        return total == 1 ? "1 ROI" : "\(total) ROIs"
    }

    // MARK: Actions

    private func attempt(_ action: () throws(AppSession.ManagerError) -> Void) {
        do throws(AppSession.ManagerError) {
            try action()
        } catch {
            message = error.text
        }
    }

    private func deselect() {
        session.roiManager.selected = []
        AppRecorder.shared.recordLine("roiManager(\"Deselect\");")
    }

    private func beginRename() {
        guard let i = session.roiManager.selected.first, session.roiManager.selected.count == 1,
            session.roiManager.entries.indices.contains(i)
        else {
            message = "Exactly one item in the list must be selected."
            return
        }
        newName = session.roiManager.entries[i].name
        renaming = true
    }

    private func commitRename() {
        attempt { () throws(AppSession.ManagerError) in try session.renameInManager(newName) }
        renaming = false
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "roi") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { () throws(AppSession.ManagerError) in try session.openInManager(url) }
    }

    private func save() {
        let panel = NSSavePanel()
        let one = session.roiManager.selected.count == 1
        panel.allowedContentTypes = [one ? UTType(filenameExtension: "roi") ?? .data : .zip]
        panel.nameFieldStringValue = one ? "\(session.roiManager.entries[session.roiManager.selected[0]].name).roi" : "RoiSet.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { () throws(AppSession.ManagerError) in try session.saveManager(to: url) }
    }
}

/// Rename…: the new name for the selected ROI.
private struct RoiRenameSheet: View {
    @Binding var name: String
    let cancel: () -> Void
    let commit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename as:")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}
