// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Vesper", platforms: [.iOS("27.0")],
    products: [.library(name: "Vesper", targets: ["Vesper"])],
    dependencies: [
        .package(path: "Core"),
        .package(path: "Packages/UsenetEngine"),
        .package(path: "Packages/DownloadEngine"),
        .package(path: "Packages/PAR2Kit"),
        .package(path: "Packages/Unrar"),
        .package(path: "Dependencies/AetherEngine"),
    ],
    targets: [
        .target(
            name: "Vesper",
            dependencies: [
                .product(name: "VesperCore", package: "Core"),
                .product(name: "UsenetEngine", package: "UsenetEngine"),
                .product(name: "DownloadEngine", package: "DownloadEngine"),
                .product(name: "PAR2Kit", package: "PAR2Kit"),
                .product(name: "Unrar", package: "Unrar"),
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            path: "Vesper",
            exclude: [
                "Info.plist", "PrivacyInfo.xcprivacy", "Assets.xcassets", "Resources", "VesperIcon.icon",
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")])
    ],
    swiftLanguageModes: [.v5]
)
