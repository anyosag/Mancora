public import MancoraCore

/// Errors from reading image and LUT files.
public enum MancoraIOError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The data ended before a structure it promised was complete.
    case truncated(offset: Int, needed: Int, available: Int)
    /// The data is not in the expected format.
    case invalidFormat(String)
    /// The format is recognized but this feature isn't supported yet.
    case unsupported(String)
    /// Decoding would need more memory than the configured limit allows.
    case tooLarge(bytes: Int, limit: Int)
    /// The decoded pieces don't form a valid image.
    case model(ImageModelError)
    /// The file could not be read.
    case unreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case .truncated(let offset, let needed, let available):
            "File is truncated: needed \(needed) bytes at offset \(offset), but only \(available) are available."
        case .invalidFormat(let detail): "Invalid file: \(detail)"
        case .unsupported(let detail): "Not supported yet: \(detail)"
        case .tooLarge(let bytes, let limit): "Image needs \(bytes) bytes, over the \(limit)-byte limit."
        case .model(let error): "Inconsistent image: \(error)"
        case .unreadable(let path, let reason): "Cannot read \(path): \(reason)"
        }
    }
}
