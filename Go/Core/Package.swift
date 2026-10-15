// swift-tools-version: 6.4
import PackageDescription

// Compile the shared core for the external-player edition, without player-only APIs.
let package = Package(
    name: "VesperCore", platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "VesperCore", targets: ["VesperCore"])],
    targets: [
        .target(
            name: "VesperCore", path: "Sources/VesperCore",
            exclude: ["PlaybackTimeline.swift", "PlaybackProgressReporter.swift"],
            swiftSettings: [.define("VESPER_GO"), .enableUpcomingFeature("StrictConcurrency")]),
        .testTarget(name: "VesperGoCoreTests", dependencies: ["VesperCore"]),
    ], swiftLanguageModes: [.v5])
