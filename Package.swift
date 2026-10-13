// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iris",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iris",
            linkerSettings: [
                // A bare binary has no Info.plist; embed one so macOS can find the
                // calendar usage string when it decides whether to show a prompt.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
    ]
)
