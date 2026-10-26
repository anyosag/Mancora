public import MancoraCommands

/// What in a macro Mancora can't run itself: built-in functions it doesn't
/// have, and `run("...")` commands that aren't native. A macro that uses
/// any of these runs entirely in ImageJ (through the Java bridge) instead,
/// so it never stops half-way through.
public enum MacroSupport {
    /// The unsupported functions and commands `source` names, in the order
    /// they appear (each once).
    ///
    /// Besides the functions Mancora lacks, this finds the calls whose
    /// constant arguments ask for something only ImageJ does: `run`
    /// commands, `call` targets, `roiManager` commands, `eval` languages,
    /// `open`, `save` and `saveAs` formats, `getInfo` and `setOption` keys.
    /// Arguments computed while the macro runs are only known then.
    ///
    /// - Parameter answersPrompts: whether the session running the macro has
    ///   a ``MacroSession/onPrompt`` handler, so a person can choose the
    ///   folders and files `getDirectory("Choose a Folder")`,
    ///   `File.openDialog` and `open()` ask for. Without one those need
    ///   ImageJ's own dialogs.
    public static func unsupported(in source: String, registry: CommandRegistry, answersPrompts: Bool = false)
        -> [String]
    {
        let pgm = Tokenizer.tokenize(source)
        var found: [String] = []
        func note(_ name: String) { if !found.contains(name) { found.append(name) } }
        let code = pgm.code
        func token(_ j: Int) -> Int { j < code.count ? code[j] : EOF }
        /// The string constant at `j`, if the token there is one.
        func string(_ j: Int) -> String? {
            guard token(j) & TOK_MASK == STRING_CONSTANT else { return nil }
            return pgm.table[token(j) >> TOK_SHIFT].str
        }
        /// The first argument of the call at `i` when it is a string constant: `f("text")` or `f("text", ...)`.
        func constantArgument(_ i: Int) -> String? {
            guard token(i + 1) == ch("("), let s = string(i + 2), token(i + 3) == ch(")") || token(i + 3) == ch(",")
            else { return nil }
            return s
        }
        /// The string constant the first argument ends with (`dir + "x.png"`), for paths.
        func pathConstant(_ i: Int) -> String? {
            guard token(i + 1) == ch("(") else { return nil }
            var depth = 0
            var j = i + 2
            var last: Int?
            while token(j) & TOK_MASK != EOF {
                let t = token(j)
                if t == ch("(") || t == ch("[") {
                    depth += 1
                } else if t == ch(")") || t == ch("]") {
                    if depth == 0 { break }
                    depth -= 1
                } else if t == ch(","), depth == 0 {
                    break
                }
                last = j
                j += 1
            }
            return last.flatMap(string)
        }
        var i = 0
        while i < code.count {
            let tok = code[i] & TOK_MASK
            if tok == EOF { break }
            let address = code[i] >> TOK_SHIFT
            switch tok {
            case PREDEFINED_FUNCTION, NUMERIC_FUNCTION, STRING_FUNCTION, ARRAY_FUNCTION, VARIABLE_FUNCTION:
                let symbol = pgm.table[address]
                let name = symbol.str ?? ""
                if token(i + 1) == ch("."), let member = pgm.table[token(i + 2) >> TOK_SHIFT].str,
                    let members = families[name]
                {
                    let full = name + "." + member
                    if !members.contains(member) || (!answersPrompts && promptMembers.contains(full)) { note(full) }
                    i += 3
                    continue
                }
                if unsupportedFunctions.contains(name) { note(name) }
                // ImageJ smooths a thresholded wand selection with a macro of its own.
                if symbol.type == DO_WAND, stringArgument(of: pgm, at: i + 1, contains: "smooth") {
                    note("doWand(\"smooth\")")
                }
                switch symbol.type {
                case RUN:
                    // run("Command") or run("Command", "options"): a constant name.
                    if let command = constantArgument(i), !registry.isNative(command) { note("run(\"\(command)\")") }
                case CALL:
                    if let target = constantArgument(i), !Functions.nativeCalls.contains(target) {
                        note("call(\"\(target)\")")
                    }
                case ROI_MANAGER:
                    if let command = constantArgument(i), !Functions.isNativeRoiManagerCommand(command.lowercased()) {
                        note("roiManager(\"\(command)\")")
                    }
                case EVAL:
                    if let language = constantArgument(i), token(i + 3) == ch(","),
                        ["script", "js", "bsh", "python"].contains(language)
                    {
                        note("eval(\"\(language)\")")
                    }
                case RUN_MACRO:
                    if let path = pathConstant(i), let ext = Functions.fileExtension(path),
                        ["js", "bsh", "py", "groovy", "clj", "rb", "java"].contains(ext)
                    {
                        note("runMacro(\"\(Functions.javaFileName(path))\")")
                    }
                case SAVE_AS:
                    guard let format = constantArgument(i) else { break }
                    if token(i + 3) == ch(")") {
                        // saveAs(path) saves as save(path) does; saveAs(format) asks where.
                        if format.contains("/") || format.contains(Functions.separator) {
                            if !Functions.saveFormat(forPath: format).isNative { note("save(\"\(Functions.javaFileName(format))\")") }
                        } else {
                            note("saveAs(\"\(format)\") with a save dialog")
                        }
                    } else if !Functions.SaveFormat(format).isNative {
                        note("saveAs(\"\(format)\")")
                    }
                case SAVE:
                    if let path = pathConstant(i), !Functions.saveFormat(forPath: path).isNative {
                        note("save(\"\(Functions.javaFileName(path))\")")
                    }
                case OPEN:
                    if token(i + 1) == ch("("), token(i + 2) == ch(")") {
                        if !answersPrompts { note("open()") }
                    } else if let path = pathConstant(i), let ext = Functions.fileExtension(path),
                        !Functions.nativeOpenExtensions.contains(ext)
                    {
                        note("open(\"\(Functions.javaFileName(path))\")")
                    }
                case GET_INFO:
                    if token(i + 1) == ch("("), token(i + 2) == ch(")") {
                        note("getInfo()")
                    } else if let key = constantArgument(i), key.lowercased() == "window.contents" {
                        note("getInfo(\"\(key)\")")
                    }
                case GET_DIRECTORY, GET_DIR:
                    if let title = constantArgument(i), !Functions.directoryKeys.contains(title.lowercased()),
                        !answersPrompts || title.lowercased() == "preferences"
                    {
                        note("\(name)(\"\(title)\")")
                    }
                case SET_OPTION:
                    guard let option = constantArgument(i) else { break }
                    switch option.lowercased() {
                    case "inverty":
                        break
                    case "changes":
                        // Mancora doesn't track changes, so is("changes") is false: as after setOption("Changes", false).
                        let off = token(i + 3) == ch(",") && token(i + 5) == ch(")")
                            && (token(i + 4) & TOK_MASK == FALSE
                                || (token(i + 4) & TOK_MASK == NUMBER && pgm.table[token(i + 4) >> TOK_SHIFT].value == 0))
                        if !off { note("setOption(\"\(option)\")") }
                    default:
                        break
                    }
                case SET_Z_COORDINATE, SET_RGB_WEIGHTS:
                    note(name)
                case MAKE_POINT:
                    // makePoint(x, y, "... add"): a point added to the overlay.
                    var j = i + 2
                    var depth = 0
                    while token(j) & TOK_MASK != EOF, depth > 0 || token(j) != ch(")") {
                        if token(j) == ch("(") { depth += 1 } else if token(j) == ch(")") { depth -= 1 }
                        if let s = string(j), s.contains("add") { note("makePoint with \"add\"") }
                        j += 1
                    }
                default:
                    break
                }
            default:
                break
            }
            i += 1
        }
        return found
    }

