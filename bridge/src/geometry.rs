//! Geometric and classification annotations as bundles: the arrays as
//! stored (spec §8, 1.2 §3), and their coordinates in world.

use std::ffi::c_char;

use medh5::annotations::{Annotation, GridRef};
use medh5::array::NdArray;
use medh5::ndarray::{Array2, ArrayD, IxDyn};
use serde_json::{json, Map, Value};

use crate::bundle::M5Bundle;
use crate::ffi::{self, guard, BResult, BridgeError, M5Status};
use crate::sample::{handle, M5Sample};

/// A stored dataset of the annotation, when present, as the engine reads it.
fn stored(a: &Annotation, name: &str) -> BResult<Option<NdArray>> {
    match a.optional_dataset(name)? {
        None => Ok(None),
        Some(ds) => Ok(Some(medh5::h5::data::read(&ds)?)),
    }
}

/// `(..., S)` coordinates in world, from the annotation's own space: index
/// coordinates through its grid's affine, world ones as they are.
fn to_world(a: &Annotation, coords: &ArrayD<f64>) -> BResult<ArrayD<f64>> {
    Ok(a.to_world(coords, GridRef::Own)?)
}

/// Every corner of each `(N, S, 2)` box, `(N, 2**S, S)`, in odometer order
/// (the first axis slowest): the box's own space.
fn box_corners(boxes: &ArrayD<f64>) -> BResult<ArrayD<f64>> {
    let shape = boxes.shape();
    if shape.len() != 3 || shape[2] != 2 {
        return Err(BridgeError::engine("validation", format!("boxes of shape {shape:?}; expected (N, S, 2)")));
    }
    let (n, s) = (shape[0], shape[1]);
    let m = 1usize << s;
    let mut out = ArrayD::<f64>::zeros(IxDyn(&[n, m, s]));
    for i in 0..n {
        for corner in 0..m {
            for k in 0..s {
                let upper = (corner >> (s - 1 - k)) & 1 == 1;
                out[[i, corner, k]] = boxes[[i, k, usize::from(upper)]];
            }
        }
    }
    Ok(out)
}

fn f64_of(array: &NdArray) -> ArrayD<f64> {
    array.to_f64()
}

/// Mesh normals carried to world: as stored for a world mesh; through the
/// inverse transpose of the grid's linear part for an index one.
fn world_normals(a: &Annotation, normals: &ArrayD<f64>) -> BResult<Option<ArrayD<f64>>> {
    if a.space()? == "world" {
        return Ok(Some(normals.clone()));
    }
    let Ok(grid) = a.grid() else { return Ok(None) };
    let s = grid.n_spatial();
    // Linear part L = direction · diag(spacing); a normal maps by L^-T.
    let mut linear = Array2::<f64>::zeros((s, s));
    for r in 0..s {
        for c in 0..s {
            linear[[r, c]] = grid.direction[[r, c]] * grid.spacing[c];
        }
    }
    let Some(inverse) = invert(&linear) else { return Ok(None) };
    let rows = normals.shape().first().copied().unwrap_or(0);
    let mut out = ArrayD::<f64>::zeros(IxDyn(&[rows, s]));
    for i in 0..rows {
        let mut v = vec![0.0; s];
        for (r, value) in v.iter_mut().enumerate() {
            // (L^-T n)_r = sum_c inverse[c][r] n_c
            *value = (0..s).map(|c| inverse[[c, r]] * normals[[i, c]]).sum();
        }
        let norm = v.iter().map(|x| x * x).sum::<f64>().sqrt();
        for (r, value) in v.iter().enumerate() {
            out[[i, r]] = if norm > 0.0 { value / norm } else { 0.0 };
        }
    }
    Ok(Some(out))
}

