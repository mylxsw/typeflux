// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypefluxChat",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "TypefluxChat", targets: ["TypefluxChat"])],
    targets: [
        .target(name: "TypefluxChat"),
        .testTarget(name: "TypefluxChatTests", dependencies: ["TypefluxChat"])
    ]
)
