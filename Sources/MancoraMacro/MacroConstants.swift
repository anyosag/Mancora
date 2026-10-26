// Token and built-in function constants, ported from ImageJ 1.54p's
// ij/macro/MacroConstants.java. The numbers must not change: the interpreter
// classifies symbols by these ranges, as ImageJ does.

/// In the tokenized macro, the token and an optional symbol table address are
/// packed into one integer: the token in the low 12 bits, the address above.
let TOK_SHIFT = 12
let TOK_MASK = 0xfff

// Two-character operators (values below 32, so they never clash with ASCII).
let PLUS_PLUS = 1, MINUS_MINUS = 2, EQ = 3, NEQ = 4, GT = 5, GTE = 6, LT = 7, LTE = 8,
    PLUS_EQUAL = 9, MINUS_EQUAL = 10, MUL_EQUAL = 11, DIV_EQUAL = 12, LOGICAL_AND = 13, LOGICAL_OR = 14,
    SHIFT_RIGHT = 15, SHIFT_LEFT = 16

// Token types.
let EOF = 128, WORD = 129, NUMBER = 130, NOP = 131, STRING_CONSTANT = 133,
    PREDEFINED_FUNCTION = 134, NUMERIC_FUNCTION = 135, STRING_FUNCTION = 136, ARRAY_FUNCTION = 137,
    USER_FUNCTION = 138, ARRAY = 139, VARIABLE_FUNCTION = 140

// Keywords.
let MACRO = 200, VAR = 201, IF = 202, ELSE = 203, WHILE = 204, DO = 205, FOR = 206, FUNCTION = 207,
    RETURN = 208, TRUE = 209, FALSE = 210, PI = 211, NaN = 212, BREAK = 213, CONTINUE = 214

let keywords: [(String, Int)] = [
    ("macro", MACRO), ("var", VAR), ("if", IF), ("else", ELSE), ("while", WHILE), ("do", DO),
    ("for", FOR), ("function", FUNCTION), ("return", RETURN), ("true", TRUE), ("false", FALSE),
    ("PI", PI), ("NaN", NaN), ("break", BREAK), ("continue", CONTINUE),
]

// Functions that don't return a value.
let RUN = 300, INVERT = 301, SELECT = 302, WAIT = 303, BEEP = 304, RESET_MIN_MAX = 305, RESET_THRESHOLD = 306,
    PRINT = 307, WRITE = 308, DO_WAND = 309, SET_MIN_MAX = 310, SET_THRESHOLD = 311, SET_TOOL = 312,
    SET_FOREGROUND = 313, SET_BACKGROUND = 314, MAKE_LINE = 315, MAKE_OVAL = 316, MAKE_RECTANGLE = 317,
    DUMP = 318, MOVE_TO = 319, LINE_TO = 320, DRAW_LINE = 321, REQUIRES = 322, AUTO_UPDATE = 323,
    UPDATE_DISPLAY = 324, DRAW_STRING = 325, SET_PASTE_MODE = 326, DO_COMMAND = 327, SHOW_STATUS = 328,
    SHOW_PROGRESS = 329, SHOW_MESSAGE = 330, PUT_PIXEL = 331, SET_PIXEL = 332, SNAPSHOT = 333, RESET = 334,
    FILL = 335, SET_COLOR = 336, SET_LINE_WIDTH = 337, CHANGE_VALUES = 338, SELECT_IMAGE = 339, EXIT = 340,
    SET_LOCATION = 341, GET_CURSOR_LOC = 342, GET_LINE = 343, GET_VOXEL_SIZE = 344, GET_HISTOGRAM = 345,
    GET_STATISTICS = 346, GET_BOUNDING_RECT = 347, GET_LUT = 348, SET_LUT = 349, GET_COORDINATES = 350,
    SHOW_MESSAGE_WITH_CANCEL = 351, MAKE_SELECTION = 352, SET_RESULT = 353, UPDATE_RESULTS = 354,
    SET_BATCH_MODE = 355, SET_JUSTIFICATION = 357, SET_Z_COORDINATE = 358, GET_THRESHOLD = 359,
    GET_PIXEL_SIZE = 360, SETUP_UNDO = 361, SAVE_SETTINGS = 362, RESTORE_SETTINGS = 363, SET_KEY_DOWN = 364,
    OPEN = 365, SET_FONT = 366, GET_MIN_AND_MAX = 367, CLOSE = 368, SET_SLICE = 369, NEW_IMAGE = 370,
    SAVE_AS = 371, SAVE = 372, SET_AUTO_THRESHOLD = 373, RENAME = 374, GET_BOUNDS = 375, FILL_RECT = 376,
    GET_RAW_STATISTICS = 377, FLOOD_FILL = 378, RESTORE_PREVIOUS_TOOL = 379, SET_VOXEL_SIZE = 380,
    GET_LOCATION_AND_SIZE = 381, GET_DATE_AND_TIME = 382, SET_METADATA = 383, CALCULATOR = 384,
    SET_RGB_WEIGHTS = 385, MAKE_POLYGON = 386, SET_SELECTION_NAME = 387, DRAW_RECT = 388, DRAW_OVAL = 389,
    FILL_OVAL = 390, SET_OPTION = 391, SHOW_TEXT = 392, SET_SELECTION_LOC = 393, GET_DIMENSIONS = 394,
    WAIT_FOR_USER = 395, MAKE_POINT = 396, MAKE_TEXT = 397, MAKE_ELLIPSE = 398, GET_DISPLAYED_AREA = 399,
    TO_SCALED = 400, TO_UNSCALED = 401, MAKE_ARROW = 402, MAKE_ROTATED_RECT = 403

