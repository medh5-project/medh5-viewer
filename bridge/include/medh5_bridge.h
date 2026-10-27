/*
 * medh5_bridge.h — the C interface between the medh5 format engine (Rust,
 * the `medh5` crate, version 2.2.3) and the macOS viewer (Swift).
 *
 * The viewer reads and writes medh5 files only through this interface, so it
 * reads and writes exactly the bytes the Python package and the `medh5`
 * command line do: one engine, a fourth frontend.  docs/BRIDGE.md is the
 * reference: the JSON schemas, the arrays of each bundle, the options.
 *
 * Conventions
 * -----------
 * - Every fallible function returns an M5Status. On anything but M5_OK,
 *   m5_last_error() returns the error of the calling thread as JSON:
 *       {"status": 1, "kind": "validation", "code": "E701" | null,
 *        "message": "…"}
 *   `kind` is the engine's error category — file, version, schema,
 *   validation, integrity, key, value, type, index, io, unsupported,
 *   runtime — or the bridge's own: argument, cancelled, panic, not_found.
 *   `code` is the §15.2 diagnostic code the engine attached, when it did.
 *   A successful call clears the thread's last error.
 * - Strings in are UTF-8, NUL-terminated. Nullable arguments say so; a
 *   nullable options_json may also be "" or "null" (no options).
 * - Strings out (`char **out_*`) are allocated by the bridge and freed by the
 *   caller with m5_string_free(). JSON out is UTF-8 JSON text.
 * - Arrays are C-contiguous (row-major), in the stored axis order the
 *   specification uses (axis 0 slowest), native-endian. Buffers the caller
 *   passes in are written in full or not at all; their size must match
 *   exactly (M5_ERR_ARGUMENT otherwise).
 * - A region of interest is `start`/`stop` (half-open, `ndim` entries);
 *   `ndim == 0` (and NULL pointers) means the whole array. For an image,
 *   `ndim` is the image's rank, or its number of spatial axes (the leading
 *   channel/time axes are then read whole); for an annotation it is the
 *   grid's number of spatial axes.
 * - Handles (M5Sample, M5Writer, M5Bundle) are thread-safe. Calls on one
 *   M5Sample from several threads may run concurrently (the engine's sample
 *   is read-only; HDF5 itself is serialised by the engine); calls on one
 *   M5Writer are serialised by the bridge.
 * - A panic in the engine is caught at the boundary and reported as
 *   M5_ERR_PANIC; it never unwinds into Swift.
 * - Progress callbacks are optional (NULL). They are called on the calling
 *   thread, first with done == 0, then after each slab. A callback returning
 *   false cancels the call, which then returns M5_ERR_CANCELLED and writes
 *   nothing the caller can rely on.
 */
#ifndef MEDH5_BRIDGE_H
#define MEDH5_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Status, types, memory                                                    */
/* ------------------------------------------------------------------------ */

typedef int32_t M5Status;
#define M5_OK 0
#define M5_ERR 1            /* the engine refused or failed; see m5_last_error */
#define M5_ERR_ARGUMENT 2   /* a bad argument: NULL, bad UTF-8/JSON, wrong size */
#define M5_ERR_PANIC 3      /* the engine panicked (a bug); caught here */
#define M5_ERR_CANCELLED 4  /* a progress callback returned false */
#define M5_ERR_NOT_FOUND 5  /* a named array/key is absent (bundles) */

/* Element types; the values are MedH5Core.ScalarType's raw values. */
typedef int32_t M5DType;
#define M5_DTYPE_NATIVE 0   /* as stored (input only) */
#define M5_DTYPE_BOOL 1     /* one byte, 0 or 1 */
#define M5_DTYPE_UINT8 2
#define M5_DTYPE_INT8 3
#define M5_DTYPE_UINT16 4
#define M5_DTYPE_INT16 5
#define M5_DTYPE_UINT32 6
#define M5_DTYPE_INT32 7
#define M5_DTYPE_UINT64 8
#define M5_DTYPE_INT64 9
#define M5_DTYPE_FLOAT16 10
#define M5_DTYPE_FLOAT32 11
#define M5_DTYPE_FLOAT64 12

