// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Vesper", platforms: [.iOS("27.0")],
    products: [.library(name: "Vesper", targets: ["Vesper"])],
    dependencies: [.package(path: "Core")],
    targets: [.target(name: "Vesper", dependencies: [.product(name: "VesperCore", package: "Core")],
                      path: "Vesper", exclude: ["Info.plist", "PrivacyInfo.xcprivacy", "Assets.xcassets"])],
    swiftLanguageModes: [.v5]
)
