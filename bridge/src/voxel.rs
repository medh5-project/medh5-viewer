//! Voxel annotations as the viewer holds them: mutually exclusive `uint16`
//! layers (spec §7.2), for every encoding; masks, probabilities, instances.
//!
//! `labelmap` and `layers` are read as stored.  `bitmask`, `probmap` and
//! `instances` are packed into layers by measuring which classes overlap and
//! colouring that graph with the engine's own greedy colouring (the one its
//! `layers` encoder uses), so two classes share a layer only if they never
//! share a voxel.  Classes are the stored ones: `closure` is not applied.

use std::collections::{BTreeSet, HashSet};
use std::ffi::{c_char, c_void};
use std::sync::{Arc, PoisonError};

use medh5::annotations::encode::{contains_at, BITS_PER_PLANE};
use medh5::annotations::select::{greedy_colour, layers_from_colouring};
use medh5::annotations::{Annotation, Instance};
use medh5::array::{Index, NdArray, Slice};
use medh5::h5::data;
use medh5::labels::ClassKey;
use serde_json::{json, Map, Value};

use crate::ffi::{self, guard, BResult, BridgeError, M5ProgressFn, M5Status, Progress};
use crate::image::{plan_slabs, slab_slices};
use crate::sample::{handle, M5Sample};

/// Bytes of decoded planes one scan holds at a time, about.
const SCAN_BYTES: usize = 64 << 20;

/// How an annotation's classes split into mutually exclusive layers.
#[derive(Debug, Clone)]
pub struct LayerPlan {
    pub ann_id: String,
    pub kind: String,
    pub spatial_shape: Vec<usize>,
    pub layers: Vec<Vec<i64>>,
    pub class_ids: Vec<i64>,
    pub annotated_class_ids: Vec<i64>,
    pub closure: String,
    pub ignore_id: i64,
    pub ignore_in_band: bool,
    pub ignore_mask: Option<String>,
    pub threshold: Option<f64>,
    pub instances: bool,
    /// The overlapping class pairs measured (packed encodings only).
    pub overlaps: Vec<(i64, i64)>,
}

impl LayerPlan {
    pub fn to_json(&self) -> Value {
        json!({
            "annotation": self.ann_id,
            "kind": self.kind,
            "spatial_shape": self.spatial_shape,
            "layers": self.layers,
            "class_ids": self.class_ids,
            "annotated_class_ids": self.annotated_class_ids,
            "closure": self.closure,
            "ignore_id": self.ignore_id,
            "ignore_in_band": self.ignore_in_band,
            "ignore_mask": self.ignore_mask,
            "threshold": self.threshold,
            "instances": self.instances,
            "overlaps": self.overlaps.iter().map(|(a, b)| json!([a, b])).collect::<Vec<_>>(),
        })
    }

    /// The layer holding `class_id`.
    pub fn layer_of(&self, class_id: i64) -> Option<usize> {
        self.layers.iter().position(|l| l.contains(&class_id))
    }
}

/// The annotation read without the label set when its `closure` could make
/// a reader infer ancestors (§5.4): every class is then read as stored.
fn literal(a: &Arc<Annotation>) -> BResult<Arc<Annotation>> {
    if a.closure() != "implicit" || a.label_set().is_none() {
        return Ok(a.clone());
    }
    Ok(Arc::new(Annotation::open(&a.ann_id, a.group.clone(), Arc::new(a.grids().clone()), None)?))
}

fn window_index(prefix: Option<usize>, window: &[(usize, usize)]) -> Vec<Index> {
    let mut out: Vec<Index> = prefix.map(|p| Index::At(p as i64)).into_iter().collect();
    out.extend(window.iter().map(|(a, b)| Index::Slice(Slice::new(*a as i64, *b as i64))));
    out
}

fn slab_window(window: &[(usize, usize)], a: usize, b: usize) -> Vec<(usize, usize)> {
    let mut w = window.to_vec();
    w[0] = (a, b);
    w
}

