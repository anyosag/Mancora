// swift-tools-version: 6.2
//
// The macOS app shell. It's a separate package so Apple-only dependencies
// never reach the platform-neutral core in the repository root.
//
//   swift run --package-path Apps/macOS
//
// Tools/package/macos/package.sh wraps the release build in Mancora.app
// (icon, Info.plist, bundled LUTs) and a DMG.

import PackageDescription

let package = Package(
    name: "MancoraMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Mancora", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MancoraApp",
            dependencies: [
                .product(name: "MancoraBridge", package: "Mancora"),
                .product(name: "MancoraCommands", package: "Mancora"),
                .product(name: "MancoraCore", package: "Mancora"),
                .product(name: "MancoraIO", package: "Mancora"),
                .product(name: "MancoraMacro", package: "Mancora"),
                .product(name: "MancoraPlugins", package: "Mancora"),
                .product(name: "MancoraProcess", package: "Mancora"),
                .product(name: "MancoraSupport", package: "Mancora"),
                .product(name: "MancoraUpdate", package: "Mancora"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
