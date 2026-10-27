// swift-tools-version: 6.0
// MedH5Render: Metal rendering for the viewer — slice (MPR) views with image,
// label, probability and vector overlays, volume ray casting, meshes and
// surface extraction. Depends only on MedH5Core; shaders are compiled at run
// time from source embedded in the module, so no Metal toolchain is needed to
// build.
//
// `render-snapshot` is a small command-line tool that renders a synthetic
// phantom through every view type and writes PNGs (and, with `bench`,
// measures upload and frame times), so the output can be looked at.
import PackageDescription

let package = Package(
    name: "MedH5Render",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MedH5Render", targets: ["MedH5Render"]),
        .executable(name: "render-snapshot", targets: ["RenderSnapshot"]),
    ],
    dependencies: [
        .package(path: "../MedH5Core"),
    ],
    targets: [
        .target(name: "MedH5Render", dependencies: ["MedH5Core"]),
        .executableTarget(
            name: "RenderSnapshot",
            dependencies: ["MedH5Render", "MedH5Core"],
            path: "Sources/render-snapshot"
        ),
        .testTarget(name: "MedH5RenderTests", dependencies: ["MedH5Render", "MedH5Core"]),
    ],
    swiftLanguageModes: [.v5]
)
