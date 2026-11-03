// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "portmon",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PortmonCore", targets: ["PortmonCore"]),
        .executable(name: "portmon", targets: ["PortmonCLI"]),
        .executable(name: "portmon-app", targets: ["PortmonApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "PortmonCore",
            path: "Sources/PortmonCore"
        ),
        .executableTarget(
            name: "PortmonCLI",
            dependencies: ["PortmonCore"],
            path: "Sources/PortmonCLI"
        ),
        .executableTarget(
            name: "PortmonApp",
            dependencies: [
                "PortmonCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Portmon",
            exclude: []
        ),
        .testTarget(
            name: "PortmonTests",
            dependencies: ["PortmonCore"],
            path: "Tests/PortmonTests"
        )
    ]
)
