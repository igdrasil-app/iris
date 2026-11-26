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
        // The HTTP gate, the HTTP scope, alarm minutes, availability, attendee words, the Reminders prompt
        // limit and how reminders read, filter and order only: who gets past the one, what the other lets a
        // caller see, how an alarm reads back, which availability a calendar takes, how a reply status or
        // address reads, whether an unanswered prompt ends the call, and which reminders a due range keeps
        // and in what order could change silently, and no hand check would notice. So could the menu bar's
        // menu, in states and permissions nobody sets up by hand to look at.
        .testTarget(name: "irisTests", dependencies: ["iris"]),
    ]
)
