// swift-tools-version: 6.2
import Foundation
import PackageDescription

// MARK: - sherpa-onnx (TTS engine, vendored static libraries)

/// Absolute path of the package directory (`app/`); manifests run with an
/// arbitrary working directory, so derive it from the manifest file itself.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
/// Static libraries downloaded by `scripts/fetch_sherpa.sh` (gitignored).
let sherpaLibDirectory = packageDirectory + "/Vendor/sherpa/lib"

/// Link sherpa-onnx + its bundled dependencies statically.
///
/// The archive order matters for static linking: `sherpa-onnx-c-api` first,
/// then the core implementation archives, then the third-party archives it
/// references (`kaldi-decoder-core` is required or `kaldi::*` symbols stay
/// undefined), and finally the system frameworks. `-L` must precede `-l`
/// flags. Kept as a single `.unsafeFlags` array so SwiftPM preserves order.
let sherpaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", sherpaLibDirectory,
        "-lsherpa-onnx-c-api",
        "-lsherpa-onnx-core",
        "-lsherpa-onnx-fst",
        "-lsherpa-onnx-fstfar",
        "-lsherpa-onnx-kaldifst-core",
        "-lkaldi-decoder-core",
        "-lssentencepiece_core",
        "-lkaldi-native-fbank-core",
        "-lkissfft-float",
        "-lutf8proc",
        "-lonnxruntime",
        "-lc++",
        "-framework", "Accelerate",
        "-framework", "CoreML",
        "-framework", "Foundation",
        "-lz",
    ])
]

let package = Package(
    name: "WeChatAI",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "WeChatAI", targets: ["WeChatAI"])
    ],
    targets: [
        // Public C header + module map for the vendored sherpa-onnx static library.
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "WeChatAI",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/WeChatBot",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: sherpaLinkerSettings
        ),
        .testTarget(
            name: "WeChatAITests",
            dependencies: ["WeChatAI"],
            path: "Tests/WeChatAITests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: sherpaLinkerSettings
        )
    ]
)
