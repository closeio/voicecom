// swift-tools-version:5.9
import PackageDescription

#if arch(arm) || arch(arm64)
let platforms: [SupportedPlatform]? = [
    .macOS(.v13),
    .iOS(.v14),
]
let exclude: [String] = ["vendor/Sources/whisper/ggml-metal.m", "vendor/Sources/whisper/ggml-metal.metal"]
#else
let platforms: [SupportedPlatform]? = [
    .macOS(.v13),
]
let exclude: [String] = ["vendor/Sources/whisper/ggml-metal.m", "vendor/Sources/whisper/ggml-metal.metal"]
#endif

let package = Package(
    name: "LocalWhisper",
    platforms: platforms,
    products: [
        .library(
            name: "LocalWhisper",
            targets: ["LocalWhisper"])
    ],
    targets: [
        .target(
            name: "LocalWhisper",
            path: ".",
            exclude: exclude + [
                "vendor/Package.swift",
                "vendor/Makefile",
                "vendor/LICENSE",
                "vendor/README.md",
                "vendor/.git",
                "vendor/.gitmodules",
                "vendor/Sources/test-objc",
                "vendor/Sources/test-swift",
            ],
            sources: [
                "vendor/Sources/whisper/ggml.c",
                "vendor/Sources/whisper/ggml-alloc.c",
                "vendor/Sources/whisper/ggml-backend.c",
                "vendor/Sources/whisper/ggml-quants.c",
                "vendor/Sources/whisper/coreml/whisper-encoder-impl.m",
                "vendor/Sources/whisper/coreml/whisper-encoder.mm",
                "vendor/Sources/whisper/whisper.cpp",
            ],
            publicHeadersPath: "vendor/Sources/whisper/include",
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("WHISPER_USE_COREML"),
                .define("WHISPER_COREML_ALLOW_FALLBACK"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
            ]
        ),
    ],
    cxxLanguageStandard: CXXLanguageStandard.cxx11
)
