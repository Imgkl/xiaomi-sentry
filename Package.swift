// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XiaomiSentry",
    platforms: [.macOS(.v15)],
    targets: [
        // go2rtc API client, fMP4 demuxer and pan reply parsing. No UI.
        .target(name: "SentryCore", path: "Sources/SentryCore"),
        // The menu bar app.
        .executableTarget(name: "XiaomiSentry", dependencies: ["SentryCore"], path: "Sources/XiaomiSentry"),
        .testTarget(
            name: "SentryCoreTests",
            dependencies: ["SentryCore"],
            path: "Tests/SentryCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
