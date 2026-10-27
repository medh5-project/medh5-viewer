//! The sample summary (`m5_sample_summary`): everything the viewer shows
//! without reading voxels, in one JSON object (docs/BRIDGE.md, "Sample
//! summary").
//!
//! An object the engine cannot read is listed with its error rather than
//! failing the summary: a damaged file still shows what is intact.

use medh5::annotations::Annotation;
use medh5::geometry::grid::Grid;
use medh5::h5::{attrs, data, ops};
use medh5::sample::{Image, Sample};
use medh5::transforms::{Body, Transform};
use serde_json::{json, Map, Value};

use crate::ffi::{BResult, BridgeError};
use crate::sample::M5Sample;

/// The error of one object, as a summary lists it.
pub fn error_json(error: &BridgeError) -> Value {
    json!({"kind": error.kind, "code": error.code, "message": error.message})
}

/// A grid as `MedH5Core.GridGeometry` decodes it, plus what else the file
/// says of it.
pub fn grid_json(g: &Grid) -> Value {
    json!({
        "id": g.grid_id,
        "shape": g.shape,
        "axis_names": g.axis_names,
        "axis_kinds": g.axis_kinds,
        "spacing": g.spacing,
        "origin": g.origin,
        "direction": g.direction.rows().into_iter().map(|r| r.to_vec()).collect::<Vec<_>>(),
        "coord_system": g.coord_system,
        "units": g.units,
        "timepoint": g.timepoint,
        "frame_uid": g.frame_uid,
        "time_values": g.time_values,
        "time_units": g.time_units,
        "chunk_hint": g.chunk_hint,
        "patch_hint": g.patch_hint,
        "physical_size": g.physical_size(),
    })
}

fn opt<T: serde::Serialize>(value: medh5::Result<T>) -> Value {
    match value {
        Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
        Err(_) => Value::Null,
    }
}

/// One image.
pub fn image_json(image: &Image) -> BResult<Value> {
    let (slope, intercept) = image.rescale()?;
    let window = image.window()?;
    let dataset = image.dataset()?;
    let pyramid = image.pyramid().ok().flatten();
    Ok(json!({
        "id": image.image_id,
        "grid": image.grid_id()?,
        "timepoint": image.timepoint()?,
        "modality": image.modality()?,
        "value_type": image.value_type()?,
        "value_units": image.value_units()?,
        "channel_names": image.channel_names()?,
        "shape": image.shape()?,
        "dtype": image.dtype()?.name(),
        "chunks": image.chunks()?,
        "levels": image.levels()?,
        "multiscale": image.is_multiscale(),
        "grid_levels": pyramid.as_ref().map(|p| p.grid_levels.clone()),
        "downsample_method": pyramid.as_ref().map(|p| p.downsample_method.clone()),
        "rescale_slope": slope,
        "rescale_intercept": intercept,
        "rescaled": slope != 1.0 || intercept != 0.0,
        "window_center": window.as_ref().map(|w| w.0.clone()),
        "window_width": window.as_ref().map(|w| w.1.clone()),
        "valid_mask": image.valid_mask()?,
        "prov": image.prov()?,
        "digest": image.digest()?,
        "nbytes": opt(image.nbytes()),
        "codec": opt(medh5::storage::codecs::describe_filters(&dataset)),
        "stored_bytes": dataset.storage_size(),
    }))
}

/// The digest of an annotation group, from its datasets' stored digests:
/// `null` when one of them has none (it would have to be computed).
fn annotation_digest(sample: &Sample, annotation: &Annotation) -> Value {
    let group = &annotation.group;
    let Ok(members) = ops::members(group) else { return Value::Null };
    for name in members {
        if let Some(ds) = ops::child_dataset(group, &name) {
            if !attrs::has(&ds, "digest") {
                return Value::Null;
            }
        }
    }
    let algo = attrs::get_str(&sample.root, "digest_algo").ok().flatten().unwrap_or_else(|| "sha256".into());
    opt(medh5::integrity::group_digest(group, &sample.root, &algo))
}