fn add_pattern_edges(positions: &[usize], class_ids: &[i64], edges: &mut BTreeSet<(i64, i64)>) {
    for (i, a) in positions.iter().enumerate() {
        for b in &positions[i + 1..] {
            let (x, y) = (class_ids[*a], class_ids[*b]);
            edges.insert((x.min(y), x.max(y)));
        }
    }
}

/// The overlapping class pairs of a `bitmask`: every distinct bit pattern of
/// two or more bits, read a slab of every plane at a time.
fn bitmask_edges(a: &Annotation) -> BResult<BTreeSet<(i64, i64)>> {
    let ids: Vec<i64> = a.bit_class_ids()?.into_iter().map(i64::from).collect();
    let mut edges = BTreeSet::new();
    if ids.len() < 2 {
        return Ok(edges);
    }
    let ds = a.data()?;
    let planes = ds.shape().first().copied().unwrap_or(0);
    let window = a.window(None)?;
    let chunk0 = data::chunks(&ds).and_then(|c| c.get(1).copied());
    let mut seen: HashSet<Vec<u64>> = HashSet::new();
    for (lo, hi) in plan_slabs(&window, 8 * planes.max(1), chunk0, SCAN_BYTES) {
        let w = slab_window(&window, lo, hi);
        let words: Vec<Vec<u64>> = (0..planes)
            .map(|p| Ok(data::read_region(&ds, &window_index(Some(p), &w))?.cast::<u64>().iter().copied().collect()))
            .collect::<BResult<_>>()?;
        let voxels = words.first().map(Vec::len).unwrap_or(0);
        let mut pattern = vec![0u64; planes];
        let mut last: Option<Vec<u64>> = None;
        for v in 0..voxels {
            let mut bits = 0u32;
            for (slot, plane) in pattern.iter_mut().zip(&words) {
                *slot = plane[v];
                bits += slot.count_ones();
            }
            if bits < 2 || last.as_deref() == Some(&pattern[..]) {
                continue;
            }
            last = Some(pattern.clone());
            seen.insert(pattern.clone());
        }
    }
    for pattern in seen {
        let positions: Vec<usize> = (0..planes * BITS_PER_PLANE)
            .filter(|bit| (pattern[bit / BITS_PER_PLANE] >> (bit % BITS_PER_PLANE)) & 1 == 1)
            .filter(|bit| *bit < ids.len())
            .collect();
        add_pattern_edges(&positions, &ids, &mut edges);
    }
    Ok(edges)
}

/// The overlapping class pairs of a `probmap` under its threshold.
fn probmap_edges(a: &Annotation) -> BResult<BTreeSet<(i64, i64)>> {
    let ids = a.class_ids().to_vec();
    let mut edges = BTreeSet::new();
    if ids.len() < 2 {
        return Ok(edges);
    }
    let ds = a.data()?;
    let threshold = a.threshold()?;
    let words = ids.len().div_ceil(64);
    let window = a.window(None)?;
    let chunk0 = data::chunks(&ds).and_then(|c| c.get(1).copied());
    let mut seen: HashSet<Vec<u64>> = HashSet::new();
    for (lo, hi) in plan_slabs(&window, 8 * words, chunk0, SCAN_BYTES) {
        let w = slab_window(&window, lo, hi);
        let voxels: usize = w.iter().map(|(a, b)| b - a).product();
        let mut bits = vec![0u64; voxels * words];
        for (position, _) in ids.iter().enumerate() {
            let inside = contains_at(&data::read_region(&ds, &window_index(Some(position), &w))?, threshold);
            for (v, hit) in inside.iter().enumerate() {
                if *hit {
                    bits[v * words + position / 64] |= 1u64 << (position % 64);
                }
            }
        }
        for pattern in bits.chunks_exact(words).take(voxels) {
            if pattern.iter().map(|w| w.count_ones()).sum::<u32>() >= 2 && !seen.contains(pattern) {
                seen.insert(pattern.to_vec());
            }
        }
    }
    for pattern in seen {
        let positions: Vec<usize> = (0..ids.len()).filter(|p| (pattern[p / 64] >> (p % 64)) & 1 == 1).collect();
        add_pattern_edges(&positions, &ids, &mut edges);
    }
    Ok(edges)
}

