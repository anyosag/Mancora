import Foundation  // NSLock
import MancoraCore

/// The planes of a TIFF, decoded on demand: the source of a virtual stack.
///
/// Decoded planes are kept, least recently used first out, up to a byte
/// budget, so scrolling back and forth doesn't decode the same plane twice.
final class TIFFPlaneSource: PlaneSource, @unchecked Sendable {
    /// What one decode yields: a page (one plane, or one per sample of 16-bit
    /// RGB), or the pixels of an ImageJ stack plane after the first IFD.
    enum Unit: Sendable {
        case page(TIFFPage)
        case contiguous(TIFFPage, offset: Int)

        var page: TIFFPage {
            switch self {
            case .page(let page), .contiguous(let page, _): page
            }
        }

        func decode(_ reader: ByteReader) throws(MancoraIOError) -> [Plane] {
            switch self {
            case .page(let page): try TIFFPlaneDecoder.decode(page, reader: reader)
            case .contiguous(let page, let offset): try TIFFPlaneDecoder.decodeContiguous(page, at: offset, reader: reader)
            }
        }
    }

    let width: Int
    let height: Int
    let pixelType: PixelType
    let count: Int
    private let reader: ByteReader
    private let units: [Unit]
    private let planesPerUnit: Int
    private let cacheBytes: Int

    // Guarded by `lock`.
    private let lock = NSLock()
    private var cache: [Int: [Plane]] = [:]
    private var recentUnits: [Int] = []  // least recent first
    private var cachedBytes = 0
    private var decodes = 0

    init(reader: ByteReader, first: TIFFPage, units: [Unit], cacheBytes: Int) {
        self.reader = reader
        self.units = units
        self.planesPerUnit = first.planesPerPage
        self.width = first.width
        self.height = first.height
        self.pixelType = first.pixelType
        self.count = units.count * first.planesPerPage
        self.cacheBytes = cacheBytes
    }

    /// How many times a unit has been decoded (for tests and diagnostics).
    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodes
    }

    func plane(at index: Int) throws -> Plane {
        guard (0..<count).contains(index) else { throw MancoraIOError.invalidFormat("no plane \(index)") }
        let unit = index / planesPerUnit, sample = index % planesPerUnit
        if let hit = cached(unit) { return hit[sample] }
        // Decode outside the lock so other planes stay available meanwhile.
        let planes = try units[unit].decode(reader)
        store(planes, for: unit)
        return planes[sample]
    }

    private func cached(_ unit: Int) -> [Plane]? {
        lock.lock()
        defer { lock.unlock() }
        guard let planes = cache[unit] else { return nil }
        if let i = recentUnits.lastIndex(of: unit) { recentUnits.remove(at: i) }
        recentUnits.append(unit)
        return planes
    }

    private func store(_ planes: [Plane], for unit: Int) {
        let bytes = planes.reduce(0) { $0 + $1.count * $1.pixelType.bytesPerPixel }
        lock.lock()
        defer { lock.unlock() }
        decodes += 1
        guard cache[unit] == nil, bytes <= cacheBytes else { return }
        while cachedBytes + bytes > cacheBytes, !recentUnits.isEmpty {
            let evicted = recentUnits.removeFirst()
            if let old = cache.removeValue(forKey: evicted) {
                cachedBytes -= old.reduce(0) { $0 + $1.count * $1.pixelType.bytesPerPixel }
            }
        }
        cache[unit] = planes
        recentUnits.append(unit)
        cachedBytes += bytes
    }
}
