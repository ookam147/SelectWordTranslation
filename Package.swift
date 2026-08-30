// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SelectWordTranslation",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "SelectWordTranslation",
            targets: ["SelectWordTranslation"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SelectWordTranslation",
            dependencies: [],
            path: "Sources/SelectWordTranslation",
            exclude: ["Info.plist"],
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageModes: [.v6]
)