let functions: [(String, Int)] = [
    ("run", RUN), ("invert", INVERT), ("selectWindow", SELECT), ("wait", WAIT), ("beep", BEEP),
    ("resetMinAndMax", RESET_MIN_MAX), ("resetThreshold", RESET_THRESHOLD), ("print", PRINT),
    ("write", WRITE), ("doWand", DO_WAND), ("setMinAndMax", SET_MIN_MAX), ("setThreshold", SET_THRESHOLD),
    ("setTool", SET_TOOL), ("setForegroundColor", SET_FOREGROUND), ("setBackgroundColor", SET_BACKGROUND),
    ("makeLine", MAKE_LINE), ("makeOval", MAKE_OVAL), ("makeRectangle", MAKE_RECTANGLE), ("dump", DUMP),
    ("moveTo", MOVE_TO), ("lineTo", LINE_TO), ("drawLine", DRAW_LINE), ("requires", REQUIRES),
    ("autoUpdate", AUTO_UPDATE), ("updateDisplay", UPDATE_DISPLAY), ("drawString", DRAW_STRING),
    ("setPasteMode", SET_PASTE_MODE), ("doCommand", DO_COMMAND), ("showStatus", SHOW_STATUS),
    ("showProgress", SHOW_PROGRESS), ("showMessage", SHOW_MESSAGE), ("putPixel", PUT_PIXEL),
    ("setPixel", SET_PIXEL), ("snapshot", SNAPSHOT), ("reset", RESET), ("fill", FILL), ("setColor", SET_COLOR),
    ("setLineWidth", SET_LINE_WIDTH), ("changeValues", CHANGE_VALUES), ("selectImage", SELECT_IMAGE),
    ("exit", EXIT), ("setLocation", SET_LOCATION), ("getCursorLoc", GET_CURSOR_LOC), ("getLine", GET_LINE),
    ("getVoxelSize", GET_VOXEL_SIZE), ("getHistogram", GET_HISTOGRAM), ("getStatistics", GET_STATISTICS),
    ("getBoundingRect", GET_BOUNDING_RECT), ("getLut", GET_LUT), ("setLut", SET_LUT),
    ("getSelectionCoordinates", GET_COORDINATES), ("showMessageWithCancel", SHOW_MESSAGE_WITH_CANCEL),
    ("makeSelection", MAKE_SELECTION), ("setResult", SET_RESULT), ("updateResults", UPDATE_RESULTS),
    ("setBatchMode", SET_BATCH_MODE), ("setJustification", SET_JUSTIFICATION),
    ("setZCoordinate", SET_Z_COORDINATE), ("getThreshold", GET_THRESHOLD), ("getPixelSize", GET_PIXEL_SIZE),
    ("setupUndo", SETUP_UNDO), ("saveSettings", SAVE_SETTINGS), ("restoreSettings", RESTORE_SETTINGS),
    ("setKeyDown", SET_KEY_DOWN), ("open", OPEN), ("setFont", SET_FONT), ("getMinAndMax", GET_MIN_AND_MAX),
    ("close", CLOSE), ("setSlice", SET_SLICE), ("newImage", NEW_IMAGE), ("saveAs", SAVE_AS), ("save", SAVE),
    ("setAutoThreshold", SET_AUTO_THRESHOLD), ("rename", RENAME), ("getSelectionBounds", GET_BOUNDS),
    ("fillRect", FILL_RECT), ("getRawStatistics", GET_RAW_STATISTICS), ("floodFill", FLOOD_FILL),
    ("restorePreviousTool", RESTORE_PREVIOUS_TOOL), ("setVoxelSize", SET_VOXEL_SIZE),
    ("getLocationAndSize", GET_LOCATION_AND_SIZE), ("getDateAndTime", GET_DATE_AND_TIME),
    ("setMetadata", SET_METADATA), ("imageCalculator", CALCULATOR), ("setRGBWeights", SET_RGB_WEIGHTS),
    ("makePolygon", MAKE_POLYGON), ("setSelectionName", SET_SELECTION_NAME), ("drawRect", DRAW_RECT),
    ("drawOval", DRAW_OVAL), ("fillOval", FILL_OVAL), ("setOption", SET_OPTION), ("showText", SHOW_TEXT),
    ("setSelectionLocation", SET_SELECTION_LOC), ("getDimensions", GET_DIMENSIONS),
    ("waitForUser", WAIT_FOR_USER), ("makePoint", MAKE_POINT), ("makeText", MAKE_TEXT),
    ("makeEllipse", MAKE_ELLIPSE), ("getDisplayedArea", GET_DISPLAYED_AREA), ("toScaled", TO_SCALED),
    ("toUnscaled", TO_UNSCALED), ("makeArrow", MAKE_ARROW), ("makeRotatedRectangle", MAKE_ROTATED_RECT),
]

