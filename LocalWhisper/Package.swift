// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalWhisper",
    platforms: [
        .macOS(.v13),
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "LocalWhisper",
            targets: ["LocalWhisper"])
    ],
    targets: [
        // Metal backend Objective-C files compiled without ARC (whisper.cpp uses manual retain/release)
        .target(
            name: "LocalWhisperMetal",
            path: "MetalObjC",
            resources: [
                .copy("ggml-metal.metal"),
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../vendor/include"),
                .headerSearchPath("../vendor/ggml/include"),
                .headerSearchPath("../vendor/ggml/src"),
                .headerSearchPath("../vendor/ggml/src/ggml-metal"),
                .define("GGML_USE_METAL"),
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("_DARWIN_C_SOURCE"),
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "LocalWhisper",
            dependencies: ["LocalWhisperMetal"],
            path: ".",
            exclude: [
                // MetalObjC target directory (compiled separately)
                "MetalObjC",

                // Top-level repo files
                "vendor/CMakeLists.txt",
                "vendor/Makefile",
                "vendor/LICENSE",
                "vendor/README.md",
                "vendor/.git",
                "vendor/.gitignore",
                "vendor/.github",
                "vendor/.devops",
                "vendor/.dockerignore",

                // Directories we don't need
                "vendor/cmake",
                "vendor/models",
                "vendor/samples",
                "vendor/scripts",
                "vendor/tests",
                "vendor/examples",
                "vendor/bindings",
                "vendor/grammars",

                // OpenVINO (not needed on Apple)
                "vendor/src/openvino",

                // ggml cmake files
                "vendor/ggml/CMakeLists.txt",
                "vendor/ggml/cmake",
                "vendor/ggml/.gitignore",
                "vendor/ggml/src/CMakeLists.txt",

                // Metal backend CMake and shader source (pre-merged version in resources/)
                "vendor/ggml/src/ggml-metal/CMakeLists.txt",
                "vendor/ggml/src/ggml-metal/ggml-metal.metal",
                // Metal ObjC files compiled separately in LocalWhisperMetal target (needs -fno-objc-arc)
                "vendor/ggml/src/ggml-metal/ggml-metal-device.m",
                "vendor/ggml/src/ggml-metal/ggml-metal-context.m",

                // Non-Apple GPU/accelerator backends
                "vendor/ggml/src/ggml-blas",
                "vendor/ggml/src/ggml-cann",
                "vendor/ggml/src/ggml-cuda",
                "vendor/ggml/src/ggml-hexagon",
                "vendor/ggml/src/ggml-hip",
                "vendor/ggml/src/ggml-musa",
                "vendor/ggml/src/ggml-opencl",
                "vendor/ggml/src/ggml-rpc",
                "vendor/ggml/src/ggml-sycl",
                "vendor/ggml/src/ggml-virtgpu",
                "vendor/ggml/src/ggml-vulkan",
                "vendor/ggml/src/ggml-webgpu",
                "vendor/ggml/src/ggml-zdnn",
                "vendor/ggml/src/ggml-zendnn",

                // CPU backend CMake
                "vendor/ggml/src/ggml-cpu/CMakeLists.txt",
                "vendor/ggml/src/ggml-cpu/cmake",

                // Non-Apple CPU arch-specific files
                "vendor/ggml/src/ggml-cpu/arch/x86",
                "vendor/ggml/src/ggml-cpu/arch/powerpc",
                "vendor/ggml/src/ggml-cpu/arch/riscv",
                "vendor/ggml/src/ggml-cpu/arch/s390",
                "vendor/ggml/src/ggml-cpu/arch/loongarch",
                "vendor/ggml/src/ggml-cpu/arch/wasm",

                // KleidiAI (needs external fetch)
                "vendor/ggml/src/ggml-cpu/kleidiai",

                // Spacemit (RISC-V only)
                "vendor/ggml/src/ggml-cpu/spacemit",

                // src cmake
                "vendor/src/CMakeLists.txt",
            ],
            sources: [
                // --- GGML core (ggml-base) ---
                "vendor/ggml/src/ggml.c",
                "vendor/ggml/src/ggml.cpp",
                "vendor/ggml/src/ggml-alloc.c",
                "vendor/ggml/src/ggml-backend.cpp",
                "vendor/ggml/src/ggml-opt.cpp",
                "vendor/ggml/src/ggml-threading.cpp",
                "vendor/ggml/src/ggml-quants.c",
                "vendor/ggml/src/gguf.cpp",

                // --- GGML backend registration ---
                "vendor/ggml/src/ggml-backend-dl.cpp",
                "vendor/ggml/src/ggml-backend-reg.cpp",

                // --- GGML CPU backend ---
                "vendor/ggml/src/ggml-cpu/ggml-cpu.c",
                "vendor/ggml/src/ggml-cpu/ggml-cpu.cpp",
                "vendor/ggml/src/ggml-cpu/repack.cpp",
                "vendor/ggml/src/ggml-cpu/hbm.cpp",
                "vendor/ggml/src/ggml-cpu/quants.c",
                "vendor/ggml/src/ggml-cpu/traits.cpp",
                "vendor/ggml/src/ggml-cpu/amx/amx.cpp",
                "vendor/ggml/src/ggml-cpu/amx/mmq.cpp",
                "vendor/ggml/src/ggml-cpu/binary-ops.cpp",
                "vendor/ggml/src/ggml-cpu/unary-ops.cpp",
                "vendor/ggml/src/ggml-cpu/vec.cpp",
                "vendor/ggml/src/ggml-cpu/ops.cpp",

                // --- ARM arch-specific (Apple Silicon) ---
                "vendor/ggml/src/ggml-cpu/arch/arm/quants.c",
                "vendor/ggml/src/ggml-cpu/arch/arm/repack.cpp",
                "vendor/ggml/src/ggml-cpu/arch/arm/cpu-feats.cpp",

                // --- GGML Metal backend (GPU acceleration, C++ files only) ---
                "vendor/ggml/src/ggml-metal/ggml-metal.cpp",
                "vendor/ggml/src/ggml-metal/ggml-metal-device.cpp",
                "vendor/ggml/src/ggml-metal/ggml-metal-common.cpp",
                "vendor/ggml/src/ggml-metal/ggml-metal-ops.cpp",

                // --- Whisper ---
                "vendor/src/whisper.cpp",

                // --- CoreML encoder (ANE acceleration) ---
                "vendor/src/coreml/whisper-compat.m",
                "vendor/src/coreml/whisper-encoder.mm",
                "vendor/src/coreml/whisper-encoder-impl.m",
                "vendor/src/coreml/whisper-decoder-impl.m",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Include paths for internal headers
                .headerSearchPath("vendor/include"),
                .headerSearchPath("vendor/ggml/include"),
                .headerSearchPath("vendor/ggml/src"),
                .headerSearchPath("vendor/ggml/src/ggml-cpu"),
                .headerSearchPath("vendor/ggml/src/ggml-metal"),
                .headerSearchPath("vendor/src"),

                // Feature flags
                .define("GGML_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_METAL"),
                .define("WHISPER_USE_COREML"),
                .define("WHISPER_COREML_ALLOW_FALLBACK"),
                .define("WHISPER_VERSION", to: "\"1.8.3\""),
                .define("GGML_VERSION", to: "\"0.0.0\""),
                .define("GGML_COMMIT", to: "\"unknown\""),
                .define("_DARWIN_C_SOURCE"),
            ],
            cxxSettings: [
                .headerSearchPath("vendor/include"),
                .headerSearchPath("vendor/ggml/include"),
                .headerSearchPath("vendor/ggml/src"),
                .headerSearchPath("vendor/ggml/src/ggml-cpu"),
                .headerSearchPath("vendor/ggml/src/ggml-metal"),
                .headerSearchPath("vendor/src"),

                .define("GGML_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_METAL"),
                .define("WHISPER_USE_COREML"),
                .define("WHISPER_COREML_ALLOW_FALLBACK"),
                .define("WHISPER_VERSION", to: "\"1.8.3\""),
                .define("GGML_VERSION", to: "\"0.0.0\""),
                .define("GGML_COMMIT", to: "\"unknown\""),
                .define("_DARWIN_C_SOURCE"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ],
    cxxLanguageStandard: CXXLanguageStandard.cxx17
)
