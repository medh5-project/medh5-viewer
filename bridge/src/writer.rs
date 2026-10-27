//! `M5Writer`: creating and amending samples (spec §14.4).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::{c_char, c_void};
use std::path::Path;
use std::sync::{Mutex, PoisonError};

use medh5::annotations::{Polygon, Polyline};
use medh5::array::{DType, NdArray};
use medh5::document::SampleDocument;
use medh5::labels::{ClassKey, LabelSet};
use medh5::ndarray::{Array2, ArrayD, ArrayViewD, IxDyn};
use medh5::sample::writer_annotations::FieldDtype;
use medh5::sample::{
    AnnotationOptions, GridOptions, ImageEdit, ImageOptions, LabelmapSource, ObjectFields, Placement, QualityArg,
    SampleWriter, SegmentationOptions, SegmentationSource, TransformSpec,
};
use serde_json::{json, Map, Value};

use crate::arrays::{self, M5DType};
use crate::bundle::M5ArrayView;
use crate::convert::{annotated, class_key, class_keys, opt_bool, opt_f64, opt_f64s, opt_i64, opt_str, opt_strs};
use crate::ffi::{self, guard, guard_value, BResult, BridgeError, M5Status};

/// The opaque `M5Writer`.
pub struct M5Writer {
    inner: Mutex<Option<SampleWriter>>,
}

fn writer_ref<'a>(ptr: *mut M5Writer) -> BResult<&'a M5Writer> {
    if ptr.is_null() {
        return Err(BridgeError::argument("writer is NULL"));
    }
    // SAFETY: a handle this bridge made and the caller has not freed.
    Ok(unsafe { &*ptr })
}

/// Run `f` on the writer behind the handle.
fn with_writer<T>(ptr: *mut M5Writer, f: impl FnOnce(&mut SampleWriter) -> BResult<T>) -> BResult<T> {
    let handle = writer_ref(ptr)?;
    let mut slot = handle.inner.lock().unwrap_or_else(PoisonError::into_inner);
    let writer = slot.as_mut().ok_or_else(|| BridgeError::from(medh5::Error::invalid("this writer has been freed")))?;
    f(writer)
}

fn publish(writer: SampleWriter, out: *mut *mut M5Writer) -> BResult<()> {
    let slot = ffi::arg_out(out, "out")?;
    *slot = Box::into_raw(Box::new(M5Writer { inner: Mutex::new(Some(writer)) }));
    Ok(())
}

// -- create, amend, commit -----------------------------------------------------------

#[no_mangle]
pub extern "C" fn m5_writer_create(
    path: *const c_char,
    options_json: *const c_char,
    out: *mut *mut M5Writer,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out, "out")?;
        let codec = opt_str(&options, "codec")?.unwrap_or_else(|| "balanced".into());
        let profiles = opt_strs(&options, "profiles")?.unwrap_or_default();
        let writer = medh5::sample::create(
            Path::new(path),
            opt_str(&options, "sample_id")?.as_deref(),
            opt_str(&options, "subject_id")?.as_deref(),
            &codec,
            &profiles,
        )?;
        publish(writer, out)
    })
}