// Numeric functions.
let GET_PIXEL = 1000, ABS = 1001, COS = 1002, EXP = 1003, FLOOR = 1004, LOG = 1005, MAX_OF = 1006, MIN_OF = 1007,
    POW = 1008, ROUND = 1009, SIN = 1010, SQRT = 1011, TAN = 1012, GET_TIME = 1013, GET_WIDTH = 1014,
    GET_HEIGHT = 1015, RANDOM = 1016, GET_RESULT = 1017, GET_COUNT = 1018, GET_NUMBER = 1019, NIMAGES = 1020,
    NSLICES = 1021, LENGTH_OF = 1022, NRESULTS = 1023, GET_ID = 1024, BIT_DEPTH = 1025, SELECTION_TYPE = 1026,
    ATAN = 1027, IS_OPEN = 1028, IS_ACTIVE = 1029, INDEX_OF = 1030, LAST_INDEX_OF = 1031, CHAR_CODE_AT = 1032,
    GET_BOOLEAN = 1033, STARTS_WITH = 1034, ENDS_WITH = 1035, ATAN2 = 1036, IS_NAN = 1037, GET_ZOOM = 1038,
    PARSE_INT = 1039, PARSE_FLOAT = 1040, IS_KEY_DOWN = 1041, GET_SLICE_NUMBER = 1042, SCREEN_WIDTH = 1043,
    SCREEN_HEIGHT = 1044, CALIBRATE = 1045, ASIN = 1046, ACOS = 1047, ROI_MANAGER = 1048, TOOL_ID = 1049,
    IS = 1050, GET_VALUE = 1051, STACK = 1052, MATCHES = 1053, GET_STRING_WIDTH = 1054, FIT = 1055,
    OVERLAY = 1056, SELECTION_CONTAINS = 1057, PLOT = 1058, MATH = 1059

