import Foundation
import Testing

/// Locates test data in the source tree, as `Tests/MancoraIOTests/Fixtures.swift` does.
enum ProcessFixtures {
    static let repoRoot: String = {
        var parts = #filePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        parts.removeLast(3)  // ProcessFixtures.swift, MancoraProcessTests, Tests
        return parts.joined(separator: "/")
    }()

    static func path(_ relative: String) -> String { repoRoot + "/" + relative }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(relative)))
    }

    /// Decodes a JSON fixture, or `nil` if it's missing or malformed.
    static func json<T: Decodable>(_ type: T.Type, _ relative: String) -> T? {
        try? JSONDecoder().decode(type, from: data(relative))
    }
}
