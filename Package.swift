// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeTop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeTop", targets: ["ClaudeTop"]),
        .executable(name: "claude-top-hook", targets: ["claude-top-hook"]),
    ],
    targets: [
        .target(name: "ClaudeTopCore"),
        .executableTarget(name: "claude-top-hook", dependencies: ["ClaudeTopCore"]),
        .executableTarget(name: "claude-top-eval", dependencies: ["ClaudeTopCore"]),
        .executableTarget(
            name: "ClaudeTop",
            dependencies: ["ClaudeTopCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ClaudeTopCoreTests", dependencies: ["ClaudeTopCore"]),
        .testTarget(
            name: "ClaudeTopSnapshotTests",
            dependencies: ["ClaudeTop", "ClaudeTopCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
