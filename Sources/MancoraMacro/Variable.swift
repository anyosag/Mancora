// A port of ImageJ 1.54p's ij/macro/Variable.java.

/// A Java `Variable[]`: arrays are shared by reference, so `b = a` makes
/// both names one array, as in ImageJ.
public final class VariableArray {
    public var elements: [Variable]

    public init(_ elements: [Variable]) { self.elements = elements }

    public var count: Int { elements.count }

    public subscript(index: Int) -> Variable {
        get { elements[index] }
        set { elements[index] = newValue }
    }
}

/// A macro value: a number, a string or an array.
public final class Variable {
    public enum Kind: Sendable { case value, array, string }

    var symTabIndex = 0
    private var value = 0.0
    private var str: String?
    private var array: VariableArray?
    private var arraySize = 0

    public init() {}
    public init(_ value: Double) { self.value = value }
    public init(_ str: String) { self.str = str }
    public init(_ array: VariableArray) { self.array = array }

    public convenience init(_ values: [Double]) {
        self.init(VariableArray(values.map { Variable($0) }))
    }

    public convenience init(_ strings: [String]) {
        self.init(VariableArray(strings.map { Variable($0) }))
    }

    init(symTabIndex: Int, value: Double, str: String?, array: VariableArray? = nil) {
        self.symTabIndex = symTabIndex
        self.value = value
        self.str = str
        self.array = array
    }

    /// The number; a string converts with `Double.valueOf` (NaN if it isn't one).
    public func getValue() -> Double {
        if let str { return javaParseDouble(str) ?? .nan }
        return value
    }

    func setValue(_ value: Double) {
        self.value = value
        str = nil
        array = nil
    }

    public func getString() -> String? { str }

    func setString(_ str: String?) {
        self.str = str
        value = 0
        array = nil
    }

    public func getArray() -> VariableArray? { array }

    func setArray(_ array: VariableArray?) {
        self.array = array
        value = 0
        str = nil
        arraySize = 0
    }

    func setArraySize(_ sizeIn: Int) {
        var size = sizeIn
        if array == nil {
            size = 0
        } else if size > array!.count {
            size = array!.count
        }
        arraySize = size
    }

    func getArraySize() -> Int {
        var size = array?.count ?? 0
        if arraySize > 0 { size = arraySize }
        return size
    }

    public var kind: Kind {
        if array != nil { return .array }
        if str != nil { return .string }
        return .value
    }

    /// The raw stored number, ignoring any string.
    var storedValue: Double { value }

    func copy() -> Variable {
        let v = Variable(symTabIndex: symTabIndex, value: value, str: str, array: array)
        v.arraySize = arraySize
        return v
    }
}

extension Variable: CustomStringConvertible {
    public var description: String {
        if let array { return "array[\(array.count)]" }
        if var s = str {
            if s.utf16.count > 80 { s = javaSubstring(s, 0, 80) + "..." }
            s = s.replacingAll("\n", with: " | ")
            return "\"" + s + "\""
        }
        if Double(jInt(value)) == value { return String(jInt(value)) }
        return ImageJFormat.d2s(value, 4)
    }
}
