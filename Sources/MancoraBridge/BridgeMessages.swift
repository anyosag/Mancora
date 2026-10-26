import Foundation

public enum BridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No Java of at least ``JavaRuntime/minimumVersion`` was found.
    case noJava
    /// The helper needs compiling and this Java has no `javac`.
    case noCompiler
    case compileFailed(String)
    case imageJMissing(path: String)
    case verificationFailed(file: String, expected: String, actual: String)
    /// The helper process ended (or was killed) before answering; `output`
    /// is the end of what it wrote to standard error, such as Java's error.
    case helperExited(status: Int32, output: String = "")
    /// The helper answered with an error, e.g. an unknown command.
    case helper(String, log: String)
    case invalidResponse(String)
    case timedOut(seconds: Double)

    public var description: String {
        switch self {
        case .noJava: "No Java \(JavaRuntime.minimumVersion) or newer was found. Install one, or set JAVA_HOME."
        case .noCompiler: "The Java found is a JRE; the bridge helper needs a JDK to be compiled once."
        case .compileFailed(let output): "The bridge helper didn't compile: \(output)"
        case .imageJMissing(let path): "ImageJ isn't installed at \(path)."
        case .verificationFailed(let file, let expected, let actual):
            "\(file) failed verification (SHA-1 \(actual), expected \(expected))."
        case .helperExited(let status, let output):
            "The Java helper stopped (status \(status))." + (output.isEmpty ? "" : "\n" + output)
        case .helper(let message, let log): log.isEmpty ? message : "\(message)\n\(log)"
        case .invalidResponse(let detail): "The Java helper sent an unexpected response: \(detail)"
        case .timedOut(let seconds): "The Java helper didn't answer within \(Int(seconds)) s."
        }
    }
}

/// One ImageJ command, as `Menus.getCommands()` lists it.
public struct BridgeCommand: Sendable, Hashable, Decodable {
    /// The menu label, e.g. `"Gaussian Blur..."` (trailing spaces are significant).
    public let name: String
    /// The plugin class and argument, e.g. `ij.plugin.Converter("16-bit")`.
    public let className: String

    /// Whether the command comes from outside ImageJ itself (a plugin jar).
    public var isPlugin: Bool { !className.hasPrefix("ij.") }
}

/// The helper's own description of itself.
public struct BridgeHello: Sendable, Hashable, Decodable {
    public let imagej: String
    public let java: String
    public let pluginsDir: String?
    public let pid: Int
}

/// A cell of ImageJ's results table.
public enum ResultValue: Sendable, Hashable, Decodable {
    case number(Double)
    case text(String)
    case empty

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .empty
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            // JSON has no NaN or infinities; the helper sends them as Java writes them.
            let text = try container.decode(String.self)
            switch text {
            case "NaN": self = .number(.nan)
            case "Infinity": self = .number(.infinity)
            case "-Infinity": self = .number(-.infinity)
            default: self = .text(text)
            }
        }
    }
}

/// ImageJ's results table after a command, column by column.
public struct BridgeResults: Sendable, Hashable, Decodable {
    public let columns: [String]
    public let rows: [[ResultValue]]

    public var isEmpty: Bool { rows.isEmpty }
}

// MARK: Wire format

struct BridgeRequest<Params: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: Params?
}

struct NoParams: Encodable {}

struct RunParams: Encodable {
    let command: String
    let options: String
    let inputs: [String]
    /// Each input's title, which its file name may not hold.
    let titles: [String]
    let outputDir: String
}

struct MacroParams: Encodable {
    let code: String
    let argument: String
    let inputs: [String]
    let titles: [String]
    let outputDir: String
}

struct OpenParams: Encodable {
    let path: String
    let outputDir: String
}

struct CommandsResult: Decodable {
    let commands: [BridgeCommand]
}

struct RunResult: Decodable {
    struct Output: Decodable {
        let path: String
        let title: String
        let replaces: String?
    }

    let outputs: [Output]
    let results: BridgeResults
    let log: String
    let value: String?
    let macroError: String?
    let macroErrorLine: Int?
}

/// Just the envelope; the result is decoded separately once the type is known.
struct ResponseHeader: Decodable {
    let id: Int?
    let error: String?
    let log: String?
}

struct Response<Result: Decodable>: Decodable {
    let result: Result
}

struct DialogParams: Encodable {
    let command: String
    let inputs: [String]
    let outputDir: String
}

/// The dialogs an ImageJ command shows, read by the helper so they can be
/// shown natively: each field with its label, macro key and default value.
public struct BridgeDialogs: Decodable, Sendable, Equatable {
    public struct Dialog: Decodable, Sendable, Equatable {
        public let title: String
        public let fields: [Field]
        public let hasPreview: Bool
    }

    public struct Field: Decodable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Decodable, Sendable {
            case number, slider, string, path, text, checkbox, choice, radio, message
        }

        public let kind: Kind
        /// The macro key: what ImageJ's recorder writes before `=`.
        public let key: String?
        public let label: String
        public let value: String?
        public let units: String?
        public let items: [String]?
        public let minimum: Double?
        public let maximum: Double?

        public var id: String { key ?? "message:" + label }
    }

    public let dialogs: [Dialog]
    /// Whether the command is a filter that, on a stack, asks to process every slice.
    public let asksForStack: Bool
    /// Whether ImageJ's dialog has a Preview checkbox (an ExtendedPlugInFilter's).
    public let supportsPreview: Bool

    /// The options string ImageJ's recorder writes for these answers (by key),
    /// in dialog order: `key=value` (bracketed when it has a space or is
    /// empty) and bare keys for ticked checkboxes.
    public func options(_ answers: [String: String], processStack: Bool = false) -> String {
        var parts: [String] = []
        for dialog in dialogs {
            for field in dialog.fields {
                guard let key = field.key, field.kind != .message else { continue }
                let value = answers[key] ?? field.value ?? ""
                if field.kind == .checkbox {
                    if value == "true" { parts.append(key) }
                } else {
                    parts.append(key + "=" + (value.isEmpty || value.contains(" ") ? "[" + value + "]" : value))
                }
            }
        }
        if processStack && asksForStack { parts.append("stack") }
        return parts.joined(separator: " ")
    }
}
