import AppKit
import MancoraCore
import SwiftUI

/// One viewer window. Each window has its own image, as in ImageJ.
struct ViewerWindow: View {
    @Binding var request: OpenRequest?
    let bridge: AppBridge
    @State private var model = ViewerModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ViewerView(model: model, showsInspector: $model.showsInspector)
            .frame(minWidth: 720, minHeight: 520)
            .sheet(isPresented: $model.showsCommandFinder) {
                CommandFinder(model: model, bridge: bridge) { urls in
                    for url in urls { openWindow(id: "viewer", value: OpenRequest(url: url)) }
                }
            }
            .sheet(
                isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })
            ) {
                ReportView(text: model.report ?? "")
            }
            .sheet(item: $model.pendingDialog) { pending in
                CommandDialogView(pending: pending) { options in
                    Task { show(await model.runRecorded(pending.command, options: options, bridge: bridge)) }
                }
            }
            .focusedSceneValue(\.viewer, model)
            .background(ChangeTracking(model: model))
            .onChange(of: activeState, initial: true) {
                if activeState == .key { AppSession.shared.activate(model) }
            }
            .task(id: request) {
                model.bridge = bridge
                model.undoManager = undoManager
                if let request {
                    model.open(request)
                } else if let command = CommandQueue.shared.take() {
                    show(await model.perform(command, bridge: bridge))
                }
            }
            .onChange(of: AppSession.shared.resultsAdded) { openWindow(id: "results") }
            .onChange(of: AppSession.shared.logAdded) { openWindow(id: "log") }
            .onChange(of: AppSession.shared.requestedWindow?.serial) {
                if activeState == .key, let id = AppSession.shared.requestedWindow?.id { openWindow(id: id) }
            }
            .onOpenURL { url in
                model.bridge = bridge
                // Files opened from the Finder: fill this window if it's empty.
                if model.hasImage {
                    openWindow(id: "viewer", value: OpenRequest(url: url))
                } else {
                    model.open(OpenRequest(url: url))
                }
            }
    }
}

extension ViewerWindow {
    /// New images: the first fills this window if it's empty, the others get their own.
    func show(_ urls: [URL]) {
        var rest = urls[...]
        if !model.hasImage, let first = rest.popFirst() { model.open(OpenRequest(url: first)) }
        for url in rest { openWindow(id: "viewer", value: OpenRequest(url: url)) }
    }
}

