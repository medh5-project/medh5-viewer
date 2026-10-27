# App design

What the app does and how it behaves — the specification the code in
`Sources/MedH5ViewerUI` implements. Conventions shared with the libraries
(geometry, orientation, values, layers, saving) are in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Principles

- **Native.** AppKit document architecture (`NSDocument`), standard menus,
  windows, tabs, toolbars, undo, Open Recent, Versions-free classic save
  ("Save", "Save As…", "Revert"), SwiftUI for the views, Metal for every
  pixel of image data. Dark appearance by default in viewports (images are
  read on black); the chrome follows the system appearance.
- **Faithful to medh5.** What the file says is shown as the file says it:
  coverage (`class_ids` vs `annotated_class_ids`) is visible, geometry is
  never invented (a layer in another frame is shown only through a
  transform), physical values are labelled with their units, a projection of
  a later format minor is read-only, every save goes through the engine and
  is validated by it.
- **Fast.** Metadata opens instantly; voxels stream in the background with
  progress in the viewport; edits appear within a frame; nothing blocks the
  main thread for more than a few milliseconds.

## Process and documents

- `MedH5ViewerApp` (executable) starts `NSApplication` with an
  `AppDelegate` that builds the main menu in code (no nibs), registers
  defaults, and sets the engine's thread count (Preferences).
- `MedH5Document: NSDocument` (`@objc(MedH5Document)`, type
  `io.github.medh5-project.medh5`). Reading opens the file with
  `SampleFile.open` (metadata only, `canConcurrentlyReadDocuments` true).
  Writing (`write(to:ofType:for:originalContentsURL:)`) amends
  `originalContentsURL` into the URL `NSDocument` provides
  (`SampleWriter.amend(url:outURL:without:)`), applying the pending edits
  (segmentations, geometric annotations, document fields, label set,
  removed objects, transforms), then reopens the saved file. Saving runs
  asynchronously (`canAsynchronouslyWrite`) on a snapshot of the edits,
  with progress in the window. `autosavesInPlace` is false: amending a
  large file continuously is neither cheap nor what a curator expects.
  Undo/redo use the document's `undoManager`; every edit marks the
  document dirty.
- Files the engine can only project (a later 1.x minor) and files whose
  digests fail verification open **read-only** with a banner saying why;
  editing commands are disabled.
- `MedH5CollectionDocument` opens a `.medh5c` collection as a list of its
  members; opening a member opens a read-only sample window.
- "New Sample from NIfTI…" creates a sample through the engine's NIfTI
  converter into a temporary file and opens it as an untitled document (the
  first save asks where to put it).
- An "Open Demo Sample" item (Help menu and the welcome window) writes the
  engine's demo sample to a temporary file and opens it, so the app can be
  explored without data.

## The document window

```
┌ toolbar: sidebar · layout · tools · timepoint · W/L preset · 3-D · inspector ┐
│┌ sidebar ──────┐┌ viewer ───────────────────────────────┐┌ inspector ──────┐│
││ subject       ││ ┌ axial ────────┐ ┌ coronal ────────┐  ││ Layers          ││
││ timepoints    ││ │               │ │                 │  ││ Segment editor  ││
││  ├ images     ││ └───────────────┘ └─────────────────┘  ││ Annotations     ││
││  └ annotations││ ┌ sagittal ─────┐ ┌ 3-D ────────────┐  ││ Measurements    ││
││ transforms    ││ │               │ │                 │  ││ Info            ││
││ label set     ││ └───────────────┘ └─────────────────┘  ││                 ││
││ curation      │└────────────────────────────────────────┘│                 ││
││ clinical      │ status: world (mm) · voxel · value · labels · timepoint     ││
│└───────────────┘                                          └─────────────────┘│
└──────────────────────────────────────────────────────────────────────────────┘
```

### Sidebar — the sample's contents

An outline built from the sample summary:

- **Header**: subject id, sample id, format version badge (1.0 / 1.1 /
  1.2), profiles as chips, `content_id` (short, copyable), a warning chip for
  a projection or failed verification.
