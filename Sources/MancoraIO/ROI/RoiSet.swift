public import MancoraCore

/// ImageJ ROI sets: the `RoiSet.zip` files the ROI Manager saves (one `.roi`
/// file per ROI, `RoiManager.saveMultiple`) and opens (`RoiManager.openZip`).
public enum RoiSet {
    /// One ROI and its ROI Manager name (the zip entry without `.roi`).
    public struct Entry: Hashable, Sendable {
        public var name: String
        public var roi: Roi

        public init(name: String, roi: Roi) {
            self.name = name
            self.roi = roi
        }
    }

    /// Decodes a ROI set as the ROI Manager opens one: every entry whose name
    /// ends in `.roi`, in file order, skipping ROIs that RoiDecoder can't
    /// return (polygons without vertices). Each ROI's name defaults to its
    /// entry name.
    /// - Parameter limit: the most uncompressed bytes to accept, to stop
    ///   decompression bombs.
    public static func decode(_ bytes: [UInt8], limit: Int = 1 << 30) throws(MancoraIOError) -> [Entry] {
        var result: [Entry] = []
        var total = 0
        for entry in try ZipArchive.entries(bytes) where entry.name.hasSuffix(".roi") {
            let data = try ZipArchive.data(of: entry, in: bytes, limit: limit - total)
            total += data.count
            let roi: Roi?
            do {
                roi = try RoiCodec.decodeIfPresent(data, name: entry.name)
            } catch {
                throw .invalidFormat("\(entry.name): \(error)")
            }
            if let roi { result.append(Entry(name: String(entry.name.dropLast(4)), roi: roi)) }
        }
        return result
    }

    /// Reads a `RoiSet.zip` file.
    public static func read(path: String) throws(MancoraIOError) -> [Entry] {
        try decode(try FileLoader.load(path: path, limit: 1 << 30))
    }

    /// Encodes ROIs as a zip of `.roi` files the ROI Manager can open.
    ///
    /// Entries are stored uncompressed (the ROI Manager deflates them), with
    /// a fixed 1980-01-01 date. Names that would repeat get `-1`, `-2`, …
    /// as the ROI Manager's `getUniqueName` makes them.
    public static func encode(_ entries: [Entry]) -> [UInt8] {
        var labels = entries.map(\.name)
        var written = Set<String>()
        var files: [(name: String, data: [UInt8])] = []
        for (i, entry) in entries.enumerated() {
            var name = withRoiSuffix(labels[i])
            while written.contains(name) {
                name = withRoiSuffix(uniqueName(&labels, i))
                if written.contains(name) { labels[i] += "-" }  // can't happen with ImageJ's names; never loop forever
            }
            written.insert(name)
            files.append((name, RoiCodec.encode(entry.roi)))
        }
        return ZipArchive.stored(files)
    }

    private static func withRoiSuffix(_ label: String) -> String {
        label.hasSuffix(".roi") ? label : label + ".roi"
    }

    /// RoiManager.getUniqueName: appends `-n` (replacing a short `-k` suffix)
    /// until no other label has the name.
    private static func uniqueName(_ names: inout [String], _ index: Int) -> String {
        func other(_ name: String) -> Bool { names.indices.contains { $0 != index && names[$0] == name } }
        var name = names[index]
        var n = 1
        while other(name) {
            let units = Array(name.utf16)
            if let lastDash = units.lastIndex(of: 0x2D), units.count - lastDash < 5 {
                name = String(decoding: units[..<lastDash], as: UTF16.self)
            }
            name += "-\(n)"
            n += 1
        }
        names[index] = name
        return name
    }
}
