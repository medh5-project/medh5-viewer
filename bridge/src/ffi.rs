//! The boundary: status codes, the thread-local last error, the panic guard
//! every exported function runs its body in, and argument checks.
//!
//! Every `extern "C"` function of the crate is a thin shell around [`guard`]
//! (or [`guard_value`]): the body returns `Result<(), BridgeError>`, a panic
//! inside it is caught here and reported as [`M5_ERR_PANIC`], and the error of
//! a failed call is stored as JSON for [`crate::m5_last_error`].  Nothing ever
//! unwinds into the caller.

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde_json::{json, Value};

/// `M5Status`: the result of every fallible call.
pub type M5Status = i32;
pub const M5_OK: M5Status = 0;
pub const M5_ERR: M5Status = 1;
pub const M5_ERR_ARGUMENT: M5Status = 2;
pub const M5_ERR_PANIC: M5Status = 3;
pub const M5_ERR_CANCELLED: M5Status = 4;
pub const M5_ERR_NOT_FOUND: M5Status = 5;

/// A failed call: what `m5_last_error` reports.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeError {
    pub status: M5Status,
    /// The engine's error category, or the bridge's own (`argument`,
    /// `cancelled`, `panic`, `not_found`).
    pub kind: String,
    /// The §15.2 diagnostic code the engine attached, when it did.
    pub code: Option<String>,
    pub message: String,
}

impl BridgeError {
    pub fn argument(message: impl Into<String>) -> Self {
        BridgeError { status: M5_ERR_ARGUMENT, kind: "argument".into(), code: None, message: message.into() }
    }

    pub fn cancelled() -> Self {
        BridgeError {
            status: M5_ERR_CANCELLED,
            kind: "cancelled".into(),
            code: None,
            message: "cancelled by the progress callback".into(),
        }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        BridgeError { status: M5_ERR_NOT_FOUND, kind: "not_found".into(), code: None, message: message.into() }
    }

    /// An engine-side failure with no engine error behind it.
    pub fn engine(kind: &str, message: impl Into<String>) -> Self {
        BridgeError { status: M5_ERR, kind: kind.into(), code: None, message: message.into() }
    }

    pub fn to_json(&self) -> Value {
        json!({"status": self.status, "kind": self.kind, "code": self.code, "message": self.message})
    }
}

/// The category name of an engine error, as `m5_last_error` spells it.
pub fn kind_of(error: &medh5::Error) -> &'static str {
    use medh5::Error as E;
    match error {
        E::File(_) => "file",
        E::Version(_) => "version",
        E::Schema(_) => "schema",
        E::Validation { .. } => "validation",
        E::Integrity(_) => "integrity",
        E::Key(_) => "key",
        E::Value(_) => "value",
        E::Type(_) => "type",
        E::Index(_) => "index",
        E::Io(_) => "io",
        E::NotImplemented(_) => "unsupported",
        E::Runtime(_) => "runtime",
    }
}

impl From<medh5::Error> for BridgeError {
    fn from(error: medh5::Error) -> Self {
        BridgeError {
            status: M5_ERR,
            kind: kind_of(&error).into(),
            code: error.code().map(str::to_string),
            message: error.message().to_string(),
        }
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(error: serde_json::Error) -> Self {
        BridgeError::argument(format!("invalid JSON: {error}"))
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(error: std::io::Error) -> Self {
        BridgeError::from(medh5::Error::Io(error.to_string()))
    }
}

impl From<medh5::ndarray::ShapeError> for BridgeError {
    fn from(error: medh5::ndarray::ShapeError) -> Self {
        BridgeError::from(medh5::Error::Value(error.to_string()))
    }
}

pub type BResult<T> = Result<T, BridgeError>;

thread_local! {
    static LAST_ERROR: RefCell<Option<BridgeError>> = const { RefCell::new(None) };
}

pub fn set_last_error(error: BridgeError) {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = Some(error));
}

pub fn clear_last_error() {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = None);
}

pub fn last_error() -> Option<BridgeError> {
    LAST_ERROR.with(|cell| cell.borrow().clone())
}

/// What a caught panic said.
fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "the engine panicked".to_string()
    }
}

fn panicked(payload: &(dyn std::any::Any + Send)) -> BridgeError {
    BridgeError {
        status: M5_ERR_PANIC,
        kind: "panic".into(),
        code: None,
        message: format!("the bridge caught a panic (a bug): {}", panic_message(payload)),
    }
}

