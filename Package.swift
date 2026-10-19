// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LogiKeyPad",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LogiKeyPad",
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(name: "LogiKeyPadTests", dependencies: ["LogiKeyPad"]),
    ]
)
