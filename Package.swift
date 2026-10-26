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
        .library(name: "MancoraCore", targets: ["MancoraCore"]),
        .library(name: "MancoraIO", targets: ["MancoraIO"]),
        .library(name: "MancoraSupport", targets: ["MancoraSupport"]),
        .library(name: "MancoraUpdate", targets: ["MancoraUpdate"]),
        .executable(name: "mancora", targets: ["MancoraCLI"]),
    ],
    targets: [
        .target(name: "MancoraCore", swiftSettings: strictness),
        .target(name: "MancoraIO", dependencies: ["MancoraCore", "MancoraSupport"], swiftSettings: strictness),
        .target(name: "MancoraSupport", swiftSettings: strictness),
        .target(name: "MancoraUpdate", dependencies: ["MancoraSupport"], swiftSettings: strictness),
        .executableTarget(
            name: "MancoraCLI",
            dependencies: ["MancoraCore", "MancoraIO", "MancoraSupport", "MancoraUpdate"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraCoreTests",
            dependencies: ["MancoraCore"],
            swiftSettings: strictness
        ),
        .testTarget(
            name: "MancoraIOTests",
            dependencies: ["MancoraCore", "MancoraIO"],
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
