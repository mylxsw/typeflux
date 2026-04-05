// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typeflux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Typeflux", targets: ["Typeflux"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Typeflux",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Typeflux",
            exclude: [
                "Resources/Info.plist",
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        .testTarget(
            name: "TypefluxTests",
            dependencies: ["Typeflux"],
            path: "Tests/TypefluxTests",
        ),
    ],
)
