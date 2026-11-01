// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "UsenetEngine", platforms: [.iOS(.v26), .macOS(.v14)],
    products: [.library(name: "UsenetEngine", targets: ["UsenetEngine"])],
    targets: [
        .target(
            name: "CUsenetCrypto",
            linkerSettings: [.linkedLibrary(":libcrypto.so.3", .when(platforms: [.linux]))]),
        .target(
            name: "UsenetEngine", dependencies: ["CUsenetCrypto"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        .testTarget(
            name: "UsenetEngineTests", dependencies: ["UsenetEngine"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5])
