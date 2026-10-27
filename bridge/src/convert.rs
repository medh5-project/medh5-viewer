//! Path-based calls: validation, NIfTI conversion, recompression and
//! collections.

use std::ffi::c_char;
use std::path::{Path, PathBuf};

use medh5::convert::nifti::{self, ExportOptions, ImportOptions, ReadOptions, SegOptions};
use medh5::convert::report::ConversionReport;
use medh5::labels::{ClassKey, LabelSet};
use medh5::sample::Annotated;
use serde_json::{json, Map, Value};

use crate::bundle::M5Bundle;
use crate::ffi::{self, guard, BResult, BridgeError, M5Status};

// -- option helpers -------------------------------------------------------------------

pub fn opt_str(options: &Map<String, Value>, key: &str) -> BResult<Option<String>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(BridgeError::argument(format!("option {key:?} must be a string"))),
    }
}

pub fn opt_bool(options: &Map<String, Value>, key: &str) -> BResult<Option<bool>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(BridgeError::argument(format!("option {key:?} must be true or false"))),
    }
}

pub fn opt_f64(options: &Map<String, Value>, key: &str) -> BResult<Option<f64>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => {
            v.as_f64().map(Some).ok_or_else(|| BridgeError::argument(format!("option {key:?} must be a number")))
        }
    }
}

pub fn opt_i64(options: &Map<String, Value>, key: &str) -> BResult<Option<i64>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => {
            v.as_i64().map(Some).ok_or_else(|| BridgeError::argument(format!("option {key:?} must be an integer")))
        }
    }
}

pub fn opt_f64s(options: &Map<String, Value>, key: &str) -> BResult<Option<Vec<f64>>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_f64().ok_or_else(|| BridgeError::argument(format!("option {key:?} must be numbers"))))
            .collect::<BResult<Vec<_>>>()
            .map(Some),
        Some(v) => v
            .as_f64()
            .map(|f| Some(vec![f]))
            .ok_or_else(|| BridgeError::argument(format!("option {key:?} must be numbers"))),
    }
}

pub fn opt_strs(options: &Map<String, Value>, key: &str) -> BResult<Option<Vec<String>>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_string)
                    .ok_or_else(|| BridgeError::argument(format!("option {key:?} must be strings")))
            })
            .collect::<BResult<Vec<_>>>()
            .map(Some),
        Some(Value::String(s)) => Ok(Some(vec![s.clone()])),
        Some(_) => Err(BridgeError::argument(format!("option {key:?} must be a list of strings"))),
    }
}

/// A class named by id or by label-set key.
pub fn class_key(value: &Value) -> BResult<ClassKey> {
    match value {
        Value::Number(n) => {
            n.as_i64().map(ClassKey::Id).ok_or_else(|| BridgeError::argument(format!("class id {n} is not an integer")))
        }
        Value::String(s) => Ok(ClassKey::Key(s.clone())),
        other => Err(BridgeError::argument(format!("a class is an id or a key, not {other}"))),
    }
}

pub fn class_keys(options: &Map<String, Value>, key: &str) -> BResult<Option<Vec<ClassKey>>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => items.iter().map(class_key).collect::<BResult<Vec<_>>>().map(Some),
        Some(_) => Err(BridgeError::argument(format!("option {key:?} must be a list of class ids or keys"))),
    }
}

/// `annotated_classes`: a list of ids or keys, `"all"` (the label set), or
/// `"given"`/null (the classes supplied).
pub fn annotated(options: &Map<String, Value>, key: &str) -> BResult<Annotated> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(Annotated::AllGiven),
        Some(Value::String(s)) if s == "all" => Ok(Annotated::All),
        Some(Value::String(s)) if s == "given" || s == "present" => Ok(Annotated::AllGiven),
        Some(Value::Array(items)) => Ok(Annotated::Classes(items.iter().map(class_key).collect::<BResult<_>>()?)),
        Some(other) => Err(BridgeError::argument(format!(
            "annotated_classes is a list of classes, \"all\" or \"given\", not {other}"
        ))),
    }
}

