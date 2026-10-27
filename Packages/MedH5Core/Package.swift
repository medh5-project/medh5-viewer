// swift-tools-version: 6.0
// MedH5Core: the types every other package shares — scalar types, grid
// geometry (medh5 spec §3), volumes in memory and anatomical orientation.
// No dependencies beyond the SDK, so it builds and tests on its own.
import PackageDescription

let package = Package(
    name: "MedH5Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MedH5Core", targets: ["MedH5Core"]),
    ],
    targets: [
        .target(name: "MedH5Core"),
        .testTarget(name: "MedH5CoreTests", dependencies: ["MedH5Core"]),
    ],
    swiftLanguageModes: [.v5]
)