/// The inverse of a small square matrix (Gauss-Jordan), or `None`.
pub fn invert(m: &Array2<f64>) -> Option<Array2<f64>> {
    let n = m.nrows();
    let mut a = m.clone();
    let mut inv = Array2::<f64>::eye(n);
    for col in 0..n {
        let pivot = (col..n).max_by(|x, y| a[[*x, col]].abs().total_cmp(&a[[*y, col]].abs()))?;
        if a[[pivot, col]].abs() < 1e-300 {
            return None;
        }
        if pivot != col {
            for k in 0..n {
                a.swap([pivot, k], [col, k]);
                inv.swap([pivot, k], [col, k]);
            }
        }
        let p = a[[col, col]];
        for k in 0..n {
            a[[col, k]] /= p;
            inv[[col, k]] /= p;
        }
        for r in 0..n {
            if r != col {
                let f = a[[r, col]];
                if f != 0.0 {
                    for k in 0..n {
                        a[[r, k]] -= f * a[[col, k]];
                        inv[[r, k]] -= f * inv[[col, k]];
                    }
                }
            }
        }
    }
    Some(inv)
}

/// The bundle of one geometric or classification annotation.
pub fn geometry_bundle(a: &Annotation) -> BResult<M5Bundle> {
    let kind = a.kind().to_string();
    if a.is_voxel() {
        return Err(BridgeError::from(medh5::Error::Type(format!(
            "annotation {:?} is a {kind} (voxel) annotation; its geometry is its layers, its mask or its instances",
            a.ann_id
        ))));
    }
    let mut header = Map::new();
    header.insert("annotation".into(), json!(a.ann_id));
    header.insert("kind".into(), json!(kind));
    header.insert("grid".into(), json!(a.grid_id()));
    header.insert("frame_uid".into(), json!(a.frame_uid()));
    header.insert("class_ids".into(), json!(a.class_ids()));
    header.insert("annotated_class_ids".into(), json!(a.annotated_class_ids()));
    let mut arrays: Vec<(String, NdArray)> = Vec::new();
    let mut keep = |name: &str, array: Option<NdArray>| {
        if let Some(array) = array {
            arrays.push((name.to_string(), array));
        }
    };

    if kind == "classification" {
        header.insert("scope".into(), json!(a.scope()?));
        header.insert("multilabel".into(), json!(a.multilabel()?));
        header.insert("scope_ids".into(), json!(a.scope_ids()?));
        header.insert("change_label".into(), json!(a.is_change_label()?));
        header.insert("compared_timepoints".into(), json!(a.compared_timepoints()?));
        let assertions: Vec<Value> = a
            .assertions()?
            .into_iter()
            .map(|s| {
                json!({
                    "class_id": s.class_id,
                    "key": a.class_key(s.class_id),
                    "value": s.value,
                    "scope_id": s.scope_id,
                    "scheme": s.scheme,
                    "scheme_value": s.scheme_value,
                })
            })
            .collect();
        header.insert("assertions".into(), Value::Array(assertions));
        let labels: Map<String, Value> = a.labels()?.into_iter().map(|(k, v)| (k, json!(v))).collect();
        header.insert("labels".into(), Value::Object(labels));
        header.insert("positives".into(), json!(a.positives()?));
        let mut bundle = M5Bundle::new(&Value::Object(header));
        drop(keep);
        for (name, array) in arrays {
            bundle.push(&name, array);
        }
        return Ok(bundle);
    }

    let space = a.space()?;
    header.insert("space".into(), json!(space));
    header.insert("items".into(), json!(a.n_items()?));
    header.insert("attributes".into(), json!(a.attributes()?));
    let mut world_error: Option<String> = None;
    let mut world = |coords: &ArrayD<f64>| -> Option<NdArray> {
        match to_world(a, coords) {
            Ok(w) => Some(NdArray::F64(w)),
            Err(e) => {
                world_error.get_or_insert(e.message);
                None
            }
        }
    };
    for column in ["class_ids", "instance_ids", "scores"] {
        if kind != "points" || column != "class_ids" {
            keep(column, stored(a, column)?);
        }
    }
    match kind.as_str() {
        "boxes" => {
            let boxes = stored(a, "boxes")?.ok_or_else(|| BridgeError::engine("validation", "boxes has no `boxes`"))?;
            let corners = box_corners(&f64_of(&boxes))?;
            keep("world_corners", world(&corners));
            keep("boxes", Some(boxes));
            keep("slice_index", stored(a, "slice_index")?);
        }
        "obb" => {
            for name in ["centers", "sizes", "rotations"] {
                keep(name, stored(a, name)?);
            }
            let corners = a.obb_corners()?.into_dyn();
            keep("world_corners", world(&corners));
            keep("corners", Some(NdArray::F64(corners)));
        }
        "keypoints" => {
            let points = stored(a, "points")?.ok_or_else(|| BridgeError::engine("validation", "no `points`"))?;
            keep("world_points", world(&f64_of(&points)));
            keep("points", Some(points));
            keep("keypoint_class_ids", stored(a, "keypoint_class_ids")?);
            keep("visibility", Some(NdArray::U8(a.visibility()?)));
            header.insert("skeleton".into(), json!(a.skeleton_id()?));
            if let Ok(Some(skeleton)) = a.skeleton() {
                header.insert("skeleton_edges".into(), json!(skeleton.edges));
                header.insert("skeleton_keypoints".into(), json!(skeleton.keypoints));
            }
        }
        "points" => {
            let points = stored(a, "points")?.ok_or_else(|| BridgeError::engine("validation", "no `points`"))?;
            keep("world_points", world(&f64_of(&points)));
            keep("points", Some(points));
            keep("class_ids", stored(a, "class_ids")?);
            keep("weights", stored(a, "weights")?);
            header.insert("names".into(), json!(a.point_names()?));
            header.insert("correspondence".into(), json!(a.correspondence()?));
        }
        "contours" => {
            let vertices = stored(a, "vertices")?.ok_or_else(|| BridgeError::engine("validation", "no `vertices`"))?;
            keep("world_vertices", world(&f64_of(&vertices)));
            keep("vertices", Some(vertices));
            keep("contour_offsets", stored(a, "contour_offsets")?);
            keep("contour_class_ids", stored(a, "contour_class_ids")?);
            keep("contour_plane", Some(NdArray::I32(a.contour_planes()?.into_dyn())));
            let roles: Vec<u8> = a.contour_roles()?.iter().map(|r| u8::from(r == "hole")).collect();
            keep("contour_role", Some(NdArray::U8(ArrayD::from_shape_vec(IxDyn(&[roles.len()]), roles)?)));
        }
        "polylines" => {
            let vertices = stored(a, "vertices")?.ok_or_else(|| BridgeError::engine("validation", "no `vertices`"))?;
            keep("world_vertices", world(&f64_of(&vertices)));
            keep("vertices", Some(vertices));
            keep("polyline_offsets", stored(a, "polyline_offsets")?);
            keep("polyline_class_ids", stored(a, "polyline_class_ids")?);
            keep("polyline_plane", Some(NdArray::I32(a.polyline_planes()?.into_dyn())));
        }
        "mesh" => {
            let vertices = stored(a, "vertices")?.ok_or_else(|| BridgeError::engine("validation", "no `vertices`"))?;
            keep("world_vertices", world(&f64_of(&vertices)));
            keep("vertices", Some(vertices));
            keep("faces", stored(a, "faces")?);
            if let Some(normals) = stored(a, "normals")? {
                if let Some(w) = world_normals(a, &f64_of(&normals))? {
                    keep("world_normals", Some(NdArray::F64(w)));
                }
                keep("normals", Some(normals));
            }
            for name in ["vertex_class_ids", "mesh_offsets", "mesh_class_ids"] {
                keep(name, stored(a, name)?);
            }
            header.insert("submeshes".into(), json!(a.n_submeshes()?));
        }
        other => {
            return Err(BridgeError::from(medh5::Error::NotImplemented(format!(
                "annotation kind {other:?} has no geometry bundle"
            ))))
        }
    }
    drop(world);
    header.insert("world_error".into(), json!(world_error));
    let mut bundle = M5Bundle::new(&Value::Object(header));
    drop(keep);
    let mut seen = std::collections::HashSet::new();
    for (name, array) in arrays {
        if seen.insert(name.clone()) {
            bundle.push(&name, array);
        }
    }
    Ok(bundle)
}

#[no_mangle]
pub extern "C" fn m5_annotation_geometry(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    out: *mut *mut M5Bundle,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        let slot = ffi::arg_out(out, "out")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        let bundle = geometry_bundle(&annotation)?;
        *slot = bundle.into_raw();
        Ok(())
    })
}
