public import MancoraCore

/// Reads and writes ImageJ `.roi` files: ports of `ij.io.RoiDecoder` and
/// `ij.io.RoiEncoder` from ImageJ 1.54p.
///
/// The format is a 64-byte big-endian header, the vertices (16-bit integers
/// relative to the bounds, then 32-bit floats for subpixel ROIs), and a
/// second 64-byte header with the hyperstack position, name, properties,
/// group and point counters. See `RoiDecoder.java` for the layout.
///
/// Decoding follows RoiDecoder rule for rule, including its version checks
/// and quirks (16-bit values below -5000 are read as unsigned; a stored
/// group recolors nothing here, while ImageJ replaces the outline color with
/// the group's). Encoding writes version 228 like RoiEncoder, and for every
/// ROI ImageJ writes, `encode(decode(file))` is byte for byte what ImageJ
/// writes when it re-saves that file, with these exceptions:
/// - Arrows: ImageJ stores the bounds of the arrow head, which depend on
///   Java2D stroking; Mancora stores the shaft's bounds. RoiDecoder ignores
///   them for lines.
/// - Spline-fitted outlines: ImageJ stores the spline's bounds; Mancora
///   stores the vertices' bounds. RoiDecoder ignores them for subpixel ROIs.
/// - Opaque ROIs (composite, text, image) are written back unchanged.
/// - Point ROIs with stack positions but no counters: RoiEncoder writes
///   all-zero counters, which RoiDecoder then reads as "no position";
///   Mancora writes the positions so ImageJ reads them back.
/// - Polygons with more than 65535 vertices store a 32-bit vertex count, as
///   ImageJ does for points (RoiDecoder reads it for every type); ImageJ
///   instead converts such polygons to composite ROIs.
public enum RoiCodec {
    /// Decodes a `.roi` file, as `RoiDecoder.getRoi()` does.
    /// - Parameter name: the file or zip entry name, used as the ROI's name
    ///   when the file stores none (a trailing `.roi` is removed).
    public static func decode(_ bytes: [UInt8], name: String? = nil) throws(MancoraIOError) -> Roi {
        guard let roi = try decodeIfPresent(bytes, name: name) else {
            throw .invalidFormat("the ROI has no coordinates")
        }
        return roi
    }

    /// Reads a `.roi` file; the file name is the default ROI name.
    public static func read(path: String) throws(MancoraIOError) -> Roi {
        let bytes = try FileLoader.load(path: path, limit: 1 << 28)
        let fileName = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        return try decode(bytes, name: fileName)
    }

    /// Encodes a ROI as RoiEncoder does (format version 228).
    public static func encode(_ roi: Roi) -> [UInt8] {
        var encoder = Encoder()
        return encoder.encode(roi)
    }

    /// RoiDecoder returns `null` (and the ROI Manager skips the entry) for
    /// polygons and points without vertices.
    static func decodeIfPresent(_ bytes: [UInt8], name: String?) throws(MancoraIOError) -> Roi? {
        var decoder = Decoder(bytes: bytes, fileName: name)
        return try decoder.decode()
    }
}

// MARK: - Layout (RoiDecoder's constants)

enum RoiFormat {
    static let headerSize = 64
    static let header2Size = 64
    static let version: Int32 = 228

    // Header offsets.
    static let versionOffset = 4, type = 6, top = 8, left = 10, bottom = 12, right = 14
    static let nCoordinates = 16, x1 = 18, y1 = 22, x2 = 26, y2 = 30
    static let xd = 18, yd = 22, widthd = 26, heightd = 30, size = 18
    static let strokeWidth = 34, shapeRoiSize = 36, strokeColor = 40, fillColor = 44
    static let subtype = 48, options = 50, arrowStyle = 52, floatParam = 52, pointType = 52
    static let arrowHeadSize = 53, roundedRectArcSize = 54, position = 56, header2Offset = 60
    static let coordinates = 64

    // Header 2 offsets.
    static let cPosition = 4, zPosition = 8, tPosition = 12, nameOffset = 16, nameLength = 20
    static let overlayLabelColor = 24, overlayFontSize = 28, group = 30, imageOpacity = 31
    static let imageSize = 32, floatStrokeWidth = 36, roiPropsOffset = 40, roiPropsLength = 44
    static let countersOffset = 48