let numericFunctions: [(String, Int)] = [
    ("getPixel", GET_PIXEL), ("abs", ABS), ("cos", COS), ("exp", EXP), ("floor", FLOOR), ("log", LOG),
    ("maxOf", MAX_OF), ("minOf", MIN_OF), ("pow", POW), ("round", ROUND), ("sin", SIN), ("sqrt", SQRT),
    ("tan", TAN), ("getTime", GET_TIME), ("getWidth", GET_WIDTH), ("getHeight", GET_HEIGHT),
    ("random", RANDOM), ("getResult", GET_RESULT), ("getResultsCount", GET_COUNT), ("getNumber", GET_NUMBER),
    ("nImages", NIMAGES), ("nSlices", NSLICES), ("lengthOf", LENGTH_OF), ("nResults", NRESULTS),
    ("getImageID", GET_ID), ("bitDepth", BIT_DEPTH), ("selectionType", SELECTION_TYPE), ("atan", ATAN),
    ("isOpen", IS_OPEN), ("isActive", IS_ACTIVE), ("indexOf", INDEX_OF), ("lastIndexOf", LAST_INDEX_OF),
    ("charCodeAt", CHAR_CODE_AT), ("getBoolean", GET_BOOLEAN), ("startsWith", STARTS_WITH),
    ("endsWith", ENDS_WITH), ("atan2", ATAN2), ("isNaN", IS_NAN), ("getZoom", GET_ZOOM),
    ("parseInt", PARSE_INT), ("parseFloat", PARSE_FLOAT), ("isKeyDown", IS_KEY_DOWN),
    ("getSliceNumber", GET_SLICE_NUMBER), ("screenWidth", SCREEN_WIDTH), ("screenHeight", SCREEN_HEIGHT),
    ("calibrate", CALIBRATE), ("asin", ASIN), ("acos", ACOS), ("roiManager", ROI_MANAGER),
    ("toolID", TOOL_ID), ("is", IS), ("getValue", GET_VALUE), ("Stack", STACK), ("matches", MATCHES),
    ("getStringWidth", GET_STRING_WIDTH), ("Fit", FIT), ("Overlay", OVERLAY),
    ("selectionContains", SELECTION_CONTAINS), ("Plot", PLOT), ("Math", MATH),
]

// String functions.
let D2S = 2000, TO_HEX = 2001, TO_BINARY = 2002, GET_TITLE = 2003, GET_STRING = 2004, SUBSTRING = 2005,
    FROM_CHAR_CODE = 2006, GET_INFO = 2007, GET_DIRECTORY = 2008, GET_ARGUMENT = 2009, GET_IMAGE_INFO = 2010,
    TO_LOWER_CASE = 2011, TO_UPPER_CASE = 2012, RUN_MACRO = 2013, EVAL = 2014, TO_STRING = 2015, REPLACE = 2016,
    DIALOG = 2017, GET_METADATA = 2018, FILE = 2019, SELECTION_NAME = 2020, GET_VERSION = 2021,
    GET_RESULT_LABEL = 2022, CALL = 2023, STRING = 2024, EXT = 2025, EXEC = 2026, LIST = 2027, DEBUG = 2028,
    IJ_CALL = 2029, GET_RESULT_STRING = 2030, GET_DIR = 2031, TRIM = 2032, CHARAT = 2033