/// `[lo, hi)` per axis of an object's voxels: its box (§8.1), unclipped.
fn object_slices(object: &Instance) -> BResult<Vec<(i64, i64)>> {
    Ok(object.slices()?)
}

/// Whether two objects share a voxel: their boxes meet, and so do their
/// masks (an object without a mask is its whole box).
fn objects_overlap(a: &Instance, b: &Instance) -> BResult<bool> {
    let (sa, sb) = (object_slices(a)?, object_slices(b)?);
    let mut meet = Vec::with_capacity(sa.len());
    for ((alo, ahi), (blo, bhi)) in sa.iter().zip(&sb) {
        let (lo, hi) = ((*alo).max(*blo), (*ahi).min(*bhi));
        if hi <= lo {
            return Ok(false);
        }
        meet.push((lo, hi));
    }
    let at = |object: &Instance, slices: &[(i64, i64)], voxel: &[i64]| -> bool {
        match &object.mask {
            None => true,
            Some(mask) => {
                let local: Vec<usize> = voxel.iter().zip(slices).map(|(v, (lo, _))| (v - lo) as usize).collect();
                mask.get(local.as_slice()).copied().unwrap_or(false)
            }
        }
    };
    let mut voxel: Vec<i64> = meet.iter().map(|(lo, _)| *lo).collect();
    loop {
        if at(a, &sa, &voxel) && at(b, &sb, &voxel) {
            return Ok(true);
        }
        let mut axis = voxel.len();
        loop {
            if axis == 0 {
                return Ok(false);
            }
            axis -= 1;
            voxel[axis] += 1;
            if voxel[axis] < meet[axis].1 {
                break;
            }
            voxel[axis] = meet[axis].0;
        }
    }
}

/// The overlapping class pairs of an `instances` annotation: objects of two
/// classes that share a voxel.
fn instances_edges(objects: &[Instance]) -> BResult<BTreeSet<(i64, i64)>> {
    let mut edges = BTreeSet::new();
    for (i, a) in objects.iter().enumerate() {
        for b in &objects[i + 1..] {
            if a.class_id == b.class_id {
                continue;
            }
            let key = (a.class_id.min(b.class_id), a.class_id.max(b.class_id));
            if edges.contains(&key) {
                continue;
            }
            if objects_overlap(a, b)? {
                edges.insert(key);
            }
        }
    }
    Ok(edges)
}

/// The plan of one annotation, computed (it may read the annotation whole).
pub fn compute_plan(a: &Arc<Annotation>) -> BResult<LayerPlan> {
    if !a.is_voxel() {
        return Err(BridgeError::from(medh5::Error::Type(format!(
            "annotation {:?} is a {} annotation; layers are defined on voxel annotations",
            a.ann_id,
            a.kind()
        ))));
    }
    let class_ids = a.class_ids().to_vec();
    let mut overlaps = Vec::new();
    let mut threshold = None;
    let layers: Vec<Vec<i64>> = match a.kind() {
        "labelmap" => vec![class_ids.clone()],
        "layers" => a.layer_classes()?,
        "mask" => Vec::new(),
        kind => {
            let view = literal(a)?;
            let edges = match kind {
                "bitmask" => bitmask_edges(&view)?,
                "probmap" => {
                    threshold = Some(view.threshold()?);
                    probmap_edges(&view)?
                }
                _ => instances_edges(&view.instances()?)?,
            };
            overlaps = edges.iter().copied().collect();
            let colouring = greedy_colour(&class_ids, &edges);
            layers_from_colouring(&colouring)
        }
    };
    let ignore_in_band = matches!(a.kind(), "labelmap" | "layers") && a.encodes_ignore()?;
    Ok(LayerPlan {
        ann_id: a.ann_id.clone(),
        kind: a.kind().to_string(),
        spatial_shape: a.spatial_shape()?,
        layers,
        class_ids,
        annotated_class_ids: a.annotated_class_ids().to_vec(),
        closure: a.closure().to_string(),
        ignore_id: a.ignore_id(),
        ignore_in_band,
        ignore_mask: a.header.ignore_mask.clone(),
        threshold,
        instances: a.kind() == "instances",
        overlaps,
    })
}

