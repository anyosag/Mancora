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
    /// ImageJ's version: `1.54p`, or in Fiji ImageJ2's and ImageJ 1.x's, `2.18.0/1.54p`.
    public let imagej: String
    public let java: String
    public let pluginsDir: String?
    public let pid: Int
    /// In Fiji: the versions of its parts by name (`Fiji`, `ImageJ2`, `ImageJ1`, `SciJava`, …).
    public let fiji: [String: String]?
    /// In Fiji: what starting ImageJ2 printed, such as plugins it couldn't load.
    public let startupLog: String?

    /// Whether the helper runs in Fiji (ImageJ2 with the legacy layer), not plain ImageJ.
    public var isFiji: Bool { fiji != nil }
}

/// A value a SciJava module or script takes or gives: text, a number, a
/// truth value, a list, or nothing.
public enum BridgeValue: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral,
    ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([BridgeValue])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            self = .list(try container.decode([BridgeValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .list(let list): try container.encode(list)
        case .null: try container.encodeNil()
        }
    }

    /// As ImageJ would print it: numbers without a needless `.0`.
    public var description: String {
        switch self {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let bool): String(bool)
        case .list(let list): "[" + list.map(\.description).joined(separator: ", ") + "]"
        case .null: "null"
        }
    }

    public var number: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}

/// An entry in ImageJ's menus, in menu order: in Fiji the whole of Fiji's
/// menu bar, where ImageJ2's legacy layer has added SciJava's commands and
/// scripts to ImageJ 1.x's. Entries the menu bar doesn't hold (SciJava
/// modules it couldn't place, and commands in no menu) follow.
public struct BridgeMenuItem: Sendable, Hashable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// An ImageJ 1.x command or plugin.
        case imagej1
        /// A SciJava command (ImageJ2's, or a plugin's: Labkit, the Script Editor, …).
        case command
        /// A script in Fiji's `scripts/` or `plugins/` folders.
        case script
        /// A separator line, after the items before it in the same menu.
        case separator
    }

    public let kind: Kind
    /// The menus down to the item, the item's own label last: `["Plugins",
    /// "Tracking", "TrackMate"]`. A separator's is its menu's; a command in
    /// no menu has none.
    public let path: [String]
    /// The name ``Bridge/run(_:options:images:interactive:)`` and macros'
    /// `run` take (the item's label); `nil` for a separator.
    public let command: String?
    /// ImageJ 1.x's class and argument (`ij.plugin.filter.Filters("invert")`),
    /// or a SciJava module's identifier (`command:<class>`, `script:<path>`).
    public let identifier: String?
    /// The class that runs it, when there is one.
    public let className: String?
    /// The keyboard shortcut ImageJ gives it, e.g. `Shift+I` (with Command on macOS, Control elsewhere).
    public let shortcut: String?

    public var isSeparator: Bool { kind == .separator }

    public init(
        kind: Kind, path: [String], command: String?, identifier: String? = nil, className: String? = nil, shortcut: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.command = command
        self.identifier = identifier
        self.className = className
        self.shortcut = shortcut
    }
}

/// A script language installed in Fiji (SciJava's script languages).
public struct BridgeScriptLanguage: Sendable, Hashable, Decodable {
    /// E.g. `Groovy`, `Python (Jython)`, `JavaScript`, `ImageJ Macro`.
    public let name: String
    /// File extensions, without the dot: `groovy`, `py`, `js`, `ijm`.
    public let extensions: [String]
    /// Other names ``Bridge/runScript(_:language:parameters:images:interactive:)`` takes for it.
    public let aliases: [String]
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
    /// Left out, the helper's default (``Bridge/Configuration/interactive``).
    var interactive: Bool?
}

struct MacroParams: Encodable {
    let code: String
    let argument: String
    let inputs: [String]
    let titles: [String]
    let outputDir: String
    var interactive: Bool?
}

/// A SciJava module: by identifier, class, menu path or label.
struct ModuleParams: Encodable {
    let command: String
    let parameters: [String: BridgeValue]
    let inputs: [String]
    let titles: [String]
    let outputDir: String
    var interactive: Bool?
}

struct ScriptParams: Encodable {
    let language: String
    let code: String
    let parameters: [String: BridgeValue]
    let inputs: [String]
    let titles: [String]
    let outputDir: String
    var interactive: Bool?
}

struct ImagesParams: Encodable {
    let outputDir: String
}

struct MenusResult: Decodable {
    let menus: [BridgeMenuItem]
}

struct LanguagesResult: Decodable {
    let languages: [BridgeScriptLanguage]
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
    let values: [String: BridgeValue]?
    let scriptError: String?
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