struct ViewerView: View {
    @Bindable var model: ViewerModel
    @Binding var showsInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let image = model.image, let bitmap = model.rendered {
                ImageCanvas(model: model, bitmap: bitmap, imageSize: CGSize(width: image.width, height: image.height))
                Divider()
                StatusBar(model: model, image: image)
            } else if model.isBusy {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Image", systemImage: "photo")
                } description: {
                    Text("Open an image to view it: TIFF natively, other formats through ImageJ.")
                } actions: {
                    Button("Open…") {
                        if let url = model.presentOpenPanel() { model.open(OpenRequest(url: url)) }
                    }
                }
            }
        }
        .navigationTitle(model.image?.title ?? "Mancora")
        .inspector(isPresented: $showsInspector) {
            DisplayInspector(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolPicker(session: AppSession.shared)
            }
            ToolbarItem {
                Menu("LUT", systemImage: "paintpalette") {
                    ForEach(LUT.builtIn, id: \.name) { lut in
                        Button(lut.name) { model.apply(lut) }
                    }
                    if !ViewerModel.bundledLUTs.isEmpty {
                        Divider()
                        ForEach(ViewerModel.bundledLUTs, id: \.url) { item in
                            Button(item.name) { model.applyLUT(at: item.url) }
                        }
                    }
                    Divider()
                    Button("Open LUT File…") { model.presentLUTPanel() }
                }
                .disabled(!model.canAdjustContrast)
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
            }
        }
        .alert(
            "Mancora",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The image at the current zoom, with nearest-neighbour magnification, a
/// pixel readout under the pointer, and the selection tools.
struct ImageCanvas: View {
    @Bindable var model: ViewerModel
    let bitmap: CGImage
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let scale = displayScale(in: geometry.size)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let tool = AppSession.shared.tool
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: bitmap, scale: 1)
                    .interpolation(scale >= 1 ? .none : .medium)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        SelectionOverlay(
                            selection: model.selection, draft: model.draft, vertices: model.vertices,
                            pointer: model.pointer, tool: tool, scale: scale, others: managerRois)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.drag(
                                    from: pixel(value.startLocation, scale), to: pixel(value.location, scale), tool: tool,
                                    shift: NSEvent.modifierFlags.contains(.shift))
                            }
                            .onEnded { value in
                                model.endDrag(
                                    at: pixel(value.location, scale), tool: tool, clicks: NSApp.currentEvent?.clickCount ?? 1,
                                    option: NSEvent.modifierFlags.contains(.option))
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): model.pointerMoved(to: point, displaySize: size)
                        case .ended: model.pointerMoved(to: nil, displaySize: size)
                        }
                    }
                    .frame(
                        minWidth: geometry.size.width, minHeight: geometry.size.height
                    )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.escape) {
                guard !model.vertices.isEmpty else { return .ignored }
                model.cancelVertices()
                return .handled
            }
            .onKeyPress(.return) {
                guard !model.vertices.isEmpty else { return .ignored }
                model.finishVertices(tool)
                return .handled
            }
        }
    }

    /// The ROI Manager's ROIs for this plane, when Show All is on.
    private var managerRois: [(index: Int, roi: Roi)] {
        let session = AppSession.shared
        guard session.showsAllRois, let image = model.image else { return [] }
        return session.managerRois(on: image, channel: model.channel, slice: model.slice, frame: model.frame)
    }

    /// A point on the displayed image, in pixels.
    private func pixel(_ point: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x / scale, y: point.y / scale)
    }

    private func displayScale(in available: CGSize) -> CGFloat {
        switch model.zoom {
        case .scale(let s):
            return s
        case .fit:
            let margin: CGFloat = 16
            let fit = min(
                (available.width - margin) / max(imageSize.width, 1),
                (available.height - margin) / max(imageSize.height, 1))
            return max(min(fit, 32), 1 / 64)
        }
    }
}

/// Channel, slice and frame sliders (for dimensions above 1) and the pointer readout.
struct StatusBar: View {
    @Bindable var model: ViewerModel
    let image: Hyperstack

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let dims = image.dimensions
            if dims.channels > 1 {
                PositionSlider(label: "c", value: $model.channel, count: dims.channels)
            }
            if dims.slices > 1 {
                PositionSlider(label: "z", value: $model.slice, count: dims.slices)
            }
            if dims.frames > 1 {
                PositionSlider(label: "t", value: $model.frame, count: dims.frames)
            }
            HStack {
                Text(model.selectionText ?? model.pointerText ?? summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.channel) { model.positionChanged() }
        .onChange(of: model.slice) { model.positionChanged() }
        .onChange(of: model.frame) { model.positionChanged() }
    }

    private var summary: String {
        var parts = ["\(image.width)×\(image.height)", "\(image.pixelType.bitDepth)-bit"]
        if image.stack.count > 1 { parts.append("\(image.stack.count) planes") }
        if image.stack.isVirtual { parts.append("virtual") }
        return parts.joined(separator: " · ")
    }
}

