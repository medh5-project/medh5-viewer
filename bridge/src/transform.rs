//! Transforms: a stored transform's parameters, and the transform the engine
//! resolves between two frames (spec §10.2), as a world-to-world matrix when
//! it is linear and as a displacement field sampled on a grid otherwise.

use std::ffi::c_char;

use medh5::array::NdArray;
use medh5::geometry::grid::Grid;
use medh5::ndarray::{Array2, ArrayD, IxDyn};
use medh5::transforms::{stored_inverse, Body, Transform};
use serde_json::{json, Value};

use crate::bundle::M5Bundle;
use crate::ffi::{self, guard, BResult, BridgeError, M5Status};
use crate::sample::{handle, M5Sample};
use crate::summary::{grid_json, transform_json};

/// A homogeneous `(S+1, S+1)` matrix as 4×4: a 2-D affine acts on world
/// `(x, y)` and leaves `z` alone.
pub fn embed(m: &Array2<f64>) -> BResult<Array2<f64>> {
    match m.nrows() {
        4 => Ok(m.clone()),
        3 => {
            let mut out = Array2::<f64>::eye(4);
            for r in 0..2 {
                for c in 0..2 {
                    out[[r, c]] = m[[r, c]];
                }
                out[[r, 3]] = m[[r, 2]];
            }
            Ok(out)
        }
        n => Err(BridgeError::engine("validation", format!("an affine of {n}×{n} has no 4×4 form"))),
    }
}

/// The transform as one 4×4 world-to-world matrix when every step of it is
/// linear (identity, affine, their inverses and compositions), evaluated as
/// the engine's `transform_points` evaluates it; `None` otherwise.
pub fn linear_matrix(t: &Transform) -> BResult<Option<Array2<f64>>> {
    match &t.body {
        Body::Chain(steps) => {
            let mut total = Array2::<f64>::eye(4);
            for step in steps {
                match linear_matrix(step)? {
                    Some(m) => total = m.dot(&total),
                    None => return Ok(None),
                }
            }
            Ok(Some(total))
        }
        Body::Inverse(inner) => {
            if inner.kind() == "identity" && matches!(inner.body, Body::Stored) {
                return Ok(Some(Array2::eye(4)));
            }
            if let Some(stored) = stored_inverse(inner)? {
                return linear_matrix(&stored);
            }
            if inner.kind() == "affine" && matches!(inner.body, Body::Stored) {
                return Ok(Some(embed(&inner.inverse_matrix()?)?));
            }
            match inner.inverse()? {
                Some(inverse) if !matches!(inverse.body, Body::Inverse(_)) => linear_matrix(&inverse),
                _ => Ok(None),
            }
        }
        Body::Stored => match t.kind() {
            "identity" => Ok(Some(Array2::eye(4))),
            "affine" => Ok(Some(embed(&t.matrix()?)?)),
            "composite" => {
                let problems = t.check_chain();
                if !problems.is_empty() {
                    return Err(BridgeError::from(medh5::Error::coded(
                        "E501",
                        format!("composite {:?} has a broken frame chain: {}", t.transform_id, problems.join("; ")),
                    )));
                }
                let mut total = Array2::<f64>::eye(4);
                for component in t.components()? {
                    match linear_matrix(&component)? {
                        Some(m) => total = m.dot(&total),
                        None => return Ok(None),
                    }
                }
                Ok(Some(total))
            }
            _ => Ok(None),
        },
    }
}

/// The spatial rank the transform's points have: its from frame's grids'.
fn rank_of(t: &Transform) -> usize {
    t.grid_in(t.from_frame()).map(Grid::n_spatial).unwrap_or(3)
}

