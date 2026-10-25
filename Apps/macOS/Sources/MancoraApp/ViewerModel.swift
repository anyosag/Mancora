import AppKit
import CoreGraphics
import MancoraCore
import MancoraIO
import Observation
import UniformTypeIdentifiers

/// State for one viewer window: the open image, the position shown, and the
/// rendered bitmap.
@Observable
final class ViewerModel {
    private(set) var image: Hyperstack?
    private(set) var rendered: CGImage?
    var errorMessage: String?
    var channel = 0
    var slice = 0
    var frame = 0

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            image = try TIFFImporter.read(path: url.path)
            channel = 0
            slice = 0
            frame = 0
            errorMessage = nil
            render()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func presentLUTPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lut") ?? .data, .plainText]
        panel.directoryURL = Self.bundledLUTDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyLUT(at: url)
    }

    func applyLUT(at url: URL) {
        do {
            apply(try LUTReader.read(path: url.path))
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The LUTs shipped inside Mancora.app (`Contents/Resources/LUTs`);
    /// empty when running unbundled with `swift run`.
    static let bundledLUTDirectory = Bundle.main.url(forResource: "LUTs", withExtension: nil)

    static let bundledLUTs: [(name: String, url: URL)] = {
        guard let dir = bundledLUTDirectory,
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { ["lut", "txt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != "README.txt" }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// Decodes and renders an image without showing any UI.
    static func smokeTest(path: String) -> Bool {
        guard let image = try? TIFFImporter.read(path: path) else { return false }
        let pixels = DisplayMapper.render(image)
        return makeCGImage(pixels, width: image.width, height: image.height) != nil
    }

    func apply(_ lut: LUT) {
        guard var image, image.pixelType.usesLUT else { return }
        var display = image.channels[channel]
        display.lut = lut
        image.setDisplay(display, forChannel: channel)
        self.image = image
        render()
    }

    func render() {
        guard let image else {
            rendered = nil
            return
        }
        let pixels = DisplayMapper.render(image, channel: channel, slice: slice, frame: frame)
        rendered = Self.makeCGImage(pixels, width: image.width, height: image.height)
    }

    /// Wraps DisplayMapper output (0xAARRGGBB words, BGRA in memory) without
    /// converting it.
    static func makeCGImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