    // Subtypes.
    static let text: Int32 = 1, arrow: Int32 = 2, ellipse: Int32 = 3, image: Int32 = 4, rotatedRect: Int32 = 5

    // Options.
    static let splineFit: Int32 = 1, doubleHeaded: Int32 = 2, outline: Int32 = 4
    static let overlayLabels: Int32 = 8, overlayNames: Int32 = 16, overlayBackgrounds: Int32 = 32
    static let overlayBold: Int32 = 64, subPixelResolution: Int32 = 128
    static let showLabels: Int32 = 1024, scaleLabels: Int32 = 2048, promptBeforeDeleting: Int32 = 4096
    static let scaleStrokeWidth: Int32 = 8192

    // File types.
    static let polygon: Int32 = 0, rect: Int32 = 1, oval: Int32 = 2, line: Int32 = 3, freeline: Int32 = 4
    static let polyline: Int32 = 5, noRoi: Int32 = 6, freehand: Int32 = 7, traced: Int32 = 8, angle: Int32 = 9
    static let point: Int32 = 10
}

// MARK: - Decoder

private struct Decoder {
    let reader: ByteReader
    /// The whole file, which opaque ROIs keep as read.
    let bytes: [UInt8]
    var fileName: String?

    init(bytes: [UInt8], fileName: String?) {
        self.bytes = bytes
        reader = ByteReader(bytes, bigEndian: true)
        if let fileName, fileName.hasSuffix(".roi") {
            self.fileName = String(fileName.dropLast(4))
        } else {
            self.fileName = fileName
        }
    }

    var size: Int { reader.count }

    func byte(_ o: Int) throws(MancoraIOError) -> Int32 { Int32(try reader.u8(at: o)) }

    /// RoiDecoder.getShort: signed, but values below -5000 are taken as
    /// unsigned (coordinates beyond 32767).
    func short(_ o: Int) throws(MancoraIOError) -> Int32 {
        let u = try reader.u16(at: o)
        let n = Int32(Int16(bitPattern: u))
        return n < -5000 ? Int32(u) : n
    }

    func unsignedShort(_ o: Int) throws(MancoraIOError) -> Int32 { Int32(try reader.u16(at: o)) }

    func int(_ o: Int) throws(MancoraIOError) -> Int32 { Int32(bitPattern: try reader.u32(at: o)) }

    func float(_ o: Int) throws(MancoraIOError) -> Float { Float(bitPattern: try reader.u32(at: o)) }

