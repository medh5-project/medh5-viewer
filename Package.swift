// swift-tools-version: 6.0
// medh5 Viewer — a native macOS viewer and editor for medh5 files.
//
// The app is this package; the libraries it is built from are local packages
// under Packages/, each building and testing on its own:
//   MedH5Core     shared types: scalar types, grid geometry, volumes
//   MedH5Kit      the medh5 engine (Rust) through a C bridge (bridge/)
//   MedH5Render   Metal rendering
//   MedH5Editing  the editing model
// scripts/build-bridge.sh must have run once (it builds the engine); then
// `swift build`, or scripts/build-app.sh for the .app bundle.
import PackageDescription

let package = Package(
    name: "MedH5Viewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "medh5-viewer", targets: ["MedH5ViewerApp"]),
        .library(name: "MedH5ViewerUI", targets: ["MedH5ViewerUI"]),
    ],
    dependencies: [
        .package(path: "Packages/MedH5Core"),
        .package(path: "Packages/MedH5Kit"),
        .package(path: "Packages/MedH5Render"),
        .package(path: "Packages/MedH5Editing"),
    ],
    targets: [
        .target(
            name: "MedH5ViewerUI",
            dependencies: [
                .product(name: "MedH5Core", package: "MedH5Core"),
                .product(name: "MedH5Kit", package: "MedH5Kit"),
                .product(name: "MedH5Render", package: "MedH5Render"),
                .product(name: "MedH5Editing", package: "MedH5Editing"),
            ],
            path: "Sources/MedH5ViewerUI"
        ),
        .executableTarget(
            name: "MedH5ViewerApp",
            dependencies: ["MedH5ViewerUI"],
            path: "Sources/MedH5ViewerApp"
        ),
        .testTarget(
            name: "MedH5ViewerTests",
            dependencies: ["MedH5ViewerUI"],
            path: "Tests/MedH5ViewerTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