/* Returns false to cancel. `done`/`total` are in elements or steps. */
typedef bool (*M5ProgressFn)(void *context, uint64_t done, uint64_t total);

/* An array: in a bundle (owned by the bundle) or passed to a writer (owned
 * by the caller for the duration of the call). */
typedef struct M5ArrayView {
    const char *name;
    M5DType dtype;
    uint32_t ndim;
    const int64_t *shape;   /* ndim extents */
    const void *data;       /* C-contiguous */
    size_t nbytes;          /* product(shape) * itemsize */
} M5ArrayView;

/* Thread-local JSON of the calling thread's last error, or NULL when the
 * last call succeeded. Free with m5_string_free. */
char *m5_last_error(void);

/* NULL-safe. */
void m5_string_free(char *s);

/* ------------------------------------------------------------------------ */
/* Library                                                                  */
/* ------------------------------------------------------------------------ */

/* The engine's package version ("2.2.3"); static, do not free. */
const char *m5_engine_version(void);
/* The newest format version the engine implements ("1.2"); static. */
const char *m5_format_version(void);
/* This bridge's version; static. */
const char *m5_bridge_version(void);

/* Threads one engine call may use for its work outside HDF5
 * (medh5::parallel::set_threads); 0 restores the engine's default
 * (MEDH5_THREADS, else 1). The setting is process-wide. */
void m5_set_threads(uint32_t threads);
uint32_t m5_threads(void);

/* The §15.2 diagnostic code table, in table order:
 * [{"code", "severity", "domain", "summary", "since", "revision"}]. */
M5Status m5_code_table(char **out_json);

/* The validation levels, lowest first: ["structural", "semantic",
 * "integrity", "strict"]. */
M5Status m5_validation_levels(char **out_json);

/* ------------------------------------------------------------------------ */
/* Bundles: a JSON header plus named arrays                                 */
/* ------------------------------------------------------------------------ */

typedef struct M5Bundle M5Bundle;

/* The header JSON, owned by the bundle (valid until m5_bundle_free). */
const char *m5_bundle_header(const M5Bundle *bundle);
size_t m5_bundle_array_count(const M5Bundle *bundle);
/* Views into the bundle's memory, valid until m5_bundle_free. */
M5Status m5_bundle_array_at(const M5Bundle *bundle, size_t index, M5ArrayView *out);
/* M5_ERR_NOT_FOUND when the bundle holds no array of that name. */
M5Status m5_bundle_array_named(const M5Bundle *bundle, const char *name, M5ArrayView *out);
/* NULL-safe. */
void m5_bundle_free(M5Bundle *bundle);

/* ------------------------------------------------------------------------ */
/* Reading a sample                                                         */
/* ------------------------------------------------------------------------ */

typedef struct M5Sample M5Sample;

/* Opens a .medh5 file read-only. A file of a later minor version than the
 * engine implements opens as a projection (summary "support"). */
M5Status m5_sample_open(const char *path, M5Sample **out);
/* Opens one member of a .medh5c collection. */
M5Status m5_sample_open_member(const char *collection_path, const char *member, M5Sample **out);
/* NULL-safe. Closes the file and everything opened through it. */
void m5_sample_close(M5Sample *sample);

/* Everything the viewer shows without reading voxels, as one JSON object
 * (the schema is in docs/BRIDGE.md, "Sample summary"): format version,
 * support, kind, profiles, content_id, identity, cohort, timepoints, label
 * set, grids, images, annotations, transforms, provenance, quality,
 * deidentification, acquisition, extra, index entries, clinical presence,
 * objects left out of a projection. An image, annotation or transform the
 * engine cannot read is listed with its "error" instead. */
M5Status m5_sample_summary(M5Sample *sample, char **out_json);

/* The /meta document exactly as stored (JSON text). */
M5Status m5_sample_document(M5Sample *sample, char **out_json);

