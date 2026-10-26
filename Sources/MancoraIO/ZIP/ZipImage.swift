#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import MancoraCore

/// ImageJ's ZIP files: one TIFF inside a zip, as File ▸ Save As ▸ ZIP
/// writes it (`FileSaver.saveAsZip`) and `Opener.openZip` reads it, and
/// ROI sets.
///
/// Like `Opener.openZip`, reading looks only at the first entry: `.roi`
/// means a ROI set, `.tif` an image (titled with the entry's name), `.dcm`
/// a DICOM image (which Mancora doesn't read yet); anything else is an
/// error.
public enum ZipImage {
    /// What a zip holds, by its first entry.
    public enum Contents: Sendable {
        case image(Hyperstack)
        case rois([RoiSet.Entry])
    }

    public static func read(path: String, options: TIFFImporter.Options = .init()) throws(MancoraIOError) -> Contents {
        try decode(FileLoader.load(path: path, limit: options.maximumFileBytes), options: options)
    }

    public static func decode(_ bytes: [UInt8], options: TIFFImporter.Options = .init()) throws(MancoraIOError) -> Contents {
        guard let first = try ZipArchive.entries(bytes).first else { throw .invalidFormat("the ZIP archive is empty") }
        if first.name.hasSuffix(".roi") { return .rois(try RoiSet.decode(bytes)) }
        if first.name.hasSuffix(".tif") {
            var tiffOptions = options
            tiffOptions.virtual = false
            let tiff = try ZipArchive.data(of: first, in: bytes, limit: options.maximumFileBytes)
            return .image(try TIFFImporter.decode(tiff, title: first.name, options: tiffOptions))
        }
        if first.name.hasSuffix(".dcm") { throw .unsupported("DICOM images in ZIP archives") }
        throw .invalidFormat("This ZIP archive does not contain a TIFF or DICOM file, or ROIs")
    }

    /// The TIFF's name in the zip, as `FileSaver.saveAsZip` makes it from
    /// a name (the image's title, or the zip file's name when a macro saves
    /// with `saveAs("ZIP", path)`): without `.zip`, and ending in `.tif`.
    public static func entryName(for name: String) -> String {
        var entry = name
        if entry.hasSuffix(".zip") { entry.removeLast(4) }
        if !entry.hasSuffix(".tif") { entry += ".tif" }
        return entry
    }

    /// A zip holding the image saved as ImageJ's TIFF, deflated, under
    /// `entryName(for: name ?? image.title)`.
    public static func encode(_ image: Hyperstack, name: String? = nil, options: TIFFExporter.Options = .init()) throws(MancoraIOError)
        -> [UInt8]
    {
        let tiff = try TIFFExporter.encode(image, options: options)
        guard tiff.count < 0xFFFF_FFFF else { throw .unsupported("ZIP entries of 4 GB or more") }
        return ZipArchive.write([(entryName(for: name ?? image.title), tiff)], deflated: true)
    }

    /// Saves the image as a ZIP (adding `.zip` to the path if it's missing,
    /// as ImageJ does) and returns the TIFF entry's name, which ImageJ
    /// makes the image's new title. The entry is named after the zip file,
    /// as File ▸ Save As ▸ ZIP names it.
    @discardableResult
    public static func write(_ image: Hyperstack, to path: String, options: TIFFExporter.Options = .init()) throws(MancoraIOError)
        -> String
    {
        let zipPath = path.hasSuffix(".zip") ? path : path + ".zip"
        let name = entryName(for: FileType.fileName(zipPath))
        let bytes = try encode(image, name: name, options: options)
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: zipPath))
        } catch {
            throw .unreadable(path: zipPath, reason: "\(error)")
        }
        return name
    }
}
