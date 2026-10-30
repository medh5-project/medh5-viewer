# Architecture

medh5 Viewer is a native macOS application (AppKit + SwiftUI, Metal) for
viewing and editing [medh5](https://github.com/medh5-project/medh5) files. It
targets medh5 **2.2.4** — format versions 1.0, 1.1 and 1.2 — on Apple silicon,
macOS 14 or later.

## One engine, a fourth frontend

medh5 is implemented once, in Rust (the `medh5` crate); the Python package and
the `medh5` command line are frontends over that engine, and all of them read
and write the same bytes. The viewer is another frontend: it links the engine
through a small C bridge (`bridge/`, a Rust `staticlib`) rather than
re-implementing the format in Swift. That gives the viewer, for free and
exactly as the engine does them:

- every voxel encoding (`labelmap`, `layers`, `bitmask`, `instances`,
  `probmap`, `mask`), every geometric kind (boxes, oriented boxes, keypoints,
  points, contours, polylines, meshes) and classification;
- Blosc2/Zstandard/gzip decompression, chunked region reads;
- copy-on-write amendment with atomic replacement, digests and `content_id`;
- the validator (§15) with its diagnostic codes, digest verification;
- transforms (affine, displacement, B-spline, composite) and their resolution
  between frames;
- the clinical profile (1.1), polylines (1.2), projections of later minors;
- NIfTI import and export, recompression, collections.

The bridge builds against the engine from crates.io (`medh5 = "=2.2.4"`) with
the same patched HDF5 the medh5 workspace ships (`[patch.crates-io]
hdf5-metno-src` from the v2.2.4 tag), so a crafted file cannot hang the
viewer's HDF5 any more than it can the medh5 wheels.

```
┌─────────────────────────────── medh5 Viewer.app ───────────────────────────────┐
│ MedH5ViewerApp (main)                                                          │
│ MedH5ViewerUI   AppKit document architecture, SwiftUI views, tools, menus      │
│   ├── MedH5Render   Metal: slice/MPR, volume ray casting, meshes, overlays     │
│   ├── MedH5Editing  segmentation editing, undo diffs, measurements             │
│   ├── MedH5Kit      Swift API over the C bridge (Sample, SampleWriter, …)      │
│   │     └── MedH5Bridge.xcframework  ← bridge/ (Rust staticlib) ← medh5 2.2.4  │
│   └── MedH5Core     ScalarType, GridGeometry, VolumeData, ImageVolume, …       │
└────────────────────────────────────────────────────────────────────────────────┘
```

## Repository layout

| Path | What |
|---|---|
| `Package.swift` | the app package: `MedH5ViewerUI` (library), `MedH5ViewerApp` (executable), tests |
| `Packages/MedH5Core` | shared types; no dependencies |
| `Packages/MedH5Kit` | the format layer; links `Frameworks/MedH5Bridge.xcframework` |
| `Packages/MedH5Render` | Metal rendering; depends on Core only |
| `Packages/MedH5Editing` | editing model; depends on Core only |
| `bridge/` | the Rust crate `medh5-bridge` and its C header `include/medh5_bridge.h` |
| `scripts/` | build, test, package and release scripts |
| `Resources/` | Info.plist template, icon, entitlements |
| `docs/` | user guide, this file, the bridge reference, building |

Each package under `Packages/` builds and tests on its own (`swift test` in
its directory), so the rendering and editing code can be developed and
tested without building the engine.

## Conventions every package follows

### Geometry (spec §3)

`MedH5Core.GridGeometry` is a medh5 grid. A spatial index is in **stored
order** (axis 0 slowest) with integers at voxel **centres**; world =
`origin + direction · (spacing ⊙ i)`, `direction` column *c* being spatial
axis *c*. The viewer pads every grid to three spatial axes (`paddedShape`;
a 2-D grid becomes one slice at world `z = 0`).

A spatial volume of padded shape `(n0, n1, n2)` is a 3-D texture of width
`n2`, height `n1`, depth `n0`; the texture coordinate of padded index `k` is
`((k2+0.5)/n2, (k1+0.5)/n1, (k0+0.5)/n0)`. `GridGeometry.worldToTexture` is
the matrix every shader uses to sample a volume at a world point.

**Boxes sit at voxel edges** (§8.1): a box `[lo, hi]` covers indices
`floor(lo+0.5) ..< floor(hi+0.5)`, rounding half up.

### World space and frames

Each viewer window has a **reference frame**: the world coordinates of the
grid of the image shown as the base layer. A layer on another grid of the same
frame (`GridGeometry.sharesFrame`) is placed by its own affine. A layer in
another frame is shown only through a transform the engine resolves
(`m5_transform_resolve`, `x_to = T(x_from)`, spec §10.2): an affine becomes a
matrix in the shader; anything else a displacement field sampled on the
reference grid. Alignment is never assumed (§3.4): a layer with no transform
is not drawn over another frame.

### Orientation

World coordinates are converted to LPS (`CoordinateSystem.toLPS`) to choose
standard planes. Axial, coronal and sagittal views follow the radiological
convention by default (patient's left on screen right); the neurological
convention flips left and right. Views are either **anatomical** (true
axial/coronal/sagittal planes, reformatting an oblique acquisition) or
**aligned** to the base image's index axes (`PlaneAxes.aligned`).

### Values

Images are held raw (`VolumeData` of the stored type); physical value =
`raw × rescale_slope + rescale_intercept` (§4.2), applied in the shaders, so
an `int16` CT stays two bytes per voxel in memory and on the GPU. Types a
texture cannot hold (`int32`, `int64`, `uint32`, `uint64`, `float64`) are read
as `float32` (`ScalarType.gpuCompatible`).

Segmentations are held as **layers**: `uint16` volumes in which classes are
mutually exclusive (spec §7.2). Any voxel encoding is read as layers
(`m5_annotation_layer_plan`), edited as layers and written back as layers,
the engine choosing the stored encoding by measuring overlap unless the
user asks for one. Class `0` is background, `65535` (or the annotation's
`ignore_id`) the ignore region.

**Coverage is never collapsed** (§6.2, §11.3): an annotation's `class_ids`
(what it can express) and `annotated_class_ids` (what was looked for) are
shown separately and preserved through edits; a class the user paints is
added to both; erasing a class leaves it annotated (an examined absence).

### Threading

`MedH5Kit` calls block; the UI calls them from background tasks
(`async` wrappers) and never on the main thread. Bridge handles are
thread-safe. Rendering happens on the main thread through `MTKView` draw
callbacks, with GPU uploads of edited regions only (dirty boxes).

### Saving

A document is saved by **amending** (`m5_writer_amend`): copy-on-write to a
temporary file, then an atomic replace, as the engine does for every
frontend. The viewer closes its read handle before the replace and reopens
afterwards. Objects that are replaced are passed as `without`, so they are
not copied first. A file whose stored digests do not verify cannot be
amended (E701) — the viewer reports it and offers Save As only after the
user repairs it with `medh5 fix`.

## Testing

| Suite | Runs | Needs |
|---|---|---|
| `cargo test` in `bridge/` | the C ABI, every function, through the engine | Rust, CMake |
| `MedH5CoreTests` | geometry, orientation, volumes | — |
| `MedH5KitTests` | reading, writing, amending, validating, NIfTI, the demo sample, the conformance corpus | the bridge |
| `MedH5RenderTests` | off-screen Metal renders checked pixel by pixel; marching cubes | a Metal device |
| `MedH5EditingTests` | brushes, fills, morphology, interpolation, undo | — |
| `MedH5ViewerTests` | view models, document round trips | the bridge |

`scripts/test.sh` runs all of them.
