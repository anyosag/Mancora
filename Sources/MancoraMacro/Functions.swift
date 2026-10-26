// A port of ImageJ 1.54p's ij/macro/Functions.java: the built-in functions.
// This file has the dispatch, argument parsing and the functions that are
// part of the language (strings, arrays, lists, math, files); the image,
// selection and results functions are in the files beside it.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraProcess
import MancoraSupport

final class Functions {
    unowned let interp: Interpreter
    var pgm: Program { interp.pgm }
    var session: MacroSession { interp.session }

    var expandableArrays = true
    var random: JavaRandom?
    var buffer: String?
    /// `List.*`'s properties.
    var props: [String: String] = [:]
    /// The file `File.open` opened, which `print(f, ...)` writes to.
    var writer: FileHandle?
    var writerPath: String?
    /// The image whose processor `getProcessor()` last set up (ImageJ's `defaultIP`).
    var cachedProcessor: Int?
    /// The drawing position `moveTo` and `lineTo` use.
    var pen: (x: Int, y: Int) = (0, 0)
    /// `snapshot()`'s copy of a plane, for `reset()`.
    var snapshot: (id: Int, index: Int, plane: Plane)?
    /// The shift and alt keys `setKeyDown` held for the next selection
    /// function (ImageJ's `shiftKeyDown`, `altKeyDown`), and whether it was
    /// called (`Interpreter.keysSet`: the keys are released at the end).
    var selectionShift = false
    var selectionAlt = false
    var keysSet = false

    init(interp: Interpreter) {
        self.interp = interp
    }

    /// The name of a built-in function's symbol type, for messages.
    static let names: [Int: String] = {
        var names: [Int: String] = [:]
        for list in [functions, numericFunctions, stringFunctions, arrayFunctions, variableFunctions] {
            for (name, id) in list where names[id] == nil { names[id] = name }
        }
        return names
    }()

    func finishUp() {
        if let writer {
            try? writer.close()
            self.writer = nil
        }
        if keysSet {
            session.keys.alt = false
            session.keys.shift = false
            session.keys.space = false
        }
        session.finishMacro()
    }

    // MARK: - Dispatch

    func doFunction(_ type: Int) throws(MacroSignal) {
        switch type {
        case RUN:
            try doRun()
            releaseKeys()
        case SELECT: try selectWindow()
        case WAIT:
            let ms = try getArg()
            if ms > 0 { Thread.sleep(forTimeInterval: Double(jInt(ms)) / 1000) }
        case BEEP: try interp.getParens()
        case RESET_MIN_MAX:
            try interp.getParens()
            try resetMinAndMax()
        case RESET_THRESHOLD:
            try interp.getParens()
            try resetThreshold()
        case PRINT, WRITE: try print()
        case SET_MIN_MAX: try setMinAndMax()
        case SET_THRESHOLD: try setThreshold()
        case SET_TOOL: _ = try getStringOrNumberArg()
        case SET_FOREGROUND: try setForegroundColor()
        case SET_BACKGROUND: try setBackgroundColor()
        case SET_COLOR: try setColor()
        case MAKE_LINE: try makeLine()
        case MAKE_OVAL: try makingSelection("makeOval", releasingKeys: true) { () throws(MacroSignal) in try makeOval() }
        case MAKE_RECTANGLE:
            try makingSelection("makeRectangle", releasingKeys: true) { () throws(MacroSignal) in try makeRectangle() }
        case DUMP: try interp.getParens()
        case MOVE_TO: try moveTo()
        case LINE_TO: try lineTo()
        case DRAW_LINE: try drawLine()
        case REQUIRES: try requires()
        case AUTO_UPDATE: _ = try getBooleanArg()
        case UPDATE_DISPLAY: try interp.getParens()
        case SET_PASTE_MODE: _ = try getStringArg()
        case SHOW_STATUS: try showStatus()
        case SHOW_PROGRESS: try showProgress()
        case SHOW_MESSAGE: try showMessage(withCancel: false)
        case SHOW_MESSAGE_WITH_CANCEL: try showMessage(withCancel: true)
        case SET_PIXEL, PUT_PIXEL: try setPixel()
        case SNAPSHOT, RESET: try snapshotOrReset(type)
        case FILL: try fill()
        case SET_LINE_WIDTH: session.lineWidth = jIntI(try getArg())
        case CHANGE_VALUES: try changeValues()
        case SELECT_IMAGE: try selectImage()
        case EXIT: try exit()
        case SET_LOCATION: try skipArgs()
        case GET_VOXEL_SIZE: try getVoxelSize()
        case GET_HISTOGRAM: try getHistogram()
        case GET_LINE: try getLine()
        case GET_BOUNDING_RECT, GET_BOUNDS: try getBounds()
        case GET_LUT: try getLut()
        case GET_COORDINATES: try getCoordinates()
        case MAKE_SELECTION:
            try makingSelection("makeSelection", combines: { $0.kind == .polygon || $0.kind == .freehand }) {
                () throws(MacroSignal) in try makeSelection()
            }
        case SET_RESULT: try setResult()
        case UPDATE_RESULTS: try interp.getParens()
        case SET_BATCH_MODE: try setBatchMode()
        case GET_THRESHOLD: try getThreshold()
        case GET_PIXEL_SIZE: try getPixelSize()
        case SETUP_UNDO: try interp.getParens()
        case SAVE_SETTINGS: try saveSettings()
        case RESTORE_SETTINGS: try restoreSettings()
        case OPEN: try open()
        case SET_FONT: try skipArgs()
        case GET_MIN_AND_MAX: try getMinAndMax()
        case CLOSE: try close()
        case SET_SLICE: try setSlice()
        case NEW_IMAGE: try newImage()
        case SAVE: try save(try getStringArg())
        case SAVE_AS: try saveAs()
        case SET_AUTO_THRESHOLD: try setAutoThreshold()
        case RENAME: try rename(try getStringArg())
        case GET_STATISTICS: try getStatistics(calibrated: true)
        case GET_RAW_STATISTICS: try getStatistics(calibrated: false)
        case SET_VOXEL_SIZE: try setVoxelSize()
        case GET_DATE_AND_TIME: try getDateAndTime()
        case SET_METADATA: try setMetadata()
        case CALCULATOR: try imageCalculator()
        case MAKE_POLYGON: try makingSelection("makePolygon") { () throws(MacroSignal) in try makePolygon() }
        case SET_SELECTION_NAME: try setSelectionName()
        case DRAW_RECT, FILL_RECT, DRAW_OVAL, FILL_OVAL: try drawOrFill(type)
        case SET_OPTION: try setOption()
        case SET_SELECTION_LOC: try setSelectionLocation()
        case GET_DIMENSIONS: try getDimensions()
        case MAKE_POINT:
            // IJ.makePoint adds (shift) or removes (alt) a point of a point selection.
            if session.keys.shift || session.keys.alt, session.context.current?.roi?.kind == .point {
                try unsupported("makePoint with the shift or alt key down")
            }
            try makePoint()
            (selectionShift, selectionAlt) = (false, false)
        case MAKE_ELLIPSE: try makeEllipse()
        case TO_SCALED: try toScaled()
        case TO_UNSCALED: try toUnscaled()
        case SET_KEY_DOWN: try setKeyDown()
        case SET_JUSTIFICATION, SET_Z_COORDINATE, RESTORE_PREVIOUS_TOOL, SET_RGB_WEIGHTS:
            try skipArgs()
        default:
            try unsupported(type)
        }
    }

