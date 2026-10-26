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

struct RoiManagerView: View {
    @Bindable var session: AppSession
    @State private var message: String?
    @State private var renaming = false
    @State private var newName = ""

    private var viewer: ViewerModel? { session.currentViewer }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            List(
                selection: Binding(
                    get: { Set(session.roiManager.selected) },
                    set: { session.selectInManager($0.sorted(), viewer: viewer) })
            ) {
                ForEach(Array(session.roiManager.entries.enumerated()), id: \.offset) { i, entry in
                    Text(entry.name).font(.callout.monospacedDigit()).tag(i)
                }
            }
            .frame(minWidth: 180)
            VStack(alignment: .leading, spacing: 6) {
                Button("Add [t]") { attempt { () throws(AppSession.ManagerError) in try session.addToManager(from: viewer) } }
                Button("Update") { attempt { () throws(AppSession.ManagerError) in try session.updateManager(from: viewer) } }
                Button("Delete") { session.deleteFromManager() }
                Button("Rename…") {
                    guard let i = session.roiManager.selected.first, session.roiManager.selected.count == 1 else {
                        message = "Exactly one item in the list must be selected."
                        return
                    }
                    newName = session.roiManager.entries[i].name
                    renaming = true
                }
                Button("Measure") { attempt { () throws(AppSession.ManagerError) in try session.measureManager(on: viewer) } }
                Button("Deselect") {
                    session.roiManager.selected = []
                    AppRecorder.shared.recordLine("roiManager(\"Deselect\");")
                }
                Divider()
                Button("Open…") { open() }
                Button("Save…") { save() }
                Divider()
                Toggle("Show All", isOn: $session.showsAllRois)
                    .onChange(of: session.showsAllRois) {
                        AppRecorder.shared.recordLine("roiManager(\"Show \(session.showsAllRois ? "All" : "None")\");")
                    }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 110, alignment: .leading)
        }
        .padding(12)
        .frame(minWidth: 320, minHeight: 300)
        .alert("ROI Manager", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $renaming) {
            Form {
                TextField("Rename as:", text: $newName)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }
                    Button("OK") {
                        attempt { () throws(AppSession.ManagerError) in try session.renameInManager(newName) }
                        renaming = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func attempt(_ action: () throws(AppSession.ManagerError) -> Void) {
        do throws(AppSession.ManagerError) {
            try action()
        } catch {
            message = error.text
        }
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