/// One annotation: its header, its coverage, and what its kind adds.
pub fn annotation_json(sample: &Sample, a: &Annotation) -> BResult<Value> {
    let h = &a.header;
    let mut out = Map::new();
    out.insert("id".into(), json!(a.ann_id));
    out.insert("kind".into(), json!(a.kind()));
    out.insert("task".into(), json!(a.task()));
    out.insert("grid".into(), json!(h.grid));
    out.insert("timepoints".into(), json!(a.timepoints()));
    out.insert("declared_timepoints".into(), json!(h.timepoints));
    out.insert("space".into(), json!(h.space));
    out.insert("frame_uid".into(), json!(a.frame_uid()));
    out.insert("class_ids".into(), json!(h.class_ids));
    out.insert("annotated_class_ids".into(), json!(h.annotated_class_ids));
    out.insert("fully_covered".into(), json!(a.is_fully_covered()));
    out.insert("closure".into(), json!(h.closure));
    out.insert("ignore_id".into(), json!(h.ignore_id));
    out.insert("ignore_mask".into(), json!(h.ignore_mask));
    out.insert("prov".into(), json!(h.prov));
    out.insert("quality".into(), json!(h.quality));
    out.insert("derived_from".into(), json!(h.derived_from));
    out.insert("voxel".into(), json!(a.is_voxel()));
    out.insert("geometric".into(), json!(a.is_geometric()));
    out.insert("digest".into(), annotation_digest(sample, a));
    let items = if a.is_voxel() && a.kind() != "instances" { Value::Null } else { opt(a.n_items()) };
    out.insert("items".into(), items);
    match a.kind() {
        "layers" => {
            out.insert("layers".into(), opt(a.n_layers()));
            out.insert("layer_classes".into(), opt(a.layer_classes()));
        }
        "bitmask" => {
            out.insert("planes".into(), opt(a.n_planes()));
        }
        "probmap" => {
            out.insert("threshold".into(), opt(a.threshold()));
            out.insert("normalized".into(), opt(a.normalized()));
        }
        "instances" => {
            out.insert("has_masks".into(), opt(a.has_masks()));
            out.insert("instance_ids".into(), opt(a.instance_ids()));
        }
        "keypoints" => {
            out.insert("skeleton".into(), opt(a.skeleton_id()));
        }
        "points" => {
            out.insert("correspondence".into(), opt(a.correspondence()));
            out.insert("names".into(), opt(a.point_names()));
        }
        "mesh" => {
            out.insert("submeshes".into(), opt(a.n_submeshes()));
        }
        "classification" => {
            out.insert("scope".into(), opt(a.scope()));
            out.insert("multilabel".into(), opt(a.multilabel()));
            out.insert("scope_ids".into(), opt(a.scope_ids()));
            out.insert("change_label".into(), opt(a.is_change_label()));
        }
        _ => {}
    }
    if a.is_voxel() {
        if let Ok(Some(ds)) = a.optional_dataset("data") {
            out.insert("shape".into(), json!(ds.shape()));
            out.insert("dtype".into(), opt(data::dtype(&ds).map(|d| d.name())));
            out.insert("codec".into(), opt(medh5::storage::codecs::describe_filters(&ds)));
        }
    }
    let extra: Map<String, Value> = h.extra.iter().map(|(k, v)| (k.clone(), crate::sample::attr_json(v))).collect();
    out.insert("attributes".into(), Value::Object(extra));
    Ok(Value::Object(out))
}

/// One transform: the engine's summary, with its header.
pub fn transform_json(t: &Transform) -> BResult<Value> {
    let mut out = match t.summary()? {
        Value::Object(m) => m,
        _ => Map::new(),
    };
    out.insert("from_grid".into(), json!(t.header.from_grid));
    out.insert("to_grid".into(), json!(t.header.to_grid));
    if matches!(t.body, Body::Stored) {
        match t.kind() {
            "displacement" => {
                out.insert("extrapolation".into(), opt(t.extrapolation()));
            }
            "bspline" => {
                out.insert("interpolation".into(), opt(t.interpolation()));
            }
            _ => {}
        }
    }
    Ok(Value::Object(out))
}

fn members_of(sample: &Sample, group: &str) -> Vec<String> {
    ops::child_group(&sample.root, group).and_then(|g| ops::members(&g).ok()).unwrap_or_default()
}

