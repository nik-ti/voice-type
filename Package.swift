// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers")
            ],
            path: "Sources/VoiceType",
            resources: [
                .process("Resources/Assets.xcassets")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    cxxLanguageStandard: .gnucxx17
)
