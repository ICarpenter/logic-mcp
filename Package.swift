// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "logic-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "LogicMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "logic-mcp",
            dependencies: [
                "LogicMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LogicMCPCoreTests",
            dependencies: [
                "LogicMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