/// The whole summary.
pub fn sample_summary(handle: &M5Sample) -> BResult<Value> {
    let sample = handle.sample()?;
    let s = sample.as_ref();
    let mut out = Map::new();
    out.insert("path".into(), json!(handle.path));
    let version = s.version()?;
    out.insert("format_version".into(), json!(version));
    out.insert(
        "support".into(),
        json!(match medh5::version::support(&version) {
            medh5::version::Support::Full => "full",
            medh5::version::Support::Projection => "projection",
            medh5::version::Support::Unsupported => "unsupported",
        }),
    );
    out.insert("engine_format_version".into(), json!(medh5::FORMAT_VERSION));
    out.insert("kind".into(), json!(s.kind()?));
    out.insert("profiles".into(), json!(s.profiles()?.into_iter().collect::<Vec<_>>()));
    out.insert("content_id".into(), json!(s.content_id()?));
    for name in ["digest_algo", "created", "generator"] {
        out.insert(name.into(), json!(attrs::get_str(&s.root, name).ok().flatten()));
    }

    // The document's members, as the document holds them.
    match s.document() {
        Ok(document) => {
            let doc = document.to_json();
            for key in [
                "identity",
                "cohort",
                "timepoints",
                "label_set",
                "provenance",
                "quality",
                "splits",
                "acquisition",
                "deidentification",
                "extra",
            ] {
                out.insert(key.into(), doc.get(key).cloned().unwrap_or(Value::Null));
            }
            out.insert("longitudinal".into(), json!(document.timepoints.is_longitudinal()));
        }
        Err(e) => {
            out.insert("document_error".into(), crate::summary::error_json(&e.into()));
        }
    }

    let grids = s.grids();
    out.insert(
        "grids".into(),
        match &grids {
            Ok(grids) => Value::Array(grids.values().map(grid_json).collect()),
            Err(_) => json!([]),
        },
    );
    if let Err(e) = &grids {
        out.insert("grids_error".into(), error_json(&e.clone().into()));
    }

    let mut images = Vec::new();
    let mut annotations = Vec::new();
    let mut transforms = Vec::new();
    if grids.is_ok() {
        for id in members_of(s, "images") {
            let found = handle.image(s, &id).and_then(|image| image_json(&image));
            images.push(found.unwrap_or_else(|e| json!({"id": id, "error": error_json(&e)})));
        }
        for id in members_of(s, "annotations") {
            if ops::child_group(&ops::child_group(&s.root, "annotations").expect("listed"), &id).is_none() {
                continue;
            }
            let found = handle.annotation(s, &id).and_then(|a| annotation_json(s, &a));
            annotations.push(found.unwrap_or_else(|e| json!({"id": id, "error": error_json(&e)})));
        }
        for id in members_of(s, "transforms") {
            let found = handle.transform(s, &id).and_then(|t| transform_json(&t));
            transforms.push(found.unwrap_or_else(|e| json!({"id": id, "error": error_json(&e)})));
        }
    }
    // What a later minor's projection leaves out is listed there, not here.
    let left_out = s.left_out().unwrap_or_default();
    let kept = |group: &str, entry: &Value| {
        let id = entry.get("id").and_then(Value::as_str).unwrap_or_default();
        !left_out.contains_key(&format!("{group}/{id}"))
    };
    images.retain(|v| kept("images", v));
    annotations.retain(|v| kept("annotations", v));
    transforms.retain(|v| kept("transforms", v));
    out.insert("images".into(), Value::Array(images));
    out.insert("annotations".into(), Value::Array(annotations));
    out.insert("transforms".into(), Value::Array(transforms));

    let index: Vec<Value> = match s.index() {
        Ok(entries) => {
            let fresh = s.fresh_indices().ok();
            let mut names: Vec<&String> = entries.keys().collect();
            names.sort();
            names
                .into_iter()
                .map(|name| json!({"annotation": name, "fresh": fresh.map(|f| f.contains(name))}))
                .collect()
        }
        Err(_) => Vec::new(),
    };
    out.insert("index".into(), Value::Array(index));

    let clinical = match s.clinical() {
        Ok(None) => json!({"present": false}),
        Ok(Some(c)) => {
            let mut summary = match c.summary() {
                Value::Object(m) => m,
                _ => Map::new(),
            };
            summary.insert("present".into(), json!(true));
            summary.insert("projection".into(), json!(c.projection));
            Value::Object(summary)
        }
        Err(e) => json!({"present": true, "error": error_json(&e.into())}),
    };
    out.insert("clinical".into(), clinical);
    let left: Map<String, Value> = left_out.into_iter().map(|(path, e)| (path, json!(e.message()))).collect();
    out.insert("left_out".into(), Value::Object(left));
    Ok(Value::Object(out))
}
