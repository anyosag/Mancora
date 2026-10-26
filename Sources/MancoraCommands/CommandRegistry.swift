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

    public func isNative(_ name: String) -> Bool { commands[Self.legacyNames[name] ?? name] != nil }

    /// `IJ.convert`: the old names of renamed commands, which `IJ.run` still accepts.
    public static let legacyNames: [String: String] = [
        "New...": "Image...", "Threshold": "Make Binary", "Display...": "Appearance...",
        "Start Animation": "Start Animation [\\]", "Convert Images to Stack": "Images to Stack",
        "Convert Stack to Images": "Stack to Images", "Convert Stack to RGB": "Stack to RGB",
        "Convert to Composite": "Make Composite", "RGB Split": "Split Channels", "RGB Merge...": "Merge Channels...",
        "Channels...": "Channels Tool...", "New... ": "Table...", "Arbitrarily...": "Rotate... ",
        "Measurements...": "Results... ", "List Commands...": "Find Commands...", "Capture Screen ": "Capture Screen",
        "Add to Manager ": "Add to Manager", "In": "In [+]", "Out": "Out [-]", "Enhance Contrast": "Enhance Contrast...",
        "XY Coodinates... ": "XY Coordinates... ", "Statistics...": "Statistics", "Channels Tool... ": "Channels Tool...",
        "Profile Plot Options...": "Plots...", "AuPbSn 40 (56K)": "AuPbSn 40",
        "Bat Cochlea Volume (19K)": "Bat Cochlea Volume", "Bat Cochlea Renderings (449K)": "Bat Cochlea Renderings",
        "Blobs (25K)": "Blobs", "Boats (356K)": "Boats", "Cardio (768K, RGB DICOM)": "Cardio (RGB DICOM)",
        "Cell Colony (31K)": "Cell Colony", "Clown (14K)": "Clown", "Confocal Series (2.2MB)": "Confocal Series",
        "CT (420K, 16-bit DICOM)": "CT (16-bit DICOM)", "Dot Blot (7K)": "Dot Blot", "Embryos (42K)": "Embryos",
        "Fluorescent Cells (400K)": "Fluorescent Cells", "Fly Brain (1MB)": "Fly Brain", "Gel (105K)": "Gel",
        "HeLa Cells (1.3M, 48-bit RGB)": "HeLa Cells (48-bit RGB)", "Leaf (36K)": "Leaf",
        "Line Graph (21K)": "Line Graph", "Mitosis (26MB, 5D stack)": "Mitosis (5D stack)",
        "MRI Stack (528K)": "MRI Stack", "M51 Galaxy (177K, 16-bits)": "M51 Galaxy (16-bits)",
        "Neuron (1.6M, 5 channels)": "Neuron (5 channels)", "Nile Bend (1.9M)": "Nile Bend",
        "Organ of Corti (2.8M, 4D stack)": "Organ of Corti (4D stack)", "Particles (75K)": "Particles",
        "T1 Head (2.4M, 16-bits)": "T1 Head (16-bits)", "T1 Head Renderings (736K)": "T1 Head Renderings",
        "TEM Filter (112K)": "TEM Filter", "Tree Rings (48K)": "Tree Rings",
    ]

    /// `run(name, options)`: the native command, else the fallback, under
    /// the command's current name (`IJ.convert`).
    public func run(_ name: String, options: MacroOptions = MacroOptions(""), in context: inout CommandContext)
        throws(CommandError)
    {
        let name = Self.legacyNames[name] ?? name
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