    func getFunctionValue(_ type: Int) throws(MacroSignal) -> Double {
        switch type {
        case GET_PIXEL: return try getPixel()
        case ABS, COS, EXP, FLOOR, LOG, ROUND, SIN, SQRT, TAN, ATAN, ASIN, ACOS: return try math(type)
        case MATH: return try doMath()
        case MAX_OF, MIN_OF, POW, ATAN2: return try math2(type)
        case GET_TIME:
            try interp.getParens()
            return currentTimeMillis()
        case GET_WIDTH:
            try interp.getParens()
            return Double(try image().image.width)
        case GET_HEIGHT:
            try interp.getParens()
            return Double(try image().image.height)
        case RANDOM: return try randomValue()
        case GET_COUNT, NRESULTS:
            try interp.getParens()
            return Double(session.context.results.count)
        case GET_RESULT: return try getResult()
        case GET_NUMBER: return try getNumber()
        case NIMAGES:
            try interp.getParens()
            return Double(session.context.images.count)
        case NSLICES:
            try interp.getParens()
            return Double(try image().image.stack.count)
        case LENGTH_OF: return try lengthOf()
        case GET_ID:
            try interp.getParens()
            return Double(try image().id)
        case BIT_DEPTH:
            try interp.getParens()
            return Double(try image().image.pixelType.bitDepth)
        case SELECTION_TYPE: return try getSelectionType()
        case IS_OPEN: return try isOpen()
        case IS_ACTIVE: return try isActive()
        case INDEX_OF: return Double(try indexOf(nil))
        case LAST_INDEX_OF:
            let s = try getFirstString()
            return Double(javaLastIndexOf(s, try getLastString()))
        case CHAR_CODE_AT: return try charCodeAt()
        case GET_BOOLEAN: return try getBoolean()
        case STARTS_WITH, ENDS_WITH:
            let s1 = try getFirstString()
            let s2 = try getLastString()
            return (type == STARTS_WITH ? javaStartsWith(s1, s2) : javaEndsWith(s1, s2)) ? 1 : 0
        case IS_NAN: return (try getArg()).isNaN ? 1 : 0
        case GET_ZOOM:
            try interp.getParens()
            return 1
        case PARSE_FLOAT: return parseDouble(try getStringArg())
        case PARSE_INT: return try parseInt()
        case IS_KEY_DOWN: return try isKeyDown()
        case GET_SLICE_NUMBER:
            try interp.getParens()
            return Double(try image().currentSliceNumber)
        case SCREEN_WIDTH, SCREEN_HEIGHT:
            try interp.getParens()
            return type == SCREEN_WIDTH ? 1920 : 1080
        case CALIBRATE: return try calibrate(try getArg())
        case ROI_MANAGER: return try roiManager()
        case TOOL_ID:
            try interp.getParens()
            return 0
        case IS: return try isFunction()
        case GET_VALUE: return try getValue()
        case STACK: return try doStack()
        case MATCHES: return try matches(nil)
        default:
            try unsupported(type)
        }
    }

    func getStringFunction(_ type: Int) throws(MacroSignal) -> String? {
        switch type {
        case D2S:
            let n = try getFirstArg()
            return ImageJFormat.d2s(n, jIntI(try getLastArg()))
        case TO_HEX: return javaToHexString(jInt(try getArg()))
        case TO_BINARY: return javaToBinaryString(jInt(try getArg()))
        case GET_TITLE:
            try interp.getParens()
            return try image().image.title
        case GET_STRING: return try getStringDialog()
        case SUBSTRING: return try substring(nil)
        case FROM_CHAR_CODE: return try fromCharCode()
        case GET_INFO: return try getInfo()
        case GET_IMAGE_INFO:
            try interp.getParens()
            return try imageInfo()
        case GET_DIRECTORY, GET_DIR: return try getDirectory()
        case GET_ARGUMENT:
            try interp.getParens()
            return interp.argument ?? ""
        case TO_LOWER_CASE: return javaToLowerCase(try getStringArg())
        case TO_UPPER_CASE: return javaToUpperCase(try getStringArg())
        case RUN_MACRO: return try runMacro(eval: false)
        case EVAL: return try runMacro(eval: true)
        case TO_STRING: return try doToString()
        case REPLACE: return try replace(nil)
        case DIALOG: return try doDialog()
        case GET_METADATA: return try getMetadata()
        case FILE: return try doFile()
        case SELECTION_NAME: return try selectionName()
        case GET_VERSION:
            try interp.getParens()
            return session.imageJVersion
        case GET_RESULT_LABEL: return try getResultLabel()
        case CALL: return try call()
        case STRING: return try doString()
        case LIST: return try doList()
        case DEBUG:
            if interp.nextToken() == ch("(") { _ = try getStringOrNumberArg() }
            return nil
        case IJ_CALL: return try doIJ()
        case GET_RESULT_STRING: return try getResultString()
        case TRIM:
            if interp.nextToken() == ch("=") { try interp.error("'trim' is a reserved word") }
            return javaTrim(try getStringArg())
        default:
            try unsupported(type)
        }
    }

    func getArrayFunction(_ type: Int) throws(MacroSignal) -> VariableArray? {
        switch type {
        case GET_PROFILE: return try getProfile()
        case NEW_ARRAY: return try newArray()
        case SPLIT: return try split()
        case GET_FILE_LIST: return try getFileList()
        case GET_LIST: return try getList()
        case ARRAY_FUNC: return try doArray()
        default:
            try unsupported(type)
        }
    }

    func getVariableFunction(_ type: Int) throws(MacroSignal) -> Variable {
        var v: Variable?
        switch type {
        case TABLE: v = try doTable()
        case ROI: v = try doRoi()
        case ROI_MANAGER2: v = try doRoiManager()
        case PROPERTY: v = try doProperty()
        case IMAGE: v = try doImage()
        case COLOR: v = try doColor()
        default:
            try unsupported(type)
        }
        return v ?? Variable(Double.nan)
    }

    /// A built-in function Mancora doesn't have: ``MacroSupport`` finds
    /// these before a macro runs, so this only happens when nothing could
    /// run the macro in ImageJ instead.
    func unsupported(_ type: Int) throws(MacroSignal) -> Never {
        try unsupported(Self.names[type] ?? "function \(type)")
    }

    func unsupported(_ name: String) throws(MacroSignal) -> Never {
        try interp.fail("\(name) is not available in Mancora yet (it runs when the Java bridge is installed)")
    }

    /// Whether `name` (a symbol's string) is a string function of a variable function, as Java's static method.
    static func isStringFunction(_ name: String, _ type: Int) -> Bool {
        switch type {
        case TABLE: return ["getString", "title", "headings", "allHeadings"].contains(name)
        case ROI:
            return ["getStrokeColor", "getDefaultColor", "getFillColor", "getName", "getProperty", "getProperties",
                "getGroupNames", "getType"].contains(name)
        case PROPERTY:
            return ["getProperty", "getProperties", "get", "getInfo", "getList", "getSliceLabel", "getDicomTag"]
                .contains(name)
        case ROI_MANAGER2: return name == "getName"
        case IMAGE: return name == "title" || name == "name"
        case COLOR: return ["foreground", "background", "toString", "wavelengthToColor"].contains(name)
        default: return false
        }
    }

    // MARK: - Arguments

    final func getString() throws(MacroSignal) -> String {
        try interp.getString() ?? "null"
    }