/* Verifies every object digest and the content_id (§13):
 * {"ok", "content_id": {"stored","computed","ok"}, "objects": [{"path","ok",
 *  "state"}], "mismatched", "malformed", "undigested", "unattested",
 *  "unverifiable", "stale_index"}. */
M5Status m5_sample_verify(M5Sample *sample, char **out_json);

/* The raw HDF5 attributes of one group or dataset path ("images/CT",
 * "annotations/organs", "annotations/organs/data", "grids/ct",
 * "transforms/t", "/"), as JSON {name: value}, for the inspector. */
M5Status m5_sample_attributes(M5Sample *sample, const char *object_path, char **out_json);

/* ---- Images ---- */

/* Reads an image's voxels (level 0 = full resolution; a single-scale image
 * has only level 0). `physical` applies rescale (spec §4.2). `dtype` is the
 * element type wanted: M5_DTYPE_NATIVE keeps the stored type, or float32
 * when `physical` is true; another type converts as the engine converts
 * (saturating). `out_bytes` must equal the region's element count times the
 * item size. Reads in slabs along axis 0 (aligned to the stored chunks),
 * straight into `out`, reporting progress in elements. */
M5Status m5_image_read(M5Sample *sample, const char *image_id, uint32_t level,
                       const int64_t *start, const int64_t *stop, uint32_t ndim,
                       bool physical, M5DType dtype,
                       void *out, size_t out_bytes,
                       M5ProgressFn progress, void *context);

/* ---- Voxel annotations (labelmap, layers, bitmask, instances, probmap, mask) ---- */

/* How the annotation's classes split into mutually exclusive uint16 layers
 * (spec §7.2), for any voxel kind:
 * {"annotation", "kind", "spatial_shape": […], "layers": [[class ids of layer
 *  0], …], "class_ids", "annotated_class_ids", "closure", "ignore_id": 65535,
 *  "ignore_in_band": bool, "ignore_mask": "ann id"|null, "threshold": 0.5|null,
 *  "instances": bool, "overlaps": [[a, b], …]}.
 * labelmap → one layer; layers → its own layers; bitmask, instances and
 * probmap (thresholded) → classes packed by the engine's greedy colouring of
 * the measured overlap graph, so two share a layer only if they never
 * overlap. Classes are the stored ones (closure not applied).
 * A `mask` annotation has no layers ("layers": []). Computed once per
 * annotation and handle (it may read the annotation whole). */
M5Status m5_annotation_layer_plan(M5Sample *sample, const char *annotation_id, char **out_json);

/* One layer of the plan above as uint16 class ids (0 = background; the
 * annotation's ignore id where it is held in band). `out_count` elements. */
M5Status m5_annotation_read_layer(M5Sample *sample, const char *annotation_id, uint32_t layer,
                                  const int64_t *start, const int64_t *stop, uint32_t ndim,
                                  uint16_t *out, size_t out_count,
                                  M5ProgressFn progress, void *context);

/* A `mask` annotation (or the ignore region of any voxel annotation — in
 * band and the sibling mask its header names — with `ignore_region` true)
 * as 0/1 bytes. */
M5Status m5_annotation_read_mask(M5Sample *sample, const char *annotation_id, bool ignore_region,
                                 const int64_t *start, const int64_t *stop, uint32_t ndim,
                                 uint8_t *out, size_t out_count);

/* One class of a probmap as float32 probabilities in [0, 1]. */
M5Status m5_annotation_read_probability(M5Sample *sample, const char *annotation_id, uint32_t class_id,
                                        const int64_t *start, const int64_t *stop, uint32_t ndim,
                                        float *out, size_t out_count);

/* The objects of an `instances` (or `boxes`) annotation:
 * [{"index", "instance_id", "class_id", "bbox": [[lo, hi], …] (box
 * convention §8.1, index space), "voxel_count", "score", "has_mask"}]. */