/// The plan of an annotation of the handle's sample, computed once.
pub fn plan_for(handle: &M5Sample, ann_id: &str) -> BResult<(Arc<Annotation>, Arc<LayerPlan>)> {
    let sample = handle.sample()?;
    let annotation = handle.annotation(&sample, ann_id)?;
    if let Some(plan) = handle.plans.lock().unwrap_or_else(PoisonError::into_inner).get(ann_id) {
        return Ok((annotation, plan.clone()));
    }
    let plan = Arc::new(compute_plan(&annotation)?);
    handle.plans.lock().unwrap_or_else(PoisonError::into_inner).insert(ann_id.to_string(), plan.clone());
    Ok((annotation, plan))
}

#[no_mangle]
pub extern "C" fn m5_annotation_layer_plan(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        ffi::arg_out(out_json, "out_json")?;
        let (_, plan) = plan_for(handle, ann_id)?;
        ffi::write_out_json(out_json, &plan.to_json())
    })
}

/// A typed output buffer of `count` elements.
fn out_slice<'a, T>(out: *mut T, out_count: usize, expected: usize) -> BResult<&'a mut [T]> {
    if out_count != expected {
        return Err(BridgeError::argument(format!(
            "the buffer holds {out_count} elements; the region needs {expected}"
        )));
    }
    if expected == 0 {
        return Ok(&mut []);
    }
    if out.is_null() {
        return Err(BridgeError::argument("out is NULL"));
    }
    // SAFETY: the caller passes a writable buffer of `out_count` elements.
    Ok(unsafe { std::slice::from_raw_parts_mut(out, out_count) })
}

/// Paint each object `value` gives a value, over `window`: the voxels of
/// its mask (or its whole box), clipped to the window.  Objects later in the
/// list paint over earlier ones.
fn paint_objects<T: Copy>(
    objects: &[Instance],
    window: &[(usize, usize)],
    out: &mut [T],
    progress: &Progress,
    value: impl Fn(usize, &Instance) -> Option<T>,
) -> BResult<()> {
    let extents: Vec<usize> = window.iter().map(|(a, b)| b - a).collect();
    let total = objects.len() as u64;
    for (index, object) in objects.iter().enumerate() {
        progress.report(index as u64, total)?;
        let Some(v) = value(index, object) else { continue };
        let slices = object_slices(object)?;
        if slices.len() != window.len() {
            return Err(BridgeError::engine(
                "validation",
                format!("object {index} has a box of {} axes on a grid of {}", slices.len(), window.len()),
            ));
        }
        let mut meet = Vec::with_capacity(window.len());
        let mut empty = false;
        for ((lo, hi), (wlo, whi)) in slices.iter().zip(window) {
            let (a, b) = ((*lo).max(*wlo as i64), (*hi).min(*whi as i64));
            if b <= a {
                empty = true;
                break;
            }
            meet.push((a, b));
        }
        if empty {
            continue;
        }
        if let Some(mask) = &object.mask {
            let expected: Vec<usize> = slices.iter().map(|(lo, hi)| (hi - lo).max(0) as usize).collect();
            if mask.shape() != expected.as_slice() {
                return Err(BridgeError::engine(
                    "validation",
                    format!("object {index}'s stored mask does not cover its box (§7.4)"),
                ));
            }
        }
        let mut voxel: Vec<i64> = meet.iter().map(|(a, _)| *a).collect();
        'walk: loop {
            let inside = match &object.mask {
                None => true,
                Some(mask) => {
                    let local: Vec<usize> = voxel.iter().zip(&slices).map(|(v, (lo, _))| (*v - *lo) as usize).collect();
                    mask[local.as_slice()]
                }
            };
            if inside {
                let mut linear = 0usize;
                for ((v, (wlo, _)), n) in voxel.iter().zip(window).zip(&extents) {
                    linear = linear * n + (*v as usize - wlo);
                }
                out[linear] = v;
            }
            let mut axis = voxel.len();
            loop {
                if axis == 0 {
                    break 'walk;
                }
                axis -= 1;
                voxel[axis] += 1;
                if voxel[axis] < meet[axis].1 {
                    break;
                }
                voxel[axis] = meet[axis].0;
            }
        }
    }
    progress.report(total, total)
}

