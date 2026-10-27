// swift-tools-version: 6.0
// MedH5Kit: the medh5 format for Swift — reading, writing, validating and
// converting samples through the medh5 engine (Rust, crates.io `medh5`
// 2.2.3), which the bridge in ../../bridge exports as a C library.
//
// scripts/build-bridge.sh builds that library and places it here as
// Frameworks/MedH5Bridge.xcframework; build it before building this package.
import PackageDescription

let package = Package(
    name: "MedH5Kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MedH5Kit", targets: ["MedH5Kit"]),
    ],
    dependencies: [
        .package(path: "../MedH5Core"),
    ],
    targets: [
        .binaryTarget(name: "MedH5Bridge", path: "Frameworks/MedH5Bridge.xcframework"),
        .target(
            name: "MedH5Kit",
            dependencies: ["MedH5Core", "MedH5Bridge"],
            // What the static library needs from the system, exactly as
            // `cargo rustc --release --target aarch64-apple-darwin --lib
            // --crate-type staticlib -- --print native-static-libs` lists it:
            // `-liconv -lSystem -lc -lm`.
            linkerSettings: [
                .linkedLibrary("iconv"),
                .linkedLibrary("System"),
                .linkedLibrary("c"),
                .linkedLibrary("m"),
            ]
        ),
        .testTarget(name: "MedH5KitTests", dependencies: ["MedH5Kit"]),
    ],
    swiftLanguageModes: [.v5]
)
