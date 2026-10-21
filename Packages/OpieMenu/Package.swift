// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpieMenu",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OpieMenu", targets: ["OpieMenu"])],
    targets: [
        .target(name: "OpieMenu"),
        .testTarget(name: "OpieMenuTests", dependencies: ["OpieMenu"])
    ]
)
