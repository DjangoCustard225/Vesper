// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "VesperCore", platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "VesperCore", targets: ["VesperCore"])],
    targets: [.target(name: "VesperCore"), .testTarget(name: "VesperCoreTests", dependencies: ["VesperCore"])],
    swiftLanguageModes: [.v5])