/// Run `body`, catching any panic, and record its error for
/// `m5_last_error`.  The status of every fallible exported function.
pub fn guard(body: impl FnOnce() -> BResult<()>) -> M5Status {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => {
            clear_last_error();
            M5_OK
        }
        Ok(Err(error)) => {
            let status = error.status;
            set_last_error(error);
            status
        }
        Err(payload) => {
            let error = panicked(payload.as_ref());
            set_last_error(error);
            M5_ERR_PANIC
        }
    }
}

/// Run an infallible body that must still never unwind: a panic yields
/// `fallback` (and is recorded as the last error).
pub fn guard_value<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(payload) => {
            set_last_error(panicked(payload.as_ref()));
            fallback
        }
    }
}

// -- arguments ------------------------------------------------------------------------

/// A required UTF-8 C string argument.
pub fn arg_str<'a>(ptr: *const c_char, what: &str) -> BResult<&'a str> {
    if ptr.is_null() {
        return Err(BridgeError::argument(format!("{what} is NULL")));
    }
    // SAFETY: the caller passes a NUL-terminated string that outlives the call.
    let text = unsafe { CStr::from_ptr(ptr) };
    text.to_str().map_err(|_| BridgeError::argument(format!("{what} is not valid UTF-8")))
}

/// An optional UTF-8 C string argument (NULL is `None`).
pub fn arg_opt_str<'a>(ptr: *const c_char, what: &str) -> BResult<Option<&'a str>> {
    if ptr.is_null() {
        Ok(None)
    } else {
        arg_str(ptr, what).map(Some)
    }
}

/// An optional JSON object argument: NULL, `""` and `null` are an empty
/// object.
pub fn arg_json(ptr: *const c_char, what: &str) -> BResult<serde_json::Map<String, Value>> {
    let Some(text) = arg_opt_str(ptr, what)? else { return Ok(serde_json::Map::new()) };
    if text.trim().is_empty() {
        return Ok(serde_json::Map::new());
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(Value::Null) => Ok(serde_json::Map::new()),
        Ok(_) => Err(BridgeError::argument(format!("{what} must be a JSON object"))),
        Err(e) => Err(BridgeError::argument(format!("{what} is not valid JSON: {e}"))),
    }
}

/// Any JSON value argument (required).
pub fn arg_json_value(ptr: *const c_char, what: &str) -> BResult<Value> {
    let text = arg_str(ptr, what)?;
    serde_json::from_str::<Value>(text).map_err(|e| BridgeError::argument(format!("{what} is not valid JSON: {e}")))
}

/// A non-NULL out-pointer.
pub fn arg_out<'a, T>(ptr: *mut T, what: &str) -> BResult<&'a mut T> {
    if ptr.is_null() {
        return Err(BridgeError::argument(format!("{what} is NULL")));
    }
    // SAFETY: non-null, and the caller passes a pointer to writable storage.
    Ok(unsafe { &mut *ptr })
}

/// A string handed to the caller, freed with `m5_string_free`.
pub fn into_c_string(text: String) -> *mut c_char {
    // An interior NUL cannot cross the boundary; it is replaced.
    let cleaned = if text.as_bytes().contains(&0) { text.replace('\0', "\u{FFFD}") } else { text };
    CString::new(cleaned).expect("NULs replaced").into_raw()
}

/// Store `text` in `*out` (which must not be NULL).
pub fn write_out_string(out: *mut *mut c_char, text: String) -> BResult<()> {
    let slot = arg_out(out, "out pointer")?;
    *slot = into_c_string(text);
    Ok(())
}

/// Store a JSON value in `*out`.
pub fn write_out_json(out: *mut *mut c_char, value: &Value) -> BResult<()> {
    write_out_string(out, serde_json::to_string(value).map_err(|e| BridgeError::engine("runtime", e.to_string()))?)
}

