# Changelog

All notable changes to medh5 Viewer are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Saving a document, or building its sampling index, while the document was
  still being verified could crash the viewer: both copy the file's datasets,
  and HDF5 wrote past the end of a buffer when it copied one the verification
  held open. The viewer now links HDF5 with the medh5 engine's fix
  ([medh5-project/medh5#116](https://github.com/medh5-project/medh5/pull/116)).

## [1.0.0] — 2026-10-27

The first release: a native macOS viewer and editor for medh5 files, built on
the medh5 engine 2.2.3 (format versions 1.0, 1.1 and 1.2). Requires macOS 14
or later on Apple silicon.

### Viewing

- Documents for samples (`.medh5`) and collections (`.medh5c`), opened
  through the engine and verified on open; read-only, with the reason shown,
  for a projection of a later format minor, a file whose digests fail, and a
  collection member.
- Layouts: a single view, 1 × 3, 2 × 2 with 3-D, 3-D only, and Compare
  Timepoints, linked through the stored registration.
- Slice views on Metal in anatomical or acquisition-aligned planes,
  radiological or neurological, with orientation letters, a shared
  crosshair, window/level presets and Auto, 21 colormaps, nearest, linear and
  cubic interpolation, and thick-slab MIP, MinIP and average.
- Images on other grids and other frames placed through their geometry and
  the stored transforms (matrices and displacement fields); never drawn
  when no transform connects the frames.
- Every annotation kind as a layer: voxel encodings with per-class
  visibility, coverage and the ignore region; probability ramps; boxes,
  oriented boxes, points, keypoints, contours, polylines and meshes;
  classification badges. Time series, channels and RGB images.
- 3-D: direct volume rendering with CT and MR presets, MIP, MinIP, average
  and isosurface; segmentation surfaces ray cast or as smoothed meshes; mesh
  annotations; a clipping box.
- Volumes are read in the background under a memory budget.

### Editing

- Segment editor: new segmentations, classes from the label set or new ones,
  examined and can-express-only coverage, class locks; brush and eraser in
  millimetres (disc or sphere, paint policies, intensity range), fill,
  threshold, region growing, morphology, fill holes, keep the largest
  component, remove islands, interpolate between slices, logical operations.
  Each stroke and operation is one undo step, within a memory budget.
- Geometric annotations: boxes, points and keypoints, polylines and contours,
  with an item list, Cut, Copy, Paste and Delete.
- Measurements: rulers, angles and ROIs with statistics, exported as CSV or
  saved as a polyline annotation.
- The sample's document and label set, edited in their own windows and
  checked by the engine before they are accepted.
- Removal of images, annotations and transforms, refused while something
  in the sample still needs them.
- Saving amends the file copy-on-write through the engine, in the
  background; Save As, Revert to Saved; no autosave.

### Records and checks

- Validation at every level, with the engine's codes, filtering, copying and
  JSON export; integrity verification of every digest and the `content_id`.
- The clinical history (format 1.1) on the subject's clock, with the
  engine's strict prospective selection at any cutoff.

### Files

- NIfTI: new samples, image and segmentation import, and export, through
  the engine's converter.
- Sampling indexes, recompression with a codec profile, and new collections
  from samples.

### The app

- A welcome window with a synthetic demo sample holding every annotation
  kind.
- The user guide in a Help window, a Keyboard Shortcuts window built from
  the menus, and the acknowledgements of every linked package.
- Settings for the default layout and planes, rendering, the memory budget,
  the engine's threads and editing.
- A snapshot mode (`medh5-viewer --snapshot`) that renders a document, a
  panel or a window to PNG without user interaction, for QA.
- Build, test and packaging scripts: the engine bridge as an XCFramework,
  every test suite, a signed app bundle (ad hoc, or Developer ID with
  notarization), a disk image, a zip and their checksums.

[1.0.0]: https://github.com/medh5-project/medh5-viewer/releases/tag/v1.0.0
