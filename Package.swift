// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typeflux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Typeflux", targets: ["Typeflux"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Typeflux",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
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
        .testTarget(
            name: "TypefluxTests",
            dependencies: ["Typeflux"],
            path: "Tests/TypefluxTests"
        )
    ]
)
