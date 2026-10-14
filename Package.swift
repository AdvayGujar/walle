// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "walle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "walle", targets: ["walle"]),
        .executable(name: "walle-picker", targets: ["walle-picker"]),
        .library(name: "WalleCore", targets: ["WalleCore"]),
    ],
    targets: [
        .target(name: "WalleCore"),
        .target(name: "WalleKit", dependencies: ["WalleCore"]),
        .executableTarget(name: "walle", dependencies: ["WalleCore"]),
        .executableTarget(name: "walle-picker", dependencies: ["WalleCore", "WalleKit"]),
        .testTarget(name: "WalleCoreTests", dependencies: ["WalleCore"]),
    ]
)
