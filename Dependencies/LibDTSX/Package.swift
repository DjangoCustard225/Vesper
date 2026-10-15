// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibDTSX",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "DTSX", targets: ["DTSX"]),
    ],
    targets: [
        .binaryTarget(name: "DTSX", path: "DTSX.xcframework"),
    ]
)
