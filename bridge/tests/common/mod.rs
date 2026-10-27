//! Helpers for calling the bridge through its C ABI from Rust tests.
#![allow(dead_code)]

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

use medh5_bridge::*;
use serde_json::Value;

/// A directory removed when dropped.
pub struct TempDir(pub PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("medh5-bridge-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    pub fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

pub fn cp(p: &Path) -> CString {
    CString::new(p.to_str().unwrap()).unwrap()
}

/// Take a bridge string (and free it).
pub fn take(p: *mut c_char) -> String {
    assert!(!p.is_null(), "a NULL string where one was expected");
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    m5_string_free(p);
    s
}

pub fn take_json(p: *mut c_char) -> Value {
    serde_json::from_str(&take(p)).expect("bridge JSON")
}

/// The calling thread's last error, as JSON (Null when none).
pub fn last_error() -> Value {
    let p = m5_last_error();
    if p.is_null() {
        Value::Null
    } else {
        take_json(p)
    }
}

#[track_caller]
pub fn ok(status: M5Status) {
    if status != M5_OK {
        panic!("status {status}: {}", last_error());
    }
}

/// A call that must fail with `expected`; returns the error JSON.
#[track_caller]
pub fn fails(status: M5Status, expected: M5Status) -> Value {
    assert_eq!(status, expected, "expected status {expected}, got {status}");
    let error = last_error();
    assert_eq!(error["status"], expected, "{error}");
    assert!(error["message"].as_str().is_some_and(|m| !m.is_empty()), "{error}");
    error
}

/// The demo sample, written once per test process (do not modify it:
/// copy it first).
pub fn demo() -> &'static Path {
    static DEMO: OnceLock<PathBuf> = OnceLock::new();
    DEMO.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("medh5-bridge-demo-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("demo.medh5");
        ok(m5_demo_write(cp(&path).as_ptr(), std::ptr::null()));
        path
    })
}

/// A copy of the demo in `dir`.
pub fn demo_copy(dir: &TempDir, name: &str) -> PathBuf {
    let path = dir.path(name);
    std::fs::copy(demo(), &path).unwrap();
    path
}

/// An open sample, closed when dropped.
pub struct Sample(pub *mut M5Sample);

unsafe impl Send for Sample {}
unsafe impl Sync for Sample {}

impl Sample {
    pub fn open(path: &Path) -> Sample {
        let mut out = std::ptr::null_mut();
        ok(m5_sample_open(cp(path).as_ptr(), &mut out));
        assert!(!out.is_null());
        Sample(out)
    }

    pub fn summary(&self) -> Value {
        let mut out = std::ptr::null_mut();
        ok(m5_sample_summary(self.0, &mut out));
        take_json(out)
    }

    pub fn plan(&self, ann: &str) -> Value {
        let mut out = std::ptr::null_mut();
        ok(m5_annotation_layer_plan(self.0, c(ann).as_ptr(), &mut out));
        take_json(out)
    }

    pub fn layer(&self, ann: &str, layer: u32, count: usize) -> Vec<u16> {
        let mut out = vec![0u16; count];
        ok(m5_annotation_read_layer(
            self.0,
            c(ann).as_ptr(),
            layer,
            std::ptr::null(),
            std::ptr::null(),
            0,
            out.as_mut_ptr(),
            count,
            None,
            std::ptr::null_mut(),
        ));
        out
    }

    pub fn image_i16(&self, id: &str, count: usize) -> Vec<i16> {
        let mut out = vec![0i16; count];
        ok(m5_image_read(
            self.0,
            c(id).as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            M5_DTYPE_NATIVE,
            out.as_mut_ptr() as *mut c_void,
            count * 2,
            None,
            std::ptr::null_mut(),
        ));
        out
    }

    pub fn json_call(
        &self,
        f: extern "C" fn(*mut M5Sample, *const c_char, *mut *mut c_char) -> M5Status,
        arg: &str,
    ) -> Value {
        let mut out = std::ptr::null_mut();
        ok(f(self.0, c(arg).as_ptr(), &mut out));
        take_json(out)
    }
}

impl Drop for Sample {
    fn drop(&mut self) {
        m5_sample_close(self.0);
    }
}

/// A bundle, freed when dropped.
pub struct Bundle(pub *mut M5Bundle);

impl Bundle {
    pub fn header(&self) -> Value {
        let p = m5_bundle_header(self.0);
        assert!(!p.is_null());
        serde_json::from_str(unsafe { CStr::from_ptr(p) }.to_str().unwrap()).unwrap()
    }

    pub fn view(&self, name: &str) -> Option<M5ArrayView> {
        let mut view = M5ArrayView::default();
        match m5_bundle_array_named(self.0, c(name).as_ptr(), &mut view) {
            M5_OK => Some(view),
            M5_ERR_NOT_FOUND => None,
            other => panic!("status {other}: {}", last_error()),
        }
    }

    pub fn names(&self) -> Vec<String> {
        let n = m5_bundle_array_count(self.0);
        (0..n)
            .map(|i| {
                let mut view = M5ArrayView::default();
                ok(m5_bundle_array_at(self.0, i, &mut view));
                unsafe { CStr::from_ptr(view.name) }.to_string_lossy().into_owned()
            })
            .collect()
    }

