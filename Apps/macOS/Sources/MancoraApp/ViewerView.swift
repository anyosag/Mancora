import MancoraCore
import SwiftUI

struct ViewerView: View {
    @Bindable var model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            if let image = model.image, let bitmap = model.rendered {
                Image(decorative: bitmap, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                PositionControls(model: model, dimensions: image.dimensions)
                    .padding(12)
            } else {
                ContentUnavailableView {
                    Label("No Image", systemImage: "photo")
                } description: {
                    Text("Open a TIFF file to view it.")
                } actions: {
                    Button("Open…") { model.presentOpenPanel() }
                }
            }
        }
        .navigationTitle(model.image?.title ?? "Mancora")
        .toolbar {
            ToolbarItem {
                Button("Open…", systemImage: "folder") { model.presentOpenPanel() }
            }
            ToolbarItem {
                Menu("LUT", systemImage: "paintpalette") {
                    ForEach(LUT.builtIn, id: \.name) { lut in
                        Button(lut.name) { model.apply(lut) }
                    }
                    Divider()
                    Button("Open LUT File…") { model.presentLUTPanel() }
                }
                .disabled(!(model.image?.pixelType.usesLUT ?? false))
            }
        }
        .alert(
            "Can't Open File",
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

/// Channel, slice and frame steppers, shown only for dimensions above 1.
struct PositionControls: View {
    @Bindable var model: ViewerModel
    let dimensions: HyperstackDimensions

    var body: some View {
        HStack(spacing: 24) {
            if dimensions.channels > 1 {
                Stepper("Channel \(model.channel + 1)/\(dimensions.channels)", value: $model.channel, in: 0...(dimensions.channels - 1))
            }
            if dimensions.slices > 1 {
                Stepper("Slice \(model.slice + 1)/\(dimensions.slices)", value: $model.slice, in: 0...(dimensions.slices - 1))
            }
            if dimensions.frames > 1 {
                Stepper("Frame \(model.frame + 1)/\(dimensions.frames)", value: $model.frame, in: 0...(dimensions.frames - 1))
            }
            Spacer()
        }
        .onChange(of: model.channel) { model.render() }
        .onChange(of: model.slice) { model.render() }
        .onChange(of: model.frame) { model.render() }
    }
}
