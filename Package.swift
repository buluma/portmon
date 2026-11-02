// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "portmon",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "portmon", targets: ["Portmon"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Portmon",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Portmon"
        ),
        .testTarget(
            name: "PortmonTests",
            dependencies: ["Portmon"],
            path: "Tests/PortmonTests"
        )
    ]
)
