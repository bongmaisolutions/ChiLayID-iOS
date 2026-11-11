// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BMSZalo",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        // Core 100% self-contained Native Zalo iOS Protocol Engine (Zero external dependencies)
        .library(
            name: "ZolaKit",
            targets: ["ZolaKit"]
        ),
        // Full-featured BMSZalo iOS/macOS SwiftUI App + JSON Cross-Platform Bridge
        .library(
            name: "BMSZaloApp",
            targets: ["BMSZaloApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ZolaKit",
            dependencies: [],
            path: "Sources/ZolaKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "BMSZaloApp",
            dependencies: ["ZolaKit"],
            path: "Sources/BMSZaloApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ZolaKitTests",
            dependencies: ["ZolaKit"],
            path: "Tests/ZolaKitTests"
        ),
        .testTarget(
            name: "ZolaKitCallTests",
            dependencies: ["ZolaKit"],
            path: "Tests/ZolaKitCallTests"
        )
    ]
)