M5Status m5_annotation_instances(M5Sample *sample, const char *annotation_id, char **out_json);

/* An `instances` annotation as one uint32 map: each voxel holds 1 + the
 * index (in m5_annotation_instances order) of the last object covering it,
 * 0 where none does. */
M5Status m5_annotation_read_instance_map(M5Sample *sample, const char *annotation_id,
                                         const int64_t *start, const int64_t *stop, uint32_t ndim,
                                         uint32_t *out, size_t out_count);

/* Per-class statistics: {"<class id>": {"voxels", "bbox": [[lo,hi],…]|null}},
 * as the engine's voxel_counts/class_bboxes answer them. Reads the whole
 * annotation. */
M5Status m5_annotation_class_stats(M5Sample *sample, const char *annotation_id, char **out_json);

/* ---- Geometric and classification annotations ---- */

/* A geometric annotation's arrays, as stored and in world coordinates
 * (docs/BRIDGE.md, "Geometric annotations", lists the arrays per kind),
 * or a classification's assertions (header only). */
M5Status m5_annotation_geometry(M5Sample *sample, const char *annotation_id, M5Bundle **out);

/* ---- Transforms ---- */

/* A stored transform: header = its summary; arrays as stored ("matrix"
 * (S+1, S+1) float64; "field" (S, *spatial) as stored for displacement;
 * "control_points" float64 for bspline). Composite transforms list their
 * components in the header. */
M5Status m5_transform_read(M5Sample *sample, const char *transform_id, M5Bundle **out);

/* Resolves the transform taking points of `from_key` to points of `to_key`
 * (x_to = T(x_from), spec §10.2); a key is a timepoint, grid or frame uid
 * (read in that order). Header:
 * {"found": bool, "same_frame": bool, "kind", "from_frame", "to_frame",
 *  "from_frames", "to_frames", "units", "linear": bool, "path": [transform
 *  ids], "inverted": [bool], "field_grid": {grid}|null}.
 * Arrays: "matrix" (4, 4) float64, world → world (a 2-D affine embedded in
 * 3-D), when the resolved transform is linear. Otherwise, when
 * `field_grid_id` is given (a grid in the from frame): "displacement"
 * (n0, n1, n2, 3) float32 = T(x) − x in world units at the voxel centres of
 * that grid subsampled by `field_step` (≥ 1; 0 is taken as 1) per spatial
 * axis; "field_grid" describes the lattice.
 * found == false (and no arrays) when no transform relates the two, or when
 * they share a frame (same_frame == true: identity). */
M5Status m5_transform_resolve(M5Sample *sample, const char *from_key, const char *to_key,
                              const char *field_grid_id /* nullable */, uint32_t field_step,
                              M5Bundle **out);

/* ---- Clinical history (format 1.1) ---- */

/* {"present": false} or {"present": true, "projection", "schema",
 *  "clock": {…}, "events": [{…}], "links": [{…}], "documents":
 *  [{"document_id", "media_type", "language", "source_type", "bytes"}],
 *  "summary": {…}}. Document text is not included. */
M5Status m5_clinical_records(M5Sample *sample, char **out_json);

/* One document's text. */
M5Status m5_clinical_document_text(M5Sample *sample, const char *document_id, char **out_text);

/* What was known at a cutoff (1.1 §9, strict prospective selection unless a
 * policy says otherwise): `query_json` {"cutoff_hours": 24} or
 * {"cutoff_us": …} or {"cutoff_days": …} (subject clock), optional
 * "policy": {…}. Returns {"cutoff_us", "policy", "status", "certified",
 * "events": [{"event_id", "record_id", "kind", "order_us", "tie_group",
 * "plan"}], "event_ids": […], "documents": [document ids], "links",
 * "payloads", "uncertain_records", "excluded"}. */
M5Status m5_clinical_select(M5Sample *sample, const char *query_json, char **out_json);

/* ------------------------------------------------------------------------ */
/* Validation (path-based: the validator opens the file itself)             */
/* ------------------------------------------------------------------------ */