/// An ImageJ-style position scrollbar with step buttons.
struct PositionSlider: View {
    let label: String
    @Binding var value: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(label) \(value + 1)/\(count)")
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .leading)
            Button("Previous", systemImage: "chevron.left") { value = max(value - 1, 0) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: 0...Double(count - 1),
                step: 1
            )
            Button("Next", systemImage: "chevron.right") { value = min(value + 1, count - 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// Brightness & contrast, channels, and image information.
struct DisplayInspector: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Form {
            if let image = model.image {
                if image.pixelType.usesLUT {
                    contrastSection(image)
                }
                if model.showsThreshold && image.pixelType != .rgb8 {
                    ThresholdSection(model: model)
                }
                if image.dimensions.channels > 1 {
                    channelsSection(image)
                }
                infoSection(image)
            } else {
                Text("No image").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func contrastSection(_ image: Hyperstack) -> some View {
        let bounds = model.sliderBounds
        let range = model.displayRange
        let step = image.pixelType == .gray32Float ? 0 : 1.0
        return Section("Brightness & Contrast") {
            RangeSlider(
                title: "Minimum",
                value: Binding(
                    get: { range.lowerBound },
                    set: { model.setDisplayRange(min($0, range.upperBound)...range.upperBound) }),
                bounds: bounds, step: step)
            RangeSlider(
                title: "Maximum",
                value: Binding(
                    get: { range.upperBound },
                    set: { model.setDisplayRange(range.lowerBound...max($0, range.lowerBound)) }),
                bounds: bounds, step: step)
            HStack {
                Button("Auto") { model.autoContrast() }
                Button("Reset") { model.resetContrast() }
                Spacer()
                Text(image.channels[model.channel].lut.name).foregroundStyle(.secondary)
            }
        }
    }

    private func channelsSection(_ image: Hyperstack) -> some View {
        Section("Channels") {
            Picker(
                "Mode",
                selection: Binding(get: { image.compositeMode }, set: { model.setCompositeMode($0) })
            ) {
                Text("Composite").tag(CompositeMode.composite)
                Text("Color").tag(CompositeMode.color)
                Text("Grayscale").tag(CompositeMode.grayscale)
            }
            ForEach(0..<image.dimensions.channels, id: \.self) { c in
                Toggle(
                    "\(c + 1): \(image.channels[c].lut.name)",
                    isOn: Binding(get: { image.channels[c].isVisible }, set: { model.setChannelVisible($0, channel: c) })
                )
                .disabled(image.compositeMode != .composite)
            }
        }
    }

    private func infoSection(_ image: Hyperstack) -> some View {
        let cal = image.calibration
        return Section("Image") {
            LabeledContent("Size", value: "\(image.width) × \(image.height)")
            LabeledContent("Type", value: "\(image.pixelType.bitDepth)-bit")
            LabeledContent(
                "Dimensions",
                value: "c=\(image.dimensions.channels) z=\(image.dimensions.slices) t=\(image.dimensions.frames)")
            if cal.isSpatiallyCalibrated {
                LabeledContent(
                    "Pixel size", value: "\(Self.number(cal.pixelWidth)) × \(Self.number(cal.pixelHeight)) \(cal.unit)")
                if image.dimensions.slices > 1 {
                    LabeledContent("Voxel depth", value: "\(Self.number(cal.pixelDepth)) \(cal.unit)")
                }
            }
            if cal.frameInterval > 0 {
                LabeledContent("Frame interval", value: "\(Self.number(cal.frameInterval)) \(cal.timeUnit)")
            }
            if let label = image.stack.labels[image.dimensions.planeIndex(channel: model.channel, slice: model.slice, frame: model.frame)] {
                LabeledContent("Label", value: label)
            }
            if image.stack.isVirtual { LabeledContent("Storage", value: "Virtual stack") }
            if let info = image.info, !info.isEmpty {
                DisclosureGroup("Info") {
                    Text(info).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private static func number(_ v: Double) -> String { String(format: "%.4g", v) }
}

/// A labelled slider with its value, for the display range ends.
struct RangeSlider: View {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step == 0 ? "%.4g" : "%.0f", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            let clamped = Binding(
                get: { min(max(value, bounds.lowerBound), bounds.upperBound) },
                set: { value = $0 })
            if step > 0 {
                Slider(value: clamped, in: bounds, step: step)
            } else {
                Slider(value: clamped, in: bounds)
            }
        }
    }
}

/// What an ImageJ command or macro logged and measured.
struct ReportView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ImageJ").font(.headline)
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
    }
}

nonisolated struct ViewerFocusKey: FocusedValueKey {
    typealias Value = ViewerModel
}

extension FocusedValues {
    /// The viewer in the key window, for menu commands.
    var viewer: ViewerModel? {
        get { self[ViewerFocusKey.self] }
        set { self[ViewerFocusKey.self] = newValue }
    }
}
