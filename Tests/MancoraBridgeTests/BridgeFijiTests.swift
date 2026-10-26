import Foundation
import MancoraFiji
import MancoraPlugins
import Testing

@testable import MancoraBridge

/// A tiny Fiji folder: placeholder jars, a JDK whose java is a script.
enum FakeFijiLayout {
    static func make() throws -> FijiInstallation {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bridge-fiji-\(UUID().uuidString)/Fiji")
        var home = "java/\(Platforms.current)/zulu21-fake"
        if Platforms.isMac(Platforms.current) { home += "/zulu-21.jdk/Contents/Home" }
        let fm = FileManager.default
        for (path, executable) in [
            ("jars/ij-1.54p.jar", false), ("jars/imagej-legacy-3.0.0.jar", false), ("jars/scijava-common-2.101.0.jar", false),
            ("jars/\(Platforms.current)/javafx-base-23.0.2.jar", false), ("plugins/TrackMate_-8.jar", false),
            ("images/icon.png", false), ("\(home)/bin/java", true), ("\(home)/bin/javac", true), ("\(home)/release", false),
        ] {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((path.hasSuffix("release") ? "JAVA_VERSION=\"21.0.7\"\n" : "#!/bin/sh\n").utf8).write(to: url)
            #if !os(Windows)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            #endif
        }
        return FijiInstallation(root: root)
    }

    static func configuration(interactive: Bool = false) -> Bridge.Configuration {
        let home = BridgeHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bridge-home-\(UUID().uuidString)"))
        var config = Bridge.Configuration(
            java: JavaRuntime(executable: URL(fileURLWithPath: "/usr/bin/java"), majorVersion: 21, compiler: nil), home: home,
            helperSource: BridgeFixtures.url("Resources/Bridge/MancoraBridgeHelper.java"),
            commandTable: BridgeFixtures.url("Resources/Bridge/imagej-commands.tsv"))
        config.interactive = interactive
        return config
    }
}

@Suite("Java bridge: in Fiji")
struct BridgeFijiTests {
    let classes = URL(fileURLWithPath: "/compiled/helper")

    @Test func fijiStartsWithItsOwnJavaOptionsAndClassPath() throws {
        let fiji = try FakeFijiLayout.make()
        defer { try? FileManager.default.removeItem(at: fiji.root.deletingLastPathComponent()) }
        let config = FakeFijiLayout.configuration()
        let arguments = Bridge.javaArguments(config, fiji: fiji, classes: classes, display: .virtual, macOS: false)
        // Fiji's launcher options first, then the class path and the class that starts ImageJ2.
        #expect(Array(arguments.prefix(fiji.javaOptions().count)) == fiji.javaOptions())
        #expect(arguments.suffix(3) == ["-cp", (fiji.classPath() + [classes]).map(\.path).joined(separator: JavaRuntime.isWindows ? ";" : ":"), "MancoraFijiBridge"])
        #expect(arguments.contains("-Dmancora.virtualDisplay=true"))
        // Fiji's ImageJ builds its own command table; there's no plain ImageJ folder.
        #expect(!arguments.contains { $0.hasPrefix("-Dmancora.commands=") || $0.hasPrefix("-Dplugins.dir=\(config.home.root.path)") })
        #expect(arguments.contains("-Dplugins.dir=\(fiji.root.path)"))
        #expect(!arguments.contains("-Dmancora.interactive=true"))
    }

    @Test func interactiveHelpersGetADockIconOnMacOS() throws {
        let fiji = try FakeFijiLayout.make()
        defer { try? FileManager.default.removeItem(at: fiji.root.deletingLastPathComponent()) }
        let batch = Bridge.javaArguments(FakeFijiLayout.configuration(), fiji: fiji, classes: classes, display: .own, macOS: true)
        #expect(batch.contains("-Dapple.awt.UIElement=true"))
        #expect(!batch.contains { $0.hasPrefix("-Xdock") })

        var config = FakeFijiLayout.configuration(interactive: true)
        let interactive = Bridge.javaArguments(config, fiji: fiji, classes: classes, display: .own, macOS: true)
        #expect(interactive.contains("-Dmancora.interactive=true"))
        #expect(interactive.contains("-Xdock:name=Fiji"))
        #expect(interactive.contains("-Xdock:icon=\(try #require(fiji.icon).path)"))
        #expect(!interactive.contains("-Dapple.awt.UIElement=true"))
        config.dockName = "Mancora Fiji"
        config.dockIcon = URL(fileURLWithPath: "/Applications/Mancora.app/Contents/Resources/AppIcon.icns")
        let named = Bridge.javaArguments(config, fiji: fiji, classes: classes, display: .own, macOS: true)
        #expect(named.contains("-Xdock:name=Mancora Fiji"))
        #expect(named.contains("-Xdock:icon=\(config.dockIcon!.path)"))
        // Elsewhere, no Dock options.
        #expect(!Bridge.javaArguments(config, fiji: fiji, classes: classes, display: .own, macOS: false).contains { $0.hasPrefix("-Xdock") })
    }

