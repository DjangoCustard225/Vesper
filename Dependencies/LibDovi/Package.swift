// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibDovi",
    platforms: [
        .iOS(.v16),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Dovi",
            targets: ["Dovi"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "Dovi",
            path: "Dovi.xcframework"
        ),
    ]
)
