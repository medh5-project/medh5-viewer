//! The engine's conformance corpus, written for the viewer's tests.

use std::ffi::c_char;
use std::path::Path;

use serde_json::{json, Value};

use crate::ffi::{self, guard, M5Status};

/// Write every case of the corpus and its `expected.json` into
/// `directory`, and the robustness fixtures (hostile files that are not
/// conformance cases) into `directory/robustness`.  Returns the manifest,
/// with `robustness` listing those files.
pub fn write_corpus(directory: &Path) -> crate::ffi::BResult<Value> {
    let manifest_path = medh5::conformance::build_corpus(directory, None)?;
    let text = std::fs::read_to_string(&manifest_path)?;
    let mut manifest: Value = serde_json::from_str(&text)
        .map_err(|e| crate::ffi::BridgeError::engine("runtime", format!("expected.json: {e}")))?;
    let robustness = medh5::conformance::robustness::write(&directory.join("robustness"))?;
    manifest["robustness"] = json!(robustness
        .iter()
        .map(|p| p.strip_prefix(directory).unwrap_or(p).to_string_lossy().into_owned())
        .collect::<Vec<_>>());
    manifest["manifest"] = json!(manifest_path.to_string_lossy());
    Ok(manifest)
}

#[no_mangle]
pub extern "C" fn m5_conformance_write(directory: *const c_char, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let directory = ffi::arg_str(directory, "directory")?;
        let manifest = write_corpus(Path::new(directory))?;
        if !out_json.is_null() {
            ffi::write_out_json(out_json, &manifest)?;
        }
        Ok(())
    })
}
