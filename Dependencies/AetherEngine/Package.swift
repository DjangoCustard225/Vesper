// swift-tools-version: 6.0
import PackageDescription
// AetherEngine 7.36.0; local pinned dependencies for Vesper. SMB, CLI and examples are omitted.
let package = Package(name: "AetherEngine", platforms: [.iOS(.v18)],
    products: [.library(name: "AetherEngine", targets: ["AetherEngine"])],
    dependencies: [.package(path: "../FFmpegBuild"), .package(path: "../LibDovi"),
                   .package(path: "../LibTrueHD"), .package(path: "../LibDTSX")],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
                .product(name: "TrueHD", package: "LibTrueHD"),
                .product(name: "DTSX", package: "LibDTSX"),
            ],
            // Silent E-AC-3 Atmos that `AtmosOutputActivator` loops beside an APAC track on tvOS.
            resources: [.copy("Resources/silent-atmos.mp4")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ])
