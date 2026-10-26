import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("Virtual stacks")
struct VirtualStackTests {
    func path(_ name: String) -> String { Fixtures.path("Tests/Fixtures/tiff/\(name)") }

    func virtual(_ name: String, cacheBytes: Int = 256 << 20) throws -> Hyperstack {
        try TIFFImporter.read(path: path(name), options: .init(virtual: true, virtualCacheBytes: cacheBytes))
    }

    /// Opening virtually changes when planes are decoded, never what they hold.
    @Test("Same image as a full read", arguments: TIFFExporterTests.fixtureNames)
    func matchesFullRead(_ name: String) throws {
        let full = try TIFFImporter.read(path: path(name))
        let lazy = try virtual(name)
        #expect(lazy.stack.isVirtual)
        #expect(imageDifferences(full, lazy) == nil)
    }

    @Test func planesDecodeOnDemandAndStayCached() throws {
        let image = try virtual("ij-hyperstack-16bit.tif")  // 24 planes, 2 channels
        let source = try #require(image.stack.source as? TIFFPlaneSource)
        // Opening reads only the planes the default display needs.
        let afterOpen = source.decodeCount
        #expect(afterOpen <= 2)
        _ = image.plane(channel: 1, slice: 2, frame: 3)
        #expect(source.decodeCount == afterOpen + 1)
        _ = image.plane(channel: 1, slice: 2, frame: 3)
        #expect(source.decodeCount == afterOpen + 1)
        #expect(image.plane(channel: 1, slice: 2, frame: 3) == .gray16((0..<(32 * 24)).map {
            Patterns.hyperstack(23, $0 % 32, $0 / 32)
        }))
    }

    @Test func cacheStaysWithinItsBudget() throws {
        // Room for one 32×24 16-bit plane: alternating planes decode every time.
        let image = try virtual("ij-hyperstack-16bit.tif", cacheBytes: 32 * 24 * 2)
        let source = try #require(image.stack.source as? TIFFPlaneSource)
        let start = source.decodeCount
        for k in [5, 6, 5, 6] { _ = image.stack[k] }
        #expect(source.decodeCount == start + 4)
        for _ in 0..<3 { _ = image.stack[6] }
        #expect(source.decodeCount == start + 4)
    }

    @Test func editsStayInMemory() throws {
        var stack = try virtual("ij-stack-8bit.tif").stack
        let blank = Plane(zeroed: .gray8, count: stack.pixelsPerPlane)
        try stack.setPlane(blank, at: 3)
        #expect(stack[3] == blank)
        #expect(stack.isVirtual)
    }

    /// An ImageJ stack cut short keeps the planes the file holds in full, as
    /// FileInfoVirtualStack.validateNImages counts them.
    @Test func truncatedStacksKeepTheirCompletePlanes() throws {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path("ij-stack-8bit.tif"))))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-truncated-\(UInt32.random(in: 0...UInt32.max)).tif")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Keep the IFD and the first planes; cut the file inside plane 4 of 5.
        let planeBytes = 32 * 24
        let firstPlane = try #require(TIFFImporter.decode(bytes, title: "x").stack[0] == .gray8((0..<planeBytes).map {
            Patterns.p8($0 % 32, $0 / 32)
        }) ? imageOffset(bytes) : nil)
        try Data(bytes[0..<(firstPlane + 3 * planeBytes + 10)]).write(to: scratch)
        for virtual in [true, false] {
            let image = try TIFFImporter.read(path: scratch.path, options: .init(virtual: virtual))
            #expect(image.stack.count == 3)
            #expect(image.stack[2] != Plane(zeroed: .gray8, count: planeBytes))
        }
    }

    /// A virtual plane that can't be read shows blank (ImageJ's behaviour);
    /// `loadPlane(at:)` reports why.
    @Test func unreadablePlanesAreBlank() throws {
        // Two pages; the second one's strip is moved past the end of the file.
        var two = TIFFBuilder.gray8(width: 2, height: 1, pixels: [5, 6])
        two.secondIFDPointsBackToFirst = true
        var file = two.build()
        let reader = ByteReader(file)
        let second = try TIFFDirectory(reader: reader, offset: Int(try reader.u32(at: 4))).nextOffset
        let strip = try #require(try TIFFDirectory(reader: reader, offset: second).entries[TIFFTag.stripOffsets])
        file.replaceSubrange(strip.valueOffset..<(strip.valueOffset + 4), with: [0xF0, 0xFF, 0, 0])
        let image = try TIFFImporter.decode(file, title: "x", options: .init(virtual: true))
        #expect(image.stack.count == 2)
        #expect(image.stack[0] == .gray8([5, 6]))
        #expect(image.stack[1] == Plane(zeroed: .gray8, count: 2))
        #expect(throws: MancoraIOError.self) { try image.stack.loadPlane(at: 1) }
    }

    func imageOffset(_ file: [UInt8]) -> Int {
        let reader = ByteReader(file, bigEndian: file[0] == 0x4D)
        let ifd = try? TIFFDirectory(reader: reader, offset: Int(try reader.u32(at: 4)))
        return (try? ifd?.integer(TIFFTag.stripOffsets, reader)) ?? 0
    }
}
