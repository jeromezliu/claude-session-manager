// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionManager",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessionManager",
            path: "Sources/ClaudeSessionManager"
        )
    ]
)
