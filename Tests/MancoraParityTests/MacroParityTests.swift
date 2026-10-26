import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraMacro
import Testing

@testable import MancoraBridge

/// A macro run natively and in ImageJ 1.54p: the Log window's text, the
/// error that stopped it (message and line), the images it made or changed
/// and the results table must all match.
struct MacroParityCase: Sendable, CustomStringConvertible {
    var name: String
    var code: String
    var inputs: [ParityInput] = []
    var tolerance = 1e-9
    var description: String { name }

    init(_ name: String, _ code: String, on inputs: ParityInput..., tolerance: Double = 1e-9) {
        self.name = name
        self.code = code
        self.inputs = inputs
        self.tolerance = tolerance
    }
}

enum MacroParity {
    static func check(_ cases: [MacroParityCase], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var config = Bridge.Configuration(
            java: Parity.java!, home: Parity.home, helperSource: Parity.url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: Parity.url("Resources/Bridge/imagej-commands.tsv"))
        config.timeoutSeconds = 300
        config.maximumHeapMegabytes = 512
        let bridge = Bridge(configuration: config)
        do {
            _ = try await bridge.start()
            for parityCase in cases {
                for difference in try await compare(parityCase, bridge: bridge) {
                    Issue.record("\(parityCase): \(difference)", sourceLocation: sourceLocation)
                }
            }
        } catch {
            await bridge.stop()
            throw error
        }
        await bridge.stop()
    }

    static func compare(_ parityCase: MacroParityCase, bridge: Bridge) async throws -> [String] {
        let inputs = try parityCase.inputs.map { try $0.image() }
        let session = MacroSession()
        var ids: [Int] = []
        for input in inputs { ids.append(session.add(input)) }
        var nativeError: MacroError?
        do { try session.run(parityCase.code) } catch { nativeError = error }
        let result = try await bridge.runMacro(parityCase.code, images: inputs)

        var differences: [String] = []
        if session.logText != result.log {
            differences.append("log:\n--- Mancora\n\(session.logText)--- ImageJ\n\(result.log)---")
        }
        if nativeError?.message != result.macroError {
            differences.append("error: Mancora \(nativeError?.message ?? "none"), ImageJ \(result.macroError ?? "none")")
        } else if let nativeError, let line = result.macroErrorLine, nativeError.lineNumber != line {
            differences.append("error line: Mancora \(nativeError.lineNumber), ImageJ \(line)")
        }
        if nativeError != nil || result.macroError != nil { return differences }

        // The images made or changed, in the order they were opened.
        var native: [Hyperstack] = []
        for open in session.context.images {
            if let k = ids.firstIndex(of: open.id), open.image == inputs[k] { continue }
            native.append(try Parity.roundTrip(open.image))
        }
        if native.count != result.images.count {
            differences.append(
                "images: Mancora \(native.map(\.title)), ImageJ \(result.images.map(\.title))")
        } else {
            for (ours, theirs) in zip(native, result.images) {
                differences += ImageComparison.differences(ours, theirs.image, tolerance: parityCase.tolerance)
                    .map { "\(theirs.title): \($0)" }
            }
        }
        differences += ImageComparison.differences(session.context.results, result.results, tolerance: parityCase.tolerance)
        return differences
    }
}

@Suite("Macro language parity with ImageJ", .enabled(if: Parity.available), .serialized)
struct MacroParityTests {
    @Test func language() async throws {
        try await MacroParity.check(MacroCorpus.language)
    }
}
