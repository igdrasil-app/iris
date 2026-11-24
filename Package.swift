// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iris",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "iris",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // The HTTP gate and the HTTP scope only: who gets past the one and what the other lets a caller
        // see could change silently, and no hand check would notice.
        .testTarget(name: "irisTests", dependencies: ["iris"]),
    ]
)
