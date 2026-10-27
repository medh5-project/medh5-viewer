//! Bundles: a JSON header plus named arrays, owned by the bridge until
//! `m5_bundle_free`.

use std::ffi::{c_char, c_void, CString};

use medh5::array::NdArray;
use serde_json::Value;

use crate::arrays::{code_of, M5DType};
use crate::ffi::{self, guard, guard_value, BResult, BridgeError, M5Status};

/// `M5ArrayView`: one array, borrowed.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct M5ArrayView {
    pub name: *const c_char,
    pub dtype: M5DType,
    pub ndim: u32,
    pub shape: *const i64,
    pub data: *const c_void,
    pub nbytes: usize,
}

impl Default for M5ArrayView {
    fn default() -> Self {
        M5ArrayView {
            name: std::ptr::null(),
            dtype: 0,
            ndim: 0,
            shape: std::ptr::null(),
            data: std::ptr::null(),
            nbytes: 0,
        }
    }
}

struct Entry {
    name: CString,
    shape: Vec<i64>,
    /// C-contiguous, so its first element's address is the data.
    array: NdArray,
}

/// The opaque `M5Bundle`.
pub struct M5Bundle {
    header: CString,
    entries: Vec<Entry>,
}

impl M5Bundle {
    pub fn new(header: &Value) -> Self {
        let text = serde_json::to_string(header).unwrap_or_else(|_| "{}".into());
        M5Bundle { header: CString::new(text.replace('\0', "\u{FFFD}")).expect("NULs replaced"), entries: Vec::new() }
    }

    /// Add an array, in C order.
    pub fn push(&mut self, name: &str, array: NdArray) {
        let array = standard(array);
        let shape = array.shape().iter().map(|v| *v as i64).collect();
        self.entries.push(Entry { name: CString::new(name).expect("array names hold no NUL"), shape, array });
    }

    pub fn into_raw(self) -> *mut M5Bundle {
        Box::into_raw(Box::new(self))
    }

    #[cfg(test)]
    pub fn names(&self) -> Vec<String> {
        self.entries.iter().map(|e| e.name.to_string_lossy().into_owned()).collect()
    }

    fn view(entry: &Entry) -> M5ArrayView {
        let (data, nbytes) = crate::arrays::with_bytes(&entry.array, |b| (b.as_ptr() as *const c_void, b.len()));
        M5ArrayView {
            name: entry.name.as_ptr(),
            dtype: code_of(entry.array.dtype()),
            ndim: entry.shape.len() as u32,
            shape: entry.shape.as_ptr(),
            data,
            nbytes,
        }
    }
}

/// The array laid out in C order (so its memory can be handed out).
fn standard(array: NdArray) -> NdArray {
    macro_rules! std_layout {
        ($a:expr, $v:ident) => {{
            if $a.is_standard_layout() {
                NdArray::$v($a)
            } else {
                NdArray::$v($a.as_standard_layout().into_owned())
            }
        }};
    }
    match array {
        NdArray::Bool(a) => std_layout!(a, Bool),
        NdArray::I8(a) => std_layout!(a, I8),
        NdArray::U8(a) => std_layout!(a, U8),
        NdArray::I16(a) => std_layout!(a, I16),
        NdArray::U16(a) => std_layout!(a, U16),
        NdArray::I32(a) => std_layout!(a, I32),
        NdArray::U32(a) => std_layout!(a, U32),
        NdArray::I64(a) => std_layout!(a, I64),
        NdArray::U64(a) => std_layout!(a, U64),
        NdArray::F16(a) => std_layout!(a, F16),
        NdArray::F32(a) => std_layout!(a, F32),
        NdArray::F64(a) => std_layout!(a, F64),
    }
}

fn bundle_ref<'a>(bundle: *const M5Bundle) -> BResult<&'a M5Bundle> {
    if bundle.is_null() {
        return Err(BridgeError::argument("bundle is NULL"));
    }
    // SAFETY: a bundle this bridge made and the caller has not freed.
    Ok(unsafe { &*bundle })
}

/// The header JSON, owned by the bundle.
#[no_mangle]
pub extern "C" fn m5_bundle_header(bundle: *const M5Bundle) -> *const c_char {
    guard_value(std::ptr::null(), || match bundle_ref(bundle) {
        Ok(b) => b.header.as_ptr(),
        Err(_) => std::ptr::null(),
    })
}

#[no_mangle]
pub extern "C" fn m5_bundle_array_count(bundle: *const M5Bundle) -> usize {
    guard_value(0, || bundle_ref(bundle).map(|b| b.entries.len()).unwrap_or(0))
}

#[no_mangle]
pub extern "C" fn m5_bundle_array_at(bundle: *const M5Bundle, index: usize, out: *mut M5ArrayView) -> M5Status {
    guard(|| {
        let b = bundle_ref(bundle)?;
        let slot = ffi::arg_out(out, "out")?;
        let entry = b
            .entries
            .get(index)
            .ok_or_else(|| BridgeError::argument(format!("array {index} of a bundle of {}", b.entries.len())))?;
        *slot = M5Bundle::view(entry);
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_bundle_array_named(
    bundle: *const M5Bundle,
    name: *const c_char,
    out: *mut M5ArrayView,
) -> M5Status {
    guard(|| {
        let b = bundle_ref(bundle)?;
        let name = ffi::arg_str(name, "name")?;
        let slot = ffi::arg_out(out, "out")?;
        let entry = b
            .entries
            .iter()
            .find(|e| e.name.to_bytes() == name.as_bytes())
            .ok_or_else(|| BridgeError::not_found(format!("the bundle holds no array {name:?}")))?;
        *slot = M5Bundle::view(entry);
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn m5_bundle_free(bundle: *mut M5Bundle) {
    guard_value((), || {
        if !bundle.is_null() {
            // SAFETY: a bundle this bridge made, freed once.
            drop(unsafe { Box::from_raw(bundle) });
        }
    })
}
