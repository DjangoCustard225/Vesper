// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PAR2Kit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PAR2Kit", targets: ["PAR2Kit"]),
    ],
    targets: [
        // Clean-room PAR2 (parse / verify / Reed-Solomon repair). Permissively licensed, no GPL.
        .target(name: "PAR2Kit"),
        .testTarget(
            name: "PAR2KitTests",
            dependencies: ["PAR2Kit"]
        ),
    ]
)
