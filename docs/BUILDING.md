# Building from source

## Requirements

- A Mac with Apple silicon, macOS 14 or later
- Xcode 16 or later (Swift 6) — the command line tools are enough to build,
  Xcode itself to work in the IDE
- Rust (stable, via [rustup](https://rustup.rs)) — the medh5 engine is Rust
- CMake (`brew install cmake`) — the engine builds HDF5 from source

## Build

```bash
scripts/build-bridge.sh   # the medh5 engine as a static library (once; ~5 min)
scripts/build-app.sh      # → build/medh5 Viewer.app (the script prints the path)
```

Build products go to `build/` — unless the repository is in a folder that
iCloud Drive (or another file provider) syncs, such as `~/Documents` with
"Desktop & Documents" on. There every build product would be uploaded, and
the provider's extended attributes make `codesign` refuse bundles, so the
scripts build in `~/Library/Caches/medh5-viewer/<repository>-<hash>/`
instead. Set `MEDH5_VIEWER_BUILD_ROOT` to choose the place yourself.

`scripts/build-bridge.sh` compiles the Rust crate in `bridge/` (which pulls
the `medh5` engine 2.2.3 from crates.io and the patched HDF5 the medh5
project ships) and wraps it as
`Packages/MedH5Kit/Frameworks/MedH5Bridge.xcframework`. Rerun it after
changing anything in `bridge/`; `scripts/build-app.sh --rebuild-bridge` does
both.

## Test

```bash
scripts/test.sh            # cargo test, then swift test for every package and the app
scripts/test.sh --skip-bridge
```

Each package also tests on its own:

```bash
swift test --package-path Packages/MedH5Core
swift test --package-path Packages/MedH5Render    # needs a Metal device
swift test --package-path Packages/MedH5Editing
swift test --package-path Packages/MedH5Kit       # needs the bridge
(cd bridge && cargo test --release)
```

(In an iCloud-synced checkout, give `swift test` a `--scratch-path` outside
the synced folder, as `scripts/test.sh` does, or code signing of the test
bundle fails.)

## Package

```bash
scripts/package-dmg.sh --build   # → build/dist/medh5-Viewer-<version>-macOS-arm64.{dmg,zip,sha256}
```

By default the app is signed ad hoc. To sign for distribution, set
`CODESIGN_IDENTITY` to a "Developer ID Application" identity; to notarize,
also set `NOTARY_PROFILE` to a profile stored with
`xcrun notarytool store-credentials`.

## Working in Xcode

Open `Package.swift` in Xcode (after `scripts/build-bridge.sh`). The local
packages appear under *Package Dependencies* and can be edited in place.
Running the `medh5-viewer` scheme from Xcode launches the executable without
an app bundle, so document types are not registered and Finder cannot open
files with it; use `scripts/build-app.sh` for the real thing.

## Layout

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and
[BRIDGE.md](BRIDGE.md) for the C interface to the engine.