    /// Whether a string constant among the arguments of the call whose "("
    /// is at `start` contains `text`.
    static func stringArgument(of pgm: Program, at start: Int, contains text: String) -> Bool {
        let code = pgm.code
        guard start < code.count, code[start] == ch("(") else { return false }
        var depth = 0
        var i = start
        while i < code.count, code[i] & TOK_MASK != EOF {
            if code[i] == ch("(") { depth += 1 }
            if code[i] == ch(")") {
                depth -= 1
                if depth == 0 { return false }
            }
            if code[i] & TOK_MASK == STRING_CONSTANT, pgm.table[code[i] >> TOK_SHIFT].str?.contains(text) == true {
                return true
            }
            i += 1
        }
        return false
    }

    /// Top-level built-ins that only ImageJ has (user interface, plots,
    /// fitting, overlays, drawing text...).
    static let unsupportedFunctions: Set<String> = [
        "doCommand", "drawString", "exec", "Ext",
        "Fit", "floodFill", "getCursorLoc", "getDisplayedArea", "getFontList", "getImageInfo",
        "getLocationAndSize", "getStringWidth", "makeText", "newMenu", "Overlay", "Plot", "setLut",
        "showText",
    ]

    /// `Family.member` built-ins that need a person to choose a file or
    /// folder, which only a ``MacroSession/onPrompt`` handler can do natively.
    static let promptMembers: Set<String> = ["File.openDialog"]

