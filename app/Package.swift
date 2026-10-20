// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WeChatAI",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "WeChatAI", targets: ["WeChatAI"])
    ],
    targets: [
        .executableTarget(
            name: "WeChatAI",
            path: "Sources/WeChatBot",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WeChatAITests",
            dependencies: ["WeChatAI"],
            path: "Tests/WeChatAITests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