/// Drop an object a nested `without` entry names from the amendment.
fn drop_object(writer: &mut SampleWriter, entry: &str) -> BResult<()> {
    let (group, name) =
        entry.split_once('/').ok_or_else(|| BridgeError::argument(format!("without entry {entry:?} is not a path")))?;
    match group {
        "annotations" => writer.remove_annotation(name)?,
        "images" => writer.remove_image(name)?,
        "transforms" => writer.remove_transform(name)?,
        "grids" => writer.remove_grid(name)?,
        other => {
            return Err(BridgeError::argument(format!(
                "without entry {entry:?}: {other:?} holds no object an amendment drops by name; name the group whole"
            )))
        }
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_writer_amend(
    path: *const c_char,
    out_path: *const c_char,
    options_json: *const c_char,
    out: *mut *mut M5Writer,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        let out_path = ffi::arg_opt_str(out_path, "out_path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out, "out")?;
        let codec = opt_str(&options, "codec")?;
        let without = opt_strs(&options, "without")?.unwrap_or_default();
        // A top-level member is left behind by the engine and never copied;
        // a nested object is copied with the graph and dropped here.
        let (top, nested): (Vec<&str>, Vec<&str>) =
            without.iter().map(|w| w.trim_matches('/')).partition(|w| !w.contains('/'));
        let target = out_path.unwrap_or(path);
        let mut writer = medh5::sample::writer::amend_into(Path::new(path), Path::new(target), codec.as_deref(), &top)?;
        for entry in nested {
            if let Err(e) = drop_object(&mut writer, entry) {
                writer.abort();
                return Err(e);
            }
        }
        publish(writer, out)
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_commit(writer: *mut M5Writer, digests: bool, out_content_id: *mut *mut c_char) -> M5Status {
    guard(|| {
        let id = with_writer(writer, |w| Ok(w.commit(digests)?))?;
        if !out_content_id.is_null() {
            // SAFETY: a caller-supplied, writable out-pointer.
            unsafe { *out_content_id = id.map(ffi::into_c_string).unwrap_or(std::ptr::null_mut()) };
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_abort(writer: *mut M5Writer) {
    guard_value((), || {
        let _ = with_writer(writer, |w| {
            w.abort();
            Ok(())
        });
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_free(writer: *mut M5Writer) {
    guard_value((), || {
        if writer.is_null() {
            return;
        }
        // SAFETY: a handle this bridge made, freed once.
        let handle = unsafe { Box::from_raw(writer) };
        let taken = handle.inner.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(mut w) = taken {
            if !w.is_closed() {
                w.abort();
            }
        }
    })
}

// -- the document --------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn m5_writer_document(writer: *mut M5Writer, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        ffi::arg_out(out_json, "out_json")?;
        let text = with_writer(writer, |w| Ok(w.document().dumps()))?;
        ffi::write_out_string(out_json, text)
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_document(writer: *mut M5Writer, document_json: *const c_char) -> M5Status {
    guard(|| {
        let text = ffi::arg_str(document_json, "document_json")?;
        let document = SampleDocument::loads(text)?;
        with_writer(writer, |w| {
            w.set_document(document);
            Ok(())
        })
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_identity(writer: *mut M5Writer, fields_json: *const c_char) -> M5Status {
    guard(|| {
        let fields = ffi::arg_json(fields_json, "fields_json")?;
        with_writer(writer, |w| w.identity(fields).map(|_| ()).map_err(Into::into))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_cohort(writer: *mut M5Writer, fields_json: *const c_char) -> M5Status {
    guard(|| {
        let fields = ffi::arg_json(fields_json, "fields_json")?;
        with_writer(writer, |w| w.cohort(fields).map(|_| ()).map_err(Into::into))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_add_timepoint(
    writer: *mut M5Writer,
    timepoint_id: *const c_char,
    fields_json: *const c_char,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(timepoint_id, "timepoint_id")?;
        let fields = ffi::arg_json(fields_json, "fields_json")?;
        with_writer(writer, |w| w.add_timepoint(id, fields).map(|_| ()).map_err(Into::into))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_label_set(writer: *mut M5Writer, label_set_json: *const c_char) -> M5Status {
    guard(|| {
        let value = ffi::arg_json_value(label_set_json, "label_set_json")?;
        let parsed = if value.is_null() { None } else { LabelSet::from_json(Some(&value))? };
        with_writer(writer, |w| {
            match parsed {
                Some(ls) => {
                    w.label_set(ls);
                }
                None => w.document_mut().label_set = None,
            }
            Ok(())
        })
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_quality(
    writer: *mut M5Writer,
    key: *const c_char,
    fields_json: *const c_char,
) -> M5Status {
    guard(|| {
        let key = ffi::arg_str(key, "key")?;
        let fields = ffi::arg_json(fields_json, "fields_json")?;
        with_writer(writer, |w| w.set_quality(key, fields).map(|_| ()).map_err(Into::into))
    })
}

/// `type`, `name` and `id` of an agent or activity record; the rest are its
/// fields.
/// A record's `type`, `id`, name (or agent) and remaining fields.
type Record = (String, Option<String>, Option<String>, Map<String, Value>);

fn split_record(mut record: Map<String, Value>, what: &str) -> BResult<Record> {
    let kind = match record.remove("type") {
        Some(Value::String(s)) => s,
        _ => return Err(BridgeError::argument(format!("{what} needs a \"type\""))),
    };
    let take = |record: &mut Map<String, Value>, key: &str| match record.remove(key) {
        Some(Value::String(s)) => Ok(Some(s)),
        None | Some(Value::Null) => Ok(None),
        Some(_) => Err(BridgeError::argument(format!("{what} \"{key}\" must be a string"))),
    };
    let id = take(&mut record, "id")?;
    let name = take(&mut record, if what == "agent" { "name" } else { "agent" })?;
    Ok((kind, id, name, record))
}

#[no_mangle]
pub extern "C" fn m5_writer_add_agent(
    writer: *mut M5Writer,
    agent_json: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let record = ffi::arg_json(agent_json, "agent_json")?;
        let (kind, id, name, fields) = split_record(record, "agent")?;
        let name = name.ok_or_else(|| BridgeError::argument("an agent needs a \"name\""))?;
        let agent = with_writer(writer, |w| Ok(w.agent(&kind, &name, id.as_deref(), fields)?))?;
        if !out_json.is_null() {
            ffi::write_out_json(out_json, &agent.to_json())?;
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_add_activity(
    writer: *mut M5Writer,
    activity_json: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let record = ffi::arg_json(activity_json, "activity_json")?;
        let (kind, id, agent, fields) = split_record(record, "activity")?;
        let activity = with_writer(writer, |w| Ok(w.activity(&kind, agent.as_deref(), id.as_deref(), fields)?))?;
        if !out_json.is_null() {
            ffi::write_out_json(out_json, &activity.to_json())?;
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_extra(
    writer: *mut M5Writer,
    name_space: *const c_char,
    value_json: *const c_char,
) -> M5Status {
    guard(|| {
        let ns = ffi::arg_str(name_space, "name_space")?;
        let value = ffi::arg_json_value(value_json, "value_json")?;
        with_writer(writer, |w| {
            if value.is_null() {
                w.document_mut().extra.remove(ns);
            } else {
                w.extra(ns, value);
            }
            Ok(())
        })
    })
}

/// Merge acquisition parameters for one image (§4.5).
#[no_mangle]
pub extern "C" fn m5_writer_set_acquisition(
    writer: *mut M5Writer,
    image_id: *const c_char,
    params_json: *const c_char,
) -> M5Status {
    guard(|| {
        let image = ffi::arg_str(image_id, "image_id")?;
        let params = ffi::arg_json(params_json, "params_json")?;
        with_writer(writer, |w| {
            w.acquisition(image, params);
            Ok(())
        })
    })
}

/// Set the de-identification record (§11.4); `null` removes it.
#[no_mangle]
pub extern "C" fn m5_writer_set_deidentification(writer: *mut M5Writer, fields_json: *const c_char) -> M5Status {
    guard(|| {
        let value = ffi::arg_json_value(fields_json, "fields_json")?;
        with_writer(writer, |w| {
            match value {
                Value::Null => w.document_mut().deidentification = None,
                Value::Object(fields) => {
                    w.deidentification(fields)?;
                }
                _ => return Err(BridgeError::argument("a de-identification record is an object or null")),
            }
            Ok(())
        })
    })
}

// -- grids and images ----------------------------------------------------------------

/// A grid as `MedH5Core.GridGeometry` encodes it.
pub fn grid_options(grid: &Map<String, Value>) -> BResult<(Vec<i64>, Vec<f64>, GridOptions)> {
    let shape: Vec<i64> = match grid.get("shape") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_i64().ok_or_else(|| BridgeError::argument("grid shape must be integers")))
            .collect::<BResult<_>>()?,
        _ => return Err(BridgeError::argument("a grid needs \"shape\"")),
    };
    let spacing = opt_f64s(grid, "spacing")?.ok_or_else(|| BridgeError::argument("a grid needs \"spacing\""))?;
    let direction = match grid.get("direction") {
        None | Some(Value::Null) => None,
        Some(Value::Array(rows)) => {
            let n = rows.len();
            let mut flat = Vec::with_capacity(n * n);
            for row in rows {
                let values = row.as_array().ok_or_else(|| BridgeError::argument("direction rows must be arrays"))?;
                if values.len() != n {
                    return Err(BridgeError::argument("direction must be square"));
                }
                for v in values {
                    flat.push(v.as_f64().ok_or_else(|| BridgeError::argument("direction must be numbers"))?);
                }
            }
            Some(Array2::from_shape_vec((n, n), flat)?)
        }
        Some(_) => return Err(BridgeError::argument("direction must be an array of rows")),
    };
    let ints = |key: &str| -> BResult<Option<Vec<i64>>> {
        match grid.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Array(items)) => items
                .iter()
                .map(|v| v.as_i64().ok_or_else(|| BridgeError::argument(format!("{key} must be integers"))))
                .collect::<BResult<Vec<_>>>()
                .map(Some),
            Some(_) => Err(BridgeError::argument(format!("{key} must be integers"))),
        }
    };
    let options = GridOptions {
        origin: opt_f64s(grid, "origin")?,
        direction,
        axis_names: opt_strs(grid, "axis_names")?,
        axis_kinds: opt_strs(grid, "axis_kinds")?,
        coord_system: opt_str(grid, "coord_system")?,
        units: opt_str(grid, "units")?,
        timepoint: opt_str(grid, "timepoint")?,
        frame_uid: opt_str(grid, "frame_uid")?,
        patch_hint: ints("patch_hint")?,
        chunk_hint: ints("chunk_hint")?,
        time_values: opt_f64s(grid, "time_values")?,
        time_units: opt_str(grid, "time_units")?,
    };
    Ok((shape, spacing, options))
}

#[no_mangle]
pub extern "C" fn m5_writer_add_grid(
    writer: *mut M5Writer,
    grid_id: *const c_char,
    grid_json: *const c_char,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(grid_id, "grid_id")?;
        let grid = ffi::arg_json(grid_json, "grid_json")?;
        let (shape, spacing, options) = grid_options(&grid)?;
        with_writer(writer, |w| w.add_grid(id, &shape, &spacing, options).map(|_| ()).map_err(Into::into))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_remove_grid(writer: *mut M5Writer, grid_id: *const c_char) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(grid_id, "grid_id")?;
        with_writer(writer, |w| Ok(w.remove_grid(id)?))
    })
}

/// A caller array of `shape` (`ndim` extents), copied into an engine array.
fn array_arg(dtype: DType, shape: *const i64, ndim: u32, data: *const c_void, nbytes: usize) -> BResult<NdArray> {
    if ndim > 0 && shape.is_null() {
        return Err(BridgeError::argument("shape is NULL"));
    }
    // SAFETY: the caller passes `ndim` extents.
    let extents = if ndim == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(shape, ndim as usize) } };
    let shape: Vec<usize> = extents
        .iter()
        .map(|v| usize::try_from(*v).map_err(|_| BridgeError::argument(format!("negative extent {v}"))))
        .collect::<BResult<_>>()?;
    let count = shape
        .iter()
        .try_fold(1usize, |n, e| n.checked_mul(*e))
        .ok_or_else(|| BridgeError::argument("shape overflows"))?;
    let expected = count.checked_mul(dtype.itemsize()).ok_or_else(|| BridgeError::argument("shape overflows"))?;
    if nbytes != expected {
        return Err(BridgeError::argument(format!(
            "{nbytes} bytes for shape {shape:?} of {}; expected {expected}",
            dtype.name()
        )));
    }
    if expected > 0 && data.is_null() {
        return Err(BridgeError::argument("data is NULL"));
    }
    // SAFETY: the caller passes `nbytes` readable bytes.
    let bytes = if expected == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(data as *const u8, nbytes) } };
    arrays::from_bytes(dtype, &shape, bytes)
}

fn quality_arg(options: &Map<String, Value>, key: &str) -> BResult<Option<QualityArg>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(QualityArg::Key(s.clone()))),
        Some(Value::Object(m)) => Ok(Some(QualityArg::Record(m.clone()))),
        Some(_) => Err(BridgeError::argument(format!("{key} is a quality key or a record"))),
    }
}

#[no_mangle]
pub extern "C" fn m5_writer_add_image(
    writer: *mut M5Writer,
    image_id: *const c_char,
    grid_id: *const c_char,
    options_json: *const c_char,
    dtype: M5DType,
    shape: *const i64,
    ndim: u32,
    data: *const c_void,
    nbytes: usize,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(image_id, "image_id")?;
        let grid = ffi::arg_str(grid_id, "grid_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let dtype = arrays::required_dtype(dtype, "dtype")?;
        let array = array_arg(dtype, shape, ndim, data, nbytes)?;
        let modality = opt_str(&options, "modality")?.unwrap_or_else(|| "OT".into());
        let image_options = ImageOptions {
            value_type: opt_str(&options, "value_type")?,
            value_units: opt_str(&options, "value_units")?,
            channel_names: opt_strs(&options, "channel_names")?,
            rescale_slope: opt_f64(&options, "rescale_slope")?,
            rescale_intercept: opt_f64(&options, "rescale_intercept")?,
            window_center: opt_f64s(&options, "window_center")?,
            window_width: opt_f64s(&options, "window_width")?,
            valid_mask: opt_str(&options, "valid_mask")?,
            prov: opt_str(&options, "prov")?,
            codec: opt_str(&options, "codec")?,
        };
        let acquisition = match options.get("acquisition") {
            Some(Value::Object(m)) => Some(m.clone()),
            _ => None,
        };
        with_writer(writer, |w| {
            w.add_image(id, &array, grid, &modality, image_options)?;
            if let Some(params) = acquisition {
                w.acquisition(id, params);
            }
            Ok(())
        })
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_remove_image(writer: *mut M5Writer, image_id: *const c_char) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(image_id, "image_id")?;
        with_writer(writer, |w| Ok(w.remove_image(id)?))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_set_image_attrs(
    writer: *mut M5Writer,
    image_id: *const c_char,
    edit_json: *const c_char,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(image_id, "image_id")?;
        let edit_map = ffi::arg_json(edit_json, "edit_json")?;
        let mut edit = ImageEdit::default();
        // A key present sets (or, as null, removes) the attribute; a key
        // absent leaves it alone.
        fn present<T>(
            map: &Map<String, Value>,
            key: &str,
            get: impl Fn(&Map<String, Value>, &str) -> BResult<Option<T>>,
        ) -> BResult<Option<Option<T>>> {
            if map.contains_key(key) {
                Ok(Some(get(map, key)?))
            } else {
                Ok(None)
            }
        }
        edit.modality = present(&edit_map, "modality", opt_str)?;
        edit.value_type = present(&edit_map, "value_type", opt_str)?;
        edit.value_units = present(&edit_map, "value_units", opt_str)?;
        edit.channel_names = present(&edit_map, "channel_names", opt_strs)?;
        edit.rescale_slope = present(&edit_map, "rescale_slope", opt_f64)?;
        edit.rescale_intercept = present(&edit_map, "rescale_intercept", opt_f64)?;
        edit.window_center = present(&edit_map, "window_center", opt_f64s)?;
        edit.window_width = present(&edit_map, "window_width", opt_f64s)?;
        edit.valid_mask = present(&edit_map, "valid_mask", opt_str)?;
        edit.prov = present(&edit_map, "prov", opt_str)?;
        let known = [
            "modality",
            "value_type",
            "value_units",
            "channel_names",
            "rescale_slope",
            "rescale_intercept",
            "window_center",
            "window_width",
            "valid_mask",
            "prov",
        ];
        if let Some(unknown) = edit_map.keys().find(|k| !known.contains(&k.as_str())) {
            return Err(BridgeError::argument(format!("{unknown:?} is not an image attribute an edit sets")));
        }
        with_writer(writer, |w| Ok(w.set_image_attrs(id, edit)?))
    })
}

// -- voxel annotations ---------------------------------------------------------------

/// The options every annotation writer shares.
pub fn annotation_options(options: &Map<String, Value>) -> BResult<AnnotationOptions> {
    Ok(AnnotationOptions {
        annotated_classes: annotated(options, "annotated_classes")?,
        closure: opt_str(options, "closure")?,
        timepoints: opt_strs(options, "timepoints")?,
        prov: opt_str(options, "prov")?,
        quality: quality_arg(options, "quality")?,
        derived_from: opt_strs(options, "derived_from")?.unwrap_or_default(),
        task: opt_str(options, "task")?,
        codec: opt_str(options, "codec")?,
    })
}

/// The ignore value of a layered segmentation: 65535 unless the options say
/// otherwise (`null`: none).
fn ignore_value(options: &Map<String, Value>) -> BResult<Option<u16>> {
    match options.get("ignore_value") {
        None => Ok(Some(u16::MAX)),
        Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .and_then(|n| u16::try_from(n).ok())
            .filter(|n| *n != 0)
            .map(Some)
            .ok_or_else(|| BridgeError::argument("ignore_value is a uint16 other than 0, or null")),
    }
}

/// A segmentation given as `uint16` layers, written through the engine's
/// label-volume writer: each distinct combination of layer values is one
/// value of a label volume naming the classes it holds, so the masks are
/// never built and the engine measures and encodes exactly what they would
/// have said (§7.1–§7.6).
pub fn add_segmentation(
    w: &mut SampleWriter,
    ann_id: &str,
    grid: &str,
    options: &Map<String, Value>,
    layers: &[&[u16]],
) -> BResult<Value> {
    let target = w.grid_ref(grid)?.clone();
    let spatial = target.spatial_shape();
    let voxels: usize = spatial.iter().product();
    for (i, layer) in layers.iter().enumerate() {
        if layer.len() != voxels {
            return Err(BridgeError::argument(format!(
                "layer {i} has {} voxels; grid {grid:?} has {voxels} {spatial:?}",
                layer.len()
            )));
        }
    }
    let ignore = ignore_value(options)?;
    let encoding = opt_str(options, "encoding")?.unwrap_or_else(|| "auto".into());
    let common = annotation_options(options)?;
    let wanted: Vec<i64> = match class_keys(options, "class_ids")? {
        Some(keys) => keys.iter().map(|k| w.class_id(k)).collect::<medh5::Result<_>>()?,
        None => Vec::new(),
    };
    let named: Vec<i64> = match &common.annotated_classes {
        medh5::sample::Annotated::Classes(keys) => keys.iter().map(|k| w.class_id(k)).collect::<medh5::Result<_>>()?,
        _ => Vec::new(),
    };
    let present_only = matches!(options.get("annotated_classes"), Some(Value::String(s)) if s == "present");

    // One value per distinct combination of layer values.
    let mut has_ignore = false;
    let mut conflict = false;
    let single = layers.len() == 1;
    let mut present: BTreeSet<i64> = BTreeSet::new();
    let mut combos: Vec<Vec<i64>> = vec![Vec::new()]; // code -> classes; 0 is background
    let mut codes: Vec<u32> = Vec::new();
    if single {
        let mut seen = vec![false; 65536];
        for v in layers[0] {
            seen[*v as usize] = true;
        }
        for (value, hit) in seen.iter().enumerate() {
            if *hit && value != 0 {
                if Some(value as u16) == ignore {
                    has_ignore = true;
                } else {
                    present.insert(value as i64);
                }
            }
        }
    } else {
        codes = vec![0u32; voxels];
        let mut table: HashMap<Vec<u16>, u32> = HashMap::new();
        let mut key = vec![0u16; layers.len()];
        let mut last: Option<(Vec<u16>, u32)> = None;
        const IGNORED: u32 = 1;
        combos.push(Vec::new()); // code 1: the ignore region
        'voxels: for (v, code) in codes.iter_mut().enumerate() {
            let mut any = false;
            let mut ignored = false;
            for (k, layer) in key.iter_mut().zip(layers) {
                let x = layer[v];
                if Some(x) == ignore {
                    ignored = true;
                    *k = 0;
                } else {
                    *k = x;
                    any |= x != 0;
                }
            }
            if ignored {
                has_ignore = true;
                if any {
                    conflict = true;
                    break 'voxels;
                }
                *code = IGNORED;
                continue;
            }
            if !any {
                continue;
            }
            if let Some((k, c)) = &last {
                if *k == key {
                    *code = *c;
                    continue;
                }
            }
            let next = combos.len() as u32;
            let c = *table.entry(key.clone()).or_insert_with(|| {
                let mut classes: Vec<i64> = key.iter().filter(|x| **x != 0).map(|x| i64::from(*x)).collect();
                classes.sort_unstable();
                classes.dedup();
                combos.push(classes);
                next
            });
            for class in &combos[c as usize] {
                present.insert(*class);
            }
            *code = c;
            last = Some((key.clone(), c));
        }
    }

    let mut annotation_options = common.clone();
    if present_only {
        annotation_options.annotated_classes =
            medh5::sample::Annotated::Classes(present.iter().map(|c| ClassKey::Id(*c)).collect());
    }
    // Classes the annotation can express without holding a voxel of.
    let mut absent: Vec<i64> = wanted.iter().chain(&named).copied().filter(|c| !present.contains(c)).collect();
    absent.sort_unstable();
    absent.dedup();
    let segmentation = |common: AnnotationOptions| SegmentationOptions {
        encoding: Some(encoding.clone()),
        threshold: None,
        ignore: None,
        ignore_mask: None,
        common,
    };
    let mut seg_options = segmentation(annotation_options);
    seg_options.ignore_mask = opt_str(options, "ignore_mask")?;

    let (kind, stats) = if conflict {
        // An ignored voxel that also holds a class: the ignore region
        // overlaps a class, so it is written as the sibling mask, from
        // masks (§7.7).
        let mut masks: BTreeMap<i64, ArrayD<bool>> = BTreeMap::new();
        let mut region = ArrayD::from_elem(IxDyn(&spatial), false);
        for layer in layers {
            let flat_region = region.as_slice_mut().expect("standard layout");
            for (v, x) in layer.iter().enumerate() {
                if Some(*x) == ignore {
                    flat_region[v] = true;
                } else if *x != 0 {
                    let mask = masks.entry(i64::from(*x)).or_insert_with(|| ArrayD::from_elem(IxDyn(&spatial), false));
                    mask.as_slice_mut().expect("standard layout")[v] = true;
                }
            }
        }
        for c in &absent {
            masks.entry(*c).or_insert_with(|| ArrayD::from_elem(IxDyn(&spatial), false));
        }
        seg_options.ignore = Some(region);
        let source = SegmentationSource::Masks(masks.into_iter().map(|(c, m)| (ClassKey::Id(c), m)).collect());
        w.add_segmentation(ann_id, grid, source, seg_options)?
    } else if single {
        let mut map: Vec<(i64, Vec<ClassKey>)> = present.iter().map(|c| (*c, vec![ClassKey::Id(*c)])).collect();
        map.extend(absent.iter().filter(|c| Some(**c) != ignore.map(i64::from)).map(|c| (*c, vec![ClassKey::Id(*c)])));
        let view = ArrayViewD::from_shape(IxDyn(&spatial), layers[0])?;
        let mut source = LabelmapSource::new(view).values(map);
        if has_ignore {
            source = source.ignore_value(i64::from(ignore.expect("an ignored voxel has an ignore value")));
        }
        w.add_segmentation_labelmap(ann_id, grid, source, seg_options)?
    } else {
        let mut map: Vec<(i64, Vec<ClassKey>)> = combos
            .iter()
            .enumerate()
            .skip(2)
            .map(|(code, classes)| (code as i64, classes.iter().map(|c| ClassKey::Id(*c)).collect()))
            .collect();
        for (next, c) in (combos.len() as i64..).zip(absent.iter()) {
            map.push((next, vec![ClassKey::Id(*c)]));
        }
        let view = ArrayViewD::from_shape(IxDyn(&spatial), &codes[..])?;
        let mut source = LabelmapSource::new(view).values(map);
        if has_ignore {
            source = source.ignore_value(1);
        }
        w.add_segmentation_labelmap(ann_id, grid, source, seg_options)?
    };
    Ok(json!({"kind": kind, "stats": stats.map(|s| s.summary())}))
}

/// The layers the caller passed, borrowed (copied only when misaligned).
fn layer_args<'a>(
    n_layers: u32,
    layers: *const *const u16,
    voxels: usize,
    owned: &'a mut Vec<Vec<u16>>,
) -> BResult<Vec<&'a [u16]>> {
    if n_layers == 0 {
        return Ok(Vec::new());
    }
    if layers.is_null() {
        return Err(BridgeError::argument("layers is NULL"));
    }
    // SAFETY: the caller passes `n_layers` layer pointers.
    let pointers = unsafe { std::slice::from_raw_parts(layers, n_layers as usize) };
    let mut aligned = Vec::new();
    for (i, p) in pointers.iter().enumerate() {
        if p.is_null() && voxels > 0 {
            return Err(BridgeError::argument(format!("layer {i} is NULL")));
        }
        if voxels == 0 {
            aligned.push(None);
        } else if (*p as usize) % std::mem::align_of::<u16>() != 0 {
            let mut copy = vec![0u16; voxels];
            // SAFETY: `voxels` elements, read bytewise from a misaligned pointer.
            unsafe { std::ptr::copy_nonoverlapping(*p as *const u8, copy.as_mut_ptr() as *mut u8, voxels * 2) };
            owned.push(copy);
            aligned.push(Some(owned.len() - 1));
        } else {
            aligned.push(None);
        }
    }
    let owned: &'a Vec<Vec<u16>> = owned;
    Ok(pointers
        .iter()
        .zip(aligned)
        .map(|(p, copy)| match copy {
            Some(index) => owned[index].as_slice(),
            // SAFETY: an aligned pointer to `voxels` elements, alive for the call.
            None if voxels > 0 => unsafe { std::slice::from_raw_parts(*p, voxels) },
            None => &[][..],
        })
        .collect())
}

#[no_mangle]
pub extern "C" fn m5_writer_add_segmentation(
    writer: *mut M5Writer,
    annotation_id: *const c_char,
    grid_id: *const c_char,
    options_json: *const c_char,
    n_layers: u32,
    layers: *const *const u16,
    voxels_per_layer: usize,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let grid = ffi::arg_str(grid_id, "grid_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let mut owned = Vec::new();
        let layers = layer_args(n_layers, layers, voxels_per_layer, &mut owned)?;
        if layers.is_empty() {
            return Err(BridgeError::argument("a segmentation needs at least one layer"));
        }
        with_writer(writer, |w| add_segmentation(w, id, grid, &options, &layers).map(|_| ()))
    })
}

/// The same, returning what the engine chose (`{"kind", "stats"}`).
#[no_mangle]
pub extern "C" fn m5_writer_add_segmentation_ex(
    writer: *mut M5Writer,
    annotation_id: *const c_char,
    grid_id: *const c_char,
    options_json: *const c_char,
    n_layers: u32,
    layers: *const *const u16,
    voxels_per_layer: usize,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let grid = ffi::arg_str(grid_id, "grid_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let mut owned = Vec::new();
        let layers = layer_args(n_layers, layers, voxels_per_layer, &mut owned)?;
        if layers.is_empty() {
            return Err(BridgeError::argument("a segmentation needs at least one layer"));
        }
        let result = with_writer(writer, |w| add_segmentation(w, id, grid, &options, &layers))?;
        if !out_json.is_null() {
            ffi::write_out_json(out_json, &result)?;
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_add_mask(
    writer: *mut M5Writer,
    annotation_id: *const c_char,
    grid_id: *const c_char,
    options_json: *const c_char,
    mask: *const u8,
    voxels: usize,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let grid = ffi::arg_str(grid_id, "grid_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        if voxels > 0 && mask.is_null() {
            return Err(BridgeError::argument("mask is NULL"));
        }
        // SAFETY: the caller passes `voxels` bytes.
        let bytes = if voxels == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(mask, voxels) } };
        let task = opt_str(&options, "task")?.unwrap_or_else(|| "other".into());
        let prov = opt_str(&options, "prov")?;
        let codec = opt_str(&options, "codec")?;
        with_writer(writer, |w| {
            let spatial = w.grid_ref(grid)?.spatial_shape();
            if spatial.iter().product::<usize>() != voxels {
                return Err(BridgeError::argument(format!("{voxels} mask voxels; grid {grid:?} has {spatial:?}")));
            }
            let array = ArrayD::from_shape_vec(IxDyn(&spatial), bytes.iter().map(|b| *b != 0).collect())?;
            Ok(w.add_mask(id, array, grid, &task, prov.as_deref(), codec.as_deref())?)
        })
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_remove_annotation(writer: *mut M5Writer, annotation_id: *const c_char) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        with_writer(writer, |w| Ok(w.remove_annotation(id)?))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_transcode_annotation(
    writer: *mut M5Writer,
    annotation_id: *const c_char,
    to_kind: *const c_char,
    drop_identity: bool,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let kind = ffi::arg_str(to_kind, "to_kind")?;
        with_writer(writer, |w| w.transcode_annotation(id, kind, None, drop_identity).map(|_| ()).map_err(Into::into))
    })
}

// -- geometric and classification annotations ---------------------------------------

/// The named arrays a caller passed, copied into engine arrays.
fn array_views(arrays: *const M5ArrayView, n: usize) -> BResult<HashMap<String, NdArray>> {
    if n == 0 {
        return Ok(HashMap::new());
    }
    if arrays.is_null() {
        return Err(BridgeError::argument("arrays is NULL"));
    }
    // SAFETY: the caller passes `n` views.
    let views = unsafe { std::slice::from_raw_parts(arrays, n) };
    let mut out = HashMap::new();
    for view in views {
        let name = ffi::arg_str(view.name, "array name")?.to_string();
        let dtype = arrays::required_dtype(view.dtype, &name)?;
        let array = array_arg(dtype, view.shape, view.ndim, view.data, view.nbytes)?;
        if out.insert(name.clone(), array).is_some() {
            return Err(BridgeError::argument(format!("array {name:?} is given twice")));
        }
    }
    Ok(out)
}

struct Arrays(HashMap<String, NdArray>);

impl Arrays {
    fn f64(&self, name: &str) -> Option<ArrayD<f64>> {
        self.0.get(name).map(|a| a.to_f64())
    }

    fn need_f64(&self, name: &str, kind: &str) -> BResult<ArrayD<f64>> {
        self.f64(name).ok_or_else(|| BridgeError::argument(format!("a {kind} annotation needs the array {name:?}")))
    }

    fn i64s(&self, name: &str) -> Option<Vec<i64>> {
        self.0.get(name).map(|a| a.cast::<i64>().iter().copied().collect())
    }

    fn u64s(&self, name: &str) -> Option<Vec<u64>> {
        self.0.get(name).map(|a| a.cast::<u64>().iter().copied().collect())
    }

    fn f64s(&self, name: &str) -> Option<Vec<f64>> {
        self.0.get(name).map(|a| a.to_f64().iter().copied().collect())
    }
}

/// Class keys: the option `name` (ids or keys) over the array of that name.
fn classes_of(options: &Map<String, Value>, arrays: &Arrays, name: &str) -> BResult<Option<Vec<ClassKey>>> {
    if let Some(keys) = class_keys(options, name)? {
        return Ok(Some(keys));
    }
    Ok(arrays.i64s(name).map(|ids| ids.into_iter().map(ClassKey::Id).collect()))
}

fn objects(options: &Map<String, Value>, arrays: &Arrays) -> BResult<ObjectFields> {
    let attributes = match options.get("attributes") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) => Some(
            items
                .iter()
                .map(|v| match v {
                    Value::Object(m) => Ok(m.clone()),
                    Value::Null => Ok(Map::new()),
                    _ => Err(BridgeError::argument("attributes are objects, one per object")),
                })
                .collect::<BResult<Vec<_>>>()?,
        ),
        Some(_) => return Err(BridgeError::argument("attributes is a list of objects")),
    };
    Ok(ObjectFields { instance_ids: arrays.u64s("instance_ids"), scores: arrays.f64s("scores"), attributes })
}

fn rows_between(offsets: &[i64], i: usize, n: usize) -> BResult<(usize, usize)> {
    let (a, b) = (offsets[i], offsets[i + 1]);
    if a < 0 || b < a || b as usize > n {
        return Err(BridgeError::argument(format!("offsets [{a}, {b}) do not delimit {n} vertices")));
    }
    Ok((a as usize, b as usize))
}

fn planes_of(arrays: &Arrays, name: &str, m: usize) -> BResult<Vec<(i64, i64)>> {
    match arrays.i64s(name) {
        None => Ok(vec![(-1, 0); m]),
        Some(flat) if flat.len() == 2 * m => Ok(flat.chunks(2).map(|p| (p[0], p[1])).collect()),
        Some(flat) => {
            Err(BridgeError::argument(format!("{name} has {} values for {m} items; (M, 2) expected", flat.len())))
        }
    }
}

pub fn add_geometric(
    w: &mut SampleWriter,
    kind: &str,
    ann_id: &str,
    options: &Map<String, Value>,
    arrays: HashMap<String, NdArray>,
) -> BResult<()> {
    let arrays = Arrays(arrays);
    let placement = Placement {
        grid: opt_str(options, "grid")?,
        space: opt_str(options, "space")?,
        frame_uid: opt_str(options, "frame_uid")?,
    };
    let common = annotation_options(options)?;
    let need_classes = |name: &str| -> BResult<Vec<ClassKey>> {
        classes_of(options, &arrays, name)?
            .ok_or_else(|| BridgeError::argument(format!("a {kind} annotation needs {name:?}")))
    };
    match kind {
        "boxes" => {
            let boxes = arrays.need_f64("boxes", kind)?;
            let classes = need_classes("class_ids")?;
            w.add_boxes(
                ann_id,
                &boxes,
                &classes,
                objects(options, &arrays)?,
                arrays.i64s("slice_index"),
                placement,
                common,
            )?;
        }
        "obb" => {
            let centers = arrays.need_f64("centers", kind)?;
            let sizes = arrays.need_f64("sizes", kind)?;
            let rotations = arrays.need_f64("rotations", kind)?;
            let classes = need_classes("class_ids")?;
            w.add_obb(ann_id, &centers, &sizes, &rotations, &classes, objects(options, &arrays)?, placement, common)?;
        }
        "keypoints" => {
            let points = arrays.need_f64("points", kind)?;
            let slots = need_classes("keypoint_class_ids")?;
            let classes = need_classes("class_ids")?;
            let visibility = arrays.0.get("visibility").map(|a| a.cast::<i64>());
            let skeleton = opt_str(options, "skeleton")?;
            let mut fields = objects(options, &arrays)?;
            fields.attributes = None;
            w.add_keypoints(
                ann_id,
                &points,
                &slots,
                &classes,
                visibility.as_ref(),
                fields,
                skeleton.as_deref(),
                placement,
                common,
            )?;
        }
        "points" => {
            let points = arrays.need_f64("points", kind)?;
            let classes = classes_of(options, &arrays, "class_ids")?;
            let ids = arrays.u64s("instance_ids");
            let names = opt_strs(options, "names")?;
            let weights = arrays.f64s("weights");
            let correspondence = opt_str(options, "correspondence")?;
            w.add_points(
                ann_id,
                &points,
                classes.as_deref(),
                ids.as_deref(),
                names.as_deref(),
                weights.as_deref(),
                correspondence.as_deref(),
                placement,
                common,
            )?;
        }
        "contours" => {
            let vertices = arrays.need_f64("vertices", kind)?;
            let offsets =
                arrays.i64s("contour_offsets").ok_or_else(|| BridgeError::argument("contours need contour_offsets"))?;
            let m = offsets.len().saturating_sub(1);
            let classes: Vec<i64> = match classes_of(options, &arrays, "contour_class_ids")? {
                Some(keys) => keys.iter().map(|k| w.class_id(k)).collect::<medh5::Result<_>>()?,
                None => return Err(BridgeError::argument("contours need contour_class_ids")),
            };
            let planes = planes_of(&arrays, "contour_plane", m)?;
            let roles = arrays.i64s("contour_role").unwrap_or_else(|| vec![0; m]);
            if classes.len() != m || roles.len() != m {
                return Err(BridgeError::argument(format!(
                    "{m} contours, {} classes, {} roles",
                    classes.len(),
                    roles.len()
                )));
            }
            let n = vertices.shape().first().copied().unwrap_or(0);
            let s = vertices.shape().get(1).copied().unwrap_or(0);
            let mut polygons = Vec::with_capacity(m);
            for i in 0..m {
                let (a, b) = rows_between(&offsets, i, n)?;
                let rows = vertices.slice_axis(medh5::ndarray::Axis(0), medh5::ndarray::Slice::from(a..b)).to_owned();
                let role = match roles[i] {
                    0 => "outer",
                    1 => "hole",
                    other => return Err(BridgeError::argument(format!("contour role {other}; 0 outer, 1 hole"))),
                };
                polygons.push(Polygon::new(
                    rows.into_shape_with_order(IxDyn(&[b - a, s]))?,
                    classes[i],
                    planes[i],
                    role,
                )?);
            }
            w.add_contours(ann_id, &polygons, placement, common)?;
        }
        "polylines" => {
            let vertices = arrays.need_f64("vertices", kind)?;
            let offsets = arrays
                .i64s("polyline_offsets")
                .ok_or_else(|| BridgeError::argument("polylines need polyline_offsets"))?;
            let m = offsets.len().saturating_sub(1);
            let classes: Vec<i64> = match classes_of(options, &arrays, "polyline_class_ids")? {
                Some(keys) => keys.iter().map(|k| w.class_id(k)).collect::<medh5::Result<_>>()?,
                None => return Err(BridgeError::argument("polylines need polyline_class_ids")),
            };
            if classes.len() != m {
                return Err(BridgeError::argument(format!("{m} polylines, {} classes", classes.len())));
            }
            let planes = planes_of(&arrays, "polyline_plane", m)?;
            let ids = arrays.u64s("instance_ids");
            let n = vertices.shape().first().copied().unwrap_or(0);
            let s = vertices.shape().get(1).copied().unwrap_or(0);
            let mut lines = Vec::with_capacity(m);
            for i in 0..m {
                let (a, b) = rows_between(&offsets, i, n)?;
                let rows = vertices.slice_axis(medh5::ndarray::Axis(0), medh5::ndarray::Slice::from(a..b)).to_owned();
                let mut line = Polyline::new(rows.into_shape_with_order(IxDyn(&[b - a, s]))?, classes[i])
                    .plane(planes[i].0, planes[i].1);
                if let Some(ids) = &ids {
                    let id = ids.get(i).ok_or_else(|| BridgeError::argument("one instance id per polyline"))?;
                    line = line.instance_id(*id);
                }
                lines.push(line);
            }
            w.add_polylines(ann_id, &lines, &placement, &common)?;
        }
        "mesh" => {
            let vertices = arrays.need_f64("vertices", kind)?;
            let faces = arrays
                .0
                .get("faces")
                .map(|a| a.cast::<i64>())
                .ok_or_else(|| BridgeError::argument("a mesh needs faces"))?;
            let normals = arrays.f64("normals");
            let vertex_classes = classes_of(options, &arrays, "vertex_class_ids")?;
            let offsets = arrays.i64s("mesh_offsets");
            let mesh_classes = classes_of(options, &arrays, "mesh_class_ids")?;
            w.add_mesh(
                ann_id,
                &vertices,
                &faces,
                normals.as_ref(),
                vertex_classes.as_deref(),
                offsets.as_deref(),
                mesh_classes.as_deref(),
                placement,
                common,
            )?;
        }
        other => {
            return Err(BridgeError::argument(format!(
                "kind {other:?} is not a geometric kind (boxes, obb, keypoints, points, contours, polylines, mesh)"
            )))
        }
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_writer_add_geometric(
    writer: *mut M5Writer,
    kind: *const c_char,
    annotation_id: *const c_char,
    options_json: *const c_char,
    arrays: *const M5ArrayView,
    n_arrays: usize,
) -> M5Status {
    guard(|| {
        let kind = ffi::arg_str(kind, "kind")?;
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let arrays = array_views(arrays, n_arrays)?;
        with_writer(writer, |w| add_geometric(w, kind, id, &options, arrays))
    })
}

pub fn add_classification(w: &mut SampleWriter, ann_id: &str, options: &Map<String, Value>) -> BResult<()> {
    let scope = opt_str(options, "scope")?.unwrap_or_else(|| "sample".into());
    let multilabel = opt_bool(options, "multilabel")?.unwrap_or(false);
    let grid = opt_str(options, "grid")?;
    let items = match options.get("assertions") {
        Some(Value::Array(items)) => items.clone(),
        None | Some(Value::Null) => Vec::new(),
        Some(_) => return Err(BridgeError::argument("assertions is a list")),
    };
    let mut assertions = medh5::annotations::Assertions::default();
    let mut scope_ids = Vec::new();
    let mut schemes = Vec::new();
    let mut scheme_values = Vec::new();
    let (mut any_scope, mut any_scheme, mut any_value) = (false, false, false);
    for item in &items {
        let m = item.as_object().ok_or_else(|| BridgeError::argument("an assertion is an object"))?;
        let class = m
            .get("class_id")
            .or_else(|| m.get("class"))
            .ok_or_else(|| BridgeError::argument("an assertion names its class_id"))?;
        assertions.class_ids.push(w.class_id(&class_key(class)?)?);
        assertions.values.push(opt_f64(m, "value")?.unwrap_or(1.0));
        let scope_id = opt_i64(m, "scope_id")?;
        any_scope |= scope_id.is_some();
        scope_ids.push(scope_id.unwrap_or(0));
        let scheme = opt_str(m, "scheme")?;
        any_scheme |= scheme.is_some();
        schemes.push(scheme.unwrap_or_default());
        let value = opt_str(m, "scheme_value")?;
        any_value |= value.is_some();
        scheme_values.push(value.unwrap_or_default());
    }
    if any_scope {
        assertions.scope_ids = Some(scope_ids);
    }
    if any_scheme {
        assertions.schemes = Some(schemes);
    }
    if any_value {
        assertions.scheme_values = Some(scheme_values);
    }
    w.add_classification(ann_id, assertions, &scope, multilabel, grid, annotation_options(options)?)?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_writer_add_classification(
    writer: *mut M5Writer,
    annotation_id: *const c_char,
    options_json: *const c_char,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(annotation_id, "annotation_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        with_writer(writer, |w| add_classification(w, id, &options))
    })
}

// -- transforms ----------------------------------------------------------------------

pub fn add_transform(
    w: &mut SampleWriter,
    transform_id: &str,
    kind: &str,
    options: &Map<String, Value>,
    arrays: HashMap<String, NdArray>,
) -> BResult<()> {
    let arrays = Arrays(arrays);
    let from = opt_str(options, "from_frame")?.ok_or_else(|| BridgeError::argument("a transform needs from_frame"))?;
    let to = opt_str(options, "to_frame")?.ok_or_else(|| BridgeError::argument("a transform needs to_frame"))?;
    let spec = TransformSpec {
        matrix: arrays.f64("matrix"),
        field: arrays.0.get("field").cloned(),
        control_points: arrays.f64("control_points"),
        components: opt_strs(options, "components")?,
        field_grid: opt_str(options, "field_grid")?,
        cp_grid: opt_str(options, "cp_grid")?,
        vector_space: opt_str(options, "vector_space")?,
        interpolation: opt_str(options, "interpolation")?,
        extrapolation: opt_str(options, "extrapolation")?,
        order: opt_i64(options, "order")?,
        units: opt_str(options, "units")?,
        from_grid: opt_str(options, "from_grid")?,
        to_grid: opt_str(options, "to_grid")?,
        invertible: opt_bool(options, "invertible")?,
        inverse_id: opt_str(options, "inverse_id")?,
        metrics: quality_arg(options, "metrics")?,
        prov: opt_str(options, "prov")?,
        codec: opt_str(options, "codec")?,
    };
    let field_dtype = match opt_str(options, "field_dtype")?.as_deref() {
        None | Some("float32") => FieldDtype::Float32,
        Some("float16") => FieldDtype::Float16,
        Some("auto") => FieldDtype::Auto,
        Some(other) => return Err(BridgeError::argument(format!("field_dtype {other:?}: float32, float16 or auto"))),
    };
    w.add_transform_with(transform_id, kind, &from, &to, spec, field_dtype)?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_writer_add_affine_transform(
    writer: *mut M5Writer,
    transform_id: *const c_char,
    options_json: *const c_char,
    matrix: *const f64,
    dim: u32,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(transform_id, "transform_id")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        if !(dim == 3 || dim == 4) {
            return Err(BridgeError::argument(format!("an affine is 3×3 or 4×4, not {dim}×{dim}")));
        }
        if matrix.is_null() {
            return Err(BridgeError::argument("matrix is NULL"));
        }
        let n = dim as usize;
        // SAFETY: the caller passes dim × dim values.
        let values = unsafe { std::slice::from_raw_parts(matrix, n * n) }.to_vec();
        let mut arrays = HashMap::new();
        arrays.insert("matrix".to_string(), NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[n, n]), values)?));
        with_writer(writer, |w| add_transform(w, id, "affine", &options, arrays))
    })
}

/// Any transform kind (§10): `identity`, `affine` ("matrix"),
/// `displacement` ("field"), `bspline` ("control_points") or `composite`
/// (options `components`).
#[no_mangle]
pub extern "C" fn m5_writer_add_transform(
    writer: *mut M5Writer,
    transform_id: *const c_char,
    kind: *const c_char,
    options_json: *const c_char,
    arrays: *const M5ArrayView,
    n_arrays: usize,
) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(transform_id, "transform_id")?;
        let kind = ffi::arg_str(kind, "kind")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let arrays = array_views(arrays, n_arrays)?;
        with_writer(writer, |w| add_transform(w, id, kind, &options, arrays))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_remove_transform(writer: *mut M5Writer, transform_id: *const c_char) -> M5Status {
    guard(|| {
        let id = ffi::arg_str(transform_id, "transform_id")?;
        with_writer(writer, |w| Ok(w.remove_transform(id)?))
    })
}

#[no_mangle]
pub extern "C" fn m5_writer_build_index(writer: *mut M5Writer, options_json: *const c_char) -> M5Status {
    guard(|| {
        let options = ffi::arg_json(options_json, "options_json")?;
        let annotations = opt_strs(&options, "annotations")?;
        let max_coords = opt_i64(&options, "max_coords")?.map(|v| v.max(0) as usize);
        let occupancy = match options.get("occupancy") {
            None => None,
            Some(Value::Null) | Some(Value::Bool(false)) => Some(None),
            Some(v) => {
                Some(Some(v.as_u64().ok_or_else(|| BridgeError::argument("occupancy is a factor or false"))? as usize))
            }
        };
        let seed = opt_i64(&options, "seed")?.unwrap_or(0) as u64;
        with_writer(writer, |w| {
            w.build_index(annotations.as_deref(), max_coords, occupancy, seed).map(|_| ()).map_err(Into::into)
        })
    })
}