    /// Plain ImageJ (what the parity tests pin) starts as it always has.
    @Test func plainImageJStartsAsBefore() {
        var config = FakeFijiLayout.configuration()
        config.maximumHeapMegabytes = 512
        let home = config.home.root.path
        let arguments = Bridge.javaArguments(config, fiji: nil, classes: classes, display: .headless, macOS: false)
        #expect(
            arguments == [
                "-Xmx512m", "-Dplugins.dir=\(home)", "-Dij.dir=\(home)", "-Dfile.encoding=UTF-8",
                "-Dmancora.commands=\(config.commandTable!.path)", "-Djava.awt.headless=true",
                "-cp", (config.home.classPath() + [classes]).map(\.path).joined(separator: JavaRuntime.isWindows ? ";" : ":"), "MancoraBridgeHelper",
            ])
    }

    @Test func javaArgumentFilesQuoteEachArgument() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Bridge.argumentFile(["-cp", "C:\\Fiji Folder\\jars\\a.jar;b.jar", "say \"hi\""], in: folder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "\"-cp\"\n\"C:/Fiji Folder/jars/a.jar;b.jar\"\n\"say \\\"hi\\\"\"")
    }

    @Test func fijisAnswersDecode() throws {
        let hello = try JSONDecoder().decode(
            BridgeHello.self,
            from: Data(#"{"imagej":"2.18.0/1.54p","java":"21.0.7","pluginsDir":"/F","pid":7,"fiji":{"Fiji":"2.18.1","ImageJ1":"1.54p"},"startupLog":""}"#.utf8))
        #expect(hello.isFiji && hello.fiji?["Fiji"] == "2.18.1")
        let plain = try JSONDecoder().decode(BridgeHello.self, from: Data(#"{"imagej":"1.54p","java":"21","pluginsDir":null,"pid":7}"#.utf8))
        #expect(!plain.isFiji)

        let values = try JSONDecoder().decode(
            [String: BridgeValue].self, from: Data(#"{"a":true,"b":1,"c":2.5,"d":"text","e":null,"f":[1,"x",false]}"#.utf8))
        #expect(values == ["a": .bool(true), "b": .number(1), "c": .number(2.5), "d": .string("text"), "e": .null,
                           "f": .list([.number(1), .string("x"), .bool(false)])])
        #expect(values["b"]?.description == "1" && values["c"]?.description == "2.5")
        let encoded = try JSONEncoder().encode(["sigma": BridgeValue.number(2), "name": "x", "on": true])
        #expect(try JSONDecoder().decode([String: BridgeValue].self, from: encoded) == ["sigma": 2, "name": "x", "on": true])

        let menus = try JSONDecoder().decode(
            [BridgeMenuItem].self,
            from: Data(#"""
                [{"kind":"imagej1","path":["Plugins","Tracking","TrackMate"],"command":"TrackMate","identifier":"fiji.plugin.trackmate.TrackMateRunner","className":"fiji.plugin.trackmate.TrackMateRunner","shortcut":null},
                 {"kind":"separator","path":["Plugins","Tracking"]},
                 {"kind":"command","path":["File","New","Script..."],"command":"Script...","identifier":"command:org.scijava.ui.swing.script.ScriptEditor","className":"org.scijava.ui.swing.script.ScriptEditor","shortcut":"Shift+N"}]
                """#.utf8))
        #expect(menus.map(\.kind) == [.imagej1, .separator, .command])
        #expect(menus[1].isSeparator && menus[1].command == nil)
        #expect(menus[2].shortcut == "Shift+N")
    }

    /// A bridge set to run in a Fiji that isn't installed says so.
    @Test func aFijiThatIsNotInstalledIsReported() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mancora-bridge-nofiji-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        var config = FakeFijiLayout.configuration()
        config.fiji = FijiManager(root: parent.appendingPathComponent("Fiji"))
        let bridge = Bridge(configuration: config)
        await #expect {
            try await bridge.start()
        } throws: { error in
            if case FijiError.notInstalled = error { return true }
            return false
        }
    }
}