/// `{"name": "/path", …}` in order, or `[["name", "/path"], …]`.
fn named_paths(options: &Map<String, Value>, key: &str) -> BResult<Vec<(String, PathBuf)>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Object(map)) => map
            .iter()
            .map(|(name, path)| {
                path.as_str()
                    .map(|p| (name.clone(), PathBuf::from(p)))
                    .ok_or_else(|| BridgeError::argument(format!("{key}.{name} must be a path")))
            })
            .collect(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|pair| match pair.as_array().map(Vec::as_slice) {
                Some([Value::String(n), Value::String(p)]) => Ok((n.clone(), PathBuf::from(p))),
                _ => Err(BridgeError::argument(format!("{key} entries are [name, path]"))),
            })
            .collect(),
        Some(_) => Err(BridgeError::argument(format!("{key} must map names to paths"))),
    }
}

fn named_strings(options: &Map<String, Value>, key: &str) -> BResult<Vec<(String, String)>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Object(map)) => map
            .iter()
            .map(|(name, v)| {
                v.as_str()
                    .map(|s| (name.clone(), s.to_string()))
                    .ok_or_else(|| BridgeError::argument(format!("{key}.{name} must be a string")))
            })
            .collect(),
        Some(_) => Err(BridgeError::argument(format!("{key} must map names to strings"))),
    }
}

pub fn label_set(options: &Map<String, Value>, key: &str) -> BResult<Option<LabelSet>> {
    match options.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => Ok(LabelSet::from_json(Some(v))?),
    }
}

// -- validation ----------------------------------------------------------------------

pub fn validate_json(path: &Path, level: &str, profiles: Option<&[String]>) -> BResult<Value> {
    let report = medh5::validate::validate_file(path, level, profiles)?;
    let mut out = report.to_json();
    if let Some(Value::Array(items)) = out.get_mut("diagnostics") {
        for (item, d) in items.iter_mut().zip(&report.diagnostics) {
            item["summary"] = json!(d.summary());
            item["effective_severity"] = json!(report.effective_severity(d));
        }
    }
    out["codes"] = json!(report.codes());
    Ok(out)
}

#[no_mangle]
pub extern "C" fn m5_validate_file(path: *const c_char, level: *const c_char, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        let level = ffi::arg_opt_str(level, "level")?.unwrap_or("integrity");
        ffi::arg_out(out_json, "out_json")?;
        ffi::write_out_json(out_json, &validate_json(Path::new(path), level, None)?)
    })
}

// -- NIfTI ---------------------------------------------------------------------------

fn nifti_read(path: &Path) -> BResult<M5Bundle> {
    let read = nifti::read_nifti(path, &ReadOptions::default())?;
    let geometry = read.geometry.clone();
    let mut header = geometry.to_json();
    let shape: Vec<usize> = geometry.shape.clone();
    let (axis_names, axis_kinds) = nifti::grid_axes(&shape, true, &geometry.leading_kind)?;
    let n_spatial = geometry.spacing.len();
    let grid = json!({
        "id": path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        "shape": shape,
        "axis_names": axis_names,
        "axis_kinds": axis_kinds,
        "spacing": geometry.spacing,
        "origin": geometry.origin,
        "direction": geometry.direction,
        "coord_system": geometry.coord_system,
        "units": geometry.units,
        "time_values": geometry.time_values,
        "time_units": geometry.time_units,
    });
    // index -> world, homogeneous, in the grid's own index order.
    let mut affine = vec![vec![0.0f64; n_spatial + 1]; n_spatial + 1];
    for (r, row) in affine.iter_mut().enumerate().take(n_spatial) {
        for (c, value) in row.iter_mut().enumerate().take(n_spatial) {
            *value = geometry.direction[r][c] * geometry.spacing[c];
        }
        row[n_spatial] = geometry.origin[r];
    }
    affine[n_spatial][n_spatial] = 1.0;
    header["grid"] = grid;
    header["affine"] = json!(affine);
    header["path"] = json!(path.to_string_lossy());
    let mut bundle = M5Bundle::new(&header);
    bundle.push("data", read.voxels.into_ndarray()?);
    Ok(bundle)
}

#[no_mangle]
pub extern "C" fn m5_nifti_read(nifti_path: *const c_char, out: *mut *mut M5Bundle) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(nifti_path, "nifti_path")?;
        let slot = ffi::arg_out(out, "out")?;
        *slot = nifti_read(Path::new(path))?.into_raw();
        Ok(())
    })
}

