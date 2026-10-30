# The bridge

The viewer reads and writes medh5 files through one engine, the Rust crate
[`medh5`](https://crates.io/crates/medh5) **2.2.4**, which the Python package
and the `medh5` command line also run. `bridge/` is a small Rust crate,
`medh5-bridge`, that exports the engine as a C library;
`bridge/include/medh5_bridge.h` is the contract and this page its reference.
`Packages/MedH5Kit` is the Swift API over it.

```
Swift (MedH5Kit) ──C ABI──▶ medh5-bridge (Rust staticlib) ──▶ medh5 2.2.4 ──▶ HDF5 2.2.0 (patched), Blosc2, zstd
```

## Building

```sh
scripts/build-bridge.sh
```

builds the static library (`cargo rustc --release --lib --crate-type staticlib
--target aarch64-apple-darwin`, `MACOSX_DEPLOYMENT_TARGET=14.0`) and packages it
with the header and a `module MedH5Bridge` module map as
`Packages/MedH5Kit/Frameworks/MedH5Bridge.xcframework`. The first build compiles
HDF5 from source with CMake (a few minutes); later ones rebuild only what
changed, and the xcframework is replaced only when the library or the header
did.

- **One build configuration.** `bridge/.cargo/config.toml` pins the target
  (`aarch64-apple-darwin`) and the deployment target, so `cargo build`,
  `cargo test` and the script share one tree:
  `bridge/target/aarch64-apple-darwin/release`. Tests run in the release
  profile too (`cargo test --release`): an optimised HDF5 is compiled with
  `NDEBUG` (a Debug HDF5 keeps its assertions and aborts on a damaged file
  where every other build reports an error), and `panic = "unwind"` lets the
  bridge catch a panic at the boundary.
- **The patched HDF5.** `bridge/Cargo.toml` takes `hdf5-metno-src` from the
  medh5 repository at the `v2.2.4` tag, the release of the engine it builds
  (`[patch.crates-io]`; cargo finds it at `vendor/hdf5-metno-src`): the HDF5
  the medh5 wheels and binaries link, with its fixes for crafted files and,
  from 2.2.4, for copying a dataset another thread holds open
  ([medh5-project/medh5#116](https://github.com/medh5-project/medh5/pull/116)).
  `Cargo.lock` records the git source, and the script refuses to package a
  build that does not use it.
- **Linking.** The archive needs `-liconv -lSystem -lc -lm` from the system
  (`cargo rustc … -- --print native-static-libs`); MedH5Kit's `Package.swift`
  links exactly these. Built alone the static library is linked with thin LTO
  (about 40 MB); built beside the rlib it would be ten times larger.
- **A standalone workspace.** `bridge/` declares `[workspace]`, so it never
  joins another.

## Testing

```sh
cd bridge && cargo test --release           # the C ABI, every function, through the engine
swift test --package-path Packages/MedH5Kit \
           --scratch-path ~/Library/Caches/medh5-viewer/swift/MedH5Kit
```

The Rust tests (`bridge/tests/`) call every exported function from Rust
through the C ABI — the demo sample's every object, every voxel encoding
against the engine's own `contains`, every geometric kind against its grid,
transforms, clinical selection, writing and amending, NIfTI, recompression,
collections, the error paths (a bad id, a wrong buffer size, a cancelled
progress callback, NULL and bad UTF-8), and the whole conformance corpus plus
the engine's robustness fixtures (each opened and read through every call:
an error is an answer, a panic or a crash is not; each validated, its codes
those the corpus expects). `tests/header.rs` holds the header and the library
to the same set of functions.

`~/Documents` is iCloud-synced on the development machine: a test bundle built
inside it is tagged with Finder information that `codesign` refuses, so give
`swift test` a scratch path outside it.

## Conventions

**Status and errors.** Every fallible function returns an `M5Status`:

| Status | Value | Meaning |
|---|---|---|
| `M5_OK` | 0 | success |
| `M5_ERR` | 1 | the engine refused or failed |
| `M5_ERR_ARGUMENT` | 2 | a bad argument: NULL, bad UTF-8 or JSON, a buffer of the wrong size, a region outside the array |
| `M5_ERR_PANIC` | 3 | the engine panicked (a bug), caught at the boundary |
| `M5_ERR_CANCELLED` | 4 | a progress callback returned false |
| `M5_ERR_NOT_FOUND` | 5 | a bundle holds no array of that name |

On anything but `M5_OK`, `m5_last_error()` returns the calling thread's error
(free it with `m5_string_free`); a success clears it:

```json
{"status": 1, "kind": "validation", "code": "E701", "message": "refusing to amend …"}
```

`kind` is the engine's category — `file`, `version`, `schema`, `validation`,
`integrity`, `key`, `value`, `type`, `index`, `io`, `unsupported`, `runtime` —
or the bridge's own: `argument`, `cancelled`, `panic`, `not_found`. `code` is
the §15.2 diagnostic code the engine attached (`null` when none); `message` is
the engine's message without the `[CODE]` prefix.

**Strings.** In: UTF-8, NUL-terminated; a nullable `options_json` may also be
`""` or `"null"`. Out (`char **out_*`): allocated by the bridge, freed by the
caller with `m5_string_free` (NULL-safe). The version strings are static.

**Arrays.** C-contiguous, stored axis order (axis 0 slowest), native-endian.
Element types are `M5DType` codes, `MedH5Core.ScalarType`'s raw values:

| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| native (reads only) | bool (one byte, 0/1) | uint8 | int8 | uint16 | int16 | uint32 | int32 | uint64 | int64 | float16 | float32 | float64 |

A buffer the caller passes is written in full or not at all, and its size must
match exactly. A **region** is `start`/`stop`, half-open, `ndim` entries
(`ndim == 0` and NULL pointers: the whole array). For an image, `ndim` is the
image's rank or its number of spatial axes (the leading channel/time axes are
then read whole); for an annotation, the grid's number of spatial axes.

**Handles.** `M5Sample`, `M5Writer` and `M5Bundle` are thread-safe. Calls on one
`M5Sample` may run concurrently: the engine's sample is read-only, so a call
takes a reference to it under a short lock and reads without the lock (HDF5
itself is serialised by the engine; decompression outside HDF5's lock runs in
parallel). `m5_sample_close` takes the sample away; a call still running
finishes or reports the file closed — but the handle memory is freed, so the
caller must not call `close` while a call on the same handle is in flight
(MedH5Kit's `SampleFile` holds a reader–writer lock for this). Calls on one
`M5Writer` are serialised.

**Progress.** `M5ProgressFn(context, done, total)` is called on the calling
thread, first with `done == 0`, then after each slab; returning `false`
cancels the call, which returns `M5_ERR_CANCELLED` and leaves the buffer
undefined. `total` is in elements.

**Performance.** Image and layer reads go straight into the caller's buffer, in
slabs along axis 0 of about 16 MB, aligned to the stored chunks so no chunk is
decompressed twice; only a slab is ever held beside the output. `labelmap` and
`layers` are read with the engine's region reader and only widened to
`uint16` when stored narrower; the packed encodings are decoded from their
stored planes. `m5_set_threads(n)` lets one engine call use `n` threads for
decompression and hashing (process-wide; 0 restores the engine's default,
`MEDH5_THREADS` or 1).

**Panics.** Every exported function runs its body under `catch_unwind`; a
panic becomes `M5_ERR_PANIC` (kind `panic`) and never unwinds into the caller.

## Reading

### Sample summary

`m5_sample_summary` returns everything the viewer shows without reading voxels.
An image, annotation or transform the engine cannot read is listed with an
`"error": {"kind", "code", "message"}` in place of its fields, so a damaged file
still shows what is intact.

| Key | Value |
|---|---|
| `path` | the file |
| `format_version` | the version the file declares (`"1.0"`, `"1.1"`, `"1.2"`) |
| `support` | `"full"`, or `"projection"` for a later minor (1.1 §2: what is known is read; never amended) |
| `engine_format_version` | `"1.2"` |
| `kind` | `"sample"` |
| `profiles` | declared profiles, e.g. `["clinical", "core", "seg", …]` |
| `content_id`, `digest_algo`, `created`, `generator` | root attributes |
| `identity`, `cohort`, `timepoints`, `label_set`, `provenance`, `quality`, `splits`, `acquisition`, `deidentification`, `extra` | the document's members, as `/meta` holds them (`null` when absent) |
| `longitudinal` | more than one timepoint |
| `grids` | each as `MedH5Core.GridGeometry` decodes it: `id`, `shape`, `axis_names`, `axis_kinds`, `spacing`, `origin`, `direction` (rows: `direction[r][c]` is world component `r` of axis `c`), `coord_system`, `units`, `timepoint` (the implicit one resolved), `frame_uid`, `time_values`, `time_units`, plus `chunk_hint`, `patch_hint`, `physical_size` |
| `images` | `id`, `grid`, `timepoint`, `modality`, `value_type`, `value_units`, `channel_names`, `shape`, `dtype` (NumPy name), `chunks`, `levels`, `multiscale`, `grid_levels`, `downsample_method`, `rescale_slope`, `rescale_intercept`, `rescaled`, `window_center`, `window_width`, `valid_mask`, `prov`, `digest`, `nbytes`, `codec`, `stored_bytes` |
| `annotations` | `id`, `kind`, `task`, `grid`, `timepoints` (declared, or the grid's), `declared_timepoints`, `space`, `frame_uid` (declared, or the grid's), `class_ids`, `annotated_class_ids`, `fully_covered`, `closure`, `ignore_id`, `ignore_mask`, `prov`, `quality`, `derived_from`, `voxel`, `geometric`, `digest` (over its datasets' stored digests; `null` when one has none), `items` (objects of a geometric, classification or instances annotation), `attributes` (attributes outside the header); by kind: `layers`, `layer_classes` (layers); `planes` (bitmask); `threshold`, `normalized` (probmap); `has_masks`, `instance_ids` (instances); `skeleton` (keypoints); `correspondence`, `names` (points); `submeshes` (mesh); `scope`, `multilabel`, `scope_ids`, `change_label` (classification); `shape`, `dtype`, `codec` (voxel kinds) |
| `transforms` | the engine's summary: `id`, `kind`, `from_frame`, `to_frame`, `units`, `timepoints`, `invertible`, `inverse_id`, `metrics`, `prov`, `from_grid`, `to_grid`; by kind `jacobian_determinant` (affine); `field_grid`, `vector_space`, `interpolation`, `extrapolation`, `field_shape`, `field_dtype` (displacement); `cp_grid`, `order`, `cp_shape` (bspline); `components`, `chain_ok` (composite) |
| `index` | `[{"annotation", "fresh"}]` sampling index entries |
| `clinical` | `{"present": false}`, or `{"present": true, "projection", "clock", "events", "records", "kinds", "documents", "links", "unknown_availability"}` (counts) |
| `left_out` | `{"grids/g": "why"}`: what a later minor's projection leaves out (W913) |

`m5_sample_document` returns `/meta` exactly as stored: Python's
`json.dumps(doc, ensure_ascii=False)`. MedH5Kit's `JSONValue` parses it and
serialises it back to the same bytes (`JSONFormat.meta`), keeping integers and
floats apart and members in order.

`m5_sample_verify` (§13):

```json
{"ok": true,
 "content_id": {"stored": "sha256:…", "computed": "sha256:…", "ok": true},
 "objects": [{"path": "images/CT_tp0", "ok": true, "state": "ok"}, …],
 "mismatched": [], "malformed": [], "undigested": [], "unattested": [],
 "unverifiable": [], "stale_index": []}
```

`m5_sample_attributes(sample, "images/CT")` returns a group's or dataset's raw
attributes (`"/"` for the root) as `{name: value}`; arrays as nested lists, a
non-finite float as the text `"NaN"`/`"Infinity"`.

### Images

`m5_image_read(sample, id, level, start, stop, ndim, physical, dtype, out,
out_bytes, progress, context)`: `physical` applies `rescale_slope` and
`rescale_intercept` (§4.2); `dtype` `M5_DTYPE_NATIVE` keeps the stored type,
or float32 when `physical`; any other type converts as the engine converts
(saturating; NumPy's float32 rounding for a rescale).

### Voxel annotations: layers

The viewer holds every segmentation as **layers**: `uint16` volumes in which
classes are mutually exclusive (§7.2). `m5_annotation_layer_plan` says how an
annotation's classes split into them, whatever its encoding:

```json
{"annotation": "organs_tp0", "kind": "layers", "spatial_shape": [64, 64, 64],
 "layers": [[2, 3, 5, 6, 7, 8], [9]],
 "class_ids": [2, 3, 5, 6, 7, 8, 9], "annotated_class_ids": [2, 3, 5, 6, 8, 9],
 "closure": "explicit", "ignore_id": 65535, "ignore_in_band": true,
 "ignore_mask": null, "threshold": null, "instances": false, "overlaps": []}
```

| Kind | Layers |
|---|---|
| `labelmap` | one: the stored volume |
| `layers` | its own, as stored |
| `bitmask`, `instances`, `probmap` | the classes packed by the engine's greedy colouring (the one its `layers` encoder uses) of the overlap graph measured over the whole annotation (`overlaps`); a probmap thresholded at its `threshold` (≥, as the engine's `contains`) |
| `mask` | none (`[]`); read it with `m5_annotation_read_mask` |

Two classes share a layer only if they never share a voxel; every class of
`class_ids` is in exactly one layer, voxels or not. Classes are the stored ones:
`closure` is not applied (an `implicit` annotation is read without its label
set's hierarchy). The plan is computed once per annotation and handle.

`m5_annotation_read_layer` writes one layer: 0 background, a class id, or the
annotation's ignore id where the ignore region is held in band
(`ignore_in_band`). An ignore region held by a sibling `mask` (`ignore_mask`)
is read with `m5_annotation_read_mask(…, ignore_region: true, …)`, which gives
the region of any voxel annotation, in band and sibling together, as 0/1 bytes.

`m5_annotation_read_probability` gives one class of a probmap as float32;
`m5_annotation_instances` the objects of an `instances` (or `boxes`) annotation,
`[{"index", "instance_id", "class_id", "bbox": [[lo, hi], …], "voxel_count",
"score", "has_mask"}]` (boxes at voxel edges, §8.1); and
`m5_annotation_read_instance_map` one `uint32` volume holding `1 +` the index of
the last object covering each voxel. `m5_annotation_class_stats` gives
`{"<class id>": {"voxels", "bbox"}}` as the engine counts them.

### Geometric annotations

`m5_annotation_geometry` returns a bundle. Its header:

```json
{"annotation": "lesion_boxes_tp0", "kind": "boxes", "grid": "ct_tp0",
 "frame_uid": "demo:frame-tp0", "space": "index", "class_ids": [3, 9],
 "annotated_class_ids": [3, 9], "items": 3,
 "attributes": [{"confirmed": true}, …] | null, "world_error": null}
```

Arrays are the stored datasets (spec §8, 1.2 §3) in their stored types, plus
`float64` coordinates in world: an `index` annotation's coordinates through its
grid's affine (`x = origin + direction · (spacing ⊙ i)`), a `world`
annotation's as stored. When world coordinates cannot be given (an index
annotation without a grid), `world_error` says why and the world arrays are
absent. `S` is the spatial rank.

| Kind | Arrays (shape) | World | Header |
|---|---|---|---|
| `boxes` | `boxes` (N, S, 2) `[lo, hi]` at voxel edges, `class_ids` (N), `instance_ids`?, `scores`?, `slice_index`? | `world_corners` (N, 2^S, S), corner bits in odometer order (the first axis slowest; corner 0 every lower bound) | |
| `obb` | `centers` (N, S), `sizes` (N, S) full edge lengths, `rotations` (N, S, S) (column k: local axis k), `class_ids`, `instance_ids`?, `scores`? | `corners` (N, 2^S, S) in its space, `world_corners` | |
| `keypoints` | `points` (N, K, S), `keypoint_class_ids` (K), `visibility` (N, K) (0 unlabelled, 1 occluded, 2 visible; all 2 when not stored), `class_ids` (N), `instance_ids`?, `scores`? | `world_points` (N, K, S) | `skeleton`, `skeleton_edges`, `skeleton_keypoints` |
| `points` | `points` (N, S), `class_ids`?, `instance_ids`?, `weights`? | `world_points` (N, S) | `names`, `correspondence` |
| `contours` | `vertices` (V, S), `contour_offsets` (M+1), `contour_class_ids` (M), `contour_plane` (M, 2) `(axis, index)`, `(-1, 0)` when not stored, `contour_role` (M) 0 outer / 1 hole, **from each polygon's depth** among its class's polygons in its plane (§8.6) | `world_vertices` (V, S) | |
| `polylines` | `vertices` (V, S), `polyline_offsets` (M+1), `polyline_class_ids` (M), `polyline_plane` (M, 2), `instance_ids`? | `world_vertices` (V, S) | |
| `mesh` | `vertices` (V, 3), `faces` (F, 3), `normals`?, `vertex_class_ids`?, `mesh_offsets`? (submeshes of faces), `mesh_class_ids`? | `world_vertices` (V, 3), `world_normals` (an index mesh's normals through the inverse transpose of its grid's linear part) | `submeshes` |
| `classification` | none | | `scope`, `multilabel`, `scope_ids`, `change_label`, `compared_timepoints`, `assertions` `[{"class_id", "key", "value", "scope_id", "scheme", "scheme_value"}]`, `labels` `{key: value}`, `positives` |

A voxel annotation has no geometry bundle (`M5_ERR`, kind `type`).

### Transforms

`m5_transform_read` returns the stored transform: header = the summary entry
(above); arrays `matrix` ((S+1, S+1) float64, affine), `field` ((S, *spatial) as
stored, displacement), `control_points` (float64, bspline).

`m5_transform_resolve(sample, from, to, field_grid, field_step)` resolves the
transform taking points of `from` to points of `to`, `x_to = T(x_from)` (§10.2),
as the engine's `transform_between` does: each key is read as a timepoint, a
grid or a frame uid, in that order; the shortest path through the frame graph,
inverses where they can be evaluated, two equally short routes refused (E501),
a visit holding several frames refused. Header:

```json
{"found": true, "same_frame": false, "kind": "affine",
 "from_frame": "demo:frame-tp0", "to_frame": "demo:frame-tp1",
 "from_frames": [...], "to_frames": [...], "units": "mm",
 "linear": true, "path": ["tp0_to_tp1"], "inverted": [false],
 "description": "tp0_to_tp1", "field_grid": null}
```

- **Linear** (identity, affine, their inverses and compositions): array
  `matrix` (4, 4) float64, world to world; a 2-D affine is embedded in 3-D. The
  matrix is held to the engine's own evaluation at probe points before it is
  returned.
- **Otherwise**, with a `field_grid` (a grid in the from frame — the view's
  reference grid): `displacement` (n0, n1, n2, 3) float32, `T(x) − x` in world
  units at that grid's voxel centres every `field_step` voxels (a 2-D grid is one
  slice, its z displacement 0), evaluated by the engine; header `field_grid`
  describes the lattice as a grid (spacing × step, the same origin and
  direction). A field grid in another frame is refused (E414). Without a field
  grid, the header alone.
- `found: false` and no arrays when no transform relates the two (alignment is
  never assumed, §3.4), or when they share a frame (`same_frame: true`: the
  identity).

### Clinical history (format 1.1)

`m5_clinical_records`:

```json
{"present": true, "projection": false, "schema": "medh5.clinical/1",
 "clock": {"id", "unit": "us", "reference": "relative", "origin_description"},
 "events": [{"event_id", "record_id", "kind", "temporal_type",
             "effective_start_us": [lo, hi] | null, "effective_end_us", "available_us",
             "status", "timepoint_id", "encounter_id", "code_system", "code",
             "code_version", "value_num", "value_comparator", "unit",
             "value_text", "missing_reason", "prov"}],
 "links": [{"source_type", "source_id", "relation", "target_type", "target_id",
            "source_span": [start, end] | null, "target_annotation_id",
            "asserted_by_event_id"}],
 "documents": [{"document_id", "media_type", "language", "source_type", "bytes"}],
 "summary": {…}}
```

Document text is not included; `m5_clinical_document_text` reads one document
(only its bytes). `m5_clinical_select(sample, {"cutoff_hours": 36})` (or
`cutoff_us`, `cutoff_days`; optional `policy`, the engine's selection policy,
strict prospective by default) returns what was known at the cutoff:
`{"cutoff_us", "policy", "status", "certified", "events": [{"event_id",
"record_id", "kind", "order_us", "tie_group", "plan"}], "event_ids",
"documents", "links", "payloads", "uncertain_records", "excluded"}`.

## Validation

`m5_validate_file(path, level)` (`level`: `structural`, `semantic`,
`integrity` (the default), `strict`):

```json
{"path": "…", "level": "integrity", "profiles": ["core", …], "ok": true,
 "errors": 0, "warnings": 0, "promoted": 0, "codes": [],
 "diagnostics": [{"code": "E701", "severity": "error", "effective_severity": "error",
                  "location": "/images/CT", "message": "…", "level": "integrity",
                  "summary": "…the code table's one line…"}],
 "checked": {…}}
```

A file that cannot be read is reported (E001), not refused. `m5_code_table`
returns the §15.2 table (`[{"code", "severity", "domain", "summary", "since",
"revision"}]`) and `m5_validation_levels` the levels.

## Writing

A writer validates every call and commits atomically: nothing is visible at
the destination until `m5_writer_commit`, which validates, writes digests, and
renames the file into place. A commit refused before it changes anything (a
sample without an image, E201; a dangling reference; a document its schema
rejects, E005) leaves the writer open; `m5_writer_abort` discards everything.

**Create:** `m5_writer_create(path, {"sample_id", "subject_id", "codec":
"balanced"|"fast"|"training"|"archive"|"portable", "profiles": []})`.

**Amend** (the viewer's save, §14.4): `m5_writer_amend(path, out_path,
{"codec", "without": […]})` copies the sample, copy-on-write; the commit replaces
`path` (or writes `out_path`, leaving `path` alone). `without` names what is
about to be removed and written again: a top-level member (`"clinical"`,
`"index"`) is not copied at all; a nested object (`"annotations/organs"`,
`"images/CT"`, `"transforms/t"`, `"grids/g"`) is copied with the graph (the
engine copies the source whole, so hard links stay one object) and dropped from
the amendment before it is written again, and the commit compacts the file so
none of its bytes remain. Close readers of `path` before the commit and reopen
after. A source whose stored digests do not match its bytes is refused at the
commit (E701), which would otherwise restamp bytes nobody verified.

**Commit:** `m5_writer_commit(writer, digests, &content_id)`: with `digests`
every digest is recomputed (and a changed one checked against the source, E701);
without, only objects that have none — those this writer wrote — are digested,
which is fast. `content_id` receives the new `content_id`, or NULL when the
writer had already committed.

### The document

| Function | Argument |
|---|---|
| `m5_writer_document` | → the document as the commit will store it (`/meta` form) |
| `m5_writer_set_document` | the whole document (identity, cohort, timepoints, label_set, provenance, quality, deidentification, acquisition, extra, splits), checked as the engine checks each field |
| `m5_writer_set_identity`, `m5_writer_set_cohort` | fields merged in |
| `m5_writer_add_timepoint(id, fields)` | `{"index"?, "label", "date", "days_from_baseline", "study_uid", "series_uids", "subject_age_years", "description"}`; the first replaces the implicit `tp0` |
| `m5_writer_set_label_set` | `{"id", "version", "classes": [{"id", "key", "name", "parents", "category", "color": [r, g, b, a], "codes": [{"system", "code", "name"}], "laterality", "properties"}], "relations", "skeletons": [{"id", "keypoints", "edges"}]}`; `null` removes it |
| `m5_writer_set_quality(key, fields)` | `{"status", "confidence", "reviewed_by", "agreement", "issues", "edit_effort_s"}` |
| `m5_writer_add_agent` | `{"type": "person"\|"software"\|"organization", "name", "id"?, "role", "version", "qualification", "organization"}` → the agent with its id |
| `m5_writer_add_activity` | `{"type": "import"\|"annotate"\|"review"\|"predict"\|"resample"\|"register"\|"derive"\|"deidentify"\|"transcode"\|"other", "agent", "id"?, "started", "ended", "tool", "inputs", "outputs", "params"}` → the activity with its id |
| `m5_writer_set_extra(namespace, value)` | any JSON; `null` removes it |
| `m5_writer_set_acquisition(image, params)` | parameters merged in (§4.5) |
| `m5_writer_set_deidentification` | `{"method", …}`; `null` removes it |

### Grids and images

`m5_writer_add_grid(id, grid)` takes a grid as `MedH5Core.GridGeometry` encodes
it (`shape`, `spacing`, `origin`, `direction`, `axis_names`, `axis_kinds`,
`coord_system`, `units`, `timepoint`, `frame_uid`, `time_values`, `time_units`,
`patch_hint`, `chunk_hint`; `id` is ignored).

`m5_writer_add_image(id, grid, options, dtype, shape, ndim, data, nbytes)`:
`shape` is the grid's full shape; options `{"modality": "OT", "value_type",
"value_units", "rescale_slope", "rescale_intercept", "window_center": [],
"window_width": [], "channel_names": [], "valid_mask", "prov", "codec",
"acquisition": {}}`. `m5_writer_set_image_attrs(id, edit)` changes attributes
without rewriting the samples: a key present sets it, `null` removes it.

### Segmentations

`m5_writer_add_segmentation(id, grid, options, n_layers, layers,
voxels_per_layer)` takes `uint16` layers of the grid's spatial shape: a voxel is
in class `c` where some layer holds `c`. They are written through the engine's
label-volume writer: each distinct combination of layer values becomes one value
of a label volume naming the classes it holds, so no mask per class is built,
and the engine measures and encodes exactly what the masks would have said (a
single aligned layer is not even copied). Options:

| Key | Meaning |
|---|---|
| `class_ids` | what it can express; default: the classes present plus the annotated ones. A save passes the annotation's own, so coverage is never collapsed |
| `annotated_classes` | what was looked for: ids or keys, `"all"` (the label set), `"present"`, or `"given"`/null (every class it can express) |
| `encoding` | null/`"auto"` (the engine chooses by measuring overlap), `"labelmap"`, `"layers"`, `"bitmask"`, `"instances"` |
| `ignore_value` | layer values equal to it form the ignore region (§7.7): default 65535, `null` for none. Held in band when the encoding can and the region holds no class; otherwise written as the sibling `mask` `<id>_ignore` |
| `ignore_mask` | a `mask` annotation already written that holds the ignore region |
| `closure`, `timepoints`, `prov`, `quality` (a key or a record), `derived_from`, `task`, `codec` | the header |

`m5_writer_add_segmentation_ex` also returns what the engine chose: `{"kind",
"stats": {"classes", "voxels", "fill", "depth", "layers", "planes", "edges",
"mean_degree", "localized", "counts"}}`.

`m5_writer_add_mask(id, grid, {"task": "other", "prov", "codec"}, bytes,
voxels)`, `m5_writer_remove_annotation`, `m5_writer_transcode_annotation(id,
to_kind, drop_identity)` (refused where the target cannot express the source:
identity, an in-band ignore region, classes into a `mask`).

### Geometric annotations and classification

`m5_writer_add_geometric(kind, id, options, arrays, n)` takes arrays named as the
stored datasets (the table above; any numeric type, converted), options
`{"grid", "space": "index"|"world", "frame_uid", "annotated_classes",
"attributes": [{} per object], "names", "correspondence", "skeleton", "task",
"prov", "quality", "timepoints", "closure", "derived_from", "codec"}`; a class
column may instead be an option of the same name holding ids or label-set keys.

| Kind | Required | Optional |
|---|---|---|
| `boxes` | `boxes` (N, S, 2), `class_ids` | `instance_ids`, `scores`, `slice_index` |
| `obb` | `centers`, `sizes`, `rotations`, `class_ids` | `instance_ids`, `scores` |
| `keypoints` | `points` (N, K, S), `keypoint_class_ids` (K), `class_ids` (N) | `visibility`, `instance_ids`, `scores` |
| `points` | `points` (N, S) | `class_ids`, `instance_ids`, `weights` |
| `contours` | `vertices`, `contour_offsets`, `contour_class_ids` | `contour_plane`, `contour_role` (0/1) |
| `polylines` | `vertices`, `polyline_offsets`, `polyline_class_ids` | `polyline_plane`, `instance_ids` |
| `mesh` | `vertices` (V, 3), `faces` (F, 3) | `normals`, `vertex_class_ids`, `mesh_offsets`, `mesh_class_ids` |

`m5_writer_add_classification(id, {"scope", "multilabel", "grid", "assertions":
[{"class_id": id or key, "value", "scope_id", "scheme", "scheme_value"}],
"annotated_classes", "timepoints", …})`.

### Transforms and the index

`m5_writer_add_affine_transform(id, {"from_frame", "to_frame", "from_grid",
"to_grid", "units", "prov", "metrics", "invertible", "inverse_id", "codec"},
matrix, dim)` (row-major, `dim = S + 1`); `m5_writer_add_transform(id, kind,
options, arrays, n)` any kind: `identity`, `affine` (`matrix`), `displacement`
(`field` (S, *spatial), options `field_grid`, `vector_space`, `interpolation`,
`extrapolation`, `field_dtype`: `float32`|`float16`|`auto`), `bspline`
(`control_points`, options `cp_grid`, `order`), `composite` (options
`components`). `m5_writer_build_index({"annotations", "max_coords",
"occupancy": factor|false, "seed"})` builds the sampling index (§14.3).

## Conversion, storage, collections

- `m5_nifti_read(path)`: a bundle; header = the engine's `read_nifti` geometry
  (axes reordered to (z, y, x), world in LPS: `spacing`, `origin`, `direction`,
  `coord_system`, `shape`, `axis_order`, `units`, `dtype`, `rescale`,
  `time_values`, notes, …) plus `grid` (a `GridGeometry`) and `affine` (its
  homogeneous index → world matrix); array `data` in the file's type.
- `m5_nifti_import(out, {"images": {"CT": path}, "masks": {"liver": path},
  "sample_id", "subject_id", "modality": "CT" | {"CT": "CT"}, "value_units",
  "coord_system", "transpose", "fourth_axis", "codec", "annotated_classes",
  "assume_geometry", "plane_as_volume", "label_set"})` and
  `m5_nifti_import_segmentation(sample, {"masks", "annotation_id", "grid",
  "coord_system", "transpose", "annotated_classes", "assume_aligned",
  "assume_geometry", "plane_as_volume"})` return the conversion report:
  `{"source", "converter", "outputs", "ok", "counts", "notes": [{"kind",
  "message", "severity": "decision"|"guess"|"warning", "detail"}]}`. Geometry is
  never invented: a mask that does not sit on the grid is refused unless
  `assume_aligned`, which is recorded as a guess.
- `m5_nifti_export(sample, {"object": "images/CT"|"annotations/organs", "out",
  "physical": true, "class": id|key})`: the report plus `path`. A one-class
  mask of a class never examined, or of an annotation that ignores voxels, is
  refused (its 0 would read as "examined, absent").
- `m5_recompress(path, {"profile", "out", "rechunk"})`: the engine's result
  (`ok`, `content_id_preserved`, bytes before and after, datasets changed).
- `m5_collection_list(path)`: `{"path", "version", "kind", "members": [{"name",
  "sample_id", "subject_id", "profiles", "content_id", "timepoints", "images",
  "annotations"}]}`; `m5_collection_pack(out, {"sources", "keys"})`;
  `m5_sample_open_member(path, name)`.

## Fixtures

`m5_demo_write(path, {"size": 64, "clinical": true, "polylines": true, "index":
true, "codec": "balanced"})` writes a synthetic, deterministic sample that
validates at `strict`: a CT phantom (an elliptical trunk with a fat layer, liver,
spleen, kidneys, aorta and spine; int16 stored as HU + 1024 with intercept
−1024) scanned at baseline and at a 92-day follow-up, each on its own grid in
its own frame (`demo:frame-tp0`, `demo:frame-tp1`; voxels 400/size mm through,
320/size mm in-plane), the subject moved between them by the rigid motion the
affine `tp0_to_tp1` stores (a 6° rotation about z and a (12, −8, 15) mm shift);
a liver lesion centred at (−70, −10, 55) mm grows from 18 to 27 mm, a satellite
lesion is gone at follow-up; an oblique MR (float32) on its own grid in the
baseline frame with a field-of-view `mask` as its valid region. A label set of
12 classes with colours, SNOMED CT and RECIST codes, a hierarchy (kidney ⊃
left/right, liver ⊃ lesion) and a skeleton; `organs_tp0` as `layers` (the lesion
inside the liver, the aorta expressible but not examined, the unreviewed top
slices ignored in band), `organs_tp1` as a `labelmap`, `lesion_prob_tp1` a
`probmap` (liver and lesion, overlapping), `lesions_tp0` `instances` (ids 1 and
2), boxes, oriented boxes, keypoints with a skeleton, corresponding fiducial
point sets in each visit's world, contours with a hole, polylines (the aortic
centreline and a needle track to the lesion: format 1.2), meshes (the lesion's
icosphere and the liver), a change-label classification, provenance (two
software agents, two people, five activities, six with the clinical history), quality records, a sampling
index, and a clinical history (format 1.1: labs, the scans, a revised report,
an assessment, a grounded span in the follow-up report, links). An object that
holds no voxel at a coarse size is left out.

`m5_conformance_write(directory)` writes the engine's conformance corpus and its
`expected.json`, and the robustness fixtures into `directory/robustness`.

## Swift (MedH5Kit)

`import MedH5Kit` (which re-exports `MedH5Core`) wraps every call above. Its
values are `Sendable`; a failed call throws `MedH5Error` (`status`, `kind`,
`code`, `message`, the C error JSON). A `ProgressHandler` returning `false`
cancels a read; the `async` variants (`loadImage`, `loadImageData`,
`loadLayer`, `loadSegmentation`, `Validator.validateInBackground`) run off the
calling task and are cancelled with it.

| Swift | C |
|---|---|
| `SampleFile.open(_:)`, `SampleFile.open(collection:member:)`, `summary` (`SampleSummary`), `close()` | `m5_sample_open`, `m5_sample_open_member`, `m5_sample_summary`, `m5_sample_close` |
| `readImage(_:level:region:physical:as:progress:)`, `loadImage(_:progress:)` → `ImageVolume` | `m5_image_read` |
| `layerPlan(_:)` → `LayerPlan`, `readLayer(_:layer:region:progress:)`, `loadSegmentation(_:progress:)` → `SegmentationData` | `m5_annotation_layer_plan`, `m5_annotation_read_layer` |
| `readMask`, `readProbability`, `instances` → `[InstanceInfo]`, `readInstanceMap`, `classStats` → `[Int: AnnotationClassStats]` | `m5_annotation_read_mask`, `…_read_probability`, `…_instances`, `…_read_instance_map`, `…_class_stats` |
| `geometry(_:)` → `GeometricAnnotation` | `m5_annotation_geometry` |
| `transform(_:)` → `StoredTransform`, `resolveTransform(from:to:fieldGrid:step:)` → `ResolvedTransform?` | `m5_transform_read`, `m5_transform_resolve` |
| `clinicalRecords()`, `clinicalDocumentText(_:)`, `clinicalSelect(cutoffHours:policy:)` | `m5_clinical_records`, `…_document_text`, `…_select` |
| `SampleWriter.create(url:options:)`, `SampleWriter.amend(url:outURL:without:codec:)`, `add…` / `remove…` / `set…`, `commit(digests:)`, `abort()` | `m5_writer_*` |
| `Validator`, `NIfTI`, `Storage`, `Collections`, `Demo`, `Conformance` | `m5_validate_file`, `m5_nifti_*`, `m5_recompress`, `m5_collection_*`, `m5_demo_write`, `m5_conformance_write` |

**Regions.** `ArrayRegion(start:stop:)` and `ArrayRegion(origin:size:)` are the C
region above, in stored axis order. `ArrayRegion(_:spatialRank:)` converts the
padded 3-D `VoxelBox` that the editor and the renderer exchange; for a 2-D grid
it drops the padding axis 0.

**Names.** The app imports MedH5Kit together with MedH5Editing and
MedH5Render, so MedH5Kit declares no top-level type that they or MedH5Core
declare. A read region is an `ArrayRegion` (MedH5Editing has a
`VoxelRegion`). A class's voxels and box in a stored annotation are an
`AnnotationClassStats` (MedH5Editing has a `ClassStatistics`). The items of a
geometric annotation are nested in `GeometricAnnotation`:
`GeometricAnnotation.Polyline`, `.Boxes`, `.Mesh` and so on (MedH5Editing has
a `Polyline`).
