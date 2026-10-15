// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibTrueHD",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "TrueHD", targets: ["TrueHD"]),
    ],
    targets: [
        .binaryTarget(name: "TrueHD", path: "TrueHD.xcframework"),
    ]
)