    /// A Java `char[]` of `length` UTF-16 units.
    func chars(_ o: Int, _ length: Int) throws(MancoraIOError) -> String {
        try reader.check(o, length * 2)
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for i in 0..<length { units.append(try reader.u16(at: o + i * 2)) }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func decode() throws(MancoraIOError) -> Roi? {
        typealias F = RoiFormat
        guard try byte(0) == 73, try byte(1) == 111 else {  // "Io" of "Iout"
            throw .invalidFormat("not an ImageJ ROI")
        }
        try reader.check(0, F.headerSize)
        let version = try short(F.versionOffset)
        let type = try byte(F.type)
        let subtype = try short(F.subtype)
        let top = try short(F.top), left = try short(F.left)
        let bottom = try short(F.bottom), right = try short(F.right)
        let width = right &- left, height = bottom &- top
        var n = Int(try unsignedShort(F.nCoordinates))
        if n == 0 { n = Int(try int(F.size)) }
        let options = try short(F.options)
        let position = try int(F.position)
        let hdr2 = Int(try int(F.header2Offset))
        let subPixelResolution = options & F.subPixelResolution != 0 && version >= 222
        let scaleStrokeWidth = version >= 228 ? options & F.scaleStrokeWidth != 0 : true
        let subPixelRect = version >= 223 && subPixelResolution && (type == F.rect || type == F.oval)

        var channel: Int32 = 0, slice: Int32 = 0, frame: Int32 = 0
        var labelColor: Int32 = 0, fontSize: Int32 = 0, group: Int32 = 0, imageSize: Int32 = 0
        if hdr2 > 0 && hdr2 + F.imageSize + 4 <= size {
            channel = try int(hdr2 + F.cPosition)
            slice = try int(hdr2 + F.zPosition)
            frame = try int(hdr2 + F.tPosition)
            labelColor = try int(hdr2 + F.overlayLabelColor)
            fontSize = try short(hdr2 + F.overlayFontSize)
            imageSize = try int(hdr2 + F.imageSize)
            group = try byte(hdr2 + F.group)
        }
        let headerBounds = RoiBounds(x: Int(left), y: Int(top), width: Int(width), height: Int(height))

        var roi: Roi
        if try int(F.shapeRoiSize) > 0 {
            // A composite ShapeRoi: segment types and coordinates as floats.
            guard type == F.rect else { throw .invalidFormat("composite ROI of type \(type)") }
            try reader.check(F.coordinates, Int(try int(F.shapeRoiSize)) * 4)
            roi = Roi(.opaque(Roi.Opaque(kind: .composite, bytes: bytes, bounds: headerBounds)))
            roi.name = try roiName(hdr2)
            if version >= 218 { try strokeWidthAndColor(&roi, hdr2, scaleStrokeWidth, isArrow: false) }
            roi.position = Self.position(position, channel, slice, frame)
            roi.labels = Self.labels(version, options, labelColor, fontSize)
            if version >= 224 { roi.properties = try properties(hdr2) }
            if version >= 228 && group > 0 { roi.group = Int(group) }
            return roi
        }

        var isPoint = false
        switch type {
        case F.rect, F.oval:
            let rect: Roi.Rect
            if subPixelRect {
                rect = .subpixel(
                    x: Double(try float(F.xd)), y: Double(try float(F.yd)),
                    width: Double(try float(F.widthd)), height: Double(try float(F.heightd)))
            } else {
                rect = .integer(x: left, y: top, width: width, height: height)
            }
            if type == F.rect {
                let arc = try short(F.roundedRectArcSize)
                roi = Roi(.rectangle(rect, cornerDiameter: arc > 0 ? Int(arc) : 0))
            } else {
                roi = Roi(.oval(rect))
            }
        case F.line:
            let x1 = Double(try float(F.x1)), y1 = Double(try float(F.y1))
            let x2 = Double(try float(F.x2)), y2 = Double(try float(F.y2))
            var line = Roi.Line(x1: x1, y1: y1, x2: x2, y2: y2)
            if subtype == F.arrow {
                var arrow = Roi.Arrow(style: .filled, headSize: 10)
                arrow.doubleHeaded = options & F.doubleHeaded != 0
                arrow.outline = options & F.outline != 0
                let style = try byte(F.arrowStyle)
                if let s = Roi.Arrow.Style(rawValue: Int(style)) { arrow.style = s }
                let headSize = try byte(F.arrowHeadSize)
                if headSize >= 0 && style <= 30 { arrow.headSize = Double(headSize) }  // sic: style, not headSize
                line.arrow = arrow
            }
            roi = Roi(.line(line))
        case F.polygon, F.freehand, F.traced, F.polyline, F.freeline, F.angle, F.point:
            guard n > 0 else { return nil }
            try reader.check(F.coordinates, n * 4)
            var ints: [Roi.IntPoint] = []
            ints.reserveCapacity(n)
            let base2 = F.coordinates + 2 * n
            for i in 0..<n {
                var xt = try short(F.coordinates + i * 2)
                if xt < 0 { xt = 0 }
                var yt = try short(base2 + i * 2)
                if yt < 0 { yt = 0 }
                ints.append(Roi.IntPoint(x: left &+ xt, y: top &+ yt))
            }
            var vertices = Roi.Vertices.integer(ints)
            if subPixelResolution {
                let fbase1 = F.coordinates + 4 * n, fbase2 = fbase1 + 4 * n
                try reader.check(fbase1, 8 * n)
                var floats: [Roi.FloatPoint] = []
                floats.reserveCapacity(n)
                for i in 0..<n {
                    floats.append(Roi.FloatPoint(x: try float(fbase1 + i * 4), y: try float(fbase2 + i * 4)))
                }
                vertices = .subpixel(floats)
            }
            if type == F.point {
                isPoint = true
                var points = Roi.Points(vertices)
                if version >= 226 {
                    if let t = Roi.Points.PointType(rawValue: Int(try byte(F.pointType))) { points.pointType = t }
                    let size = try short(F.strokeWidth)
                    if (0...6).contains(size) { points.size = Int(size) }
                }
                points.showLabels = options & F.showLabels != 0
                points.promptBeforeDeleting = options & F.promptBeforeDeleting != 0
                roi = Roi(.points(points))
                break
            }
            if type == F.freehand && subtype == F.ellipse {
                let aspect = Double(try float(F.floatParam))
                roi = Roi(.polygon(Roi.Polygon(
                    .freehand, .subpixel(vertices.floatPoints),
                    parametric: .ellipse(aspectRatio: min(max(aspect, 0), 1)))))
                break
            }
            if type == F.freehand && subtype == F.rotatedRect {
                roi = Roi(.polygon(.rotatedRectangle(
                    x1: Double(try float(F.x1)), y1: Double(try float(F.y1)),
                    x2: Double(try float(F.x2)), y2: Double(try float(F.y2)),
                    width: Double(try float(F.floatParam)))))
                break
            }
            let kind: Roi.Polygon.Kind =
                switch type {
                case F.polygon: .polygon
                case F.freehand: .freehand
                case F.traced: .traced
                case F.polyline: .polyline
                case F.freeline: .freeline
                default: .angle
                }
            roi = Roi(.polygon(Roi.Polygon(kind, vertices)))
        default:
            throw .invalidFormat("unrecognized ROI type \(type)")
        }
        roi.name = try roiName(hdr2)

        if version >= 218 {
            var isArrow = false
            if case .line(let l) = roi.shape { isArrow = l.arrow != nil }
            try strokeWidthAndColor(&roi, hdr2, scaleStrokeWidth, isArrow: isArrow)
            if isPoint { roi.strokeWidth = 0 }
            if options & F.splineFit != 0, case .polygon(var p) = roi.shape {
                p.isSplineFit = true
                roi.shape = .polygon(p)
            }
        }
        if version >= 218 && subtype == F.text {
            try textRoi(&roi, headerBounds, version)
        }
        if version >= 221 && subtype == F.image && imageSize > 0 {
            try reader.check(F.coordinates, Int(imageSize))
            // A new ImageRoi: no name, fill or stroke width, and a black outline.
            roi = Roi(.opaque(Roi.Opaque(kind: .image, bytes: bytes, bounds: headerBounds)), strokeColor: 0xFF00_0000)
        }
        if version >= 224 { roi.properties = try properties(hdr2) }

        if case .points(var points) = roi.shape {
            // PointRoi.setPosition(n) sets every point's position, then
            // setCounters() replaces counters and positions together.
            let p = position < 0 && position != -2 ? 0 : position
            if p != 0 {
                points.positions = [Int32](repeating: p == -2 ? 0 : p, count: points.vertices.count)
            }
            if version >= 227, let counters = try pointCounters(hdr2, n) {
                points.counters = counters.map { UInt8(truncatingIfNeeded: $0) }
                points.positions = counters.map { $0 >> 8 }
            }
            roi.shape = .points(points)
            roi.position = Self.position(0, channel, slice, frame)
        } else {
            roi.position = Self.position(position, channel, slice, frame)
        }
        if version >= 228 && group > 0 { roi.group = Int(group) }
        roi.labels = Self.labels(version, options, labelColor, fontSize)
        return roi
    }

    static func position(_ position: Int32, _ c: Int32, _ z: Int32, _ t: Int32) -> Roi.Position {
        if c > 0 || z > 0 || t > 0 {
            return .hyperstack(channel: Int(max(c, 0)), slice: Int(max(z, 0)), frame: Int(max(t, 0)))
        }
        return position > 0 ? .stack(Int(position)) : .none
    }

    /// RoiDecoder.decodeOverlayOptions.
    static func labels(_ version: Int32, _ options: Int32, _ color: Int32, _ fontSize: Int32) -> Roi.OverlayLabels {
        typealias F = RoiFormat
        var labels = Roi.OverlayLabels(
            drawLabels: options & F.overlayLabels != 0, drawNames: options & F.overlayNames != 0,
            drawBackgrounds: options & F.overlayBackgrounds != 0)
        if version >= 220 && color != 0 { labels.color = 0xFF00_0000 | UInt32(bitPattern: color) }  // new Color(int) is opaque
        let bold = options & F.overlayBold != 0, scalable = options & F.scaleLabels != 0
        if fontSize > 0 || bold || scalable {
            labels.font = Roi.OverlayLabels.Font(size: Int(fontSize), bold: bold)
            labels.scalable = scalable
        }
        return labels
    }

    /// RoiDecoder.getStrokeWidthAndColor.
    func strokeWidthAndColor(_ roi: inout Roi, _ hdr2: Int, _ scale: Bool, isArrow: Bool) throws(MancoraIOError) {
        if isArrow {  // the Arrow constructor sets a width of 2
            roi.strokeWidth = 2
            roi.scalesStrokeWidth = true
        }
        var width = Double(try short(RoiFormat.strokeWidth))
        if hdr2 > 0 {
            let w = Double(try float(hdr2 + RoiFormat.floatStrokeWidth))
            if w > 0 { width = w }
        }
        if width > 0 {
            roi.strokeWidth = Float(width)
            roi.scalesStrokeWidth = scale
        }
        let fill = try int(RoiFormat.fillColor)
        if fill != 0 { roi.fillColor = UInt32(bitPattern: fill) }
        let stroke = try int(RoiFormat.strokeColor)
        if stroke != 0 { roi.strokeColor = UInt32(bitPattern: stroke) }
    }

    /// RoiDecoder.getRoiName: the stored name, else the file name.
    func roiName(_ hdr2: Int) throws(MancoraIOError) -> String? {
        if hdr2 == 0 { return fileName }
        let offset = Int(try int(hdr2 + RoiFormat.nameOffset))
        let length = Int(try int(hdr2 + RoiFormat.nameLength))
        if offset == 0 || length == 0 || offset + length * 2 > size { return fileName }
        guard offset > 0, length > 0 else { throw .invalidFormat("bad ROI name offset or length") }
        return try chars(offset, length)
    }

    /// RoiDecoder.getRoiProps.
    func properties(_ hdr2: Int) throws(MancoraIOError) -> String? {
        if hdr2 == 0 { return nil }
        let offset = Int(try int(hdr2 + RoiFormat.roiPropsOffset))
        let length = Int(try int(hdr2 + RoiFormat.roiPropsLength))
        if offset == 0 || length == 0 || offset + length * 2 > size { return nil }
        guard offset > 0, length > 0 else { throw .invalidFormat("bad ROI properties offset or length") }
        return try chars(offset, length)
    }

    /// RoiDecoder.getPointCounters.
    func pointCounters(_ hdr2: Int, _ n: Int) throws(MancoraIOError) -> [Int32]? {
        if hdr2 == 0 { return nil }
        let offset = Int(try int(hdr2 + RoiFormat.countersOffset))
        if offset == 0 || offset + n * 4 > size { return nil }
        guard offset > 0 else { throw .invalidFormat("bad point counter offset") }
        var counters: [Int32] = []
        counters.reserveCapacity(n)
        for i in 0..<n { counters.append(try int(offset + i * 4)) }
        return counters
    }

    /// RoiDecoder.getTextRoi: checks the text block ImageJ reads, and keeps
    /// the ROI as bytes with the properties a TextRoi carries.
    func textRoi(_ roi: inout Roi, _ bounds: RoiBounds, _ version: Int32) throws(MancoraIOError) {
        let h = RoiFormat.headerSize
        let nameLength = Int(try int(h + 8)), textLength = Int(try int(h + 12))
        guard nameLength >= 0, textLength >= 0 else { throw .invalidFormat("bad text ROI lengths") }
        try reader.check(h + 16, (nameLength + textLength) * 2 + (version >= 225 ? 4 : 0))
        var text = Roi(.opaque(Roi.Opaque(kind: .text, bytes: bytes, bounds: bounds)))
        text.name = roi.name
        text.strokeColor = roi.strokeColor
        text.fillColor = roi.fillColor
        roi = text
    }
}

// MARK: - Encoder

private struct Encoder {
    typealias F = RoiFormat
    var data: [UInt8] = []