/* `level` (nullable: "integrity") is one of m5_validation_levels.
 * {"path", "level", "profiles", "ok", "errors": n, "warnings": n,
 *  "promoted": n, "codes": […], "diagnostics": [{"code", "severity",
 *  "effective_severity", "location", "message", "level", "summary"}],
 *  "checked"}. A file that cannot be read is reported (E001), not refused. */
M5Status m5_validate_file(const char *path, const char *level, char **out_json);

/* ------------------------------------------------------------------------ */
/* Writing: create and amend                                                 */
/* ------------------------------------------------------------------------ */

typedef struct M5Writer M5Writer;

/* A new sample. options: {"sample_id": "…"|null, "subject_id": "…"|null,
 * "codec": "balanced"|"fast"|"training"|"archive"|"portable"…,
 * "profiles": [] }. Nothing is visible at `path` until commit. */
M5Status m5_writer_create(const char *path, const char *options_json, M5Writer **out);

/* Amends an existing sample, copy-on-write (spec §14.4). `out_path` NULL
 * replaces `path` on commit; otherwise the amended sample is written to
 * `out_path` and `path` is left alone. options: {"codec": null|"…",
 * "without": ["annotations/organs", "clinical", …]} — objects about to be
 * removed and written again. A top-level member ("clinical", "index") is
 * not copied at all; a nested object ("annotations/x", "images/x",
 * "transforms/x", "grids/x") is dropped from the amendment before it is
 * written again, and the commit compacts the file, so none of its bytes
 * remain. A file whose stored digests do not verify is refused (E701). */
M5Status m5_writer_amend(const char *path, const char *out_path /* nullable */,
                         const char *options_json /* nullable */, M5Writer **out);

/* Validates, writes digests (when `digests`; missing ones are always
 * stamped), and commits atomically. `out_content_id` (nullable) receives the
 * new content_id, or NULL when the writer had already committed. */
M5Status m5_writer_commit(M5Writer *writer, bool digests, char **out_content_id);
/* Discards everything written. The handle stays valid (free it). */
void m5_writer_abort(M5Writer *writer);
/* NULL-safe; aborts an uncommitted writer. */
void m5_writer_free(M5Writer *writer);

/* ---- The document ---- */

/* The document as the commit will store it in /meta. */
M5Status m5_writer_document(M5Writer *writer, char **out_json);
/* Replaces the whole document (identity, cohort, timepoints, label_set,
 * provenance, quality, deidentification, acquisition, extra, splits).
 * Checked as the engine checks each field; the writer's grids and objects
 * are not affected. */
M5Status m5_writer_set_document(M5Writer *writer, const char *document_json);
/* Merges fields into the identity / the cohort record. */
M5Status m5_writer_set_identity(M5Writer *writer, const char *fields_json);
M5Status m5_writer_set_cohort(M5Writer *writer, const char *fields_json);
/* Declares a timepoint; the first explicit one replaces the implicit tp0. */
M5Status m5_writer_add_timepoint(M5Writer *writer, const char *timepoint_id, const char *fields_json);
/* A label set as the document holds it ({"id","version","classes":[…],…});
 * "null" removes it. */
M5Status m5_writer_set_label_set(M5Writer *writer, const char *label_set_json);
/* Creates or replaces a quality record (status defaults to "draft"). */
M5Status m5_writer_set_quality(M5Writer *writer, const char *key, const char *fields_json);
/* {"type": "person"|"software"|"organization", "name", "id"?, "role"?,
 * "version"?, "qualification"?, "organization"?} → the agent JSON (with its
 * id). `out_json` is nullable. */
M5Status m5_writer_add_agent(M5Writer *writer, const char *agent_json, char **out_json);
/* {"type": "import"|"annotate"|"review"|"predict"|"resample"|"register"|
 * "derive"|"deidentify"|"transcode"|"other", "agent"?, "id"?, "started"?,
 * "ended"?, "tool"?, "inputs"?: […], "outputs"?: […], "params"?: {…}}
 * → the activity JSON (with its id). `out_json` is nullable. */
