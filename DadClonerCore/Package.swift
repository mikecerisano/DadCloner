// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DadClonerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DadClonerCore", targets: ["DadClonerCore"])
    ],
    targets: [
        .target(name: "DadClonerCore"),
        .testTarget(name: "DadClonerCoreTests", dependencies: ["DadClonerCore"])
    ]
)
