<p align="center"><img src="Resources/AppIcon.png" width="128" alt="medh5 Viewer icon"></p>

# medh5 Viewer

**A native macOS viewer and editor for [medh5](https://github.com/medh5-project/medh5)
files — one medical-imaging subject, at every timepoint, with all of its ground
truth.**

medh5 Viewer opens a `.medh5` sample and shows everything in it: every
timepoint and image, segmentations in all five voxel encodings, boxes,
keypoints, contours, polylines and meshes, classifications, registrations
between visits, provenance, quality, integrity and — from format 1.1 — the
clinical history around the images. It edits them too: paint and refine
segmentations, draw geometric annotations, curate the sample's document and
label set, import and export NIfTI, and save through the medh5 engine's
copy-on-write amendment, validated on every save.

It is built with AppKit, SwiftUI and Metal, and reads and writes files through
the medh5 engine itself (Rust, `medh5` 2.2.3) — so it writes exactly the bytes
the Python package and the `medh5` command line write.

## Features

- **Multi-planar viewing on the GPU** — axial, coronal and sagittal views in
  true anatomical planes or along the acquisition axes, with a shared
  crosshair, window/level presets, colormaps, thick-slab MIP, and images on
  different grids placed by their geometry.
- **3-D** — volume ray casting (MIP, DVR with presets, isosurfaces),
  segmentation surfaces and mesh annotations in one depth-correct scene.
- **Every annotation kind** — `labelmap`, `layers`, `bitmask`, `instances`,
  `probmap` and `mask`; `boxes`, `obb`, `keypoints`, `points`, `contours`,
  `polylines` (format 1.2) and `mesh`; `classification`. Coverage — what an
  annotation *can express* versus what was *looked for* — is shown, and kept
  through every edit.
- **Longitudinal** — timepoints side by side, linked through the
  registration stored in the file; follow-up overlaid on baseline through an
  affine or a displacement field.
- **Segmentation editing** — brush and eraser in millimetres, 2-D/3-D fill
  and region growing, threshold, morphology, hole filling, island removal,
  interpolation between slices, logical operations, unlimited undo.
- **Curation** — the sample document, label set, quality and provenance;
  validation at every level with medh5's diagnostic codes; digest and
  `content_id` verification.
- **Clinical history** (format 1.1) — events on the subject clock with when
  each happened and when it became known, and what was known at any cutoff.
- **Interoperability** — NIfTI import and export through the engine's
  converter; `.medh5c` collections.

## Install

Download the disk image from the [latest release](../../releases/latest),
open it and drag **medh5 Viewer** to Applications. Requires a Mac with Apple
silicon and macOS 14 or later. See [Installing](docs/INSTALL.md).

No data at hand? **Help › Open Demo Sample** writes a synthetic two-visit
sample with every kind of annotation and opens it.

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Installing](docs/INSTALL.md) · [Building from source](docs/BUILDING.md)
- [Architecture](docs/ARCHITECTURE.md) · [App design](docs/APP_DESIGN.md) ·
  [The engine bridge](docs/BRIDGE.md)
- [medh5 documentation](https://medh5.readthedocs.io/) — the format, its
  specification and the Python package

## Build

```bash
scripts/build-bridge.sh    # the medh5 engine (Rust) as a static library
scripts/build-app.sh       # → build/medh5 Viewer.app
scripts/test.sh            # every test suite
scripts/package-dmg.sh     # → dist/*.dmg
```

Requires Xcode 16+, Rust and CMake. Details in [BUILDING.md](docs/BUILDING.md).

## License

[MIT](LICENSE). The medh5 engine is MIT-licensed; HDF5, C-Blosc2, LZ4,
Zstandard and zlib, which it links statically, carry their own licenses (see
the medh5 project's `THIRD_PARTY_NOTICES`).
