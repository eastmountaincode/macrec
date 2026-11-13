// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacRecCore", targets: ["MacRecCore"]),
        .executable(name: "macrec", targets: ["macrec"]),
        .executable(name: "macrec-whisper-prefetch", targets: ["macrec-whisper-prefetch"]),
        .executable(name: "MacRecApp", targets: ["MacRecApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", branch: "main"),
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", from: "0.0.60"),
    ],
    targets: [
        .target(
            name: "MacRecCore",
            path: "Sources/MacRecCore"
        ),
        .executableTarget(
            name: "macrec",
            dependencies: ["MacRecCore"],
            path: "Sources/macrec"
        ),
        .executableTarget(
            name: "MacRecApp",
            dependencies: [
                "MacRecCore",
                .product(name: "MoonshineVoice", package: "moonshine-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/MacRecApp"
        ),
        .executableTarget(
            name: "macrec-whisper-prefetch",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/macrec-whisper-prefetch"
        ),
        .testTarget(
            name: "MacRecCoreTests",
            dependencies: ["MacRecCore", "MacRecApp"],
            path: "Tests/MacRecCoreTests"
        ),
    ]
)
