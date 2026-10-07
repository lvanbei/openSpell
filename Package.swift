// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSpell",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OpenSpell", targets: ["OpenSpell"])
    ],
    dependencies: [
        .package(path: "Packages/OpenSpellCore"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenSpell",
            dependencies: [
                .product(name: "OpenSpellCore", package: "OpenSpellCore"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/OpenSpell",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