M5Status m5_writer_add_activity(M5Writer *writer, const char *activity_json, char **out_json);
/* A namespaced extension member of the document; "null" removes it. */
M5Status m5_writer_set_extra(M5Writer *writer, const char *name_space, const char *value_json);
/* Merges acquisition parameters for one image (§4.5). */
M5Status m5_writer_set_acquisition(M5Writer *writer, const char *image_id, const char *params_json);
/* The de-identification record (§11.4, at least {"method"}); "null"
 * removes it. */
M5Status m5_writer_set_deidentification(M5Writer *writer, const char *fields_json);

/* ---- Grids and images ---- */

/* A grid as MedH5Core.GridGeometry encodes it (snake_case keys; `id`
 * ignored in favour of `grid_id`): shape, spacing, origin?, direction?,
 * axis_names?, axis_kinds?, coord_system?, units?, timepoint?, frame_uid?,
 * time_values?, time_units?, patch_hint?, chunk_hint?. */
M5Status m5_writer_add_grid(M5Writer *writer, const char *grid_id, const char *grid_json);
M5Status m5_writer_remove_grid(M5Writer *writer, const char *grid_id);
/* options: {"modality" (default "OT"), "value_type", "value_units",
 * "rescale_slope", "rescale_intercept", "window_center": […],
 * "window_width": […], "channel_names": […], "valid_mask", "prov", "codec",
 * "acquisition": {…}}. `shape` is the full array shape (it must equal the
 * grid's). The data is copied. */
M5Status m5_writer_add_image(M5Writer *writer, const char *image_id, const char *grid_id,
                             const char *options_json, M5DType dtype,
                             const int64_t *shape, uint32_t ndim,
                             const void *data, size_t nbytes);
M5Status m5_writer_remove_image(M5Writer *writer, const char *image_id);
/* The engine's ImageEdit: {"modality", "value_type", "value_units",
 * "channel_names", "rescale_slope", "rescale_intercept", "window_center",
 * "window_width", "valid_mask", "prov"}; a key present sets the attribute
 * (null removes it), a key absent leaves it. */
M5Status m5_writer_set_image_attrs(M5Writer *writer, const char *image_id, const char *edit_json);

/* ---- Voxel annotations ---- */

/* A segmentation given as `n_layers` uint16 layers of the grid's spatial
 * shape (each `voxels_per_layer` long): a voxel is in class c where some
 * layer holds c. options: {"class_ids": [...] (what it can express;
 * default: the classes present plus "annotated_classes"),
 * "annotated_classes": [ids or keys] | "all" (the label set) | "present" |
 * "given"/null (every class it can express), "closure", "timepoints",
 * "prov", "quality": key | {record}, "derived_from": [annotation ids],
 * "task", "codec", "encoding": null|"auto" (the engine chooses by measuring
 * overlap) | "labelmap" | "layers" | "bitmask" | "instances" (each class
 * one object, minted an unused instance id),
 * "ignore_value": 65535 (layer values equal to it form the ignore region) |
 * null, "ignore_mask": a `mask` annotation already written}.
 * Written through the engine's label-volume writer (each distinct
 * combination of layer values is one value naming its classes), so no mask
 * per class is built; a single aligned layer is not copied. An ignored
 * voxel that also holds a class makes the ignore region the sibling mask
 * `<id>_ignore` (§7.7). */
M5Status m5_writer_add_segmentation(M5Writer *writer, const char *annotation_id, const char *grid_id,
                                    const char *options_json,
                                    uint32_t n_layers, const uint16_t *const *layers,
                                    size_t voxels_per_layer);
/* The same; `out_json` (nullable) receives what the engine chose:
 * {"kind", "stats": {overlap statistics}|null}. */
M5Status m5_writer_add_segmentation_ex(M5Writer *writer, const char *annotation_id, const char *grid_id,
                                       const char *options_json,
                                       uint32_t n_layers, const uint16_t *const *layers,
                                       size_t voxels_per_layer, char **out_json);
