public import MancoraCore

/// Opens any file Mancora reads natively, routed by ``FileType`` as
/// ImageJ's `Opener` routes it: TIFF, ImageJ ZIP, PNG and GIF images, ROI
/// sets and selections, and tables.
///
/// Formats Mancora doesn't read yet, and TIFF-based vendor formats it can't
/// read correctly (MetaMorph STK, Zeiss LSM, OME-TIFF), throw
/// ``MancoraIOError/unsupported(_:)``, so callers can open them in ImageJ
/// or Bio-Formats through the bridge instead.
///
/// `ImageOpener.read(path:options:)` takes the place of
/// `TIFFImporter.read(path:options:)` for any image file.
public enum ImageOpener {
    /// What a file holds, as ImageJ's File ▸ Open sees it.
    public enum Contents: Sendable {
        case image(Hyperstack)
        /// A `RoiSet.zip`, for the ROI Manager.
        case rois([RoiSet.Entry])
        /// A `.roi` file: the selection.
        case roi(Roi)
        /// A table, with the title ImageJ shows it under.
        case table(ResultsTable, title: String)
    }

    /// Opens an image file of any format Mancora reads. A ZIP of ROIs, a
    /// selection or a table isn't an image: ``open(path:options:)`` reads those.
    /// Only TIFFs open as virtual stacks; other formats are read whole.
    public static func read(path: String, options: TIFFImporter.Options = .init()) throws(MancoraIOError) -> Hyperstack {
        switch try open(path: path, options: options) {
        case .image(let image): return image
        case .rois: throw .unsupported("\(FileType.fileName(path)) holds ROIs, not an image (open it in the ROI Manager)")
        case .roi: throw .unsupported("\(FileType.fileName(path)) is a selection, not an image")
        case .table: throw .unsupported("\(FileType.fileName(path)) is a table, not an image")
        }
    }

    /// Opens a file as File ▸ Open would.
    public static func open(path: String, options: TIFFImporter.Options = .init()) throws(MancoraIOError) -> Contents {
        let type = FileType.of(path: path)
        let name = FileType.fileName(path)
        switch type {
        case .tiff:
            return .image(try TIFFImporter.read(path: path, options: options))
        case .zip:
            switch try ZipImage.read(path: path, options: options) {
            case .image(let image): return .image(image)
            case .rois(let rois): return .rois(rois)
            }
        case .png:
            return .image(try PNGReader.read(path: path, maximumDecodedBytes: options.maximumDecodedBytes))
        case .gif:
            return .image(try GIFReader.read(path: path, maximumDecodedBytes: options.maximumDecodedBytes))
        case .roi:
            return .roi(try RoiCodec.read(path: path))
        case .table:
            return .table(try ResultsTableIO.read(path: path), title: ResultsTableIO.title(forPath: path))
        case .unknown where name.hasSuffix(".lsm"):
            throw .unsupported("Zeiss LSM files (ImageJ's LSM reader or Bio-Formats opens them)")
        case .unknown:
            if !FileType.fileExists(path) { throw .unreadable(path: path, reason: "file not found") }
            throw .unsupported("\(name): a format ImageJ doesn't know (Bio-Formats may read it)")
        default:
            throw .unsupported("\(type.description) files")
        }
    }

    /// Decodes an image from memory, its format told from its first bytes
    /// and `name` as for a file.
    public static func decode(_ bytes: [UInt8], name: String, options: TIFFImporter.Options = .init()) throws(MancoraIOError)
        -> Hyperstack
    {
        switch FileType.of(header: bytes, name: name) {
        case .tiff: return try TIFFImporter.decode(bytes, title: name, options: options)
        case .png: return try PNGReader.decode(bytes, title: name, maximumDecodedBytes: options.maximumDecodedBytes)
        case .gif: return try GIFReader.decode(bytes, title: name, maximumDecodedBytes: options.maximumDecodedBytes)
        case .zip:
            guard case .image(let image) = try ZipImage.decode(bytes, options: options) else {
                throw .unsupported("\(name) holds ROIs, not an image")
            }
            return image
        case let type: throw .unsupported("\(type.description) files")
        }
    }

    /// Whether Mancora reads files of this type itself (TIFFs only when they
    /// aren't a vendor format, which the file's contents tell).
    public static func readsNatively(_ type: FileType) -> Bool {
        [.tiff, .zip, .png, .gif, .roi, .table].contains(type)
    }
}

/// Saves images in the formats Mancora writes natively, as ImageJ's
/// File ▸ Save As does: TIFF, ZIP, PNG and GIF.
public enum ImageSaver {
    public enum Format: String, Sendable, CaseIterable {
        case tiff, zip, png, gif

        /// The file extension ImageJ gives this format.
        public var fileExtension: String {
            switch self {
            case .tiff: ".tif"
            case .zip: ".zip"
            case .png: ".png"
            case .gif: ".gif"
            }
        }

        /// The format a path's extension names, if Mancora writes it.
        public init?(path: String) {
            switch FileType.fileName(path).split(separator: ".").last.map({ $0.lowercased() }) {
            case "tif", "tiff": self = .tiff
            case "zip": self = .zip
            case "png": self = .png
            case "gif": self = .gif
            default: return nil
            }
        }
    }

    /// Where the image is: the plane PNG and GIF save from a single-slice
    /// image or composite (0-based).
    public struct Position: Sendable {
        public var channel: Int, slice: Int, frame: Int
        public init(channel: Int = 0, slice: Int = 0, frame: Int = 0) {
            (self.channel, self.slice, self.frame) = (channel, slice, frame)
        }
    }

    /// Saves `image` at `path` in `format` (by default the one the path's
    /// extension names), and returns the title ImageJ gives the image after
    /// saving: the file name (for ZIP, the TIFF's name inside).
    @discardableResult
    public static func write(_ image: Hyperstack, to path: String, format: Format? = nil, position: Position = Position())
        throws(MancoraIOError) -> String
    {
        guard let format = format ?? Format(path: path) else {
            throw .unsupported("saving \(FileType.fileName(path)): Mancora saves TIFF, ZIP, PNG and GIF")
        }
        switch format {
        case .tiff:
            try TIFFExporter.write(image, to: path)
        case .zip:
            return try ZipImage.write(image, to: path)
        case .png:
            try PNGWriter.write(image, to: path, options: .init(channel: position.channel, slice: position.slice, frame: position.frame))
        case .gif:
            try GIFWriter.write(image, to: path, options: .init(channel: position.channel, slice: position.slice, frame: position.frame))
        }
        return FileType.fileName(path)
    }
}

extension FileType: CustomStringConvertible {
    /// The format's name in messages.
    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .tiff: "TIFF"
        case .dicom: "DICOM"
        case .fits: "FITS"
        case .pgm: "PGM"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .lut: "LUT"
        case .bmp: "BMP"
        case .zip: "ZIP"
        case .javaOrText: "text"
        case .roi: "ROI"
        case .text: "text"
        case .png: "PNG"
        case .tiffAndDicom: "TIFF/DICOM"
        case .avi: "AVI"
        case .ojj: "ObjectJ"
        case .table: "table"
        case .raw: "raw"
        }
    }
}
