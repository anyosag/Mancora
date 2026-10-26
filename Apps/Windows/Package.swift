// swift-tools-version: 6.2
//
// The Windows app shell: a small native Win32 viewer, used until the WinUI 3
// app arrives in Phase 5. It's a separate package so Windows-only code never
// reaches the platform-neutral core.
//
//   swift build --package-path Apps/Windows
//
// Tools/package/windows/package.ps1 builds the installer.

import PackageDescription

let package = Package(
    name: "MancoraWindows",
    dependencies: [
        .package(name: "Mancora", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MancoraViewer",
            dependencies: [
                .product(name: "MancoraCore", package: "Mancora"),
                .product(name: "MancoraIO", package: "Mancora"),
                .product(name: "MancoraSupport", package: "Mancora"),
                .product(name: "MancoraUpdate", package: "Mancora"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")],
            linkerSettings: [
                // A GUI program: no console window. Swift provides `main`,
                // so start through the CRT's console entry point.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
