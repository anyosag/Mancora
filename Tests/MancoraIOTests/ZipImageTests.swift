import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("ImageJ ZIP files")
struct ZipImageTests {
    static func zip(_ name: String) -> String { Fixtures.path("Tests/Fixtures/zip/" + name) }

    @Test(arguments: ["stack.zip", "stack-stored.zip"])
    func aTIFFInsideOpensAsTheTIFF(_ name: String) throws {
        guard case .image(let image) = try ZipImage.read(path: Self.zip(name)) else {
            Issue.record("not an image")
            return
        }
        let tiff = try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/ij-stack-8bit.tif"))
        // The title is the TIFF's name in the zip, as Opener.openZip leaves it.
        #expect(image.title == "ij-stack-8bit.tif")
        #expect(image.stack.planes == tiff.stack.planes)
        #expect(image.dimensions == tiff.dimensions)
        #expect(image.calibration == tiff.calibration)
    }

    @Test func onlyTheFirstEntryCounts() throws {
        guard case .image(let image) = try ZipImage.read(path: Self.zip("hyperstack.zip")) else {
            Issue.record("not an image")
            return
        }
        #expect(image.title == "hyper.tif")
        #expect(image.dimensions == HyperstackDimensions(channels: 2, slices: 3, frames: 4))
    }

    @Test func roiSetsAndOtherZips() throws {
        guard case .rois(let rois) = try ZipImage.read(path: Self.zip("rois.zip")) else {
            Issue.record("not ROIs")
            return
        }
        #expect(rois.count == 1)
        #expect(throws: MancoraIOError.invalidFormat("This ZIP archive does not contain a TIFF or DICOM file, or ROIs")) {
            try ZipImage.read(path: Self.zip("text.zip"))
        }
        #expect(throws: MancoraIOError.unsupported("DICOM images in ZIP archives")) { try ZipImage.read(path: Self.zip("dicom.zip")) }
        #expect(throws: MancoraIOError.self) { try ZipImage.decode(ZipContents.write([])) }
    }

    @Test func entryNamesFollowFileSaver() {
        #expect(ZipImage.entryName(for: "blobs.gif") == "blobs.gif.tif")
        #expect(ZipImage.entryName(for: "mri.zip") == "mri.tif")
        #expect(ZipImage.entryName(for: "cells.tif") == "cells.tif")
        #expect(ZipImage.entryName(for: "x.tif.zip") == "x.tif")
    }

    @Test func savedZipsAreDeflatedTIFFsThatReadBack() throws {
        let original = try TIFFImporter.read(path: Fixtures.path("Tests/Fixtures/tiff/ij-hyperstack-16bit.tif"))
        let bytes = try ZipImage.encode(original, name: "hyper")
        let entries = try ZipArchive.entries(bytes)
        #expect(entries.map(\.name) == ["hyper.tif"])
        #expect(entries.first?.method == 8)
        #expect(entries.first.map { $0.compressedSize < $0.size } == true)
        guard case .image(let back) = try ZipImage.decode(bytes) else {
            Issue.record("not an image")
            return
        }
        #expect(back.stack.planes == original.stack.planes)
        #expect(back.channels == original.channels)
        #expect(back.title == "hyper.tif")
        // The TIFF inside is exactly what Save As TIFF writes.
        #expect(try ZipArchive.data(of: entries[0], in: bytes, limit: 1 << 30) == TIFFExporter.encode(original))
    }

    @Test func writingAddsTheExtensionAndNamesTheEntryAfterTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try Hyperstack(title: "anything", stack: ImageStack(width: 3, height: 2, planes: [.gray8([1, 2, 3, 4, 5, 6])]))
        let name = try ZipImage.write(image, to: dir.appendingPathComponent("saved").path)
        #expect(name == "saved.tif")
        guard case .image(let back) = try ZipImage.read(path: dir.appendingPathComponent("saved.zip").path) else {
            Issue.record("not an image")
            return
        }
        #expect(back.title == "saved.tif")
        #expect(back.stack[0] == image.stack[0])
    }

    @Test func deflatedEntriesOfEverySize() throws {
        let files: [(name: String, data: [UInt8])] = [
            ("empty", []), ("one", [7]), ("text", Array(repeating: Array("ImageJ ".utf8), count: 300).flatMap { $0 }),
        ]
        let zip = ZipContents.write(files)
        let back = try ZipContents.read(zip)
        #expect(back.map(\.name) == files.map(\.name))
        #expect(back.map(\.data) == files.map(\.data))
    }
}
