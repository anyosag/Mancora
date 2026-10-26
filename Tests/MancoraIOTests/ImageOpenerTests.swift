import Foundation
import MancoraCore
import Testing

@testable import MancoraIO

@Suite("File types and opening")
struct ImageOpenerTests {
    @Test func typesFromMagicNumbersAndNames() {
        func type(_ bytes: [UInt8], _ name: String) -> FileType { FileType.of(header: bytes, name: name) }
        #expect(type([73, 73, 42, 0], "x.dat") == .tiff)
        #expect(type([77, 77, 0, 42], "x") == .tiff)
        #expect(type([73, 73, 43, 0], "big.tf8") == .tiff)
        #expect(type([73, 73, 42, 0], "scan.lsm") == .unknown)
        #expect(type([137, 80, 78, 71], "x.bin") == .png)
        #expect(type(Array("GIF89a".utf8), "anim") == .gif)
        #expect(type([255, 216, 255, 224], "photo") == .jpeg)
        #expect(type([0, 1, 2, 3], "image.zip") == .zip)
        #expect(type(Array("Iout".utf8), "sel") == .roi)
        #expect(type(Array("Area,Mean\n".utf8), "m.csv") == .table)
        #expect(type(Array("Area\tMean\n".utf8), "m.XLS") == .table)
        #expect(type(Array("Area\tMean\n".utf8), "notes.txt") == .javaOrText)
        #expect(type(Array("P5\n".utf8), "x") == .pgm)
        #expect(type(Array("hello world".utf8), "README") == .text)
        #expect(type([66, 77, 0, 200], "pic") == .bmp)
        #expect(type([0, 0, 0, 0, 200], "data.raw") == .raw)
        #expect(type([1, 2, 0xC8, 0xC9], "mystery") == .unknown)
        var dicom = [UInt8](repeating: 0, count: 132)
        dicom.replaceSubrange(128..<132, with: Array("DICM".utf8))
        #expect(type(dicom, "ct") == .dicom)
        dicom.replaceSubrange(0..<4, with: [73, 73, 42, 0])
        #expect(type(dicom, "ct") == .tiffAndDicom)
        #expect(FileType.of(path: "/no/such/file.tif") == .unknown)
    }

    @Test func opensEachNativeFormat() throws {
        func image(_ path: String) throws -> Hyperstack { try ImageOpener.read(path: Fixtures.path(path)) }
        #expect(try image("Tests/Fixtures/tiff/ij-stack-8bit.tif").stack.count > 1)
        #expect(try image("Tests/Fixtures/zip/stack.zip").title == "ij-stack-8bit.tif")
        #expect(try image("Tests/Fixtures/png/rgb8.png").pixelType == .rgb8)
        #expect(try image("Tests/Fixtures/gif/animated.gif").stack.count == 3)
        guard case .rois(let rois) = try ImageOpener.open(path: Fixtures.path("Tests/Fixtures/zip/rois.zip")) else {
            Issue.record("not ROIs")
            return
        }
        #expect(rois.count == 1)
        #expect(throws: MancoraIOError.self) { try image("Tests/Fixtures/zip/rois.zip") }
        guard case .roi = try ImageOpener.open(path: Fixtures.path("Tests/Fixtures/roi/ellipse.roi")) else {
            Issue.record("not a selection")
            return
        }
        #expect(throws: MancoraIOError.unreadable(path: "/no/such/file.tif", reason: "file not found")) {
            try ImageOpener.read(path: "/no/such/file.tif")
        }
    }

    @Test func decodesFromMemory() throws {
        let png = [UInt8](try Fixtures.data("Tests/Fixtures/png/gray16.png"))
        #expect(try ImageOpener.decode(png, name: "g.png").pixelType == .gray16)
        #expect(throws: MancoraIOError.self) { try ImageOpener.decode([255, 216, 255, 0], name: "x.jpg") }
    }

    @Test func tablesOpenWithTheirTitle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Results.csv").path
        try Data(" ,Area\n1,5\n".utf8).write(to: URL(fileURLWithPath: path))
        guard case .table(let rt, let title) = try ImageOpener.open(path: path) else {
            Issue.record("not a table")
            return
        }
        #expect(title == "Results")
        #expect(rt.number("Area", row: 0) == 5)
        #expect(rt.showsRowNumbers == true)
    }

    // MARK: Vendor TIFFs

    static func vendor(_ change: (inout TIFFBuilder) -> Void) -> [UInt8] {
        var b = TIFFBuilder.gray8(width: 4, height: 2)
        change(&b)
        return b.build()
    }

    @Test func vendorTIFFsAreLeftToImageJOrBioFormats() throws {
        let lsm = Self.vendor { $0.set(34412, 1, [UInt32](repeating: 0, count: 8)) }
        let stk = Self.vendor { $0.set(33629, 4, [UInt32](repeating: 0, count: 6 * 3)) }
        let ome = Self.vendor { $0.set(270, text: "<?xml version=\"1.0\"?><OME xmlns=\"http://www.openmicroscopy.org/Schemas/OME/2016-06\"/>") }
        for bytes in [lsm, stk, ome] {
            #expect {
                try TIFFImporter.decode(bytes, title: "v.tif")
            } throws: { error in
                guard case .unsupported = error as? MancoraIOError else { return false }
                return true
            }
            // Read as plain pages only when asked to.
            #expect(try TIFFImporter.decode(bytes, title: "v.tif", options: .init(ignoresVendorMetadata: true)).width == 4)
        }
        // One MetaMorph plane, and ImageJ's own descriptions, read as plain TIFF.
        let onePlane = Self.vendor { $0.set(33629, 4, [0]) }
        #expect(try TIFFImporter.decode(onePlane, title: "one.stk").width == 4)
        let imageJ = Self.vendor { $0.set(270, text: "ImageJ=1.54p\nOME note: <OME>\n") }
        #expect(try TIFFImporter.decode(imageJ, title: "ij.tif").width == 4)
    }

    @Test func lsmFilesAreRoutedAwayByName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-lsm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("plain.lsm").path
        try Data(Self.vendor { _ in }).write(to: URL(fileURLWithPath: path))
        #expect {
            try ImageOpener.read(path: path)
        } throws: { error in
            guard case .unsupported = error as? MancoraIOError else { return false }
            return true
        }
    }

    // MARK: Saving

    @Test func savesByExtension() throws {
        #expect(ImageSaver.Format(path: "/a/b.TIF") == .tiff)
        #expect(ImageSaver.Format(path: "b.tiff") == .tiff)
        #expect(ImageSaver.Format(path: "b.png") == .png)
        #expect(ImageSaver.Format(path: "b.gif") == .gif)
        #expect(ImageSaver.Format(path: "b.zip") == .zip)
        #expect(ImageSaver.Format(path: "b.jpg") == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try Hyperstack(title: "t", stack: ImageStack(width: 2, height: 2, planes: [.gray8([0, 50, 100, 150])]))
        for ext in ["tif", "zip", "png", "gif"] {
            let path = dir.appendingPathComponent("out." + ext).path
            let title = try ImageSaver.write(image, to: path)
            #expect(title == (ext == "zip" ? "out.tif" : "out." + ext))
            #expect(try ImageOpener.read(path: path).stack[0] == image.stack[0], "\(ext)")
        }
        #expect(throws: MancoraIOError.self) { try ImageSaver.write(image, to: dir.appendingPathComponent("out.jpg").path) }
    }
}