/// Copy a `uint16` block (any integer type, cast) into `out` at `offset`.
fn copy_u16(block: &NdArray, out: &mut [u16]) -> BResult<()> {
    let values = block.cast::<u16>();
    let values = values.as_standard_layout();
    let slice = values.as_slice().expect("standard layout");
    if slice.len() != out.len() {
        return Err(BridgeError::engine("runtime", "internal: a layer block of the wrong size"));
    }
    out.copy_from_slice(slice);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn read_layer(
    handle: &M5Sample,
    ann_id: &str,
    layer: u32,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    out: *mut u16,
    out_count: usize,
    progress: Progress,
) -> BResult<()> {
    let (annotation, plan) = plan_for(handle, ann_id)?;
    let layer = layer as usize;
    let classes = plan.layers.get(layer).cloned().ok_or_else(|| {
        BridgeError::argument(format!(
            "annotation {ann_id:?} has {} layer(s); there is no layer {layer}",
            plan.layers.len()
        ))
    })?;
    let window = ffi::region(start, stop, ndim, &plan.spatial_shape, false)?;
    let count = ffi::window_count(&window)?;
    let buffer = out_slice(out, out_count, count)?;
    let total = count as u64;
    progress.report(0, total)?;
    if count == 0 {
        return Ok(());
    }
    let row: usize = window[1..].iter().map(|(a, b)| b - a).product();
    match plan.kind.as_str() {
        "labelmap" | "layers" => {
            let ds = annotation.data()?;
            let prefix = if plan.kind == "layers" { Some(layer) } else { None };
            let chunks = data::chunks(&ds);
            let chunk0 = chunks.and_then(|c| c.get(usize::from(prefix.is_some())).copied());
            let itemsize = data::dtype(&ds)?.itemsize().max(2);
            let mut done = 0usize;
            for (a, b) in plan_slabs(&window, itemsize, chunk0, crate::image::SLAB_BYTES) {
                let block = data::read_region(&ds, &window_index(prefix, &slab_window(&window, a, b)))?;
                let n = (b - a) * row;
                let offset = (a - window[0].0) * row;
                copy_u16(&block, &mut buffer[offset..offset + n])?;
                done += n;
                progress.report(done as u64, total)?;
            }
        }
        "bitmask" => {
            let view = literal(&annotation)?;
            let ids: Vec<i64> = view.bit_class_ids()?.into_iter().map(i64::from).collect();
            let ds = view.data()?;
            // Plane -> [(bit, class id)] for the classes of this layer.
            let mut by_plane: std::collections::BTreeMap<usize, Vec<(usize, u16)>> = Default::default();
            for class_id in &classes {
                if let Some(position) = ids.iter().position(|c| c == class_id) {
                    by_plane
                        .entry(position / BITS_PER_PLANE)
                        .or_default()
                        .push((position % BITS_PER_PLANE, *class_id as u16));
                }
            }
            let chunk0 = data::chunks(&ds).and_then(|c| c.get(1).copied());
            let mut done = 0usize;
            for (a, b) in plan_slabs(&window, 8 * by_plane.len().max(1), chunk0, crate::image::SLAB_BYTES) {
                let n = (b - a) * row;
                let offset = (a - window[0].0) * row;
                let slot = &mut buffer[offset..offset + n];
                slot.fill(0);
                for (plane, bits) in &by_plane {
                    let block =
                        data::read_region(&ds, &window_index(Some(*plane), &slab_window(&window, a, b)))?.cast::<u64>();
                    for (o, word) in slot.iter_mut().zip(block.iter()) {
                        if *word == 0 {
                            continue;
                        }
                        for (bit, class_id) in bits {
                            if (word >> bit) & 1 == 1 {
                                *o = *class_id;
                            }
                        }
                    }
                }
                done += n;
                progress.report(done as u64, total)?;
            }
        }
        "probmap" => {
            let view = literal(&annotation)?;
            let ds = view.data()?;
            let threshold = view.threshold()?;
            let positions: Vec<(usize, u16)> = classes
                .iter()
                .filter_map(|c| view.class_ids().iter().position(|k| k == c).map(|p| (p, *c as u16)))
                .collect();
            let chunk0 = data::chunks(&ds).and_then(|c| c.get(1).copied());
            let mut done = 0usize;
            for (a, b) in plan_slabs(&window, 4 * positions.len().max(1), chunk0, crate::image::SLAB_BYTES) {
                let n = (b - a) * row;
                let offset = (a - window[0].0) * row;
                let slot = &mut buffer[offset..offset + n];
                slot.fill(0);
                for (position, class_id) in &positions {
                    let block = data::read_region(&ds, &window_index(Some(*position), &slab_window(&window, a, b)))?;
                    for (o, hit) in slot.iter_mut().zip(contains_at(&block, threshold).iter()) {
                        if *hit {
                            *o = *class_id;
                        }
                    }
                }
                done += n;
                progress.report(done as u64, total)?;
            }
        }
        "instances" => {
            let objects = annotation.instances()?;
            buffer.fill(0);
            paint_objects(&objects, &window, buffer, &progress, |_, o| {
                classes.contains(&o.class_id).then_some(o.class_id as u16)
            })?;
        }
        kind => {
            let message = format!("annotation {ann_id:?} is a {kind} annotation, which has no layers");
            return Err(BridgeError::from(medh5::Error::Type(format!(
                "{message}; read it with m5_annotation_read_mask"
            ))));
        }
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_annotation_read_layer(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    layer: u32,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    out: *mut u16,
    out_count: usize,
    progress: M5ProgressFn,
    context: *mut c_void,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        read_layer(handle, ann_id, layer, start, stop, ndim, out, out_count, Progress::new(progress, context))
    })
}

#[no_mangle]
pub extern "C" fn m5_annotation_read_mask(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    ignore_region: bool,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    out: *mut u8,
    out_count: usize,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        let shape = annotation.spatial_shape()?;
        let window = ffi::region(start, stop, ndim, &shape, false)?;
        let count = ffi::window_count(&window)?;
        let buffer = out_slice(out, out_count, count)?;
        if count == 0 {
            return Ok(());
        }
        let row: usize = window[1..].iter().map(|(a, b)| b - a).product();
        for (a, b) in plan_slabs(&window, 1, None, crate::image::SLAB_BYTES) {
            let slices = slab_slices(&window, a, b);
            let mask = if ignore_region {
                s.ignore_region(ann_id, Some(&slices))?
            } else {
                annotation.read_mask(Some(&slices))?
            };
            let offset = (a - window[0].0) * row;
            for (o, v) in buffer[offset..offset + (b - a) * row].iter_mut().zip(mask.iter()) {
                *o = u8::from(*v);
            }
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_annotation_read_probability(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    class_id: u32,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    out: *mut f32,
    out_count: usize,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        let shape = annotation.spatial_shape()?;
        let window = ffi::region(start, stop, ndim, &shape, false)?;
        let count = ffi::window_count(&window)?;
        let buffer = out_slice(out, out_count, count)?;
        if !annotation.class_ids().contains(&i64::from(class_id)) {
            return Err(BridgeError::from(medh5::Error::Key(format!(
                "annotation {ann_id:?} has no class {class_id} (class_ids {:?})",
                annotation.class_ids()
            ))));
        }
        if count == 0 {
            return Ok(());
        }
        let row: usize = window[1..].iter().map(|(a, b)| b - a).product();
        let key = [ClassKey::Id(i64::from(class_id))];
        for (a, b) in plan_slabs(&window, 4, None, crate::image::SLAB_BYTES) {
            let slices = slab_slices(&window, a, b);
            let block = annotation.probabilities(Some(&key), Some(&slices))?;
            let offset = (a - window[0].0) * row;
            for (o, v) in buffer[offset..offset + (b - a) * row].iter_mut().zip(block.iter()) {
                *o = *v;
            }
        }
        Ok(())
    })
}

fn bbox_json(bbox: &medh5::ndarray::Array2<f32>) -> Value {
    Value::Array(bbox.outer_iter().map(|r| json!([f64::from(r[0]), f64::from(r[1])])).collect())
}

#[no_mangle]
pub extern "C" fn m5_annotation_instances(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        ffi::arg_out(out_json, "out_json")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        let objects = annotation.instances()?;
        let list: Vec<Value> = objects
            .iter()
            .map(|o| {
                Ok(json!({
                    "index": o.index,
                    "instance_id": o.instance_id,
                    "class_id": o.class_id,
                    "bbox": bbox_json(&o.bbox),
                    "voxel_count": o.voxel_count()?,
                    "score": o.score,
                    "has_mask": o.mask.is_some(),
                }))
            })
            .collect::<BResult<_>>()?;
        ffi::write_out_json(out_json, &Value::Array(list))
    })
}

