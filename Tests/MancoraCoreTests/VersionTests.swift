import Foundation
import MancoraCore
import Testing

@Test("MancoraVersion matches the VERSION file the installers use")
func versionMatchesFile() throws {
    var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
    parts.removeLast(3)
    let path = parts.joined(separator: "/") + "/VERSION"
    let file = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == MancoraVersion.number)
}
