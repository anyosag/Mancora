import Foundation

public enum FijiError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Fiji publishes no download for this platform.
    case unsupportedPlatform(String)
    case notInstalled(path: String)
    /// Another install or update of the same Fiji is under way (in this process or another).
    case busy
    case badChecksumFile(String)
    case checksumMismatch(file: String, expected: String, actual: String)
    /// Neither `ditto`, `unzip` nor `bsdtar` is there to unpack the archive.
    case noUnzip
    case extractionFailed(String)
    /// The archive or an update left something that isn't a complete Fiji.
    case incomplete(String)
    /// The update sites ask for decisions an automatic update can't make.
    case conflicts([String])
    /// Some update sites couldn't be read; their files would look removed, so nothing is updated.
    case sitesUnreadable([String])
    case lockFailed(String, Int32)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let platform): "Fiji has no download for this platform (\(platform))."
        case .notInstalled(let path): "Fiji isn't installed at \(path)."
        case .busy: "Fiji is being installed or updated already."
        case .badChecksumFile(let detail): "Fiji's published checksum couldn't be read: \(detail)"
        case .checksumMismatch(let file, let expected, let actual):
            "The download of \(file) is corrupt (SHA-256 \(actual), expected \(expected))."
        case .noUnzip: "Unpacking Fiji needs unzip; install it (e.g. apt-get install unzip)."
        case .extractionFailed(let detail): "Fiji's archive couldn't be unpacked: \(detail)"
        case .incomplete(let detail): "That isn't a complete Fiji: \(detail)"
        case .conflicts(let list): "Fiji's update sites need a decision:\n" + list.joined(separator: "\n")
        case .sitesUnreadable(let list): "Fiji's update sites couldn't all be read:\n" + list.joined(separator: "\n")
        case .lockFailed(let path, let code): "Couldn't lock \(path) (error \(code))."
        }
    }
}