    final func getArg() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        let arg = try interp.getExpression()
        try interp.getRightParen()
        return arg
    }

    final func getFirstArg() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        return try interp.getExpression()
    }

    final func getNextArg() throws(MacroSignal) -> Double {
        try interp.getComma()
        return try interp.getExpression()
    }

    final func getLastArg() throws(MacroSignal) -> Double {
        try interp.getComma()
        let arg = try interp.getExpression()
        try interp.getRightParen()
        return arg
    }

    func getStringArg() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        let arg = try getString()
        try interp.getRightParen()
        return arg
    }

    final func getFirstString() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        return try getString()
    }

    final func getNextString() throws(MacroSignal) -> String {
        try interp.getComma()
        return try getString()
    }

    final func getLastString() throws(MacroSignal) -> String {
        try interp.getComma()
        let arg = try getString()
        try interp.getRightParen()
        return arg
    }

    func getBooleanArg() throws(MacroSignal) -> Bool {
        try interp.getLeftParen()
        let arg = try interp.getBooleanExpression()
        try interp.checkBoolean(arg)
        try interp.getRightParen()
        return arg != 0
    }

    final func getFirstVariable() throws(MacroSignal) -> Variable {
        try interp.getLeftParen()
        return try getVariable()
    }

    final func getNextVariable() throws(MacroSignal) -> Variable {
        try interp.getComma()
        return try getVariable()
    }

    final func getLastVariable() throws(MacroSignal) -> Variable {
        try interp.getComma()
        let v = try getVariable()
        try interp.getRightParen()
        return v
    }

    /// A variable (or array element) the function stores a result in.
    final func getVariable() throws(MacroSignal) -> Variable {
        interp.getToken()
        if interp.token != WORD { try interp.error("Variable expected") }
        var v: Variable
        if let local = interp.lookupLocalVariable(interp.tokenAddress) { v = local } else {
            v = try interp.push(interp.tokenAddress, 0, nil)
        }
        if let array = v.getArray() {
            let index = try interp.getIndex()
            try checkIndex(index, 0, v.getArraySize() - 1)
            v = array[index]
        }
        return v
    }

    final func getFirstArrayVariable() throws(MacroSignal) -> Variable {
        try interp.getLeftParen()
        return try getArrayVariable()
    }

    final func getLastArrayVariable() throws(MacroSignal) -> Variable {
        try interp.getComma()
        let v = try getArrayVariable()
        try interp.getRightParen()
        return v
    }

    final func getArrayVariable() throws(MacroSignal) -> Variable {
        interp.getToken()
        if interp.token != WORD { try interp.error("Variable expected") }
        if let local = interp.lookupLocalVariable(interp.tokenAddress) { return local }
        return try interp.push(interp.tokenAddress, 0, nil)
    }

    func getNumericArray() throws(MacroSignal) -> [Double] {
        try getArray().elements.map { $0.getValue() }
    }

    func getStringArray() throws(MacroSignal) -> [String] {
        try getArray().elements.map { $0.getString() ?? javaString($0.getValue()) }
    }

    /// An array argument: a variable, `newArray(...)`, an array function or `Table.getColumn`.
    func getArray() throws(MacroSignal) -> VariableArray {
        interp.getToken()
        if interp.token == VARIABLE_FUNCTION && pgm.table[interp.tokenAddress].type == TABLE {
            let v = try getVariableFunction(TABLE)
            if let a = v.getArray() { return a }
        }
        let newArray = interp.token == ARRAY_FUNCTION && pgm.table[interp.tokenAddress].type == NEW_ARRAY
        let arrayFunction = interp.token == ARRAY_FUNCTION
        if !(interp.token == WORD || newArray || arrayFunction) { try interp.error("Array expected") }
        var a: VariableArray?
        if newArray {
            a = try getArrayFunction(NEW_ARRAY)
        } else if arrayFunction {
            a = try getArrayFunction(pgm.table[interp.tokenAddress].type)
        } else if let v = try interp.lookupVariable() {
            a = v.getArray()
            let size = v.getArraySize()
            if let array = a, array.count != size {
                v.setArray(VariableArray(Array(array.elements[0..<size])))
                a = v.getArray()
            }
        }
        guard let a else { try interp.fail("Array expected") }
        return a
    }

    func checkIndex(_ index: Int, _ lower: Int, _ upper: Int) throws(MacroSignal) {
        if index < lower || index > upper {
            try interp.fail("Index (\(index)) is outside of the \(lower)-\(upper) range")
        }
    }

    /// `isStringArg()`: whether the next argument is a string.
    func isStringArg() -> Bool {
        let nextToken = interp.code(interp.pc + 1)
        let tok = nextToken & 0xff
        if tok == STRING_CONSTANT || tok == STRING_FUNCTION { return true }
        if tok == VARIABLE_FUNCTION && interp.isString(interp.pc + 1) { return true }
        if tok != WORD { return false }
        guard let v = interp.lookupVariable(nextToken >> TOK_SHIFT) else { return false }
        guard let array = v.getArray() else { return v.kind == .string }
        if array.count == 0 || interp.nextNextToken() == ch(".") { return false }
        return array[0].kind == .string
    }

    func isArrayArg() -> Bool {
        let nextToken = interp.code(interp.pc + 1)
        let tok = nextToken & 0xff
        if tok == ARRAY_FUNCTION { return true }
        if tok == VARIABLE_FUNCTION && pgm.table[nextToken >> TOK_SHIFT].type == TABLE {
            return pgm.table[interp.code(interp.pc + 3) >> TOK_SHIFT].str == "getColumn"
        }
        if tok != WORD { return false }
        guard let v = interp.lookupVariable(nextToken >> TOK_SHIFT) else { return false }
        return v.kind == .array && interp.nextNextToken() != ch("[")
    }

    /// Skips a function's arguments, for calls that only matter in the user interface.
    func skipArgs() throws(MacroSignal) {
        if interp.nextToken() == ch("(") { try interp.skipParens() }
    }

    private func getStringOrNumberArg() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        let s = isStringArg() ? try getString() : javaString(try interp.getExpression())
        try interp.getRightParen()
        return s
    }

    // MARK: - Math

    private func doMath() throws(MacroSignal) -> Double {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == NUMERIC_FUNCTION) { try interp.error("Function name expected: ") }
        let name = interp.tokenString ?? ""
        switch name {
        case "min": return javaMin(try getFirstArg(), try getLastArg())
        case "max": return javaMax(try getFirstArg(), try getLastArg())
        case "pow": return javaPow(try getFirstArg(), try getLastArg())
        case "atan2": return jAtan2(try getFirstArg(), try getLastArg())
        case "constrain":
            let v = try getFirstArg()
            let lo = try getNextArg()
            return javaMin(javaMax(v, lo), try getLastArg())
        case "map":
            let value = try getFirstArg()
            let fromLow = try getNextArg()
            let fromHigh = try getNextArg()
            let toLow = try getNextArg()
            let toHigh = try getLastArg()
            return (value - fromLow) * (toHigh - toLow) / (fromHigh - fromLow) + toLow
        default: break
        }
        let arg = try getArg()
        switch name {
        case "ceil": return jCeil(arg)
        case "abs": return abs(arg)
        case "cos": return jCos(arg)
        case "exp": return jExp(arg)
        case "floor": return jFloor(arg)
        case "log": return jLog(arg)
        case "log10": return javaLog10(arg)
        case "round": return Double(javaMathRound(arg))
        case "sin": return jSin(arg)
        case "sqr": return arg * arg
        case "sqrt": return jSqrt(arg)
        case "tan": return jTan(arg)
        case "atan": return jAtan(arg)
        case "asin": return jAsin(arg)
        case "acos": return jAcos(arg)
        case "erf": return ijErf(arg)
        case "toRadians": return arg / 180.0 * Double.pi
        case "toDegrees": return arg * 180.0 / Double.pi
        default:
            try interp.error("Unrecognized function name")
            return .nan
        }
    }

    final func math(_ type: Int) throws(MacroSignal) -> Double {
        let arg = try getArg()
        switch type {
        case ABS: return abs(arg)
        case COS: return jCos(arg)
        case EXP: return jExp(arg)
        case FLOOR: return jFloor(arg)
        case LOG: return jLog(arg)
        case ROUND: return jFloor(arg + 0.5)
        case SIN: return jSin(arg)
        case SQRT: return jSqrt(arg)
        case TAN: return jTan(arg)
        case ATAN: return jAtan(arg)
        case ASIN: return jAsin(arg)
        case ACOS: return jAcos(arg)
        default: return 0
        }
    }

    final func math2(_ type: Int) throws(MacroSignal) -> Double {
        let a1 = try getFirstArg()
        let a2 = try getLastArg()
        switch type {
        case MIN_OF: return javaMin(a1, a2)
        case MAX_OF: return javaMax(a1, a2)
        case POW: return javaPow(a1, a2)
        case ATAN2: return jAtan2(a1, a2)
        default: return 0
        }
    }

    /// `IJMath.erf`: Abramowitz and Stegun 7.1.26 with ImageJ's coefficients.
    private func ijErf(_ x: Double) -> Double { jErf(x) }

    private func randomValue() throws(MacroSignal) -> Double {
        var dseed = Double.nan
        var gaussian = false
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if isStringArg() {
                let arg = javaToLowerCase(try getString())
                if arg == "seed" {
                    try interp.getComma()
                    dseed = try interp.getExpression()
                    let seed = jLong(dseed)
                    if Double(seed) != dseed { try interp.error("Seed not integer") }
                    random = JavaRandom(seed: seed)
                    session.randomSeed = dseed
                } else if arg == "gaussian" {
                    gaussian = true
                } else {
                    try interp.error("'seed' or ''gaussian' expected")
                }
            }
            try interp.getRightParen()
            if !dseed.isNaN { return .nan }
        }
        session.randomSeed = .nan
        try interp.getParens()
        if random == nil { random = JavaRandom() }
        return gaussian ? random!.nextGaussian() : random!.nextDouble()
    }

    private func requires() throws(MacroSignal) {
        let version = try getStringArg()
        if Self.versionLessThan(session.imageJVersion, version) { interp.done = true }
    }

    /// `IJ.versionLessThan`: compares "1.54p"-style versions as strings, as ImageJ does.
    static func versionLessThan(_ have: String, _ need: String) -> Bool {
        javaCompare(have, need) < 0
    }

    // MARK: - Output

    private func print() throws(MacroSignal) {
        interp.inPrint = true
        var s = try getFirstString()
        if interp.nextToken() == ch(",") {
            if javaStartsWith(s, "[") && javaEndsWith(s, "]") {
                try printToWindow(s)
                return
            } else if s == "~0~" {
                guard let writer else { try interp.fail("File not open") }
                var s2 = try getLastString()
                if !javaEndsWith(s2, "\n") { s2 += "\n" }
                try? writer.write(contentsOf: Data(s2.utf8))
                interp.inPrint = false
                return
            }
            repeat {
                s += " " + (try getNextString())
            } while interp.nextToken() == ch(",")
        }
        try interp.getRightParen()
        interp.log(s)
        interp.inPrint = false
    }

    private func printToWindow(_ s: String) throws(MacroSignal) {
        let title = javaSubstring(s, 1, s.utf16.count - 1)
        let s2 = try getLastString()
        if title == "Log" {
            session.log(s2)
        } else {
            try interp.error("Window not found")
        }
    }

    private func showStatus() throws(MacroSignal) {
        try interp.getLeftParen()
        _ = try getString()
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            _ = try getString()
        }
        try interp.getRightParen()
    }

    private func showProgress() throws(MacroSignal) {
        try interp.getLeftParen()
        _ = try interp.getExpression()
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            _ = try interp.getExpression()
        }
        try interp.getRightParen()
    }

    private func showMessage(withCancel: Bool) throws(MacroSignal) {
        var title = "Message"
        var message: String
        try interp.getLeftParen()
        message = try getString()
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            title = message
            message = try getString()
        }
        try interp.getRightParen()
        if !session.showMessage(title: title, message, withCancel: withCancel) {
            // Cancel aborts the macro, as ImageJ's showMessageWithCancel does.
            throw .exit(message: nil)
        }
    }

    private func exit() throws(MacroSignal) -> Never {
        var msg: String?
        if interp.nextToken() == ch("(") {
            try interp.getLeftParen()
            if interp.nextToken() != ch(")") { msg = try getString() }
            try interp.getRightParen()
        }
        interp.finishUp()
        throw .exit(message: msg)
    }

    // MARK: - Dialogs (macros run without a person to answer them)

    private func getNumber() throws(MacroSignal) -> Double {
        let prompt = try getFirstString()
        let defaultValue = try getLastArg()
        return session.askNumber(prompt, defaultValue: defaultValue) ?? defaultValue
    }

    private func getBoolean() throws(MacroSignal) -> Double {
        try interp.getLeftParen()
        let prompt = try getString()
        if interp.nextToken() == ch(",") {
            _ = try getNextString()
            _ = try getNextString()
        }
        try interp.getRightParen()
        return session.askYesNo(prompt) ? 1 : 0
    }

    private func getStringDialog() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        let prompt = try getString()
        try interp.getComma()
        let defaultString = try getString()
        try interp.getRightParen()
        return session.askString(prompt, defaultValue: defaultString) ?? defaultString
    }

    private func doDialog() throws(MacroSignal) -> String? {
        try unsupported("Dialog functions")
    }

    // MARK: - Strings

    private func getStringFunctionArg(_ s: String?) throws(MacroSignal) -> String {
        if let s {
            try interp.getLeftParen()
            return s
        }
        let first = try getFirstString()
        try interp.getComma()
        return first
    }

    func substring(_ sIn: String?) throws(MacroSignal) -> String {
        let s = try getStringFunctionArg(sIn)
        let index1 = jIntI(try interp.getExpression())
        var index2 = s.utf16.count
        if interp.nextToken() == ch(",") { index2 = jIntI(try getLastArg()) } else { try interp.getRightParen() }
        if index1 > index2 { try interp.fail("beginIndex>endIndex") }
        try checkIndex(index1, 0, s.utf16.count)
        try checkIndex(index2, 0, s.utf16.count)
        return javaSubstring(s, index1, index2)
    }

    func indexOf(_ s1In: String?) throws(MacroSignal) -> Int {
        let s1 = try getStringFunctionArg(s1In)
        let s2 = try getString()
        var fromIndex = 0
        if interp.nextToken() == ch(",") {
            fromIndex = jIntI(try getLastArg())
            try checkIndex(fromIndex, 0, s1.utf16.count - 1)
        } else {
            try interp.getRightParen()
        }
        return javaIndexOf(s1, s2, from: fromIndex)
    }

    func matches(_ strIn: String?) throws(MacroSignal) -> Double {
        let str = try getStringFunctionArg(strIn)
        let regex = try getString()
        try interp.getRightParen()
        do {
            return try JavaRegex.matches(str, regex) ? 1 : 0
        } catch {
            try interp.error(error.description)
            return 0
        }
    }

    func replace(_ s1In: String?) throws(MacroSignal) -> String {
        let s1 = try getStringFunctionArg(s1In)
        let s2 = try getString()
        let s3 = try getLastString()
        let pattern = Array(s2.utf16)
        if pattern.count == 1 {
            var out: [UInt16] = []
            let replacement = Array(s3.utf16)
            for c in s1.utf16 {
                if c == pattern[0] { out.append(contentsOf: replacement) } else { out.append(c) }
            }
            return utf16String(out)
        }
        do {
            return try JavaRegex.replaceAll(s1, s2, s3)
        } catch {
            try interp.fail(error.description)
        }
    }

    private func fromCharCode() throws(MacroSignal) -> String {
        var chars: [UInt16] = []
        try interp.getLeftParen()
        while interp.nextToken() != ch(")") {
            let value = jIntI(try interp.getExpression())
            if value < 0 || value > 65535 { try interp.fail("Value (\(value)) out of 0-65535 range") }
            chars.append(UInt16(value))
            if interp.nextToken() == ch(",") { interp.getToken() }
            if interp.done { break }
        }
        try interp.getRightParen()
        return utf16String(chars)
    }

    private func charCodeAt() throws(MacroSignal) -> Double {
        let str = try getFirstString()
        let index = jIntI(try getLastArg())
        try checkIndex(index, 0, str.utf16.count - 1)
        return Double(try interp.javaCharAt(str, index))
    }

    private func lengthOf() throws(MacroSignal) -> Double {
        var length = 0
        try interp.getLeftParen()
        switch interp.nextToken() {
        case STRING_CONSTANT, STRING_FUNCTION, USER_FUNCTION:
            length = try getString().utf16.count
        case WORD:
            if interp.code(interp.pc + 2) == ch("[") {
                length = try getString().utf16.count
                break
            }
            interp.getToken()
            guard let v = try interp.lookupVariable() else { return 0 }
            if let s = v.getString() {
                length = s.utf16.count
            } else if v.getArray() != nil {
                length = v.getArraySize()
            } else {
                try interp.error("String or array expected")
            }
        default:
            try interp.error("String or array expected")
        }
        try interp.getRightParen()
        return Double(length)
    }

    func parseDouble(_ sIn: String?) -> Double {
        guard var s = sIn else { return 0 }
        s = javaTrim(s)
        let space = javaIndexOf(s, " ")
        if space != -1 { s = javaSubstring(s, 0, space) }
        return toolsParseDouble(s)
    }

    private func parseInt() throws(MacroSignal) -> Double {
        let s = try getFirstString()
        var radix = 10
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            radix = jIntI(try interp.getExpression())
            if radix < 2 || radix > 36 { radix = 10 }
        }
        try interp.getRightParen()
        if radix == 10 {
            let n = parseDouble(s)
            return n.isNaN ? n : Double(javaMathRound(n))
        }
        guard let n = javaParseInt(s, radix: radix) else { return .nan }
        return Double(n)
    }

    private func doToString() throws(MacroSignal) -> String {
        try interp.getLeftParen()
        if interp.nextNextToken() == ch(",") {
            let n = try interp.getExpression()
            let digits = jIntI(try getLastArg())
            return ImageJFormat.d2s(n, digits)
        }
        var s = try getString()
        interp.getToken()
        if interp.token == ch(",") {
            let value = toolsParseDouble(s)
            s = ImageJFormat.d2s(value, jIntI(try interp.getExpression()))
            interp.getToken()
        }
        if interp.token != ch(")") { try interp.error("')' expected") }
        return s
    }

    private func doString() throws(MacroSignal) -> String? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == STRING_FUNCTION) { try interp.error("Function name expected: ") }
        let name = interp.tokenString ?? ""
        switch name {
        case "append":
            buffer = (buffer ?? "") + (try getStringArg())
            return nil
        case "resetBuffer":
            try interp.getParens()
            buffer = ""
            return nil
        case "buffer":
            try interp.getParens()
            return buffer ?? ""
        case "join":
            try interp.getLeftParen()
            let array = try getArray()
            var delimiter = ", "
            if interp.nextToken() == ch(",") { delimiter = try getNextString() }
            try interp.getRightParen()
            return Self.join(array, delimiter)
        case "trim": return javaTrim(try getStringArg())
        case "pad": return try pad()
        case "format":
            let format = try getFirstString()
            var params: [Double] = []
            while interp.nextToken() == ch(",") { params.append(try getNextArg()) }
            try interp.getRightParen()
            do {
                return try JavaFormatter.format(format, params)
            } catch {
                try interp.error(error.description)
                return nil
            }
        case "getResultsHeadings":
            try interp.getParens()
            // ResultsTable.getColumnHeadings(): the row number column, Label, then the columns.
            let rt = session.context.results
            let label = rt.labels.contains { $0 != nil } ? "Label\t" : ""
            return " \t" + label + rt.columns.map { $0 + "\t" }.joined()
        case "copy", "show", "copyResults", "paste", "setFontSize":
            try unsupported("String." + name)
        default:
            try interp.error("Unrecognized String function")
            return nil
        }
    }

    /// `joinArray`: numbers as integers, or with 4 decimal places as the results table shows them.
    static func join(_ a: VariableArray, _ delimiter: String) -> String {
        var parts: [String] = []
        parts.reserveCapacity(a.count)
        for v in a.elements {
            if let s = v.getString() {
                parts.append(s)
            } else {
                let value = v.getValue()
                parts.append(
                    Double(jInt(value)) == value ? ImageJFormat.d2s(value, 0) : ImageJFormat.resultsTableD2S(value, 4))
            }
        }
        return parts.joined(separator: delimiter)
    }

    private func pad() throws(MacroSignal) -> String {
        var intArg: Int32 = 0
        var stringArg: String?
        try interp.getLeftParen()
        if isStringArg() { stringArg = try getString() } else { intArg = jInt(try interp.getExpression()) }
        let digits = jIntI(try getLastArg())
        if let stringArg { return ImageJFormat.pad(stringArg, digits) }
        return ImageJFormat.pad(intArg, digits)
    }

    private func doIJ() throws(MacroSignal) -> String? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == NUMERIC_FUNCTION) { try interp.error("Function name expected: ") }
        let name = interp.tokenString ?? ""
        switch name {
        case "pad": return try pad()
        case "log":
            session.log(try getStringArg())
        case "deleteRows":
            let first = jIntI(try getFirstArg())
            let last = jIntI(try getLastArg())
            session.deleteRows(first, last)
        case "freeMemory":
            try interp.getParens()
            return "10MB of 1000MB (1%)"
        case "currentMemory":
            try interp.getParens()
            return "10000000"
        case "maxMemory":
            try interp.getParens()
            return "1000000000"
        case "getToolName":
            try interp.getParens()
            return "rectangle"
        case "redirectErrorMessages":
            try interp.getParens()
        case "renameResults":
            try renameResults()
        case "getFullVersion":
            try interp.getParens()
            return session.imageJVersion + "99"
        case "checksum":
            return try checksum()
        default:
            try interp.error("Unrecognized IJ function name")
        }
        return nil
    }

    private func checksum() throws(MacroSignal) -> String {
        let method = javaToUpperCase(try getFirstString())
        let source = try getLastString()
        let isFile = method.contains("FILE")
        let isString = method.contains("STRING")
        guard isFile || isString, method.contains("MD5") || method.contains("SHA-256") else {
            try interp.error("must contain 'file' or 'string' and 'MD5' or 'SHA-256'")
            return "0"
        }
        let bytes: [UInt8]
        if isFile {
            guard let data = FileManager.default.contents(atPath: source) else { return "0" }
            bytes = Array(data)
        } else {
            bytes = Array(source.utf8)
        }
        return hexString(method.contains("MD5") ? MD5.hash(bytes) : SHA256.hash(bytes))
    }

    // MARK: - Lists

    private func doList() throws(MacroSignal) -> String? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == ARRAY_FUNCTION || interp.token == NUMERIC_FUNCTION) {
            try interp.error("Function name expected: ")
        }
        var value: String?
        let name = interp.tokenString ?? ""
        switch name {
        case "get":
            value = props[try getStringArg()] ?? ""
        case "getValue":
            value = props[try getStringArg()]
            if value == nil { try interp.error("Value not found") }
        case "set", "add", "put":
            let key = try getFirstString()
            props[key] = try getLastString()
        case "clear", "reset":
            try interp.getParens()
            props = [:]
        case "setList":
            props = Self.loadProperties(try getStringArg())
        case "getList":
            try interp.getParens()
            value = props.keys.sorted { javaCompare($0, $1) < 0 }.map { $0 + "=" + props[$0]! + "\n" }.joined()
        case "size", "getSize":
            try interp.getParens()
            value = String(props.count)
        case "setMeasurements":
            try setListMeasurements()
        case "setCommands":
            try interp.getParens()
            props = session.commandTable
        case "indexOf":
            let key = try getStringArg()
            let keys = props.keys.sorted { javaCompare($0, $1) < 0 }
            value = String(keys.firstIndex(of: key) ?? -1)
        case "fromArrays":
            try interp.getLeftParen()
            let keys = try getStringArray()
            try interp.getComma()
            let values = try getStringArray()
            if values.count != keys.count { try interp.fail("Arrays must have same length") }
            props = [:]
            for (k, v) in zip(keys, values) {
                if k.isEmpty { try interp.error("Key cannot be an empty string") }
                props[k] = v
            }
            try interp.getRightParen()
        case "toArrays":
            let keysVariable = try getFirstArrayVariable()
            let valuesVariable = try getLastArrayVariable()
            let keys = props.keys.sorted { javaCompare($0, $1) < 0 }
            keysVariable.setArray(VariableArray(keys.map { Variable($0) }))
            valuesVariable.setArray(VariableArray(keys.map { Variable(props[$0]!) }))
        default:
            try interp.error("Unrecognized List function")
        }
        return value
    }

    /// `Properties.load`: `key=value`, `key:value` or `key value` lines, with `#`/`!` comments and `\` escapes.
    static func loadProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var lines: [[UInt16]] = []
        var current: [UInt16] = []
        var continuing = false
        let units = Array(text.utf16)
        var i = 0
        func isWhite(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 12 }
        while i <= units.count {
            let c: UInt16 = i < units.count ? units[i] : 10
            i += 1
            if c == 10 || c == 13 {
                if c == 13 && i < units.count && units[i] == 10 { i += 1 }
                // An odd number of trailing backslashes continues the line.
                var slashes = 0
                var k = current.count - 1
                while k >= 0 && current[k] == 92 {
                    slashes += 1
                    k -= 1
                }
                if slashes % 2 == 1 {
                    current.removeLast()
                    continuing = true
                    continue
                }
                lines.append(current)
                current = []
                continuing = false
                if i > units.count { break }
                continue
            }
            if continuing && current.isEmpty && isWhite(c) { continue }
            if continuing && isWhite(c) && current.last.map(isWhite) == nil { continue }
            continuing = false
            current.append(c)
        }
        for raw in lines {
            var line = raw[...]
            while let first = line.first, isWhite(first) { line = line.dropFirst() }
            guard let first = line.first, first != 35, first != 33 else { continue }
            var key: [UInt16] = []
            var j = line.startIndex
            var escaped = false
            while j < line.endIndex {
                let c = line[j]
                if escaped {
                    key.append(unescape(c))
                    escaped = false
                } else if c == 92 {
                    escaped = true
                } else if c == 61 || c == 58 || isWhite(c) {
                    break
                } else {
                    key.append(c)
                }
                j += 1
            }
            while j < line.endIndex && isWhite(line[j]) { j += 1 }
            if j < line.endIndex && (line[j] == 61 || line[j] == 58) { j += 1 }
            while j < line.endIndex && isWhite(line[j]) { j += 1 }
            var value: [UInt16] = []
            escaped = false
            while j < line.endIndex {
                let c = line[j]
                if escaped {
                    value.append(unescape(c))
                    escaped = false
                } else if c == 92 {
                    escaped = true
                } else {
                    value.append(c)
                }
                j += 1
            }
            result[utf16String(key)] = utf16String(value)
        }
        return result
    }

    private static func unescape(_ c: UInt16) -> UInt16 {
        switch c {
        case 116: 9  // t
        case 110: 10  // n
        case 114: 13  // r
        case 102: 12  // f
        default: c
        }
    }

    // MARK: - Arrays

    private func newArray() throws(MacroSignal) -> VariableArray {
        if interp.nextToken() != ch("(") || interp.nextNextToken() == ch(")") {
            try interp.getParens()
            return VariableArray([])
        }
        try interp.getLeftParen()
        var elements: [Variable] = []
        repeat {
            let v = Variable()
            if isStringArg() { v.setString(try getString()) } else { v.setValue(try interp.getExpression()) }
            elements.append(v)
            interp.getToken()
        } while interp.token == ch(",")
        if interp.token != ch(")") { try interp.error("';' expected") }
        if elements.count == 1 && elements[0].getString() == nil {
            let size = jIntI(elements[0].getValue())
            if size < 0 { try interp.fail("Negative array size") }
            return VariableArray((0..<size).map { _ in Variable() })
        }
        return VariableArray(elements)
    }

    private func split() throws(MacroSignal) -> VariableArray {
        let s1 = try getFirstString()
        var s2: String?
        if interp.nextToken() == ch(")") { try interp.getRightParen() } else { s2 = try getLastString() }
        var strings: [String]
        do {
            if !s1.isEmpty, let s2, s2 == "," || s2 == ";" {
                strings = try JavaRegex.split(s1, s2)
            } else if !s1.isEmpty, var s2, s2.utf16.count >= 3, javaStartsWith(s2, "("), javaEndsWith(s2, ")") {
                s2 = javaSubstring(s2, 1, s2.utf16.count - 1)
                strings = try JavaRegex.split(s1, s2)
            } else if s2 == nil || s2 == "" {
                strings = Self.toolsSplit(s1, " \t\n\r")
            } else {
                strings = Self.toolsSplit(s1, s2!)
            }
        } catch {
            try interp.fail(error.description)
        }
        return VariableArray(strings.map { Variable($0) })
    }

    /// `Tools.split(str, delim)`: tokens between any of the delimiter characters; `"\n"` splits lines.
    static func toolsSplit(_ str: String, _ delim: String) -> [String] {
        let delimiters = Set(delim.utf16)
        if delim == "\n" {
            // BufferedReader.readLine: \n, \r or \r\n end a line; no empty last line.
            var lines: [String] = []
            var current: [UInt16] = []
            let units = Array(str.utf16)
            var i = 0
            while i < units.count {
                let c = units[i]
                if c == 10 || c == 13 {
                    lines.append(utf16String(current))
                    current = []
                    if c == 13 && i + 1 < units.count && units[i + 1] == 10 { i += 1 }
                } else {
                    current.append(c)
                }
                i += 1
            }
            if !current.isEmpty { lines.append(utf16String(current)) }
            return lines
        }
        var tokens: [String] = []
        var current: [UInt16] = []
        for c in str.utf16 {
            if delimiters.contains(c) {
                if !current.isEmpty { tokens.append(utf16String(current)) }
                current = []
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(utf16String(current)) }
        return tokens
    }

    private func getFileList() throws(MacroSignal) -> VariableArray {
        let dir = try getStringArg()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue,
            var list = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return VariableArray([]) }
        #if !os(Windows)
            list.sort { javaCompare($0, $1) < 0 }
        #endif
        var names: [String] = []
        for name in list where !name.hasPrefix(".") && name != "Thumbs.db" {
            var sub: ObjCBool = false
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path, isDirectory: &sub), sub.boolValue {
                names.append(name + "/")
            } else {
                names.append(name)
            }
        }
        return VariableArray(names.map { Variable($0) })
    }

    private func doArray() throws(MacroSignal) -> VariableArray? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == PREDEFINED_FUNCTION || interp.token == STRING_FUNCTION) {
            try interp.error("Function name expected: ")
        }
        let name = interp.tokenString ?? ""
        switch name {
        case "copy":
            try interp.getLeftParen()
            let a = try getArray()
            try interp.getRightParen()
            return VariableArray(a.elements.map { $0.copy() })
        case "trim":
            try interp.getLeftParen()
            let a = try getArray()
            let size = max(0, min(a.count, jIntI(try getLastArg())))
            return VariableArray(a.elements[0..<size].map { $0.copy() })
        case "sort": return try sortArray()
        case "rankPositions": return try rankPositions()
        case "getStatistics": return try arrayStatistics()
        case "sequence", "getSequence":
            let n = jIntI(try getArg())
            return VariableArray((0..<max(0, n)).map { Variable(Double($0)) })
        case "fill":
            try interp.getLeftParen()
            let a = try getArray()
            let v = try getLastArg()
            for element in a.elements { element.setValue(v) }
            return a
        case "reverse", "invert":
            try interp.getLeftParen()
            let a = try getArray()
            try interp.getRightParen()
            a.elements.reverse()
            return a
        case "concat": return try concatArray()
        case "slice": return try sliceArray()
        case "print":
            var prefix: String?
            try interp.getLeftParen()
            if !isArrayArg() && isStringArg() {
                prefix = try getString()
                try interp.getComma()
            }
            let a = try getArray()
            try interp.getRightParen()
            var str = Self.join(a, ", ")
            if let prefix { str = prefix + " " + str }
            interp.log(str)
            return nil
        case "resample":
            try interp.getLeftParen()
            let a = try getArray()
            let len2 = jIntI(try getLastArg())
            if a.count == 0 || len2 <= 0 { try interp.fail("Cannot resample from or to zero-length") }
            return VariableArray(Self.resample(a.elements.map { $0.getValue() }, len2).map { Variable($0) })
        case "rotate":
            try interp.getLeftParen()
            let a = try getArray()
            try interp.getComma()
            var rot = jIntI(try interp.getExpression())
            try interp.getRightParen()
            let len = a.count
            guard len > 0 else { return a }
            while rot < 0 { rot += len }
            var b = a.elements
            for i in 0..<len { b[(i + rot) % len] = a[i] }
            a.elements = b
            return a
        case "deleteValue", "delete": return try deleteArrayValue()
        case "deleteIndex":
            try interp.getLeftParen()
            let a = try getArray()
            let index = jIntI(try getLastArg())
            try checkIndex(index, 0, a.count - 1)
            var elements: [Variable] = []
            for (i, v) in a.elements.enumerated() where i != index { elements.append(v.copy()) }
            return VariableArray(elements)
        case "filter":
            try interp.getLeftParen()
            let a = try getArray()
            let filter = try getLastString()
            var elements: [Variable] = []
            for v in a.elements {
                guard let str = v.getString() else { continue }
                var contains: Bool
                if javaStartsWith(filter, "(") && javaEndsWith(filter, ")") {
                    contains = (try? JavaRegex.find(str, filter, caseSensitive: false)) ?? false
                } else {
                    contains = javaContains(str, filter)
                }
                if contains { elements.append(v) }
            }
            return VariableArray(elements)
        case "getVertexAngles": return try vertexAngles()
        case "findMaxima", "findMinima": return try findArrayMaxima(minima: name == "findMinima")
        case "show", "fourier":
            try unsupported("Array." + name)
        default:
            try interp.error("Unrecognized Array function")
            return nil
        }
    }

    private func sortArray() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let a = try getArray()
        let multipleArrays = interp.nextToken() == ch(",")
        var indexes: [Int] = []
        let len = a.count
        let nNumbers = a.elements.filter { $0.getString() == nil }.count
        if nNumbers == len {
            var d = a.elements.map { $0.getValue() }
            if multipleArrays { indexes = Self.rank(d) }
            d.sort { javaDoubleCompare($0, $1) < 0 }
            for i in 0..<len { a[i].setValue(d[i]) }
        } else if nNumbers == 0 {
            var s = a.elements.map { $0.getString()! }
            if multipleArrays { indexes = Self.rank(s) }
            s = Self.stableSorted(s) { javaCompareToIgnoreCase($0, $1) }
            for i in 0..<len { a[i].setString(s[i]) }
        } else {
            try interp.error("Mixed strings and numbers")
            return a
        }
        while interp.nextToken() == ch(",") {
            try interp.getComma()
            let b = try getArray()
            if b.count != len {
                try interp.error("Arrays must have same length")
                return a
            }
            let c = indexes.map { b[$0] }
            b.elements = c
        }
        try interp.getRightParen()
        return a
    }

    /// Java's object sort (TimSort) is stable.
    static func stableSorted<T>(_ values: [T], _ compare: (T, T) -> Int) -> [T] {
        values.enumerated().sorted { x, y in
            let c = compare(x.element, y.element)
            return c != 0 ? c < 0 : x.offset < y.offset
        }.map(\.element)
    }

    /// `Tools.rank(double[])`.
    static func rank(_ values: [Double]) -> [Int] {
        stableSorted(Array(values.indices)) { javaDoubleCompare(values[$0], values[$1]) }
    }

    /// `Tools.rank(String[])`.
    static func rank(_ values: [String]) -> [Int] {
        stableSorted(Array(values.indices)) { javaCompareToIgnoreCase(values[$0], values[$1]) }
    }

    private func rankPositions() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let a = try getArray()
        try interp.getRightParen()
        let nNumbers = a.elements.filter { $0.getString() == nil }.count
        if nNumbers != a.count && nNumbers != 0 {
            try interp.error("Mixed strings and numbers")
            return a
        }
        let indexes =
            nNumbers == a.count ? Self.rank(a.elements.map { $0.getValue() }) : Self.rank(a.elements.map { $0.getString()! })
        return VariableArray(indexes.map { Variable(Double($0)) })
    }

    private func arrayStatistics() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let a = try getArray()
        let minv = try getNextVariable()
        var maxv: Variable?, mean: Variable?, std: Variable?
        interp.getToken()
        var arg = 1
        while interp.token == ch(",") {
            arg += 1
            switch arg {
            case 2: maxv = try getVariable()
            case 3: mean = try getVariable()
            case 4: std = try getVariable()
            default: try interp.error("')' expected")
            }
            interp.getToken()
        }
        if interp.token != ch(")") { try interp.error("')' expected") }
        let n = Double(a.count)
        var sum = 0.0, sum2 = 0.0
        var minimum = Double.infinity, maximum = -Double.infinity
        for v in a.elements {
            let value = v.getValue()
            sum += value
            sum2 += value * value
            if value < minimum { minimum = value }
            if value > maximum { maximum = value }
        }
        minv.setValue(minimum)
        maxv?.setValue(maximum)
        mean?.setValue(sum / n)
        if let std {
            let stdDev = (n * sum2 - sum * sum) / n
            std.setValue(jSqrt(stdDev / (n - 1.0)))
        }
        return a
    }

    private func concatArray() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        var elements: [Variable] = []
        repeat {
            if isArrayArg() {
                elements.append(contentsOf: try getArray().elements.map { $0.copy() })
            } else if isStringArg() {
                elements.append(Variable(try getString()))
            } else {
                elements.append(Variable(try interp.getExpression()))
            }
            interp.getToken()
        } while interp.token == ch(",")
        return VariableArray(elements)
    }

    private func sliceArray() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let a = try getArray()
        let len = a.count
        var i1 = jIntI(try getNextArg())
        var i2 = len
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            i2 = jIntI(try interp.getExpression())
        }
        if i1 < 0 { try interp.fail("Invalid argument") }
        if i2 > len { i2 = len }
        var len2 = i2 - i1
        if len2 < 0 { len2 = 0 }
        if len2 > len { len2 = len }
        try interp.getRightParen()
        var elements: [Variable] = []
        for _ in 0..<len2 {
            guard i1 < len else { try interp.fail("Index (\(i1)) out of 0-\(len - 1) range") }
            elements.append(a[i1].copy())
            i1 += 1
        }
        return VariableArray(elements)
    }

    private func deleteArrayValue() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let a = try getArray()
        var value = Double.greatestFiniteMagnitude
        var stringValue: String?
        try interp.getComma()
        if isStringArg() { stringValue = try getString() } else { value = try interp.getExpression() }
        try interp.getRightParen()
        var kept: [Variable] = []
        for v in a.elements {
            var remove = false
            if let stringValue {
                if v.kind == .string { remove = stringValue == v.getString() }
            } else if v.kind == .value {
                let val = v.getValue()
                remove = val == value || (val.isNaN && value.isNaN)
            }
            if !remove { kept.append(v.copy()) }
        }
        return VariableArray(kept)
    }

    /// `Tools.resampleArray`.
    static func resample(_ y1: [Double], _ len2: Int) -> [Double] {
        let len1 = y1.count
        let factor = Double(len2 - 1) / Double(len1 - 1)
        var y2 = [Double](repeating: 0, count: len2)
        if len1 == 0 { return y2 }
        if len1 == 1 { return [Double](repeating: y1[0], count: len2) }
        let f2 = (0..<len2).map { Double($0) / factor }
        for jj in 0..<(len2 - 1) {
            let pos = f2[jj]
            let leftPos = jIntI(jFloor(pos))
            let rightPos = leftPos + 1
            let fraction = pos - jFloor(pos)
            y2[jj] = y1[leftPos] + fraction * (y1[rightPos] - y1[leftPos])
        }
        y2[len2 - 1] = y1[len1 - 1]
        return y2
    }

    private func vertexAngles() throws(MacroSignal) -> VariableArray {
        try interp.getLeftParen()
        let xx = try getArray()
        try interp.getComma()
        let yy = try getArray()
        try interp.getComma()
        let arm = jIntI(try interp.getExpression())
        let len = xx.count
        if yy.count != len { try interp.fail("Same size expected") }
        try interp.getRightParen()
        let x = xx.elements.map { $0.getValue() }, y = yy.elements.map { $0.getValue() }
        var angles: [Variable] = []
        for mid in 0..<len {
            let left = (mid + 10 * len - arm) % len
            let right = (mid + arm) % len
            let dotprod = (x[right] - x[mid]) * (x[left] - x[mid]) + (y[right] - y[mid]) * (y[left] - y[mid])
            let crossprod = (x[right] - x[mid]) * (y[left] - y[mid]) - (y[right] - y[mid]) * (x[left] - x[mid])
            var phi = 180.0 - 180.0 / Double.pi * jAtan2(crossprod, dotprod)
            while phi >= 180.0 { phi -= 360.0 }
            angles.append(Variable(phi))
        }
        return VariableArray(angles)
    }

    private func findArrayMaxima(minima: Bool) throws(MacroSignal) -> VariableArray {
        var edgeMode = 0
        try interp.getLeftParen()
        let a = try getArray()
        let tolerance = try getNextArg()
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            edgeMode = jIntI(try interp.getExpression())
        }
        try interp.getRightParen()
        let d = a.elements.map { $0.getValue() }
        let maxima = minima
            ? MaximumFinder1D.findMinima(d, tolerance, edgeMode) : MaximumFinder1D.findMaxima(d, tolerance, edgeMode)
        return VariableArray(maxima.map { Variable(Double($0)) })
    }

    // MARK: - Files and directories

    private func getDirectory() throws(MacroSignal) -> String {
        session.directory(try getStringArg()) ?? ""
    }

    private func doFile() throws(MacroSignal) -> String? {
        interp.getToken()
        if interp.token != ch(".") { try interp.error("'.' expected") }
        interp.getToken()
        if !(interp.token == WORD || interp.token == STRING_FUNCTION || interp.token == NUMERIC_FUNCTION
            || interp.token == PREDEFINED_FUNCTION)
        {
            try interp.error("Function name expected: ")
        }
        let name = interp.tokenString ?? ""
        let fm = FileManager.default
        switch name {
        case "open": return try openFile()
        case "openAsString":
            let path = try getStringArg()
            guard let data = fm.contents(atPath: path) else {
                try interp.error("File not found")
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        case "openAsRawString":
            var maximum = 5000
            let path = try getFirstString()
            var specifiedMax = false
            if interp.nextToken() == ch(",") {
                maximum = jIntI(try getNextArg())
                specifiedMax = true
            }
            try interp.getRightParen()
            guard let data = fm.contents(atPath: path) else { try interp.fail("File not found") }
            if maximum > data.count || (javaEndsWith(path, ".txt") && !specifiedMax) { maximum = data.count }
            return utf16String(data.prefix(maximum).map { UInt16($0) })
        case "close":
            let f = try getStringArg()
            if f != "~0~" { try interp.error("Invalid file variable") }
            if let writer {
                try? writer.close()
                self.writer = nil
            }
            return nil
        case "separator":
            try interp.getParens()
            #if os(Windows)
                return "\\"
            #else
                return "/"
            #endif
        case "directory":
            try interp.getParens()
            return session.lastDirectory ?? ""
        case "name":
            try interp.getParens()
            return session.lastName ?? ""
        case "nameWithoutExtension":
            try interp.getParens()
            guard var name = session.lastName else { return "" }
            let dot = javaLastIndexOf(name, ".")
            if dot >= 0 && name.utf16.count - dot <= 5 { name = javaSubstring(name, 0, dot) }
            return name
        case "rename":
            let f1 = try getFirstString()
            let f2 = try getLastString()
            guard try checkPath(f1), try checkPath(f2) else { return "0" }
            return (try? fm.moveItem(atPath: f1, toPath: f2)) != nil ? "1" : "0"
        case "copy":
            let f1 = try getFirstString()
            let f2 = try getLastString()
            do {
                if fm.fileExists(atPath: f2) { try fm.removeItem(atPath: f2) }
                try fm.copyItem(atPath: f1, toPath: f2)
            } catch {
                try interp.error("\(error)")
            }
            return nil
        case "append":
            let text = try getFirstString()
            let path = try getLastString()
            appendLine(text, to: path)
            return nil
        case "saveString":
            let text = try getFirstString()
            let path = try getLastString()
            if (try? Data(text.utf8).write(to: URL(fileURLWithPath: path))) == nil {
                try interp.error("Error saving " + path)
            }
            return nil
        case "setDefaultDir":
            session.defaultDirectory = try getStringArg()
            return nil
        case "getDefaultDir":
            return session.defaultDirectory ?? ""
        case "openSequence", "openDialog", "openUrlAsString":
            try unsupported("File." + name)
        default:
            break
        }
        let path = try getStringArg()
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
        switch name {
        case "getLength", "length":
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return String(exists && !isDirectory.boolValue ? size : 0)
        case "getNameWithoutExtension":
            var name2 = Self.javaFileName(path)
            let dot = javaLastIndexOf(name2, ".")
            if dot >= 0 { name2 = javaSubstring(name2, 0, dot) }
            return name2
        case "getName":
            return Self.javaFileName(path)
        case "getDirectory":
            guard let parent = Self.javaParent(path) else { return "" }
            return parent.replacingAll("\\", with: "/") + "/"
        case "getAbsolutePath":
            return path.hasPrefix("/") ? path : fm.currentDirectoryPath + "/" + path
        case "getParent":
            return Self.javaParent(path)
        case "exists":
            return exists ? "1" : "0"
        case "isDirectory":
            return exists && isDirectory.boolValue ? "1" : "0"
        case "isFile":
            return exists && !isDirectory.boolValue ? "1" : "0"
        case "makeDirectory", "mkdir":
            try? fm.createDirectory(at: url, withIntermediateDirectories: false)
            return nil
        case "lastModified":
            let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            return String(Int64((date?.timeIntervalSince1970 ?? 0) * 1000))
        case "dateLastModified":
            let date = ((try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil) ?? Date(
                timeIntervalSince1970: 0)
            return Self.javaDateString(date)
        case "delete":
            return (try? fm.removeItem(atPath: path)) != nil ? "1" : "0"
        default:
            try interp.error("Unrecognized File function " + name)
            return nil
        }
    }

    private func checkPath(_ path: String) throws(MacroSignal) -> Bool {
        if path == "0" || path == "NaN" {
            try interp.error("Invalid path")
            return false
        }
        return true
    }

    /// `IJ.append(text, path)`: the text and a line separator.
    private func appendLine(_ text: String, to path: String) {
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }

    private func openFile() throws(MacroSignal) -> String {
        if writer != nil {
            try interp.error("Currently, only one file can be open at a time")
            return ""
        }
        let path = try getFirstString()
        if interp.nextToken() == ch(")") {
            try interp.getRightParen()
        } else {
            _ = try getLastString()
            try unsupported("File.open with a save dialog")
        }
        if path.isEmpty { try unsupported("File.open with a save dialog") }
        let allowed = [".txt", ".java", ".xls", ".csv", ".tsv", ".ijm", ".html", ".htm"]
        if FileManager.default.fileExists(atPath: path) && !allowed.contains(where: { javaEndsWith(path, $0) }) {
            try interp.error("File exists and suffix is not '.txt', '.java', etc.")
        }
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let handle = FileHandle(forWritingAtPath: path)
        else {
            try interp.error("File open error \n\"" + path + "\"\n")
            return ""
        }
        writer = handle
        writerPath = path
        return "~0~"
    }

    /// `new File(path).getName()`.
    static func javaFileName(_ path: String) -> String {
        let i = max(javaLastIndexOf(path, "/"), javaLastIndexOf(path, Self.separator))
        return javaSubstring(path, i + 1)
    }

    /// `new File(path).getParent()`.
    static func javaParent(_ pathIn: String) -> String? {
        var path = pathIn
        while path.utf16.count > 1 && (javaEndsWith(path, "/") || javaEndsWith(path, Self.separator)) {
            path = javaSubstring(path, 0, path.utf16.count - 1)
        }
        let i = max(javaLastIndexOf(path, "/"), javaLastIndexOf(path, Self.separator))
        if i < 0 { return nil }
        if i == 0 { return path.utf16.count > 1 ? javaSubstring(path, 0, 1) : nil }
        return javaSubstring(path, 0, i)
    }

    #if os(Windows)
        static let separator = "\\"
    #else
        static let separator = "/"
    #endif

    /// `Date.toString()`: "Mon Oct 26 04:10:00 UTC 2026".
    static func javaDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Other

    private func getDateAndTime() throws(MacroSignal) {
        let year = try getFirstVariable()
        let month = try getNextVariable()
        let dayOfWeek = try getNextVariable()
        let dayOfMonth = try getNextVariable()
        let hour = try getNextVariable()
        let minute = try getNextVariable()
        let second = try getNextVariable()
        let millisecond = try getLastVariable()
        let f = currentDateFields()
        for (v, value) in zip([year, month, dayOfWeek, dayOfMonth, hour, minute, second, millisecond], f) {
            v.setValue(value)
        }
    }

    private func getInfo() throws(MacroSignal) -> String {
        if interp.nextNextToken() == STRING_CONSTANT || (interp.nextToken() == ch("(") && interp.nextNextToken() != ch(")")) {
            return try getInfo(try getStringArg())
        }
        try interp.getParens()
        return try imageInfo()
    }

    private func getInfo(_ key: String) throws(MacroSignal) -> String {
        let lowercaseKey = javaToLowerCase(key)
        switch lowercaseKey {
        case "log": return session.logText
        case "micrometer.abbreviation": return "\u{00B5}m"
        case "image.title": return try image().image.title
        case "window.contents": return try imageInfo()
        case "macro.filepath": return session.macroPath ?? "null"
        case "threshold.method": return session.thresholdMethod
        case "threshold.mode": return session.thresholdMode
        case "window.type": return session.context.current == nil ? "" : "Image"
        case "window.title", "window.name": return session.context.current?.title ?? ""
        case "command.name": return ""
        default: break
        }
        if let value = try imageInfo(forKey: key, lowercaseKey: lowercaseKey) { return value }
        if !javaContains(key, ".") { return "" }
        return Self.systemProperty(key) ?? "Invalid key"
    }

    /// The Java system properties macros read through `getInfo`.
    static func systemProperty(_ key: String) -> String? {
        switch key {
        case "os.name":
            #if os(macOS)
                return "Mac OS X"
            #elseif os(Windows)
                return "Windows 10"
            #else
                return "Linux"
            #endif
        case "file.separator": return separator
        case "line.separator": return "\n"
        case "path.separator":
            #if os(Windows)
                return ";"
            #else
                return ":"
            #endif
        case "user.home": return FileManager.default.homeDirectoryForCurrentUser.path
        case "user.dir": return FileManager.default.currentDirectoryPath
        case "user.name": return ProcessInfo.processInfo.environment["USER"] ?? ProcessInfo.processInfo.environment["USERNAME"]
        case "java.io.tmpdir": return NSTemporaryDirectory()
        case "java.version": return "21"
        case "os.arch":
            #if arch(arm64)
                return "aarch64"
            #else
                return "amd64"
            #endif
        default: return ProcessInfo.processInfo.environment[key]
        }
    }

    private func runMacro(eval: Bool) throws(MacroSignal) -> String? {
        try interp.getLeftParen()
        let name = try getString()
        var arg: String?
        if interp.nextToken() == ch(",") {
            try interp.getComma()
            arg = try getString()
        }
        try interp.getRightParen()
        if eval {
            if arg != nil && ["script", "js", "bsh", "python"].contains(name) { try unsupported("eval(\"\(name)\", ...)") }
            return try session.runMacro(code: name, argument: arg)
        }
        return try session.runMacroFile(name, argument: arg)
    }

    private func call() throws(MacroSignal) -> String? {
        let fullName = try getFirstString()
        var args: [String] = []
        while interp.nextToken() == ch(",") { args.append(try getNextString()) }
        try interp.getRightParen()
        switch fullName {
        case "ij.IJ.pad":
            guard args.count == 2 else { break }
            return ImageJFormat.pad(args[0], jIntI(toolsParseDouble(args[1])))
        case "java.lang.System.getProperty":
            guard args.count == 1 else { break }
            return Self.systemProperty(args[0]) ?? "null"
        case "ij.IJ.freeMemory":
            return "10MB of 1000MB (1%)"
        case "ij.IJ.maxMemory":
            return "1000000000"
        case "java.lang.Thread.sleep", "ij.IJ.wait":
            if let ms = args.first { Thread.sleep(forTimeInterval: max(0, toolsParseDouble(ms)) / 1000) }
            return nil
        case "ij.Prefs.get":
            guard args.count == 2 else { break }
            return session.preferences[args[0]] ?? args[1]
        case "ij.Prefs.set":
            guard args.count == 2 else { break }
            session.preferences[args[0]] = args[1]
            return nil
        default:
            break
        }
        try unsupported("call(\"\(fullName)\")")
    }
}
