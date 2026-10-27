// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YTTranscriber",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YTTranscriber", targets: ["YTTranscriber"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "YTTranscriber",
            dependencies: [
                "TranscriberCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
