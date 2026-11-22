// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Vesper", platforms: [.iOS("27.0")],
    products: [
        .library(name: "Vesper", targets: ["Vesper"]),
        .library(name: "VesperWidgets", targets: ["VesperWidgets"]),
    ],
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
                "Vesper.entitlements",
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        .target(
            name: "VesperWidgets", path: "VesperWidgets",
            exclude: ["Info.plist", "VesperWidgets.entitlements"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
            // Extensions start in Foundation's _NSExtensionMain, which then runs the @main code in
            // `_main`. Nothing else references it, so without this the linker drops the widgets.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_main"])]),
    ],
    swiftLanguageModes: [.v5]
)