    pub fn shape(&self, name: &str) -> Vec<i64> {
        let v = self.view(name).unwrap_or_else(|| panic!("no array {name}"));
        unsafe { std::slice::from_raw_parts(v.shape, v.ndim as usize) }.to_vec()
    }

    /// An array's elements as f64.
    pub fn f64s(&self, name: &str) -> Vec<f64> {
        let v = self.view(name).unwrap_or_else(|| panic!("no array {name}"));
        let n: i64 = unsafe { std::slice::from_raw_parts(v.shape, v.ndim as usize) }.iter().product();
        let n = n as usize;
        unsafe {
            match v.dtype {
                1 | 2 => std::slice::from_raw_parts(v.data as *const u8, n).iter().map(|x| f64::from(*x)).collect(),
                3 => std::slice::from_raw_parts(v.data as *const i8, n).iter().map(|x| f64::from(*x)).collect(),
                4 => std::slice::from_raw_parts(v.data as *const u16, n).iter().map(|x| f64::from(*x)).collect(),
                5 => std::slice::from_raw_parts(v.data as *const i16, n).iter().map(|x| f64::from(*x)).collect(),
                6 => std::slice::from_raw_parts(v.data as *const u32, n).iter().map(|x| f64::from(*x)).collect(),
                7 => std::slice::from_raw_parts(v.data as *const i32, n).iter().map(|x| f64::from(*x)).collect(),
                8 => std::slice::from_raw_parts(v.data as *const u64, n).iter().map(|x| *x as f64).collect(),
                9 => std::slice::from_raw_parts(v.data as *const i64, n).iter().map(|x| *x as f64).collect(),
                10 => std::slice::from_raw_parts(v.data as *const half::f16, n).iter().map(|x| x.to_f64()).collect(),
                11 => std::slice::from_raw_parts(v.data as *const f32, n).iter().map(|x| f64::from(*x)).collect(),
                12 => std::slice::from_raw_parts(v.data as *const f64, n).to_vec(),
                other => panic!("dtype {other}"),
            }
        }
    }
}

impl Drop for Bundle {
    fn drop(&mut self) {
        m5_bundle_free(self.0);
    }
}

pub fn geometry(sample: &Sample, ann: &str) -> Bundle {
    let mut out = std::ptr::null_mut();
    ok(m5_annotation_geometry(sample.0, c(ann).as_ptr(), &mut out));
    Bundle(out)
}

/// An array view of caller data, for the writer calls.
pub struct Owned {
    pub name: CString,
    pub shape: Vec<i64>,
    pub bytes: Vec<u8>,
    pub dtype: M5DType,
}

impl Owned {
    pub fn f64(name: &str, shape: &[i64], values: &[f64]) -> Owned {
        Owned {
            name: c(name),
            shape: shape.to_vec(),
            bytes: values.iter().flat_map(|v| v.to_ne_bytes()).collect(),
            dtype: 12,
        }
    }

    pub fn i64(name: &str, shape: &[i64], values: &[i64]) -> Owned {
        Owned {
            name: c(name),
            shape: shape.to_vec(),
            bytes: values.iter().flat_map(|v| v.to_ne_bytes()).collect(),
            dtype: 9,
        }
    }

    pub fn f32(name: &str, shape: &[i64], values: &[f32]) -> Owned {
        Owned {
            name: c(name),
            shape: shape.to_vec(),
            bytes: values.iter().flat_map(|v| v.to_ne_bytes()).collect(),
            dtype: 11,
        }
    }

    pub fn view(&self) -> M5ArrayView {
        M5ArrayView {
            name: self.name.as_ptr(),
            dtype: self.dtype,
            ndim: self.shape.len() as u32,
            shape: self.shape.as_ptr(),
            data: self.bytes.as_ptr() as *const c_void,
            nbytes: self.bytes.len(),
        }
    }
}

pub fn views(owned: &[Owned]) -> Vec<M5ArrayView> {
    owned.iter().map(Owned::view).collect()
}

/// An open writer, freed (and so aborted, when not committed) when dropped.
pub struct Writer(pub *mut M5Writer);

impl Writer {
    pub fn create(path: &Path, options: &str) -> Writer {
        let mut out = std::ptr::null_mut();
        ok(m5_writer_create(cp(path).as_ptr(), c(options).as_ptr(), &mut out));
        Writer(out)
    }

    pub fn amend(path: &Path, out_path: Option<&Path>, options: &str) -> Writer {
        let mut out = std::ptr::null_mut();
        let out_c = out_path.map(cp);
        ok(m5_writer_amend(
            cp(path).as_ptr(),
            out_c.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            c(options).as_ptr(),
            &mut out,
        ));
        Writer(out)
    }

    pub fn commit(&self) -> String {
        let mut id = std::ptr::null_mut();
        ok(m5_writer_commit(self.0, true, &mut id));
        take(id)
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        m5_writer_free(self.0);
    }
}

/// Validate a file at a level.
pub fn validate(path: &Path, level: &str) -> Value {
    let mut out = std::ptr::null_mut();
    ok(m5_validate_file(cp(path).as_ptr(), c(level).as_ptr(), &mut out));
    take_json(out)
}

/// The engine's own reading of a sample, the tests' oracle.
pub fn engine(path: &Path) -> medh5::sample::Sample {
    medh5::sample::open_sample(path).unwrap()
}
