// swift-tools-version: 6.2
import PackageDescription

// MARK: - WeChat AI native app
//
// 语音合成走本机 CosyVoice3 HTTP 旁路（devtools/cosyvoice/server.py），
// App 侧不链接任何本地推理静态库：`swift build` 无需额外下载 vendored 依赖。

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
