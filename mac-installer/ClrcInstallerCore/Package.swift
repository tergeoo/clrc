// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClrcInstallerCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClrcInstallerCore", targets: ["ClrcInstallerCore"])],
    targets: [
        .target(name: "ClrcInstallerCore"),
        .testTarget(name: "ClrcInstallerCoreTests", dependencies: ["ClrcInstallerCore"]),
    ]
)