    mutating func put8(_ o: Int, _ v: Int32) { data[o] = UInt8(truncatingIfNeeded: v) }

    mutating func put16(_ o: Int, _ v: Int32) {
        data[o] = UInt8(truncatingIfNeeded: v >> 8)
        data[o + 1] = UInt8(truncatingIfNeeded: v)
    }

    mutating func put32(_ o: Int, _ v: Int32) {
        data[o] = UInt8(truncatingIfNeeded: v >> 24)
        data[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        data[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        data[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    mutating func putFloat(_ o: Int, _ v: Float) { put32(o, Int32(bitPattern: v.bitPattern)) }

    /// The vertices RoiEncoder writes for a polygon-like ROI.
    struct Coordinates {
        var ints: (xs: [Int32], ys: [Int32])
        var floats: (xs: [Float], ys: [Float])?
        var count: Int { ints.xs.count }
    }

    mutating func encode(_ roi: Roi) -> [UInt8] {
        var shape = roi.shape
        if case .opaque(let o) = shape { return o.bytes }

        // RoiEncoder calls enableSubPixelResolution() for ROIs beyond 60000.
        let r = roi.bounds
        let far = r.width > 60000 || r.height > 60000 || r.x > 60000 || r.y > 60000
        if far, case .rectangle(.integer, let corner) = shape {
            shape = .rectangle(Self.subpixel(r), cornerDiameter: corner)
        }
        if far, case .oval(.integer) = shape { shape = .oval(Self.subpixel(r)) }

        var options: Int32 = roi.scalesStrokeWidth ? F.scaleStrokeWidth : 0
        let name = Array((roi.name ?? "").utf16)
        let props = Array((roi.properties ?? "").utf16)

        let type: Int32
        var coordinates: Coordinates?
        var polygonState: PolygonState?
        var pointCounters: [Int32]?
        var position: Int32 = 0  // Roi.getPosition()
        if case .stack(let n) = roi.position { position = Int32(clamping: max(n, 0)) }
        switch shape {
        case .rectangle: type = F.rect
        case .oval: type = F.oval
        case .line: type = F.line
        case .polygon(let p):
            type =
                switch p.kind {
                case .polygon: F.polygon
                case .freehand: F.freehand
                case .traced: F.traced
                case .polyline: F.polyline
                case .freeline: F.freeline
                case .angle: F.angle
                }
            var state = p.state
            if far { state.enableSubPixelResolution() }
            polygonState = state
            coordinates = Coordinates(ints: state.relativeIntegerPolygon, floats: state.isSubpixel ? state.floatPolygon : nil)
        case .points(var p):
            type = F.point
            if case .stack(let n) = roi.position {  // PointRoi.setPosition(n)
                p.positions = n > 0 ? [Int32](repeating: Int32(clamping: n), count: p.vertices.count) : nil
            }
            let state = p.state
            polygonState = state
            coordinates = Coordinates(ints: state.relativeIntegerPolygon, floats: state.floatPolygon)
            position = Self.pointPosition(p)
            if p.vertices.count <= 65535 {
                // PointRoi.getCounters(): counter + (position << 8). (ImageJ
                // writes zeros when no counter was ever set, losing the
                // positions on reading; Mancora keeps them.)
                let counters = p.counters ?? [], positions = p.positions ?? []
                pointCounters = (0..<p.vertices.count).map { i in
                    let counter = i < counters.count ? Int32(counters[i]) : 0
                    let pos = i < positions.count ? positions[i] : 0
                    return (counter & 0xFF) &+ (pos << 8)
                }
            }
        case .opaque: return []
        }

        let n = coordinates?.count ?? 0
        if coordinates?.floats != nil { options |= F.subPixelResolution }
        let floatSize = coordinates?.floats != nil ? n * 8 : 0
        let countersSize = (pointCounters?.count ?? 0) * 4
        data = [UInt8](repeating: 0, count: F.headerSize + F.header2Size + n * 4 + floatSize + name.count * 2 + props.count * 2 + countersSize)
        data[0] = 73
        data[1] = 111
        data[2] = 117
        data[3] = 116  // "Iout"
        put16(F.versionOffset, F.version)
        put8(F.type, type)
        let bx = Int32(truncatingIfNeeded: r.x), by = Int32(truncatingIfNeeded: r.y)
        put16(F.top, by)
        put16(F.left, bx)
        put16(F.bottom, by &+ Int32(truncatingIfNeeded: r.height))
        put16(F.right, bx &+ Int32(truncatingIfNeeded: r.width))

        switch shape {
        case .rectangle(.subpixel(let x, let y, let w, let h), _), .oval(.subpixel(let x, let y, let w, let h)):
            // getFloatPolygon(): the four corners as floats.
            let x0 = Float(x), y0 = Float(y), x1 = Float(x + w), y1 = Float(y + h)
            putFloat(F.xd, x0)
            putFloat(F.yd, y0)
            putFloat(F.widthd, x1 - x0)
            putFloat(F.heightd, y1 - y0)
            options |= F.subPixelResolution
        default: break
        }
        if n > 65535 {  // RoiEncoder does this for points only
            put32(F.size, Int32(clamping: n))
        } else {
            put16(F.nCoordinates, Int32(n))
        }
        put32(F.position, position)

        if case .rectangle(_, let corner) = shape, corner > 0 {
            put16(F.roundedRectArcSize, Int32(clamping: corner))
        }
        if case .line(let line) = shape {
            putFloat(F.x1, Float(line.x1))
            putFloat(F.y1, Float(line.y1))
            putFloat(F.x2, Float(line.x2))
            putFloat(F.y2, Float(line.y2))
            if let arrow = line.arrow {
                put16(F.subtype, F.arrow)
                if arrow.doubleHeaded { options |= F.doubleHeaded }
                if arrow.outline { options |= F.outline }
                put8(F.arrowStyle, Int32(arrow.style.rawValue))
                put8(F.arrowHeadSize, JavaNumerics.int32(arrow.headSize))
            }
        }
        if case .points(let p) = shape {
            put8(F.pointType, Int32(p.pointType.rawValue))
            put16(F.strokeWidth, Int32(clamping: p.size))
            if p.showLabels { options |= F.showLabels }
            if p.promptBeforeDeleting { options |= F.promptBeforeDeleting }
        }
        if case .polygon(let p) = shape, let parametric = p.parametric, let s = polygonState, let xpf = s.xpf, let ypf = s.ypf, !xpf.isEmpty {
            let fx = Float(s.x), fy = Float(s.y)
            let params: (Float, Float, Float, Float, Float)
            switch parametric {
            case .ellipse(let aspect):
                // EllipseRoi.getParams(): vertices count/2 and 0, and the aspect ratio.
                let h = xpf.count / 2
                params = (xpf[h] + fx, ypf[h] + fy, xpf[0] + fx, ypf[0] + fy, Float(aspect))
                put16(F.subtype, F.ellipse)
            case .rotatedRectangle(let width):
                // RotatedRectRoi.getParams(): midpoints of edges 3→0 and 1→2.
                func h(_ v: [Float], _ i: Int, _ base: Float) -> Float {
                    let j = i < 3 ? i + 1 : 0
                    return v[i] + (v[j % v.count] - v[i]) / 2 + base
                }
                let i3 = min(3, xpf.count - 1), i1 = min(1, xpf.count - 1)
                params = (h(xpf, i3, fx), h(ypf, i3, fy), h(xpf, i1, fx), h(ypf, i1, fy), Float(width))
                put16(F.subtype, F.rotatedRect)
            }
            putFloat(F.x1, params.0)
            putFloat(F.y1, params.1)
            putFloat(F.x2, params.2)
            putFloat(F.y2, params.3)
            putFloat(F.floatParam, params.4)
        }

        // saveStrokeWidthAndColor (1.43i or later).
        if roi.strokeWidth > 0 { put16(F.strokeWidth, JavaNumerics.int32(roi.strokeWidth)) }
        if let c = roi.strokeColor { put32(F.strokeColor, Int32(bitPattern: c)) }
        if let c = roi.fillColor { put32(F.fillColor, Int32(bitPattern: c)) }
        if case .polygon(let p) = shape, p.isSplineFit { options |= F.splineFit }

        let hdr2 = F.headerSize + n * 4 + floatSize
        putHeader2(roi, hdr2, name: name, props: props, counters: pointCounters)

        if let coordinates {
            let base2 = F.coordinates + 2 * n
            for i in 0..<n {
                put16(F.coordinates + i * 2, coordinates.ints.xs[i])
                put16(base2 + i * 2, coordinates.ints.ys[i])
            }
            if let floats = coordinates.floats {
                let fbase1 = F.coordinates + 4 * n, fbase2 = fbase1 + 4 * n
                for i in 0..<n {
                    putFloat(fbase1 + i * 4, floats.xs[i])
                    putFloat(fbase2 + i * 4, floats.ys[i])
                }
            }
        }

        // saveOverlayOptions.
        let labels = roi.labels
        if labels.drawLabels { options |= F.overlayLabels }
        if labels.drawNames { options |= F.overlayNames }
        if labels.drawBackgrounds { options |= F.overlayBackgrounds }
        if labels.font?.bold == true { options |= F.overlayBold }
        if labels.scalable { options |= F.scaleLabels }
        put16(F.options, options)
        return data
    }

    mutating func putHeader2(_ roi: Roi, _ hdr2: Int, name: [UInt16], props: [UInt16], counters: [Int32]?) {
        put32(F.header2Offset, Int32(truncatingIfNeeded: hdr2))
        if case .hyperstack(let c, let z, let t) = roi.position {
            put32(hdr2 + F.cPosition, Int32(clamping: max(c, 0)))
            put32(hdr2 + F.zPosition, Int32(clamping: max(z, 0)))
            put32(hdr2 + F.tPosition, Int32(clamping: max(t, 0)))
        }
        if let color = roi.labels.color { put32(hdr2 + F.overlayLabelColor, Int32(bitPattern: color)) }
        if let font = roi.labels.font { put16(hdr2 + F.overlayFontSize, Int32(clamping: font.size)) }
        if !name.isEmpty {
            let offset = hdr2 + F.header2Size
            put32(hdr2 + F.nameOffset, Int32(truncatingIfNeeded: offset))
            put32(hdr2 + F.nameLength, Int32(truncatingIfNeeded: name.count))
            for (i, c) in name.enumerated() { put16(offset + i * 2, Int32(c)) }
        }
        putFloat(hdr2 + F.floatStrokeWidth, roi.strokeWidth > 0 ? roi.strokeWidth : 0)
        if !props.isEmpty {
            let offset = hdr2 + F.header2Size + name.count * 2
            put32(hdr2 + F.roiPropsOffset, Int32(truncatingIfNeeded: offset))
            put32(hdr2 + F.roiPropsLength, Int32(truncatingIfNeeded: props.count))
            for (i, c) in props.enumerated() { put16(offset + i * 2, Int32(c)) }
        }
        if let counters, !counters.isEmpty {
            let offset = hdr2 + F.header2Size + name.count * 2 + props.count * 2
            put32(hdr2 + F.countersOffset, Int32(truncatingIfNeeded: offset))
            for (i, c) in counters.enumerated() { put32(offset + i * 4, c) }
        }
        put8(hdr2 + F.group, Int32(truncatingIfNeeded: roi.group))
    }

    static func subpixel(_ r: RoiBounds) -> Roi.Rect {
        .subpixel(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
    }

    /// PointRoi.getPosition(): the points' common position, 0 for none, or
    /// -2 (POINTWISE_POSITION) when they differ.
    static func pointPosition(_ p: Roi.Points) -> Int32 {
        guard let positions = p.positions, p.vertices.count > 0, let first = positions.first else { return 0 }
        for i in 1..<p.vertices.count where (i < positions.count ? positions[i] : 0) != first { return -2 }
        return first
    }
}
