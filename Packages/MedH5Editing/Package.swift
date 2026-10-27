// swift-tools-version: 6.0
// MedH5Editing: the editing model — segmentation layers with undoable voxel
// edits, painting and region tools, morphology and interpolation, geometric
// annotation and measurement models. Pure Swift over MedH5Core volumes.
import PackageDescription

let package = Package(
    name: "MedH5Editing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MedH5Editing", targets: ["MedH5Editing"]),
    ],
    dependencies: [
        .package(path: "../MedH5Core"),
    ],
    targets: [
        .target(name: "MedH5Editing", dependencies: ["MedH5Core"]),
        .testTarget(name: "MedH5EditingTests", dependencies: ["MedH5Editing"]),
    ],
    swiftLanguageModes: [.v5]
)
