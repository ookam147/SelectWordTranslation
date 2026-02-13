// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SelectWordTranslation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SelectWordTranslation",
            targets: ["SelectWordTranslation"]
        )
    ],
    dependencies: [
        // 不再需要 MLX 依赖！
    ],
    targets: [
        .executableTarget(
            name: "SelectWordTranslation",
            dependencies: [],
            path: "Sources"
        )
    ]
)