/// Whether `matrix` maps a few points as the engine's evaluation does: the
/// structural reading above is held to the engine's own answer.
fn agrees(t: &Transform, matrix: &Array2<f64>) -> BResult<bool> {
    let s = rank_of(t);
    let probes: Vec<Vec<f64>> = vec![
        vec![0.0; s],
        {
            let mut v = vec![0.0; s];
            v[0] = 97.0;
            v
        },
        {
            let mut v = vec![0.0; s];
            v[s - 1] = -53.0;
            v
        },
        (0..s).map(|i| 11.0 + 7.0 * i as f64).collect(),
    ];
    let flat: Vec<f64> = probes.iter().flatten().copied().collect();
    let points = ArrayD::from_shape_vec(IxDyn(&[probes.len(), s]), flat)?;
    let mapped = t.transform_points(&points)?;
    for (i, p) in probes.iter().enumerate() {
        let mut x = [0.0, 0.0, 0.0, 1.0];
        for (k, v) in p.iter().enumerate().take(3) {
            x[k] = *v;
        }
        for r in 0..s.min(3) {
            let expected: f64 = (0..4).map(|c| matrix[[r, c]] * x[c]).sum();
            let got = mapped[[i, r]];
            if (expected - got).abs() > 1e-6 * (1.0 + got.abs()) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// The steps of a resolved transform: `(id, inverted)` in application order.
fn path_of(t: &Transform) -> Vec<(String, bool)> {
    match &t.body {
        Body::Chain(steps) => steps.iter().flat_map(path_of).collect(),
        Body::Inverse(inner) => vec![(inner.transform_id.clone(), true)],
        Body::Stored => vec![(t.transform_id.clone(), false)],
    }
}

/// `T(x) − x` in world units at the voxel centres of `grid` subsampled by
/// `step`, as `(n0, n1, n2, 3)` `float32` (a 2-D grid is one slice, its `z`
/// displacement 0), and the lattice it was sampled on.
pub fn displacement_field(t: &Transform, grid: &Grid, step: usize) -> BResult<(NdArray, Value)> {
    let s = grid.n_spatial();
    if !(2..=3).contains(&s) {
        return Err(BridgeError::argument(format!("a field grid of {s} spatial axes; 2 or 3 are sampled")));
    }
    let spatial = grid.spatial_shape();
    let sub: Vec<usize> = spatial.iter().map(|n| n.div_ceil(step)).collect();
    let padded: [usize; 3] = if s == 3 { [sub[0], sub[1], sub[2]] } else { [1, sub[0], sub[1]] };
    let total: usize = sub.iter().product();
    let mut out = vec![0f32; total * 3];
    const BATCH: usize = 1 << 16;
    let mut index = vec![0usize; s];
    let mut done = 0;
    while done < total {
        let n = BATCH.min(total - done);
        let mut indices = Vec::with_capacity(n * s);
        for _ in 0..n {
            indices.extend(index.iter().map(|i| (i * step) as f64));
            for axis in (0..s).rev() {
                index[axis] += 1;
                if index[axis] < sub[axis] {
                    break;
                }
                index[axis] = 0;
            }
        }
        let world = grid.index_to_world(&indices)?;
        let points = ArrayD::from_shape_vec(IxDyn(&[n, s]), world.clone())?;
        let mapped = t.transform_points(&points)?;
        for p in 0..n {
            for c in 0..s {
                out[(done + p) * 3 + c] = (mapped[[p, c]] - world[p * s + c]) as f32;
            }
        }
        done += n;
    }
    let field = NdArray::F32(ArrayD::from_shape_vec(IxDyn(&[padded[0], padded[1], padded[2], 3]), out)?);
    let mut lattice = grid.clone();
    let lead = grid.shape.len() - s;
    for (axis, extent) in sub.iter().enumerate() {
        lattice.shape[lead + axis] = *extent as i64;
        lattice.spacing[axis] = grid.spacing[axis] * step as f64;
    }
    lattice.shape = lattice.shape[lead..].to_vec();
    lattice.axis_kinds = lattice.axis_kinds[lead..].to_vec();
    lattice.axis_names = lattice.axis_names[lead..].to_vec();
    lattice.time_values = None;
    lattice.time_units = None;
    let mut described = grid_json(&lattice);
    described["id"] = json!(format!("{}@{step}", grid.grid_id));
    Ok((field, described))
}

#[no_mangle]
pub extern "C" fn m5_transform_read(
    sample: *mut M5Sample,
    transform_id: *const c_char,
    out: *mut *mut M5Bundle,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let id = ffi::arg_str(transform_id, "transform_id")?;
        let slot = ffi::arg_out(out, "out")?;
        let s = handle.sample()?;
        let t = handle.transform(&s, id)?;
        let mut bundle = M5Bundle::new(&transform_json(&t)?);
        match t.kind() {
            "affine" => bundle.push("matrix", NdArray::F64(t.matrix()?.into_dyn())),
            "displacement" => bundle.push("field", t.read_field(None, None)?),
            "bspline" => bundle.push("control_points", NdArray::F64(t.control_points()?)),
            _ => {}
        }
        *slot = bundle.into_raw();
        Ok(())
    })
}

fn resolve(
    handle: &M5Sample,
    from_key: &str,
    to_key: &str,
    field_grid: Option<&str>,
    field_step: u32,
) -> BResult<M5Bundle> {
    let s = handle.sample()?;
    let from_frames = s.frames_for(from_key)?;
    let to_frames = s.frames_for(to_key)?;
    let same_frame = !from_frames.is_empty() && from_frames.first() == to_frames.first() && from_frames.len() == 1;
    let resolved = s.transform_between(from_key, to_key)?;
    let Some(t) = resolved else {
        return Ok(M5Bundle::new(&json!({
            "found": false,
            "same_frame": same_frame,
            "from_frames": from_frames,
            "to_frames": to_frames,
            "linear": same_frame,
            "path": [],
            "field_grid": null,
        })));
    };
    let path = path_of(&t);
    let mut matrix = linear_matrix(&t)?;
    if let Some(m) = &matrix {
        if !agrees(&t, m)? {
            matrix = None;
        }
    }
    let mut header = json!({
        "found": true,
        "same_frame": false,
        "kind": t.kind(),
        "from_frame": t.from_frame(),
        "to_frame": t.to_frame(),
        "from_frames": from_frames,
        "to_frames": to_frames,
        "units": t.units(),
        "linear": matrix.is_some(),
        "path": path.iter().map(|(id, _)| id.clone()).collect::<Vec<_>>(),
        "inverted": path.iter().map(|(_, inv)| *inv).collect::<Vec<_>>(),
        "description": t.transform_id,
        "field_grid": null,
    });
    let mut arrays: Vec<(&str, NdArray)> = Vec::new();
    match matrix {
        Some(m) => arrays.push(("matrix", NdArray::F64(m.into_dyn()))),
        None => {
            if let Some(grid_id) = field_grid {
                let grid = s.grid(grid_id)?;
                if grid.frame_uid.as_deref() != Some(t.from_frame()) {
                    return Err(BridgeError::from(medh5::Error::coded(
                        "E414",
                        format!(
                            "grid {grid_id:?} is in frame {:?}, not the frame {:?} the transform maps from; a field is \
                             sampled where its points are",
                            grid.frame_uid,
                            t.from_frame()
                        ),
                    )));
                }
                let (field, lattice) = displacement_field(&t, grid, field_step as usize)?;
                header["field_grid"] = lattice;
                arrays.push(("displacement", field));
            }
        }
    }
    let mut bundle = M5Bundle::new(&header);
    for (name, array) in arrays {
        bundle.push(name, array);
    }
    Ok(bundle)
}

#[no_mangle]
pub extern "C" fn m5_transform_resolve(
    sample: *mut M5Sample,
    from_key: *const c_char,
    to_key: *const c_char,
    field_grid_id: *const c_char,
    field_step: u32,
    out: *mut *mut M5Bundle,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let from_key = ffi::arg_str(from_key, "from_key")?;
        let to_key = ffi::arg_str(to_key, "to_key")?;
        let field_grid = ffi::arg_opt_str(field_grid_id, "field_grid_id")?;
        let slot = ffi::arg_out(out, "out")?;
        let bundle = resolve(handle, from_key, to_key, field_grid, field_step.max(1))?;
        *slot = bundle.into_raw();
        Ok(())
    })
}