fn nifti_import(out: &Path, options: &Map<String, Value>) -> BResult<Value> {
    let images = named_paths(options, "images")?;
    if images.is_empty() {
        return Err(BridgeError::argument("options.images names no image"));
    }
    let mut import = ImportOptions::default();
    let mut masks = named_paths(options, "masks")?;
    masks.extend(named_paths(options, "segmentations")?);
    import = import.with_masks(masks);
    if let Some(v) = opt_str(options, "sample_id")? {
        import = import.with_sample_id(v);
    }
    if let Some(v) = opt_str(options, "subject_id")? {
        import = import.with_subject_id(v);
    }
    let modalities = match options.get("modality").or_else(|| options.get("modalities")) {
        Some(Value::String(m)) => images.iter().map(|(n, _)| (n.clone(), m.clone())).collect(),
        Some(Value::Object(_)) => {
            named_strings(options, if options.contains_key("modality") { "modality" } else { "modalities" })?
        }
        None | Some(Value::Null) => Vec::new(),
        Some(_) => return Err(BridgeError::argument("modality is one string or {image: modality}")),
    };
    import = import.with_modalities(modalities);
    if let Some(v) = opt_str(options, "coord_system")? {
        import = import.with_coord_system(v);
    }
    if let Some(v) = opt_bool(options, "transpose")? {
        import = import.with_transpose(v);
    }
    if let Some(v) = opt_str(options, "fourth_axis")? {
        import = import.with_fourth_axis(v);
    }
    import = import.with_value_units(named_strings(options, "value_units")?);
    if let Some(v) = opt_str(options, "codec")? {
        import = import.with_codec(v);
    }
    import = import.with_annotated_classes(annotated(options, "annotated_classes")?);
    if let Some(v) = opt_bool(options, "assume_geometry")? {
        import = import.with_assume_geometry(v);
    }
    if let Some(v) = opt_bool(options, "plane_as_volume")? {
        import = import.with_plane_as_volume(v);
    }
    if let Some(ls) = label_set(options, "label_set")? {
        import = import.with_label_set(ls);
    }
    let mut report = ConversionReport::new("nifti", "");
    nifti::from_nifti(&images, out, &import, &mut report)?;
    Ok(report.to_json())
}

#[no_mangle]
pub extern "C" fn m5_nifti_import(
    out_path: *const c_char,
    options_json: *const c_char,
    out_report_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let out = ffi::arg_str(out_path, "out_path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out_report_json, "out_report_json")?;
        ffi::write_out_json(out_report_json, &nifti_import(Path::new(out), &options)?)
    })
}

fn nifti_import_segmentation(path: &Path, options: &Map<String, Value>) -> BResult<Value> {
    let masks = named_paths(options, "masks")?;
    if masks.is_empty() {
        return Err(BridgeError::argument("options.masks names no mask"));
    }
    let mut seg = SegOptions::default();
    if let Some(v) = opt_str(options, "annotation_id")?.or(opt_str(options, "ann_id")?) {
        seg = seg.with_ann_id(v);
    }
    if let Some(v) = opt_str(options, "grid")? {
        seg = seg.with_grid(v);
    }
    if let Some(v) = opt_str(options, "coord_system")? {
        seg = seg.with_coord_system(v);
    }
    if let Some(v) = opt_bool(options, "transpose")? {
        seg = seg.with_transpose(v);
    }
    seg = seg.with_annotated_classes(annotated(options, "annotated_classes")?);
    if let Some(v) = opt_bool(options, "assume_aligned")? {
        seg = seg.with_assume_aligned(v);
    }
    if let Some(v) = opt_bool(options, "assume_geometry")? {
        seg = seg.with_assume_geometry(v);
    }
    if let Some(v) = opt_bool(options, "plane_as_volume")? {
        seg = seg.with_plane_as_volume(v);
    }
    let mut report = ConversionReport::new("nifti", "");
    nifti::import_seg_nifti(path, &masks, &seg, &mut report)?;
    Ok(report.to_json())
}

#[no_mangle]
pub extern "C" fn m5_nifti_import_segmentation(
    sample_path: *const c_char,
    options_json: *const c_char,
    out_report_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(sample_path, "sample_path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out_report_json, "out_report_json")?;
        ffi::write_out_json(out_report_json, &nifti_import_segmentation(Path::new(path), &options)?)
    })
}

