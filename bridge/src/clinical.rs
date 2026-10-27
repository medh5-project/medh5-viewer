//! The clinical history (format 1.1): records, document text, and what was
//! known at a cutoff.

use std::ffi::c_char;

use medh5::clinical::SelectionPolicy;
use serde_json::{json, Value};

use crate::ffi::{self, guard, BResult, BridgeError, M5Status};
use crate::sample::{handle, M5Sample};

fn records_json(handle: &M5Sample) -> BResult<Value> {
    let s = handle.sample()?;
    let Some(c) = s.clinical()? else { return Ok(json!({"present": false})) };
    let documents: Vec<Value> = c
        .documents()
        .iter()
        .map(|d| {
            json!({
                "document_id": d.document_id,
                "media_type": d.media_type,
                "language": d.language,
                "source_type": d.source_type,
                "bytes": d.n_bytes,
            })
        })
        .collect();
    Ok(json!({
        "present": true,
        "projection": c.projection,
        "schema": c.descriptor.schema,
        "clock": c.descriptor.clock.to_json(),
        "events": c.events.iter().map(|e| e.to_json()).collect::<Vec<_>>(),
        "links": c.links.iter().map(|l| l.to_json()).collect::<Vec<_>>(),
        "documents": documents,
        "summary": c.summary(),
    }))
}

#[no_mangle]
pub extern "C" fn m5_clinical_records(sample: *mut M5Sample, out_json: *mut *mut c_char) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        ffi::arg_out(out_json, "out_json")?;
        ffi::write_out_json(out_json, &records_json(handle)?)
    })
}

#[no_mangle]
pub extern "C" fn m5_clinical_document_text(
    sample: *mut M5Sample,
    document_id: *const c_char,
    out_text: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let id = ffi::arg_str(document_id, "document_id")?;
        ffi::arg_out(out_text, "out_text")?;
        let s = handle.sample()?;
        let documents = s
            .documents()?
            .ok_or_else(|| BridgeError::from(medh5::Error::Key("the sample has no clinical profile".into())))?;
        let text = documents.text(id)?;
        ffi::write_out_string(out_text, text)
    })
}

/// The cutoff of a query, in microseconds of the subject clock.
fn cutoff_of(query: &serde_json::Map<String, Value>) -> BResult<i64> {
    if let Some(us) = query.get("cutoff_us") {
        return us.as_i64().ok_or_else(|| BridgeError::argument("cutoff_us must be an integer"));
    }
    if let Some(hours) = query.get("cutoff_hours") {
        let h = hours.as_f64().ok_or_else(|| BridgeError::argument("cutoff_hours must be a number"))?;
        return Ok(medh5::clinical::hours(h)?);
    }
    if let Some(days) = query.get("cutoff_days") {
        let d = days.as_f64().ok_or_else(|| BridgeError::argument("cutoff_days must be a number"))?;
        return Ok(medh5::clinical::days(d)?);
    }
    Err(BridgeError::argument("the query names no cutoff (cutoff_us, cutoff_hours or cutoff_days)"))
}

#[no_mangle]
pub extern "C" fn m5_clinical_select(
    sample: *mut M5Sample,
    query_json: *const c_char,
    out_json: *mut *mut c_char,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let query = ffi::arg_json(query_json, "query_json")?;
        ffi::arg_out(out_json, "out_json")?;
        let cutoff = cutoff_of(&query)?;
        let policy = match query.get("policy") {
            None | Some(Value::Null) => SelectionPolicy::strict(),
            Some(p) => SelectionPolicy::from_json(p)?,
        };
        let s = handle.sample()?;
        let c = s.clinical()?.ok_or_else(|| {
            BridgeError::from(medh5::Error::Key("the sample has no clinical profile to select from".into()))
        })?;
        let selection = c.select(cutoff, &policy)?;
        let mut out = selection.to_json(&c.events);
        out["certified"] = json!(selection.certified());
        out["event_ids"] = json!(selection.event_ids(&c.events));
        out["documents"] = json!(selection
            .payloads
            .iter()
            .filter(|(_, kind, _)| kind == "document")
            .map(|(_, _, id)| id.clone())
            .collect::<Vec<_>>());
        ffi::write_out_json(out_json, &out)
    })
}