/// `(start, stop)` per axis from the C region arguments, checked against
/// `shape`: `ndim == 0` is the whole array.  Returns the window.
pub fn region(
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    shape: &[usize],
    allow_trailing: bool,
) -> BResult<Vec<(usize, usize)>> {
    if ndim == 0 {
        return Ok(shape.iter().map(|n| (0, *n)).collect());
    }
    if start.is_null() || stop.is_null() {
        return Err(BridgeError::argument("a region with ndim > 0 needs start and stop"));
    }
    let n = ndim as usize;
    if n > shape.len() || (n < shape.len() && !allow_trailing) {
        return Err(BridgeError::argument(format!(
            "the region has {n} axes; the array has {} ({:?})",
            shape.len(),
            shape
        )));
    }
    // SAFETY: the caller passes `ndim` entries in each.
    let (a, b) = unsafe { (std::slice::from_raw_parts(start, n), std::slice::from_raw_parts(stop, n)) };
    let lead = shape.len() - n;
    let mut out: Vec<(usize, usize)> = shape[..lead].iter().map(|s| (0, *s)).collect();
    for (axis, ((lo, hi), extent)) in a.iter().zip(b).zip(&shape[lead..]).enumerate() {
        if *lo < 0 || *hi < *lo || *hi as u64 > *extent as u64 {
            return Err(BridgeError::argument(format!("region axis {axis}: [{lo}, {hi}) is not within [0, {extent}]")));
        }
        out.push((*lo as usize, *hi as usize));
    }
    Ok(out)
}

/// The number of elements a window holds, refusing an overflow.
pub fn window_count(window: &[(usize, usize)]) -> BResult<usize> {
    window
        .iter()
        .try_fold(1usize, |n, (a, b)| n.checked_mul(b - a))
        .ok_or_else(|| BridgeError::argument("the region holds more elements than an address space"))
}

/// A progress callback: returns `false` to cancel.
pub type M5ProgressFn = Option<unsafe extern "C" fn(context: *mut std::ffi::c_void, done: u64, total: u64) -> bool>;

/// A progress callback and its context, as one value.
#[derive(Clone, Copy)]
pub struct Progress {
    pub callback: M5ProgressFn,
    pub context: *mut std::ffi::c_void,
}

impl Progress {
    pub fn new(callback: M5ProgressFn, context: *mut std::ffi::c_void) -> Self {
        Progress { callback, context }
    }

    pub fn none() -> Self {
        Progress { callback: None, context: std::ptr::null_mut() }
    }

    /// Report `done` of `total`; `Err(cancelled)` when the callback says stop.
    pub fn report(&self, done: u64, total: u64) -> BResult<()> {
        if let Some(callback) = self.callback {
            // SAFETY: the caller's callback, with the context it gave.
            let go_on = unsafe { callback(self.context, done, total) };
            if !go_on {
                return Err(BridgeError::cancelled());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_is_caught_reported_and_never_unwinds() {
        let status = guard(|| panic!("boom at the boundary"));
        assert_eq!(status, M5_ERR_PANIC);
        let error = last_error().expect("a panic is the last error");
        assert_eq!(error.kind, "panic");
        assert!(error.message.contains("boom at the boundary"), "{}", error.message);
        assert_eq!(error.to_json()["status"], M5_ERR_PANIC);
        let value = guard_value(7, || -> i32 { panic!("in a value") });
        assert_eq!(value, 7);
        assert!(guard(|| Ok(())) == M5_OK && last_error().is_none());
    }

    #[test]
    fn engine_errors_keep_their_kind_and_code() {
        let error = BridgeError::from(medh5::Error::coded("E701", "a digest does not match"));
        assert_eq!((error.status, error.kind.as_str(), error.code.as_deref()), (M5_ERR, "validation", Some("E701")));
        assert_eq!(error.message, "a digest does not match");
        assert_eq!(BridgeError::from(medh5::Error::Key("x".into())).kind, "key");
        assert_eq!(BridgeError::from(medh5::Error::NotImplemented("x".into())).kind, "unsupported");
        assert_eq!(BridgeError::cancelled().status, M5_ERR_CANCELLED);
    }

    #[test]
    fn regions_are_checked_against_the_shape() {
        let shape = [4usize, 5, 6];
        assert_eq!(region(std::ptr::null(), std::ptr::null(), 0, &shape, false).unwrap(), vec![(0, 4), (0, 5), (0, 6)]);
        let (a, b) = ([1i64, 2], [3i64, 5]);
        assert_eq!(region(a.as_ptr(), b.as_ptr(), 2, &shape, true).unwrap(), vec![(0, 4), (1, 3), (2, 5)]);
        assert!(region(a.as_ptr(), b.as_ptr(), 2, &shape, false).is_err());
        let (a, b) = ([0i64, 0, 0], [4i64, 5, 7]);
        assert!(region(a.as_ptr(), b.as_ptr(), 3, &shape, false).is_err());
        let (a, b) = ([2i64, 0, 0], [1i64, 5, 6]);
        assert!(region(a.as_ptr(), b.as_ptr(), 3, &shape, false).is_err());
        assert!(region(std::ptr::null(), b.as_ptr(), 3, &shape, false).is_err());
    }
}
