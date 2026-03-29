// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typeflux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Typeflux", targets: ["VoiceInput"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources/VoiceInput",
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
            name: "VoiceInputTests",
            dependencies: ["VoiceInput"],
            path: "Tests/VoiceInputTests"
        )
    ]
)
