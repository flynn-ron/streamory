// swift-tools-version: 6.0
import PackageDescription

// Host-runnable tests for the Photos-independent session logic.
let package = Package(
    name: "StreamoryCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Streamory", targets: ["Streamory"])],
    targets: [
        .target(name: "Streamory", path: "Streamory/Core"),
        .testTarget(name: "StreamoryTests", dependencies: ["Streamory"], path: "StreamoryTests")
    ]
)
