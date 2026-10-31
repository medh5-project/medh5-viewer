# Changelog

All notable changes to medh5 Viewer are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## [1.1.0] — 2026-10-31

A minor release that brings the design of macOS 26 and later, built on the
medh5 engine 2.2.4 like 1.0.1. It reads and writes the same format versions
(1.0, 1.1 and 1.2) and still requires macOS 14 or later on Apple silicon.

### Added

- Snapshot mode's `--activate` captures the window as it looks in use, and
  `--widest-panels` at the tightest a user can make it. Toolbar items that do
  not fit are named on standard error.

### Changed

- On macOS 26 and later the app takes the system's new design, with the toolbar
  in capsules. macOS 14 and 15 look as before, and the user guide's screenshots
  show the new design on every system.
- On macOS 26 and later the sidebar goes up to 320 points wide and the
  inspector to 340 (440 and 460 before), and the document window down to 1000
  points wide (900 before): in the new design the viewer runs under both
  panels, and the window has to hold them.
- The Document window goes down to 810 points wide (620 before), where every
  page fits, and the lists of its Timepoints and Quality pages have a fixed
  width.
- From macOS 14.4 snapshot mode captures the window as the window server
  composites it, so materials and vibrant text come out as on screen, with no
  Screen Recording permission and without showing the window. The window's
  chrome is then no sharper than its display, whatever `--scale` asks for.
  `--size` stops at the window's minimum, and a document window can now be
  larger than the display.
- Building takes Xcode 26 or later, whose SDK gives the app the new design.
  `scripts/build-app.sh` and `scripts/test.sh` name that SDK to the linker,
  which Swift 6.4 otherwise leaves out, and CI takes snapshots of the built app
  on macOS 14, 15 and 26.

### Fixed

- On macOS 15 the window's title took the toolbar's width, and the 3-D menu and
  the inspector button went into its overflow in a window of the default size.
- The document window's status bar was cut off at the window's minimum height.
- The Compare bar's timepoint wrapped letter by letter in a narrow viewer.
- An edit made while the 3-D view's surfaces were being extracted could leave
  them showing the segmentation from before the edit.

## [1.0.1] — 2026-10-30

A patch release that fixes a crash, built on the medh5 engine 2.2.4. It reads
and writes the same format versions as 1.0.0 (1.0, 1.1 and 1.2) and still
requires macOS 14 or later on Apple silicon.

### Fixed

- Saving a document while it was still being verified, which starts when it
  opens, could crash the viewer or leave it running with damaged memory. So
  could Build Sampling Index…, Recompress…, New Collection from Samples… with
  that file, and applying an edit in the Document or Label Set window. All of
  them copy the file's datasets, and HDF5 wrote past the end of a buffer when
  it copied one the verification held open. The viewer now builds on medh5
  2.2.4, whose HDF5 has the fix
  ([medh5-project/medh5#116](https://github.com/medh5-project/medh5/pull/116)).
- The sources build with Xcode 26.6 (Swift 6.3), whose type checker gave up on
  a few expressions in 1.0.0.

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

[1.1.0]: https://github.com/medh5-project/medh5-viewer/releases/tag/v1.1.0
[1.0.1]: https://github.com/medh5-project/medh5-viewer/releases/tag/v1.0.1
[1.0.0]: https://github.com/medh5-project/medh5-viewer/releases/tag/v1.0.0
