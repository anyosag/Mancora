// swift-tools-version: 6.2
//
// The macOS app shell. It's a separate package so Apple-only dependencies
// never reach the platform-neutral core in the repository root.
//
//   swift run --package-path Apps/macOS
//
// Phase 1 replaces this executable with an XcodeGen project that builds a
// signed .app bundle with the Mancora icon.

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
                .product(name: "MancoraCore", package: "Mancora"),
                .product(name: "MancoraIO", package: "Mancora"),
            ],
            // A copy of Resources/Branding/AppIcon.appiconset/icon_512x512.png
            // for the Dock; the Phase 1 app bundle uses the asset catalog.
            resources: [.copy("Resources/AppIcon.png")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
