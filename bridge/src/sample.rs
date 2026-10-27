//! `M5Sample`: an open sample, and the calls that read its metadata.

use std::collections::HashMap;
use std::ffi::c_char;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

use medh5::annotations::Annotation;
use medh5::h5::attrs;
use medh5::h5::ops;
use medh5::sample::{Image, Sample};
use medh5::transforms::Transform;
use serde_json::{json, Map, Value};

use crate::ffi::{self, guard, guard_value, BResult, BridgeError, M5Status};
use crate::voxel::LayerPlan;

/// The opaque `M5Sample`.
///
/// The engine's `Sample` is read-only and shared: a call takes a reference to
/// it under a short lock and reads without holding the lock, so reads of one
/// handle may run in parallel (HDF5 itself is serialised by the engine);
/// `close` takes it away, and a read still under way finishes or reports the
/// file closed.
pub struct M5Sample {
    inner: Mutex<Option<Arc<Sample>>>,
    pub(crate) path: String,
    /// Annotations opened one by one, when the engine's listing of them all
    /// fails because another annotation of the file is damaged.
    fallback: Mutex<HashMap<String, Arc<Annotation>>>,
    /// Layer plans, computed once per annotation (they read it whole).
    pub(crate) plans: Mutex<HashMap<String, Arc<LayerPlan>>>,
}

impl M5Sample {
    fn new(sample: Sample) -> M5Sample {
        let path = sample.path.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        M5Sample {
            inner: Mutex::new(Some(Arc::new(sample))),
            path,
            fallback: Mutex::new(HashMap::new()),
            plans: Mutex::new(HashMap::new()),
        }
    }

    /// The engine sample, refused once closed.
    pub fn sample(&self) -> BResult<Arc<Sample>> {
        let sample = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .ok_or_else(|| BridgeError::from(medh5::Error::File("the sample has been closed".into())))?;
        medh5::h5::alive(&sample.root)?;
        Ok(sample)
    }

    fn close(&self) {
        let taken = self.inner.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(sample) = taken {
            let _ = sample.close_file();
        }
        self.fallback.lock().unwrap_or_else(PoisonError::into_inner).clear();
        self.plans.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }

    /// One image: the engine's, or --- when the engine cannot list the images
    /// because another of them is damaged --- this one opened alone.
    pub fn image(&self, sample: &Sample, image_id: &str) -> BResult<Image> {
        match sample.image(image_id) {
            Ok(image) => Ok(image.clone()),
            Err(error) => {
                if sample.images().is_ok() {
                    return Err(error.into());
                }
                refuse_left_out(sample, "images", image_id)?;
                let node = ops::child_group(&sample.root, "images")
                    .ok_or_else(|| BridgeError::from(medh5::Error::Key(format!("no image {image_id:?}"))))?;
                Ok(Image::open(image_id, &node, sample.grids()?.clone())?)
            }
        }
    }

    /// One annotation, as [`M5Sample::image`] finds an image.
    pub fn annotation(&self, sample: &Sample, ann_id: &str) -> BResult<Arc<Annotation>> {
        match sample.annotation(ann_id) {
            Ok(annotation) => Ok(annotation.clone()),
            Err(error) => {
                if sample.annotations().is_ok() {
                    return Err(error.into());
                }
                if let Some(found) = self.fallback.lock().unwrap_or_else(PoisonError::into_inner).get(ann_id) {
                    return Ok(found.clone());
                }
                refuse_left_out(sample, "annotations", ann_id)?;
                let node = ops::child_group(&sample.root, "annotations")
                    .ok_or_else(|| BridgeError::from(medh5::Error::Key(format!("no annotation {ann_id:?}"))))?;
                let group = ops::child_group(&node, ann_id)
                    .ok_or_else(|| BridgeError::from(medh5::Error::Key(format!("no annotation {ann_id:?}"))))?;
                let label_set = sample.label_set().ok().flatten().cloned().map(Arc::new);
                let opened = Arc::new(Annotation::open(ann_id, group, sample.grids()?.clone(), label_set)?);
                self.fallback.lock().unwrap_or_else(PoisonError::into_inner).insert(ann_id.to_string(), opened.clone());
                Ok(opened)
            }
        }
    }

    /// One transform, as [`M5Sample::image`] finds an image.
    pub fn transform(&self, sample: &Sample, transform_id: &str) -> BResult<Transform> {
        match sample.transform(transform_id) {
            Ok(t) => Ok(t.clone()),
            Err(error) => {
                if sample.transforms().is_ok() {
                    return Err(error.into());
                }
                refuse_left_out(sample, "transforms", transform_id)?;
                let groups = medh5::transforms::model::transform_groups(&sample.root)?;
                let group = groups
                    .get(transform_id)
                    .cloned()
                    .ok_or_else(|| BridgeError::from(medh5::Error::Key(format!("no transform {transform_id:?}"))))?;
                Ok(Transform::open(transform_id, group, sample.grids()?.clone(), Arc::new(groups))?)
            }
        }
    }
}

/// W913 for an object a later minor's projection leaves out.
fn refuse_left_out(sample: &Sample, group: &str, id: &str) -> BResult<()> {
    if let Ok(left_out) = sample.left_out() {
        if let Some(error) = left_out.get(&format!("{group}/{id}")) {
            return Err(error.clone().into());
        }
    }
    Ok(())
}

pub fn handle<'a>(ptr: *mut M5Sample) -> BResult<&'a M5Sample> {
    if ptr.is_null() {
        return Err(BridgeError::argument("sample is NULL"));
    }
    // SAFETY: a handle this bridge made and the caller has not closed.
    Ok(unsafe { &*ptr })
}