/* A `mask` annotation (0/1 bytes of the grid's spatial shape). options:
 * {"task": "other", "prov", "codec"}. */
M5Status m5_writer_add_mask(M5Writer *writer, const char *annotation_id, const char *grid_id,
                            const char *options_json, const uint8_t *mask, size_t voxels);
/* Drops an annotation and its index entry. */
M5Status m5_writer_remove_annotation(M5Writer *writer, const char *annotation_id);
/* Re-encodes a voxel annotation in place (§7.6), keeping its header;
 * refused where the target cannot express it. */
M5Status m5_writer_transcode_annotation(M5Writer *writer, const char *annotation_id,
                                        const char *to_kind, bool drop_identity);

/* ---- Geometric and classification annotations ---- */

/* kind: "boxes", "obb", "keypoints", "points", "contours", "polylines",
 * "mesh". Arrays are named as the stored datasets of spec §8 and 1.2 §3
 * (docs/BRIDGE.md lists them per kind); any numeric dtype, converted.
 * options: {"grid", "space": "index"|"world", "frame_uid",
 * "annotated_classes", "attributes": [{…} per object], "names": [...],
 * "correspondence", "skeleton", "task", "prov", "quality", "timepoints",
 * "closure", "derived_from", "codec"}; a class column may be given as an
 * option of the same name holding ids or label-set keys. */
M5Status m5_writer_add_geometric(M5Writer *writer, const char *kind, const char *annotation_id,
                                 const char *options_json,
                                 const M5ArrayView *arrays, size_t n_arrays);
/* A classification annotation (spec §9) from JSON:
 * {"scope": "sample"|"timepoint"|"grid"|"roi"|"slice"|"instance",
 *  "multilabel": false, "grid", "assertions": [{"class_id" (id or key),
 *  "value", "scope_id", "scheme", "scheme_value"}], "annotated_classes",
 *  "timepoints", "closure", "prov", "quality", …}. */
M5Status m5_writer_add_classification(M5Writer *writer, const char *annotation_id,
                                      const char *options_json);

/* ---- Transforms ---- */

/* An affine (spec §10.3): `matrix` is (dim × dim) row-major, dim = S + 1.
 * options: {"from_frame", "to_frame", "from_grid", "to_grid", "units",
 * "prov", "metrics": key | {record}, "invertible", "inverse_id", "codec"}. */
M5Status m5_writer_add_affine_transform(M5Writer *writer, const char *transform_id,
                                        const char *options_json,
                                        const double *matrix, uint32_t dim);
/* Any transform kind (§10): "identity", "affine" (array "matrix"),
 * "displacement" (array "field" (S, *spatial), options "field_grid",
 * "vector_space", "interpolation", "extrapolation", "field_dtype":
 * "float32"|"float16"|"auto"), "bspline" (array "control_points", options
 * "cp_grid", "order") or "composite" (options "components": [ids]); the
 * options of m5_writer_add_affine_transform besides. */
M5Status m5_writer_add_transform(M5Writer *writer, const char *transform_id, const char *kind,
                                 const char *options_json,
                                 const M5ArrayView *arrays, size_t n_arrays);
M5Status m5_writer_remove_transform(M5Writer *writer, const char *transform_id);

/* The sampling index (spec §14.3). options: {"annotations": [ids]|null (every
 * class-bearing voxel annotation), "max_coords", "occupancy": factor |
 * false, "seed"}. */
M5Status m5_writer_build_index(M5Writer *writer, const char *options_json);

/* ------------------------------------------------------------------------ */
/* Conversion, storage, collections                                          */
/* ------------------------------------------------------------------------ */

/* A NIfTI file's geometry and voxels, in medh5 conventions (axes reordered
 * to (z, y, x), world in LPS): header = the engine's read_nifti geometry
 * ({"spacing", "origin", "direction", "coord_system", "shape", "axis_order",
 * "units", "dtype", "rescale", "time_values", …}) plus "grid" (as
 * MedH5Core.GridGeometry decodes it) and "affine" (the homogeneous
 * index → world matrix of that grid); array "data" as stored in the file. */
