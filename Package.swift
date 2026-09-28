// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Janus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Janus", targets: ["Janus"]),
        .executable(name: "JanusLauncher", targets: ["JanusLauncher"]),
        .library(name: "JanusCore", targets: ["JanusCore"])
    ],
    targets: [
        .target(name: "JanusCore"),
        .executableTarget(name: "Janus", dependencies: ["JanusCore"]),
        // Copied into every Claude desktop launcher Janus makes.
        .executableTarget(name: "JanusLauncher", dependencies: ["JanusCore"]),
        .testTarget(name: "JanusCoreTests", dependencies: ["JanusCore"])
    ]
)