let stringFunctions: [(String, Int)] = [
    ("d2s", D2S), ("toHex", TO_HEX), ("toBinary", TO_BINARY), ("getTitle", GET_TITLE),
    ("getString", GET_STRING), ("substring", SUBSTRING), ("fromCharCode", FROM_CHAR_CODE),
    ("getInfo", GET_INFO), ("getDirectory", GET_DIRECTORY), ("getArgument", GET_ARGUMENT),
    ("getImageInfo", GET_IMAGE_INFO), ("toLowerCase", TO_LOWER_CASE), ("toUpperCase", TO_UPPER_CASE),
    ("runMacro", RUN_MACRO), ("eval", EVAL), ("toString", TO_STRING), ("replace", REPLACE),
    ("Dialog", DIALOG), ("getMetadata", GET_METADATA), ("File", FILE), ("selectionName", SELECTION_NAME),
    ("getVersion", GET_VERSION), ("getResultLabel", GET_RESULT_LABEL), ("call", CALL), ("String", STRING),
    ("Ext", EXT), ("exec", EXEC), ("List", LIST), ("debug", DEBUG), ("IJ", IJ_CALL),
    ("getResultString", GET_RESULT_STRING), ("getDir", GET_DIR), ("trim", TRIM), ("charAt", CHARAT),
]

// Array functions.
let GET_PROFILE = 3000, NEW_ARRAY = 3001, SPLIT = 3002, GET_FILE_LIST = 3003, GET_FONT_LIST = 3004,
    NEW_MENU = 3005, GET_LIST = 3006, ARRAY_FUNC = 3007

let arrayFunctions: [(String, Int)] = [
    ("getProfile", GET_PROFILE), ("newArray", NEW_ARRAY), ("split", SPLIT), ("getFileList", GET_FILE_LIST),
    ("getFontList", GET_FONT_LIST), ("newMenu", NEW_MENU), ("getList", GET_LIST), ("Array", ARRAY_FUNC),
]

// Functions that return a Variable.
let TABLE = 4000, ROI = 4001, ROI_MANAGER2 = 4002, PROPERTY = 4003, IMAGE = 4004, COLOR = 4005

let variableFunctions: [(String, Int)] = [
    ("Table", TABLE), ("Roi", ROI), ("RoiManager", ROI_MANAGER2), ("Property", PROPERTY), ("Image", IMAGE),
    ("Color", COLOR),
]

extension MancoraMacro {
    /// The language's keywords (`macro`, `if`, `true`, `PI`…) and the names of its built-in functions
    /// (`print`, `getTitle`, `Array`, `Table`…), for editors that color them.
    public static let vocabulary: (keywords: Set<String>, functions: Set<String>) = (
        Set(keywords.map { $0.0 }),
        Set((functions + numericFunctions + stringFunctions + arrayFunctions + variableFunctions).map { $0.0 })
    )
}

/// The function type of a built-in symbol type, as `Symbol.getFunctionType`.
@inline(__always)
func functionType(ofSymbolType type: Int) -> Int {
    if type >= 300 && type < 1000 { return PREDEFINED_FUNCTION }
    if type >= 1000 && type < 2000 { return NUMERIC_FUNCTION }
    if type >= 2000 && type < 3000 { return STRING_FUNCTION }
    if type >= 3000 && type < 4000 { return ARRAY_FUNCTION }
    if type >= 4000 && type < 5000 { return VARIABLE_FUNCTION }
    return 0
}

/// ASCII code of a character literal, for comparing with token values.
@inline(__always)
func ch(_ c: Unicode.Scalar) -> Int { Int(c.value) }

// Single-character tokens, named for readability (they are their ASCII codes).
let T_LPAREN = 40, T_RPAREN = 41, T_LBRACKET = 91, T_RBRACKET = 93, T_LBRACE = 123, T_RBRACE = 125,
    T_SEMI = 59, T_COMMA = 44, T_DOT = 46, T_ASSIGN = 61, T_PLUS = 43, T_MINUS = 45, T_STAR = 42,
    T_SLASH = 47, T_PERCENT = 37, T_AMP = 38, T_BAR = 124, T_CARET = 94, T_TILDE = 126, T_BANG = 33,
    T_LT = 60, T_GT = 62
