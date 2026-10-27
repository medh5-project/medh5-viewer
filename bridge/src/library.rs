//! Library information: versions, threads, the code table and the levels;
//! the last error and string ownership.

use std::ffi::{c_char, CString};
use std::sync::OnceLock;

use serde_json::{json, Value};

use crate::ffi::{self, guard, guard_value, M5Status};

fn static_c(cell: &'static OnceLock<CString>, text: &str) -> *const c_char {
    cell.get_or_init(|| CString::new(text).expect("versions hold no NUL")).as_ptr()
}

/// The engine's package version (`"2.2.3"`).
#[no_mangle]
pub extern "C" fn m5_engine_version() -> *const c_char {
    static CELL: OnceLock<CString> = OnceLock::new();
    guard_value(std::ptr::null(), || static_c(&CELL, medh5::VERSION))
}

/// The newest format version the engine implements (`"1.2"`).
#[no_mangle]
pub extern "C" fn m5_format_version() -> *const c_char {
    static CELL: OnceLock<CString> = OnceLock::new();
    guard_value(std::ptr::null(), || static_c(&CELL, medh5::FORMAT_VERSION))
}

/// This bridge's version.
#[no_mangle]
pub extern "C" fn m5_bridge_version() -> *const c_char {
    static CELL: OnceLock<CString> = OnceLock::new();
    guard_value(std::ptr::null(), || static_c(&CELL, env!("CARGO_PKG_VERSION")))
}

/// The engine's default thread count: `MEDH5_THREADS`, else 1.
fn default_threads() -> usize {
    std::env::var("MEDH5_THREADS").ok().and_then(|v| v.trim().parse::<usize>().ok()).filter(|n| *n > 0).unwrap_or(1)
}

/// Threads one engine call may use outside HDF5; 0 restores the engine's
/// default (`MEDH5_THREADS`, else 1).
#[no_mangle]
pub extern "C" fn m5_set_threads(threads: u32) {
    guard_value((), || {
        let n = if threads == 0 { default_threads() } else { threads as usize };
        let _ = medh5::parallel::set_threads(n.max(1));
    })
}

#[no_mangle]
pub extern "C" fn m5_threads() -> u32 {
    guard_value(1, || medh5::parallel::threads().map(|n| n as u32).unwrap_or(1))
}

/// The calling thread's last error as JSON, or NULL after a success.
#[no_mangle]
pub extern "C" fn m5_last_error() -> *mut c_char {
    guard_value(std::ptr::null_mut(), || match ffi::last_error() {
        Some(error) => ffi::into_c_string(error.to_json().to_string()),
        None => std::ptr::null_mut(),
    })
}

/// Free a string the bridge returned.  NULL-safe.
#[no_mangle]
pub extern "C" fn m5_string_free(s: *mut c_char) {
    guard_value((), || {
        if !s.is_null() {
            // SAFETY: a string this bridge allocated with `CString::into_raw`.
            drop(unsafe { CString::from_raw(s) });
        }
    })
}

/// The §15.2 code table: every code with its severity, domain, summary,
/// the version whose rules it reports (`since`) and the table revision that
/// allocated it (`revision`), in table order.
pub fn code_table() -> Value {
    let table: Value = serde_json::from_str(medh5::codes::table_json()).unwrap_or(Value::Null);
    table.get("codes").cloned().unwrap_or_else(|| json!([]))
}

#[no_mangle]
pub extern "C" fn m5_code_table(out_json: *mut *mut c_char) -> M5Status {
    guard(|| ffi::write_out_json(out_json, &code_table()))
}

#[no_mangle]
pub extern "C" fn m5_validation_levels(out_json: *mut *mut c_char) -> M5Status {
    guard(|| ffi::write_out_json(out_json, &json!(medh5::validate::LEVELS)))
}