    /// `Family.member` built-ins Mancora has, by family.
    static let families: [String: Set<String>] = [
        "Array": [
            "copy", "trim", "sort", "rankPositions", "getStatistics", "sequence", "getSequence", "fill", "reverse",
            "invert", "concat", "slice", "print", "resample", "rotate", "deleteValue", "delete", "deleteIndex", "filter",
            "getVertexAngles", "findMaxima", "findMinima", "show",
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
            "dateLastModified", "delete", "openDialog",
        ],
        "Stack": [
            "size", "isHyperstack", "isHyperStack", "getDimensions", "setPosition", "setChannel", "setSlice",
            "setFrame", "getPosition", "getFrameRate", "setFrameRate", "getFrameInterval", "setFrameInterval",
            "setTUnit", "setXUnit", "setYUnit", "setZUnit", "getUnits", "setDimensions", "setDisplayMode",
            "getDisplayMode",
        ],
        "Table": [
            "size", "title", "headings", "allHeadings", "get", "getString", "set", "getColumn", "setColumn",
            "columnExists", "create", "reset", "update", "applyMacro", "deleteRows", "deleteColumn", "renameColumn",
            "save", "open", "rename", "showRowNumbers", "showRowIndexes", "hideRowNumbers", "saveColumnHeader",
            "saveColumnHeaders", "sort", "showArray", "showArrays", "getSelectionStart", "getSelectionEnd",
            "setSelection", "setLocAndSize", "setLocationAndSize",
        ],
        "Roi": [
            "size", "getBounds", "getFloatBounds", "getCoordinates", "getContainedPoints", "getName", "setName",
            "getType", "move", "translate", "remove", "selectNone", "contains", "copy", "paste", "getStrokeColor",
            "setStrokeColor", "getFillColor", "setFillColor", "getStrokeWidth", "setStrokeWidth",
            "setUnscalableStrokeWidth", "setMinStrokeWidth", "setAntiAlias", "getGroup", "getProperty",
            "setProperty", "getProperties", "getPosition", "setPosition", "getPointPosition", "getFeretPoints",
            "getDefaultColor", "getDefaultStrokeWidth", "setDefaultStrokeWidth", "getDefaultGroup", "getGroupNames",
            "setGroupNames", "setFontSize", "setJustification",
        ],
        "RoiManager": [
            "size", "selected", "getName", "getIndex", "select", "selectByName", "selectGroup", "selectPosition",
            "setPosition", "translate", "delete", "associateROIsWithSlices", "restoreCentered", "useNamesAsLabels",
        ],
        "Property": ["get", "set", "getInfo", "setInfo", "getSliceLabel"],
        "Image": ["title", "name", "width", "height"],
        "Color": ["foreground", "background", "setForeground", "setBackground"],
        "Dialog": [
            "create", "createNonBlocking", "addString", "addDirectory", "addFile", "addImageChoice", "addNumber",
            "addSlider", "addCheckbox", "addCheckboxGroup", "addRadioButtonGroup", "addMessage", "addHelp",
            "addChoice", "setInsets", "addImage", "addToSameRow", "enableYesNoCancel", "setLocation", "getLocation",
            "show", "getString", "getNumber", "getCheckbox", "getChoice", "getImageChoice", "getRadioButton",
            "getYesNoCancel",
        ],
    ]
}