fn publish(sample: Sample, out: *mut *mut M5Sample) -> BResult<()> {
    let slot = ffi::arg_out(out, "out")?;
    *slot = Box::into_raw(Box::new(M5Sample::new(sample)));
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_sample_open(path: *const c_char, out: *mut *mut M5Sample) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        ffi::arg_out(out, "out")?;
        let sample = medh5::sample::open_sample(Path::new(path))?;
        publish(sample, out)
    })
}

#[no_mangle]
pub extern "C" fn m5_sample_open_member(
    collection_path: *const c_char,
    member: *const c_char,
    out: *mut *mut M5Sample,
) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(collection_path, "collection_path")?;
        let member = ffi::arg_str(member, "member")?;
        ffi::arg_out(out, "out")?;
        let collection = medh5::collection::open_collection(Path::new(path))?;
        let sample = collection.into_member(member)?;
        publish(sample, out)
    })
}

#[no_mangle]
pub extern "C" fn m5_sample_close(sample: *mut M5Sample) {
    guard_value((), || {
        if !sample.is_null() {
            // SAFETY: a handle this bridge made, closed once.
            let handle = unsafe { Box::from_raw(sample) };
            handle.close();
        }
    })
}

#[no_mangle]
pub extern "C" fn m5_sample_summary(sample: *mut M5Sample, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        ffi::arg_out(out_json, "out_json")?;
        let summary = crate::summary::sample_summary(handle)?;
        ffi::write_out_json(out_json, &summary)
    })
}

#[no_mangle]
pub extern "C" fn m5_sample_document(sample: *mut M5Sample, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        ffi::arg_out(out_json, "out_json")?;
        let s = handle.sample()?;
        let text = medh5::sample::read_document_text(&s.root)?;
        ffi::write_out_string(out_json, text)
    })
}

/// The integrity report (§13).
pub fn verify_json(sample: &Sample) -> BResult<Value> {
    let result = sample.verify(None)?;
    let mismatched: std::collections::HashSet<&String> = result.mismatched.iter().collect();
    let malformed: std::collections::HashSet<&String> = result.malformed.iter().collect();
    let objects: Vec<Value> = result
        .checked
        .iter()
        .map(|path| {
            let state = if mismatched.contains(path) {
                "mismatched"
            } else if malformed.contains(path) {
                "malformed"
            } else {
                "ok"
            };
            json!({"path": path, "ok": state == "ok", "state": state})
        })
        .collect();
    Ok(json!({
        "ok": result.ok(),
        "content_id": {
            "stored": result.content_id_declared,
            "computed": result.content_id_computed,
            "ok": result.content_id_ok(),
        },
        "objects": objects,
        "mismatched": result.mismatched,
        "malformed": result.malformed,
        "undigested": result.undigested,
        "unattested": result.unattested,
        "unverifiable": result.unverifiable,
        "stale_index": result.stale_index,
    }))
}

#[no_mangle]
pub extern "C" fn m5_sample_verify(sample: *mut M5Sample, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        ffi::arg_out(out_json, "out_json")?;
        let report = verify_json(handle.sample()?.as_ref())?;
        ffi::write_out_json(out_json, &report)
    })
}

/// The raw attributes of one object, `{name: value}`.
pub fn attributes_json(sample: &Sample, object_path: &str) -> BResult<Value> {
    let root = &sample.root;
    let path = object_path.trim_matches('/');
    let location: hdf5_location::Location = if path.is_empty() {
        (**root).clone()
    } else {
        let (parent, name) = match path.rsplit_once('/') {
            Some((parent, name)) => (
                root.group(parent).map_err(|_| {
                    BridgeError::from(medh5::Error::Key(format!("no object {object_path:?} in the sample")))
                })?,
                name,
            ),
            None => (root.clone(), path),
        };
        match ops::node_kind(&parent, name) {
            Some(ops::NodeKind::Group) => (*parent.group(name).map_err(medh5::Error::from)?).clone(),
            Some(ops::NodeKind::Dataset) => (**parent.dataset(name).map_err(medh5::Error::from)?).clone(),
            _ => {
                return Err(BridgeError::from(medh5::Error::Key(format!(
                    "no group or dataset {object_path:?} in the sample"
                ))))
            }
        }
    };
    let mut out = Map::new();
    for name in attrs::names(&location)? {
        let value = match attrs::read(&location, &name) {
            Ok(Some(v)) => attr_json(&v),
            Ok(None) => Value::Null,
            Err(e) => json!({"error": e.message()}),
        };
        out.insert(name, value);
    }
    Ok(Value::Object(out))
}

/// An attribute value as JSON; a non-finite float is spelled as text.
pub fn attr_json(value: &medh5::AttrValue) -> Value {
    match value {
        medh5::AttrValue::Float(f) if !f.is_finite() => Value::String(medh5::json::float_repr(*f)),
        other => other.to_json(),
    }
}

/// The HDF5 types the engine re-exports.
mod hdf5_location {
    pub use medh5::hdf5::Location;
}

#[no_mangle]
pub extern "C" fn m5_sample_attributes(
    sample: *mut M5Sample,
    object_path: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let object_path = ffi::arg_str(object_path, "object_path")?;
        ffi::arg_out(out_json, "out_json")?;
        let value = attributes_json(handle.sample()?.as_ref(), object_path)?;
        ffi::write_out_json(out_json, &value)
    })
}
