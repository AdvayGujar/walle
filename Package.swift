// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "walle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "walle", targets: ["walle"]),
        .executable(name: "walle-picker", targets: ["walle-picker"]),
        .executable(name: "walle-upscaler", targets: ["walle-upscaler"]),
        .library(name: "WalleCore", targets: ["WalleCore"]),
    ],
    targets: [
        .target(name: "WalleCore"),
        .target(name: "WalleKit", dependencies: ["WalleCore"]),
        .target(name: "WalleUpscalerCore", dependencies: ["WalleCore"]),
        .executableTarget(name: "walle", dependencies: ["WalleCore"]),
        .executableTarget(name: "walle-picker", dependencies: ["WalleCore", "WalleKit"]),
        .executableTarget(name: "walle-upscaler", dependencies: ["WalleUpscalerCore", "WalleCore"]),
        .testTarget(name: "WalleCoreTests", dependencies: ["WalleCore"]),
        .testTarget(name: "WalleUpscalerCoreTests",
                    dependencies: ["WalleUpscalerCore", "WalleCore"]),
    ]
)
