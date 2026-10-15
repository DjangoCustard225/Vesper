// swift-tools-version: 5.9
import PackageDescription

// The generated framework keeps mpv's FFmpeg symbols private to its own ABI.
let package = Package(
    name: "MPVKit", platforms: [.iOS("27.0")],
    products: [.library(name: "MPVKit", targets: ["MPVKit"])],
    targets: [
        .target(name: "MPVKit", dependencies: ["Libmpv"], path: "Sources"),
        .binaryTarget(name: "Libmpv", path: "MPVEngine.xcframework")
    ]
)
