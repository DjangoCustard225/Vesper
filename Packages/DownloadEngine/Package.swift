// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DownloadEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DownloadEngine", targets: ["DownloadEngine"]),
    ],
    targets: [
        // Pure Swift (CRC32 is table-based in-package; no system-library dependency).
        .target(name: "DownloadEngine"),
        .testTarget(
            name: "DownloadEngineTests",
            dependencies: ["DownloadEngine"]
        ),
    ]
)
