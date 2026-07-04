// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClrcCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ClrcCore", targets: ["ClrcCore"])
    ],
    targets: [
        .target(name: "ClrcCore"),
        .testTarget(name: "ClrcCoreTests", dependencies: ["ClrcCore"]),
    ]
)