M5Status m5_nifti_read(const char *nifti_path, M5Bundle **out);

/* Creates a sample from NIfTI files (medh5::convert::nifti::from_nifti).
 * options: {"images": {"CT": "/path/ct.nii.gz", …}, "masks": {"liver":
 * "/path", …}, "sample_id", "subject_id", "modality": "CT" | {"CT": "CT"},
 * "value_units": {…}, "coord_system", "transpose", "fourth_axis", "codec",
 * "annotated_classes", "assume_geometry", "plane_as_volume", "label_set"}.
 * Returns the conversion report ({"ok", "notes": [{kind, message,
 * severity, detail}], "outputs", …}: what was decided and guessed). */
M5Status m5_nifti_import(const char *out_path, const char *options_json, char **out_report_json);

/* Adds NIfTI masks to an existing sample as one segmentation
 * (import_seg_nifti), amending it. options: {"masks": {"liver": "/p.nii.gz",
 * …}, "annotation_id", "grid", "coord_system", "transpose",
 * "annotated_classes", "assume_aligned", "assume_geometry",
 * "plane_as_volume"}. Returns the conversion report. */
M5Status m5_nifti_import_segmentation(const char *sample_path, const char *options_json,
                                      char **out_report_json);

/* Writes one image or voxel annotation as NIfTI (to_nifti / write_nifti).
 * options: {"object": "images/CT"|"annotations/organs", "out":
 * "/path.nii.gz", "physical": true, "class": id|key (one class of an
 * annotation as 0/1)}. Returns the conversion report with "path". */
M5Status m5_nifti_export(const char *sample_path, const char *options_json, char **out_report_json);

/* Rewrites a sample's storage with a codec profile (storage::recompress).
 * options: {"profile": "portable"|…, "out": "/path"|null, "rechunk": false}.
 * Digests and content_id are unchanged; the result says so. */
M5Status m5_recompress(const char *path, const char *options_json, char **out_json);

/* The members of a .medh5c collection: {"path", "version", "kind",
 * "members": [{"name", "key", "sample_id", "subject_id", "profiles",
 * "content_id", "timepoints", "images", "annotations"}]}. */
M5Status m5_collection_list(const char *path, char **out_json);

/* Packs samples into a .medh5c collection: options {"sources": [paths],
 * "keys": [member names]|null}. `out_json` (nullable) receives {"path",
 * "members"}. */
M5Status m5_collection_pack(const char *out_path, const char *options_json, char **out_json);

/* ------------------------------------------------------------------------ */
/* Fixtures                                                                 */
/* ------------------------------------------------------------------------ */

/* Writes a synthetic demonstration sample: one subject, two timepoints
 * (baseline and follow-up CT of a phantom, plus an MR on its own grid),
 * a label set with colours and a hierarchy, segmentations in several
 * encodings (layers with an overlapping lesion, a labelmap, a probmap,
 * instances, a mask), boxes, oriented boxes, keypoints, points, contours,
 * polylines (format 1.2), meshes, a classification, an affine between the
 * visits, provenance, quality, a sampling index and a clinical history
 * (format 1.1). It validates at "strict". options: {"size": 64} (voxels per
 * axis, 16–512, default 64), {"clinical": true}, {"polylines": true},
 * {"index": true}, {"codec": "balanced"}. Deterministic. */
M5Status m5_demo_write(const char *path, const char *options_json);

/* Writes the engine's conformance corpus into `directory`
 * (medh5::conformance) and its robustness fixtures into
 * `directory/robustness`; `out_json` (nullable) receives the manifest
 * (expected.json, plus "robustness": [files] and "manifest": path). */
M5Status m5_conformance_write(const char *directory, char **out_json);

#ifdef __cplusplus
}
#endif

#endif /* MEDH5_BRIDGE_H */
