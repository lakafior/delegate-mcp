// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "delegate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DelegateCore", targets: ["DelegateCore"]),
        .executable(name: "delegate-mcp", targets: ["delegate-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "DelegateCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .executableTarget(
            name: "delegate-mcp",
            dependencies: [
                "DelegateCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(name: "DelegateCoreTests", dependencies: ["DelegateCore"]),
    ]
)
