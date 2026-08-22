// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typeflux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TypefluxKit", targets: ["Typeflux"]),
        .executable(name: "Typeflux", targets: ["TypefluxCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.26.0"),
        .package(url: "https://github.com/doggy8088/opencc-swift.git", branch: "main")
    ],
    targets: [
        .target(
            name: "TypefluxAudioSafety",
            path: "Sources/TypefluxAudioSafety",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Typeflux",
            dependencies: [
                "TypefluxAudioSafety",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "OpenCCSwift", package: "opencc-swift")
            ],
            path: "Sources/Typeflux",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TypefluxCLI",
            dependencies: [
                "Typeflux"
            ],
            path: "Sources/TypefluxCLI"
        ),
        .testTarget(
            name: "TypefluxTests",
            dependencies: ["Typeflux"],
            path: "Tests/TypefluxTests"
        )
    ]
)
