// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PRNotch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "PRNotch", targets: ["PRNotch"]),
    ],
    targets: [
        .executableTarget(
            name: "PRNotch",
            path: "Sources/PRNotch"
        ),
        .testTarget(
            name: "PRNotchTests",
            dependencies: ["PRNotch"],
            path: "Tests/PRNotchTests"
        ),
    ]
)
