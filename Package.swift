// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Vesper", platforms: [.iOS("27.0")],
    products: [.library(name: "Vesper", targets: ["Vesper"])],
    dependencies: [
        .package(path: "Core"),
        .package(path: "Dependencies/AetherEngine"),
    ],
    targets: [
        .target(
            name: "Vesper",
            dependencies: [
                .product(name: "VesperCore", package: "Core"),
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