#[no_mangle]
pub extern "C" fn m5_annotation_read_instance_map(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    out: *mut u32,
    out_count: usize,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        if annotation.kind() != "instances" {
            return Err(BridgeError::from(medh5::Error::Type(format!(
                "an instance map is defined on `instances` annotations; {ann_id:?} is a {} annotation",
                annotation.kind()
            ))));
        }
        let shape = annotation.spatial_shape()?;
        let window = ffi::region(start, stop, ndim, &shape, false)?;
        let count = ffi::window_count(&window)?;
        let buffer = out_slice(out, out_count, count)?;
        buffer.fill(0);
        let objects = annotation.instances()?;
        paint_objects(&objects, &window, buffer, &Progress::none(), |index, _| Some(index as u32 + 1))
    })
}

#[no_mangle]
pub extern "C" fn m5_annotation_class_stats(
    sample: *mut M5Sample,
    annotation_id: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let ann_id = ffi::arg_str(annotation_id, "annotation_id")?;
        ffi::arg_out(out_json, "out_json")?;
        let s = handle.sample()?;
        let annotation = handle.annotation(&s, ann_id)?;
        let counts = annotation.voxel_counts(None)?;
        let boxes = annotation.class_bboxes(None)?;
        let mut out = Map::new();
        for (class_id, voxels) in counts {
            let bbox = boxes.get(&class_id).and_then(|b| b.as_ref()).map(bbox_json).unwrap_or(Value::Null);
            out.insert(class_id.to_string(), json!({"voxels": voxels, "bbox": bbox}));
        }
        ffi::write_out_json(out_json, &Value::Object(out))
    })
}