- **Timepoints** in acquisition order (label, date, days from baseline);
  under each, its **grids** and, under each grid, its **images** (modality,
  dtype, shape) and **annotations** (kind icon, task, class count, coverage
  "3/3 examined"). Annotations spanning timepoints (`timepoints` attribute)
  appear under "Across timepoints".
- **Transforms** (from frame → to frame, kind), **Label set** (class colour
  swatches; opens the label set editor), **Provenance**, **Quality**,
  **De-identification** (or "none recorded — treat as identifying"),
  **Clinical** (1.1; opens the clinical window), **Index** (sampling index
  entries and whether they are fresh).

Selecting an item shows it in the inspector's Info tab. Double-clicking an
image makes it the base layer; the eye button adds or removes an image or
annotation as an overlay. Context menus: show, overlay, export as NIfTI,
remove (edits), reveal attributes.

### Viewer

- **Layouts**: one view, 1×3 (axial, coronal, sagittal), 2×2 (three planes
  and 3-D), 3-D only, and **Compare** (two timepoints side by side, same
  plane, crosshairs linked through the transform the engine resolves
  between them; without one, linked by index and labelled "not
  registered"). Keyboard 1–5.
- **Slice views** (MPR): anatomical planes (default) or aligned to the base
  image's axes (View menu); radiological or neurological convention
  (Preferences). Orientation letters at the edges; corner text: image id,
  slice position (mm) and index, window/level, zoom, interpolation. The
  crosshair is shared: clicking in one view moves the cursor in all of them.
  Scroll/arrow keys move through slices by one voxel of the base image;
  Page Up/Down by 10; Home/End to the ends.
- **3-D view**: ray-cast volume of the base image (MIP, MinIP, DVR with
  presets, isosurface), segmentation surfaces in class colours, mesh
  annotations, the three planes, a clipping box; drag to orbit, scroll to
  zoom, option-drag to pan; double-click resets.
- **Layers** shown in a view: one base image, any number of image overlays
  (fusion: colormap, opacity, threshold; an image on another grid in the
  same frame is placed by its affine; in another frame, by the resolved
  transform — an affine as a matrix, otherwise a displacement field),
  segmentations (fill / outline / both, opacity, per-class visibility),
  probability maps, masks, instance maps (colour by instance), and
  geometric annotations (boxes and oriented boxes as their intersection with
  the plane, keypoints with skeleton edges, points with names, contours
  filled with holes, polylines, meshes as contours on slices and surfaces in
  3-D, classification shown in the Info tab and as a corner badge).
- **Time and channels**: a slider for a time axis (with `time_values`) and a
  channel picker; RGB images render in colour.
- **Status bar**: world coordinates (with the coordinate system), voxel
  index, raw and physical value with units, the classes at the cursor in
  every visible segmentation, the timepoint.

### Tools (toolbar and Tools menu)

| Tool | Key | Does |
|---|---|---|
| Navigate | V | click sets the crosshair; drag pans with ⌥, zooms with ⌃, windows with ⇧ |
| Window/Level | W | drag horizontally for width, vertically for level |
| Pan / Zoom | H / Z | |
| Ruler, Angle | M, A | distances in mm, angles in degrees, stored as measurements |
| ROI | O | ellipse or rectangle: area, mean, SD, min, max in physical units |
| Brush, Eraser | B, E | paint the active class; radius in mm ([ and ]); 2-D disc or 3-D sphere; paint policy; optional intensity range |
| Fill | F | 2-D or 3-D flood fill / region growing from the clicked voxel |
| Box, Point, Polyline, Contour | ⇧B, ⇧P, ⇧L, ⇧C | draw geometric annotations on the active annotation |

### Inspector

- **Layers**: the layer stack of the active view: visibility, opacity,
  order; for images window/level (sliders, presets, auto from percentiles,
  histogram), colormap, interpolation; for segmentations display mode,
  outline width, per-class toggles; for overlays from other frames, the
  transform used.
- **Segment editor**: the active segmentation (pick one, or create one on
  the base image's grid); its classes (colour, name, visibility, lock,
  voxels, volume in mm³, coverage: *examined* / *can express only*); add a
  class from the label set or create one (which adds it to the label set);
  tools and their options; operations (threshold, region grow, morphology,
  fill holes, keep largest component, remove islands, interpolate between
  slices, logical operations); undo and redo. Coverage is edited
  explicitly: painting a class marks it examined; "Mark not examined" needs
  the class to have no voxels.
- **Annotations**: the items of the active geometric annotation (class,
  score, coordinates), select to jump, delete, edit class.
- **Measurements**: every measurement with its value; copy, delete, export
  CSV.
- **Info**: everything about the selected object — the image's grid
  (shape, spacing, origin, direction, coordinate system, units, frame,
  timepoint), dtype, rescale, value type and units, window presets, chunks,
  digest, provenance; an annotation's header (kind, task, grid, space,
  classes, coverage, closure, ignore id, quality, derived-from); a
  transform's summary; and the raw HDF5 attributes.

