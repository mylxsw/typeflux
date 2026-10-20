// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The focused runner supplies reviewed source closures. The normal package and
// explicit full validation retain every test file. Never change production targets.
let testDirectory = Context.packageDirectory + "/Tests/TypefluxTests"
let allTestFiles = try FileManager.default.contentsOfDirectory(atPath: testDirectory).filter { $0.hasSuffix(".swift") }
let focusedTestFiles: [String]? = try Context.environment["TYPEFLUX_TEST_FILES"].map { value in
    let files = try JSONDecoder().decode([String].self, from: Data(value.utf8))
    guard !files.isEmpty, Set(files).isSubset(of: Set(allTestFiles)) else {
        fatalError("Invalid focused test-source selection")
    }
    return files.sorted()
}

let package = Package(
    name: "Typeflux",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TypefluxKit", targets: ["Typeflux"]),
        .library(name: "TypefluxMediaWorkerKit", targets: ["TypefluxMediaRuntime"]),
        .executable(name: "TypefluxMediaHelper", targets: ["TypefluxMediaHelper"]),
        .library(name: "TypefluxInferenceWorkerKit", targets: ["TypefluxInferenceRuntime"]),
        .executable(name: "Typeflux", targets: ["TypefluxCLI"]),
        .executable(name: "TypefluxInferenceHelper", targets: ["TypefluxInferenceHelper"])
    ],
    dependencies: [
        .package(path: "Packages/TypefluxChat"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.26.0"),
        .package(url: "https://github.com/doggy8088/opencc-swift.git", branch: "main"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1")
    ],
    targets: [
        .target(name: "TypefluxMediaProtocol"),
        .target(name: "TypefluxMediaRuntime", dependencies: ["TypefluxMediaProtocol"]),
        .executableTarget(name: "TypefluxMediaHelper", dependencies: ["TypefluxMediaRuntime"]),
        .target(name: "TypefluxInferenceProtocol"),
        .target(name: "TypefluxInferenceRuntime", dependencies: [
            "TypefluxInferenceProtocol", .product(name: "WhisperKit", package: "WhisperKit")
        ]),
        .executableTarget(name: "TypefluxInferenceHelper", dependencies: ["TypefluxInferenceRuntime"]),
        .target(
            name: "TypefluxAudioSafety",
            path: "Sources/TypefluxAudioSafety",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Typeflux",
            dependencies: [
                "TypefluxAudioSafety",
                "TypefluxInferenceProtocol",
                "TypefluxMediaProtocol",
                .product(name: "TypefluxChat", package: "TypefluxChat"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "OpenCCSwift", package: "opencc-swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Typeflux",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources"),
                // Gallery examples are workflow folders: copied as they are, not flattened.
                .copy("WorkflowGallery")
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
            name: focusedTestFiles == nil ? "TypefluxTests" : "TypefluxFocusedTests",
            dependencies: ["Typeflux", "TypefluxInferenceRuntime", "TypefluxMediaRuntime"],
            path: "Tests/TypefluxTests",
            exclude: focusedTestFiles.map { selected in allTestFiles.filter { !selected.contains($0) } } ?? [],
            sources: focusedTestFiles
        )
    ]
)
