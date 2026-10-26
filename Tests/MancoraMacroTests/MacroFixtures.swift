import Foundation
import Testing

/// Locates test data in the source tree, as `Tests/MancoraIOTests/Fixtures.swift` does.
enum MacroFixtures {
    static let repoRoot: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)  // MacroFixtures.swift, MancoraMacroTests, Tests
        return parts.joined(separator: "/")
    }()

    static func path(_ relative: String) -> String { repoRoot + "/" + relative }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(relative)))
    }
}
