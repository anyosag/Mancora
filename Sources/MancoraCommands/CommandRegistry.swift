/// One command, under the name ImageJ's menus and macros use for it.
public struct CommandDefinition: Sendable {
    /// Errors other than ``CommandError`` are reported as ``CommandError/failed(command:detail:)``.
    public typealias Action = @Sendable (inout CommandContext, MacroOptions) throws -> Void

    /// ImageJ's command name, e.g. `"Gaussian Blur..."` (trailing spaces count).
    public let name: String
    /// Where ImageJ shows it, e.g. `"Process>Filters"`.
    public let menu: String
    public let run: Action

    public init(_ name: String, menu: String, run: @escaping Action) {
        self.name = name
        self.menu = menu
        self.run = run
    }
}

/// Runs what Mancora can't natively, e.g. through the Java bridge. Returns
/// `false` for a command it doesn't know either.
public protocol CommandFallback: Sendable {
    func run(_ name: String, options: MacroOptions, context: inout CommandContext) throws(CommandError) -> Bool
}

/// ImageJ's command table: names to native implementations, with an
/// optional fallback for the rest, and a recorder.
public struct CommandRegistry: Sendable {
    public private(set) var commands: [String: CommandDefinition] = [:]
    public var fallback: (any CommandFallback)?

    public init() {}

    /// The commands Mancora implements natively.
    public static var standard: CommandRegistry {
        var registry = CommandRegistry()
        for command in BuiltInCommands.all { registry.register(command) }
        return registry
    }

    public mutating func register(_ command: CommandDefinition) {
        commands[command.name] = command
    }

    public func isNative(_ name: String) -> Bool { commands[name] != nil }

    /// `run(name, options)`: the native command, else the fallback.
    public func run(_ name: String, options: MacroOptions = MacroOptions(""), in context: inout CommandContext)
        throws(CommandError)
    {
        if let command = commands[name] {
            do {
                try command.run(&context, options)
            } catch let error as CommandError {
                throw error
            } catch {
                throw .failed(command: name, detail: "\(error)")
            }
            return
        }
        if let fallback, try fallback.run(name, options: options, context: &context) { return }
        throw .unrecognized(name)
    }
}

/// Plugins ▸ Macros ▸ Record: the `run()` calls that reproduce what was done.
public struct MacroRecorder: Sendable {
    public private(set) var lines: [String] = []

    public init() {}

    public mutating func record(_ command: String, options: MacroOptions? = nil) {
        if let options, !options.text.isEmpty {
            lines.append("run(\"\(Self.escape(command))\", \"\(Self.escape(options.text))\");")
        } else {
            lines.append("run(\"\(Self.escape(command))\");")
        }
    }

    public mutating func recordLine(_ line: String) { lines.append(line) }

    public var macro: String { lines.map { $0 + "\n" }.joined() }

    /// `Recorder.fixString`: backslash, quote and control characters escaped.
    public static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", "\"": out += "\\" + String(scalar)
            case "\n": out += "\\n"
            default:
                let v = scalar.value
                if v < 0x20 || (v > 0x7E && v < 0xA0) {
                    let octal = String(v, radix: 8)
                    out += "\\" + String(repeating: "0", count: max(0, 3 - octal.count)) + octal
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