fn nifti_export(path: &Path, options: &Map<String, Value>) -> BResult<Value> {
    let out = opt_str(options, "out")?.ok_or_else(|| BridgeError::argument("options.out names no output path"))?;
    let object = opt_str(options, "object")?;
    let mut export = ExportOptions::default();
    if let Some(v) = opt_bool(options, "physical")? {
        export = export.with_physical(v);
    }
    let (mut image, annotation) = match object.as_deref() {
        Some(o) if o.starts_with("annotations/") => (None, Some(o["annotations/".len()..].to_string())),
        Some(o) => (Some(o.strip_prefix("images/").unwrap_or(o).to_string()), None),
        None => (opt_str(options, "image")?, opt_str(options, "annotation")?),
    };
    if let Some(image_option) = opt_str(options, "image")? {
        image = Some(image_option);
    }
    if let Some(ann) = &annotation {
        export = export.with_annotation(ann.clone());
        if let Some(class) = options.get("class").filter(|v| !v.is_null()) {
            export = export.with_class_key(class_key(class)?);
        }
    }
    // The engine names an image even for an annotation, which it writes on
    // its own grid: the first image on that grid, else the first image.
    let image = match image {
        Some(i) => i,
        None => {
            let sample = medh5::sample::open_sample(path)?;
            let wanted = match &annotation {
                Some(a) => sample.annotation(a)?.grid_id().map(str::to_string),
                None => None,
            };
            let images = sample.images()?;
            images
                .iter()
                .find(|(_, img)| wanted.is_some() && img.grid_id().ok() == wanted)
                .or_else(|| images.first())
                .map(|(id, _)| id.clone())
                .ok_or_else(|| BridgeError::argument("the sample holds no image"))?
        }
    };
    let mut report = ConversionReport::new("nifti", &path.to_string_lossy());
    let written = nifti::to_nifti(path, &image, Path::new(&out), &export, Some(&mut report))?;
    let mut value = report.to_json();
    value["path"] = json!(written.to_string_lossy());
    Ok(value)
}

#[no_mangle]
pub extern "C" fn m5_nifti_export(
    sample_path: *const c_char,
    options_json: *const c_char,
    out_report_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(sample_path, "sample_path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out_report_json, "out_report_json")?;
        ffi::write_out_json(out_report_json, &nifti_export(Path::new(path), &options)?)
    })
}

// -- storage and collections ---------------------------------------------------------

#[no_mangle]
pub extern "C" fn m5_recompress(
    path: *const c_char,
    options_json: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        ffi::arg_out(out_json, "out_json")?;
        let profile = opt_str(&options, "profile")?.unwrap_or_else(|| "balanced".into());
        let out = opt_str(&options, "out")?;
        let rechunk = opt_bool(&options, "rechunk")?.unwrap_or(false);
        let result =
            medh5::storage::recompress::recompress(Path::new(path), &profile, out.as_deref().map(Path::new), rechunk)?;
        ffi::write_out_json(out_json, &result.to_json())
    })
}

#[no_mangle]
pub extern "C" fn m5_collection_list(path: *const c_char, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        ffi::arg_out(out_json, "out_json")?;
        let collection = medh5::collection::open_collection(Path::new(path))?;
        let mut summary = collection.summary()?;
        if let Some(Value::Array(samples)) = summary.get_mut("samples").map(std::mem::take) {
            let members: Vec<Value> = samples
                .into_iter()
                .map(|mut s| {
                    s["name"] = s.get("key").cloned().unwrap_or(Value::Null);
                    s
                })
                .collect();
            summary["members"] = Value::Array(members);
            if let Value::Object(m) = &mut summary {
                m.remove("samples");
            }
        }
        ffi::write_out_json(out_json, &summary)
    })
}

/// Pack samples into a `.medh5c` collection (§2.2): options `{"sources":
/// ["/a.medh5", …], "keys": ["a", …] | null}`.  Returns `{"path", "members"}`.
#[no_mangle]
pub extern "C" fn m5_collection_pack(
    out_path: *const c_char,
    options_json: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let out = ffi::arg_str(out_path, "out_path")?;
        let options = ffi::arg_json(options_json, "options_json")?;
        let sources = opt_strs(&options, "sources")?.unwrap_or_default();
        let keys = opt_strs(&options, "keys")?;
        let paths: Vec<&Path> = sources.iter().map(Path::new).collect();
        let written = medh5::collection::pack(&paths, Path::new(out), keys.as_deref())?;
        let members = medh5::collection::open_collection(&written)?.keys()?;
        if !out_json.is_null() {
            ffi::write_out_json(out_json, &json!({"path": written.to_string_lossy(), "members": members}))?;
        }
        Ok(())
    })
}
