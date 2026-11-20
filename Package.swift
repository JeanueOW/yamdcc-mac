// swift-tools-version:5.9
// YAMDCC for macOS — a SwiftUI port of YAMDCC (Yet Another MSI Dragon Center Clone).
// GPL-3.0-or-later. See README.md and LICENSE.

import PackageDescription

let package = Package(
    name: "yamdcc-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "YAMDCCKit", targets: ["YAMDCCKit"]),
        .executable(name: "yamdcc", targets: ["yamdcc-cli"]),
        .executable(name: "YAMDCCApp", targets: ["YAMDCCApp"]),
    ],
    targets: [
        .target(
            name: "YAMDCCKit",
            path: "Sources/YAMDCCKit"
        ),
        .executableTarget(
            name: "yamdcc-cli",
            dependencies: ["YAMDCCKit"],
            path: "Sources/yamdcc-cli"
        ),
        .executableTarget(
            name: "YAMDCCApp",
            dependencies: ["YAMDCCKit"],
            path: "Sources/YAMDCCApp"
        ),
        .testTarget(name: "YAMDCCKitTests", dependencies: ["YAMDCCKit"]),
    ]
)
