// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PathoScopeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PathoScopeCore", targets: ["PathoScopeCore"]),
        .executable(name: "PathoScopeApp", targets: ["PathoScopeApp"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "PathoScopeCore", dependencies: ["CZlib"]),
        .executableTarget(name: "PathoScopeApp", dependencies: ["PathoScopeCore"]),
        .testTarget(name: "PathoScopeCoreTests", dependencies: ["PathoScopeCore"])
    ]
)
