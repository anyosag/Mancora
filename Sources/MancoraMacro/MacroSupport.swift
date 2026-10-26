public import MancoraCommands

/// What in a macro Mancora can't run itself: built-in functions it doesn't
/// have, and `run("...")` commands that aren't native. A macro that uses
/// any of these runs entirely in ImageJ (through the Java bridge) instead,
/// so it never stops half-way through.
public enum MacroSupport {
    /// The unsupported functions and commands `source` names, in the order
    /// they appear (each once). Commands are checked when `run`'s first
    /// argument is a string constant; others are only known when they run.
    public static func unsupported(in source: String, registry: CommandRegistry) -> [String] {
        let pgm = Tokenizer.tokenize(source)
        var found: [String] = []
        func note(_ name: String) { if !found.contains(name) { found.append(name) } }
        let code = pgm.code
        var i = 0
        while i < code.count {
            let token = code[i] & TOK_MASK
            if token == EOF { break }
            let address = code[i] >> TOK_SHIFT
            switch token {
            case PREDEFINED_FUNCTION, NUMERIC_FUNCTION, STRING_FUNCTION, ARRAY_FUNCTION, VARIABLE_FUNCTION:
                let symbol = pgm.table[address]
                let name = symbol.str ?? ""
                if code[i + 1] == ch("."), let member = pgm.table[code[i + 2] >> TOK_SHIFT].str, families[name] != nil {
                    if !(families[name]!.contains(member)) { note(name + "." + member) }
                    i += 3
                    continue
                }
                if unsupportedFunctions.contains(name) { note(name) }
                if symbol.type == RUN, code[i + 1] == ch("("), code[i + 2] & TOK_MASK == STRING_CONSTANT,
                    let command = pgm.table[code[i + 2] >> TOK_SHIFT].str
                {
                    let next = code[i + 3]
                    // run("Command") or run("Command", "options"): a constant name.
                    if next == ch(")") || next == ch(","), !registry.isNative(command) { note("run(\"\(command)\")") }
                }
            default:
                break
            }
            i += 1
        }
        return found
    }

    /// Top-level built-ins that only ImageJ has (user interface, plots,
    /// fitting, overlays, drawing text...).
    static let unsupportedFunctions: Set<String> = [
        "Dialog", "doCommand", "doWand", "drawString", "exec", "Ext",
        "Fit", "floodFill", "getCursorLoc", "getDisplayedArea", "getFontList", "getImageInfo",
        "getLine", "getLocationAndSize", "getProfile", "getStringWidth", "makeArrow", "makeEllipse",
        "makeRotatedRectangle", "makeText", "newMenu", "Overlay", "Plot", "selectionContains", "setLut",
        "showText", "waitForUser",
    ]

    /// `Family.member` built-ins Mancora has, by family.
    static let families: [String: Set<String>] = [
        "Array": [
            "copy", "trim", "sort", "rankPositions", "getStatistics", "sequence", "getSequence", "fill", "reverse",
            "invert", "concat", "slice", "print", "resample", "rotate", "deleteValue", "delete", "deleteIndex", "filter",
            "getVertexAngles", "findMaxima", "findMinima",
        ],
        "String": ["append", "resetBuffer", "buffer", "join", "trim", "pad", "format", "getResultsHeadings"],
        "Math": [
            "min", "max", "pow", "atan2", "constrain", "map", "ceil", "abs", "cos", "exp", "floor", "log", "log10",
            "round", "sin", "sqr", "sqrt", "tan", "atan", "asin", "acos", "erf", "toRadians", "toDegrees",
        ],
        "List": [
            "get", "getValue", "set", "add", "put", "clear", "reset", "setList", "getList", "size", "getSize",
            "setMeasurements", "setCommands", "indexOf", "fromArrays", "toArrays",
        ],
        "IJ": [
            "pad", "log", "deleteRows", "freeMemory", "currentMemory", "maxMemory", "getToolName",
            "redirectErrorMessages", "renameResults", "getFullVersion", "checksum",
        ],
        "File": [
            "open", "openAsString", "openAsRawString", "close", "separator", "directory", "name",
            "nameWithoutExtension", "rename", "copy", "append", "saveString", "setDefaultDir", "getDefaultDir",
            "getLength", "length", "getNameWithoutExtension", "getName", "getDirectory", "getAbsolutePath",
            "getParent", "exists", "isDirectory", "isFile", "makeDirectory", "mkdir", "lastModified",
            "dateLastModified", "delete",
        ],
        "Stack": [
            "size", "isHyperstack", "isHyperStack", "getDimensions", "setPosition", "setChannel", "setSlice",
            "setFrame", "getPosition", "getFrameRate", "setFrameRate", "getFrameInterval", "setFrameInterval",
            "setTUnit", "setXUnit", "setYUnit", "setZUnit", "getUnits", "setDimensions", "setDisplayMode",
            "getDisplayMode",
        ],
        "Table": ["size", "title", "headings", "get", "getString", "set", "getColumn", "setColumn", "columnExists",
            "create", "reset", "update", "show", "save", "open", "showRowNumbers", "hideRowNumbers"],
        "Roi": ["size", "getBounds", "getCoordinates", "getName", "setName", "getType", "move", "translate",
            "remove", "contains"],
        "RoiManager": ["size", "selected", "getName", "getIndex", "select"],
        "Property": ["get", "set", "getInfo", "setInfo", "getSliceLabel"],
        "Image": ["title", "name", "width", "height"],
        "Color": ["foreground", "background", "setForeground", "setBackground"],
    ]
}
