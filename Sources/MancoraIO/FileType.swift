import Foundation

/// A file's format as ImageJ tells formats apart: ImageJ 1.54p's
/// `Opener.getFileType`, which looks at the first 132 bytes and the name.
///
/// The cases are ImageJ's file types, in its order. ``ImageOpener`` reads
/// the ones Mancora has natively; for the rest it throws
/// ``MancoraIOError/unsupported(_:)`` so callers can hand the file to ImageJ
/// or Bio-Formats through the bridge.
public enum FileType: String, Sendable, CaseIterable {
    /// Nothing ImageJ recognizes: Bio-Formats, or Fiji's `HandleExtraFileTypes`, may.
    case unknown
    case tiff
    case dicom
    case fits
    /// PGM, PPM or PBM.
    case pgm
    case jpeg
    /// GIF, including animated GIF.
    case gif
    /// An ImageJ `.lut` lookup table.
    case lut
    case bmp
    /// A zip of one TIFF or DICOM image, or of `.roi` files (a ROI set).
    case zip
    /// Java source, a macro, a script or a plain `.txt` file, which ImageJ opens in its editor.
    case javaOrText
    /// An ImageJ `.roi` selection.
    case roi
    /// Text with no known extension.
    case text
    case png
    /// A GE Senographe file that is both TIFF and DICOM.
    case tiffAndDicom
    case avi
    /// An ObjectJ project.
    case ojj
    /// Tab- or comma-separated text: `.csv`, `.tsv` and `.xls` (which ImageJ writes as tab-separated text).
    case table
    /// Raw pixels, read through File ▸ Import ▸ Raw.
    case raw

    /// The type of the file at `path`, from its first 132 bytes and name
    /// (`.unknown` if it can't be read).
    public static func of(path: String) -> FileType {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 132)) ?? Data()
        return of(header: [UInt8](header), name: fileName(path))
    }

    /// The type of a file whose contents start with `header` (ImageJ reads
    /// 132 bytes; fewer count as zeros) and whose name is `name`.
    public static func of(header bytes: [UInt8], name: String) -> FileType {
        var buf = Array(bytes.prefix(132))
        if buf.count < 132 { buf += [UInt8](repeating: 0, count: 132 - buf.count) }
        let b0 = buf[0], b1 = buf[1], b2 = buf[2], b3 = buf[3]
        let dicm = buf[128] == 68 && buf[129] == 73 && buf[130] == 67 && buf[131] == 77

        // ImageJ tests these names case-sensitively.
        if name.hasSuffix(".msr") || name.hasSuffix(".MSR") { return .unknown }  // Imspector, for Bio-Formats
        if dicm && ((b0 == 73 && b1 == 73) || (b0 == 77 && b1 == 77)) { return .tiffAndDicom }
        if name.hasSuffix(".lsm") { return .unknown }  // the LSM reader or Bio-Formats opens these
        if b0 == 73 && b1 == 73 && b2 == 42 && b3 == 0 { return .tiff }
        if b0 == 77 && b1 == 77 && b2 == 0 && b3 == 42 { return .tiff }
        // BigTIFF, which ImageJ's own reader can't open, but Mancora's can.
        if (b0 == 73 && b1 == 73 && b2 == 43 && b3 == 0) || (b0 == 77 && b1 == 77 && b2 == 0 && b3 == 43) { return .tiff }
        if b0 == 255 && b1 == 216 && b2 == 255 { return .jpeg }
        if b0 == 71 && b1 == 73 && b2 == 70 && b3 == 56 { return .gif }  // "GIF8"

        let lower = name.lowercased()
        if dicm || lower.hasSuffix(".dcm") { return .dicom }
        // ACR/NEMA, whose first tag is (0002,00xx) or (0008,00xx).
        if (b0 == 8 || b0 == 2) && b1 == 0 && b3 == 0 && !lower.hasSuffix(".spe") && lower != "fid" { return .dicom }
        // "P1" to "P6" and whitespace.
        if b0 == 80 && (49...54).contains(b1) && [10, 13, 32, 9].contains(b2) { return .pgm }
        if lower.hasSuffix(".lut") { return .lut }
        if b0 == 137 && b1 == 80 && b2 == 78 && b3 == 71 { return .png }
        if lower.hasSuffix(".zip") { return .zip }
        if (b0 == 83 && b1 == 73 && b2 == 77 && b3 == 80) || lower.hasSuffix(".fts.gz") || lower.hasSuffix(".fits.gz") {
            return .fits  // "SIMP"
        }
        if [".java", ".txt", ".ijm", ".js", ".bsh", ".py", ".html"].contains(where: lower.hasSuffix) { return .javaOrText }
        if b0 == 73 && b1 == 111 { return .roi }  // "Iout"
        if (b0 == 111 && b1 == 106 && b2 == 106 && b3 == 0) || lower.hasSuffix(".ojj") { return .ojj }
        if lower.hasSuffix(".xls") || lower.hasSuffix(".csv") || lower.hasSuffix(".tsv") { return .table }
        if lower.hasSuffix(".avi") { return .avi }
        if buf.prefix(10).allSatisfy({ $0 >= 32 && $0 <= 126 || $0 == 9 || $0 == 10 || $0 == 13 }) { return .text }
        if (b0 == 66 && b1 == 77) || lower.hasSuffix(".dib") { return .bmp }  // "BM"
        if lower.hasSuffix(".raw") { return .raw }
        return .unknown
    }

    static func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The last path component, split at `/` and `\` as Java's `File.getName` does on each platform.
    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}