## Other windows and sheets

- **Validate…** (⌘⇧V): runs the engine's validator at a chosen level on the
  saved file; diagnostics grouped by severity with code, path and message;
  filter; copy; export JSON. **Verify Integrity** checks every digest and
  the `content_id`.
- **Document** (⌘⌥D): the `/meta` document as an outline, with forms for
  identity, cohort, timepoints, quality, de-identification, and a JSON
  editor for everything (validated by the engine on apply). Order and number
  types are preserved.
- **Label set editor**: id, key, name, colour, category, laterality,
  parents, codes; adding, removing (refused while an annotation uses the
  class) and recolouring classes.
- **Clinical history** (format 1.1): a timeline of events on the subject
  clock with effective and available intervals and the imaging timepoints;
  an event table; document text; a cutoff slider showing what was known at
  that moment (strict prospective selection).
- **Import NIfTI…**: add an image (onto an existing grid or a new one,
  with modality and timepoint) or a segmentation; **Export ▸ NIfTI**:
  the selected image or segmentation; **Export ▸ Screenshot** of the active
  view (PNG, at view or 2× resolution); **Export ▸ Measurements (CSV)**.
- **Preferences**: General (default layout, anatomical or aligned planes,
  radiological or neurological), Rendering (interpolation, 3-D quality,
  GPU memory budget), Editing (default brush radius, undo memory),
  Performance (engine threads).
- **Welcome window** when no document is open: Open…, Open Recent, Open Demo
  Sample, New Sample from NIfTI…, links to the user guide and the medh5
  documentation.

## Menus

- **File**: New Sample from NIfTI…, Open… ⌘O, Open Recent, Open Demo
  Sample, Close ⌘W, Save ⌘S, Save As… ⇧⌘S, Revert to Saved, Import ▸
  (NIfTI Image…, NIfTI Segmentation…), Export ▸ (NIfTI…, Screenshot…,
  Measurements…), Page Setup is omitted.
- **Edit**: Undo/Redo, Cut/Copy/Paste (measurements, annotation items),
  Delete, Select All (annotation items).
- **View**: layouts, Anatomical/Aligned planes, Show Crosshair, Show
  Overlays, Show Orientation Labels, Interpolation, Reset View ⌘0, Zoom
  In/Out, Toggle Sidebar, Toggle Inspector, Enter Full Screen.
- **Image**: window presets, auto window, colormap, invert, next/previous
  timepoint, next/previous channel.
- **Segmentation**: New Segmentation, Add Class, tools, operations, Show
  Outline Only, Hide All.
- **Tools**: the interaction tools, Validate…, Verify Integrity, Build
  Sampling Index, Recompress…
- **Window**, **Help** (medh5 Viewer Help, Keyboard Shortcuts, medh5
  Documentation, Open Demo Sample, Report an Issue).

## Accessibility and polish

VoiceOver labels on controls and sidebar items; full keyboard navigation of
the sidebar and inspector; tooltips on toolbar items; the viewport respects
"Reduce Motion" (no animated transitions); colour-blind-safe default label
palette; all measurements and values copyable as text.
