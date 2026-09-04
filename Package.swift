// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentUsageBar", path: "Sources/AgentUsageBar")
    ]
)
