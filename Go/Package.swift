// swift-tools-version: 6.4
import Foundation
import PackageDescription

struct BuildConfiguration: Decodable { let excludedSources: [String] }
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let configuration = try JSONDecoder().decode(
    BuildConfiguration.self,
    from: Data(contentsOf: directory.appendingPathComponent("Build.json")))

let package = Package(
    name: "VesperGo", platforms: [.iOS("27.0")],
    products: [.library(name: "VesperGo", targets: ["VesperGo"])],
    dependencies: [.package(path: "Core")],
    targets: [
        .target(
            name: "VesperGo", dependencies: [.product(name: "VesperCore", package: "Core")],
            path: "Sources",
            exclude: configuration.excludedSources + [
                "Info.plist", "PrivacyInfo.xcprivacy", "Assets.xcassets", "Resources", "VesperIcon.icon",
            ],
            swiftSettings: [.define("VESPER_GO"), .enableUpcomingFeature("StrictConcurrency")])
    ],
    swiftLanguageModes: [.v5]
)
