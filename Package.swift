// swift-tools-version: 6.2
//
// Mancora's platform-neutral packages. Everything here must build on macOS,
// Windows and Linux; platform UI lives in the separate packages under Apps/.

import PackageDescription

let strictness: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Mancora",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MancoraBridge", targets: ["MancoraBridge"]),
        .library(name: "MancoraCommands", targets: ["MancoraCommands"]),
        .library(name: "MancoraCore", targets: ["MancoraCore"]),
        .library(name: "MancoraFiji", targets: ["MancoraFiji"]),
        .library(name: "MancoraIO", targets: ["MancoraIO"]),
        .library(name: "MancoraMacro", targets: ["MancoraMacro"]),
        .library(name: "MancoraPlugins", targets: ["MancoraPlugins"]),
        .library(name: "MancoraProcess", targets: ["MancoraProcess"]),
        .library(name: "MancoraSupport", targets: ["MancoraSupport"]),
        .library(name: "MancoraUpdate", targets: ["MancoraUpdate"]),
        .executable(name: "mancora", targets: ["MancoraCLI"]),
    ],
    targets: [
        .target(
            name: "MancoraBridge",
            dependencies: ["MancoraCore", "MancoraIO", "MancoraPlugins", "MancoraSupport", "MancoraUpdate"],
            swiftSettings: strictness
        ),
        .target(name: "MancoraCommands", dependencies: ["MancoraCore", "MancoraIO", "MancoraProcess"], swiftSettings: strictness),
        .target(name: "MancoraCore", swiftSettings: strictness),
        .target(
            name: "MancoraFiji", dependencies: ["MancoraPlugins", "MancoraSupport", "MancoraUpdate"], swiftSettings: strictness),
        .target(name: "MancoraIO", dependencies: ["MancoraCore", "MancoraSupport"], swiftSettings: strictness),
        .target(
            name: "MancoraMacro",
            dependencies: ["MancoraCommands", "MancoraCore", "MancoraIO", "MancoraProcess", "MancoraSupport"],
            swiftSettings: strictness
        ),
        .target(
            name: "MancoraPlugins", dependencies: ["MancoraIO", "MancoraSupport", "MancoraUpdate"], swiftSettings: strictness),
        .target(name: "MancoraProcess", dependencies: ["MancoraCore"], swiftSettings: strictness),
        .target(name: "MancoraSupport", swiftSettings: strictness),
        .target(name: "MancoraUpdate", dependencies: ["MancoraSupport"], swiftSettings: strictness),
        .executableTarget(
            name: "MancoraCLI",
            dependencies: [
                "MancoraBridge", "MancoraCommands", "MancoraCore", "MancoraIO", "MancoraMacro", "MancoraPlugins",
                "MancoraSupport", "MancoraUpdate",
            ],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraBridgeTests",
            dependencies: ["MancoraBridge", "MancoraCore", "MancoraIO", "MancoraPlugins", "MancoraUpdate"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraCommandsTests",
            dependencies: ["MancoraCommands", "MancoraCore", "MancoraProcess"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraCoreTests",
            dependencies: ["MancoraCore"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraFijiTests",
            dependencies: ["MancoraFiji", "MancoraPlugins", "MancoraSupport", "MancoraUpdate"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraIOTests",
            dependencies: ["MancoraCore", "MancoraIO"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraMacroTests",
            dependencies: ["MancoraCommands", "MancoraCore", "MancoraMacro"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraParityTests",
            dependencies: [
                "MancoraBridge", "MancoraCommands", "MancoraCore", "MancoraIO", "MancoraMacro", "MancoraPlugins",
                "MancoraSupport", "MancoraUpdate",
            ],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraPluginsTests",
            dependencies: ["MancoraIO", "MancoraPlugins", "MancoraSupport", "MancoraUpdate"],
            exclude: ["Fixtures"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraProcessTests",
            dependencies: ["MancoraCore", "MancoraProcess"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraSupportTests",
            dependencies: ["MancoraSupport"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraUpdateTests",
            dependencies: ["MancoraSupport", "MancoraUpdate"],
            swiftSettings: strictness
        ),
    ],
    swiftLanguageModes: [.v6]
)
