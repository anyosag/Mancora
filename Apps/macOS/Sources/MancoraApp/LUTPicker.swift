import AppKit
import MancoraCore
import MancoraIO
import SwiftUI

/// A lookup table drawn as the strip of colors it maps to, dark end to bright end.
struct LUTSwatch: View {
    let lut: LUT

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        shape
            .fill(LinearGradient(colors: Self.colors(lut), startPoint: .leading, endPoint: .trailing))
            .overlay { shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5) }
    }

    /// The LUT sampled every eighth entry, and its last.
    private static func colors(_ lut: LUT) -> [Color] {
        (Array(stride(from: 0, to: 256, by: 8)) + [255]).map { i in
            Color(
                .sRGB, red: Double(lut.reds[i]) / 255, green: Double(lut.greens[i]) / 255,
                blue: Double(lut.blues[i]) / 255, opacity: 1)
        }
    }
}

/// The same strips as bitmaps, for menu items, which show images but not views.
enum LUTSwatchImage {
    private static var cache: [String: NSImage] = [:]

    /// A swatch of `lut`, kept under `key`.
    static func image(for lut: LUT, key: String) -> NSImage {
        if let cached = cache[key] { return cached }
        // Twice the size it is shown at (36 × 10 points), for Retina screens.
        let width = 72
        let height = 20
        var pixels = [UInt32](repeating: 0xFF80_8080, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                pixels[y * width + x] = lut.argb((x - 1) * 255 / (width - 3))
            }
        }
        let made: NSImage
        if let bitmap = ViewerModel.makeCGImage(pixels, width: width, height: height) {
            made = NSImage(cgImage: bitmap, size: NSSize(width: 36, height: 10))
        } else {
            made = NSImage()
        }
        cache[key] = made
        return made
    }

    /// The swatch of a LUT file, read once; a file that doesn't read gets a gray one.
    static func image(forFileAt url: URL) -> NSImage {
        if let cached = cache[url.path] { return cached }
        guard let lut = try? LUTReader.read(path: url.path) else { return image(for: .grays, key: "Grays") }
        return image(for: lut, key: url.path)
    }
}

/// The LUT of the channel shown, as a menu with a swatch for each LUT: the inspector's way to
/// choose one (Image ▸ Lookup Tables has them too).
struct LUTPicker: View {
    @Bindable var model: ViewerModel
    let current: LUT

    var body: some View {
        Menu {
            ForEach(LUT.builtIn, id: \.name) { lut in
                Toggle(
                    isOn: Binding(
                        get: { current.hasSameColors(as: lut) },
                        set: { _ in model.apply(lut) })
                ) {
                    Label {
                        Text(lut.name)
                    } icon: {
                        Image(nsImage: LUTSwatchImage.image(for: lut, key: lut.name)).renderingMode(.original)
                    }
                }
            }
            if !ViewerModel.bundledLUTs.isEmpty {
                Divider()
                Menu("ImageJ LUTs") {
                    ForEach(ViewerModel.bundledLUTs, id: \.url) { item in
                        Button {
                            model.applyLUT(at: item.url)
                        } label: {
                            Label {
                                Text(item.name)
                            } icon: {
                                Image(nsImage: LUTSwatchImage.image(forFileAt: item.url)).renderingMode(.original)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Open LUT File…") { model.presentLUTPanel() }
        } label: {
            HStack(spacing: 6) {
                LUTSwatch(lut: current)
                    .frame(width: 36, height: 10)
                Text(current.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 190)
        .help("Lookup table of the channel shown")
    }
}
