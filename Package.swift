// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacSonosControl",
    platforms: [.macOS(.v14)],
    targets: [
        // All Sonos logic lives here so it can be tested without the app.
        .target(name: "SonosKit"),
        // Key handling only: knows nothing about Sonos. Turns media-key events into "which key" and
        // hands them to whatever action is registered for that key.
        .target(name: "KeyKit"),
        // The menu bar app itself (AppKit code, kept in Swift 5 mode for simplicity).
        .executableTarget(
            name: "MacSonosControl",
            dependencies: ["SonosKit", "KeyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SonosKitTests", dependencies: ["SonosKit"]),
        .testTarget(name: "KeyKitTests", dependencies: ["KeyKit"]),
    ]
)
