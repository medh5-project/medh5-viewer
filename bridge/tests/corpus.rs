//! The conformance corpus through the C ABI: every case, valid or damaged,
//! and every robustness fixture is opened and read through every call; an
//! error is an answer, a panic (or a crash) is not.  The validator's codes
//! match what each case expects.

mod common;

use std::collections::BTreeSet;
use std::ffi::c_void;
use std::path::Path;

use common::*;
use medh5_bridge::*;

/// A status any call may give on a damaged file, but never a panic.
#[track_caller]
fn answered(status: M5Status, what: &str) {
    assert_ne!(status, M5_ERR_PANIC, "{what}: {}", last_error());
    if status != M5_OK {
        let error = last_error();
        assert!(error["message"].is_string(), "{what}: {error}");
    }
}

fn json_or_null(status: M5Status, out: *mut std::ffi::c_char, what: &str) -> serde_json::Value {
    answered(status, what);
    if status == M5_OK {
        take_json(out)
    } else {
        serde_json::Value::Null
    }
}

/// Read everything a viewer would from one file.
fn exercise(path: &Path) -> bool {
    let name = path.file_name().unwrap().to_string_lossy().into_owned();
    let mut handle = std::ptr::null_mut();
    let status = m5_sample_open(cp(path).as_ptr(), &mut handle);
    answered(status, &format!("{name}: open"));
    if status != M5_OK {
        return false;
    }
    let sample = Sample(handle);
    let mut out = std::ptr::null_mut();
    let summary = json_or_null(m5_sample_summary(sample.0, &mut out), out, &format!("{name}: summary"));
    let mut out = std::ptr::null_mut();
    let status = m5_sample_document(sample.0, &mut out);
    answered(status, &format!("{name}: document"));
    if status == M5_OK {
        m5_string_free(out);
    }
    let mut out = std::ptr::null_mut();
    json_or_null(m5_sample_verify(sample.0, &mut out), out, &format!("{name}: verify"));
    let mut out = std::ptr::null_mut();
    json_or_null(m5_sample_attributes(sample.0, c("/").as_ptr(), &mut out), out, &format!("{name}: attributes"));
    let mut out = std::ptr::null_mut();
    json_or_null(m5_clinical_records(sample.0, &mut out), out, &format!("{name}: clinical"));
    if summary.is_null() {
        return true;
    }
    for image in summary["images"].as_array().into_iter().flatten() {
        let Some(id) = image["id"].as_str() else { continue };
        let what = format!("{name}: image {id}");
        // A region of at most one voxel per axis: enough to drive the read.
        let shape: Vec<i64> =
            image["shape"].as_array().map(|s| s.iter().filter_map(|v| v.as_i64()).collect()).unwrap_or_default();
        if shape.is_empty() || shape.iter().any(|n| *n <= 0) {
            continue;
        }
        let start = vec![0i64; shape.len()];
        let stop: Vec<i64> = shape.iter().map(|n| (*n).min(2)).collect();
        let count: i64 = stop.iter().product();
        let mut buffer = vec![0f32; count as usize];
        answered(
            m5_image_read(
                sample.0,
                c(id).as_ptr(),
                0,
                start.as_ptr(),
                stop.as_ptr(),
                shape.len() as u32,
                true,
                11,
                buffer.as_mut_ptr() as *mut c_void,
                buffer.len() * 4,
                None,
                std::ptr::null_mut(),
            ),
            &what,
        );
    }
    for annotation in summary["annotations"].as_array().into_iter().flatten() {
        let Some(id) = annotation["id"].as_str() else { continue };
        let what = format!("{name}: annotation {id}");
        if annotation["voxel"] == true {
            let mut out = std::ptr::null_mut();
            let plan = json_or_null(m5_annotation_layer_plan(sample.0, c(id).as_ptr(), &mut out), out, &what);
            let spatial: Vec<i64> = plan["spatial_shape"]
                .as_array()
                .map(|s| s.iter().filter_map(|v| v.as_i64()).collect())
                .unwrap_or_default();
            let count: usize = spatial.iter().map(|n| (*n).max(0) as usize).product();
            if count > 0 && count < 1 << 24 {
                for layer in 0..plan["layers"].as_array().map_or(0, |l| l.len()) as u32 {
                    let mut buffer = vec![0u16; count];
                    answered(
                        m5_annotation_read_layer(
                            sample.0,
                            c(id).as_ptr(),
                            layer,
                            std::ptr::null(),
                            std::ptr::null(),
                            0,
                            buffer.as_mut_ptr(),
                            count,
                            None,
                            std::ptr::null_mut(),
                        ),
                        &what,
                    );
                }
                let mut mask = vec![0u8; count];
                answered(
                    m5_annotation_read_mask(
                        sample.0,
                        c(id).as_ptr(),
                        true,
                        std::ptr::null(),
                        std::ptr::null(),
                        0,
                        mask.as_mut_ptr(),
                        count,
                    ),
                    &what,
                );
                if annotation["kind"] == "instances" {
                    let mut map = vec![0u32; count];
                    answered(
                        m5_annotation_read_instance_map(
                            sample.0,
                            c(id).as_ptr(),
                            std::ptr::null(),
                            std::ptr::null(),
                            0,
                            map.as_mut_ptr(),
                            count,
                        ),
                        &what,
                    );
                    let mut out = std::ptr::null_mut();
                    json_or_null(m5_annotation_instances(sample.0, c(id).as_ptr(), &mut out), out, &what);
                }
                let mut out = std::ptr::null_mut();
                json_or_null(m5_annotation_class_stats(sample.0, c(id).as_ptr(), &mut out), out, &what);
            }
        } else {
            let mut bundle = std::ptr::null_mut();
            let status = m5_annotation_geometry(sample.0, c(id).as_ptr(), &mut bundle);
            answered(status, &what);
            if status == M5_OK {
                drop(Bundle(bundle));
            }
        }
    }
    for transform in summary["transforms"].as_array().into_iter().flatten() {
        let Some(id) = transform["id"].as_str() else { continue };
        let mut bundle = std::ptr::null_mut();
        let status = m5_transform_read(sample.0, c(id).as_ptr(), &mut bundle);
        answered(status, &format!("{name}: transform {id}"));
        if status == M5_OK {
            drop(Bundle(bundle));
        }
    }
    let timepoints: Vec<String> = summary["timepoints"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|t| t["id"].as_str().map(str::to_string))
        .collect();
    if timepoints.len() >= 2 {
        let grid = summary["grids"][0]["id"].as_str().unwrap_or("").to_string();
        let mut bundle = std::ptr::null_mut();
        let status = m5_transform_resolve(
            sample.0,
            c(&timepoints[0]).as_ptr(),
            c(&timepoints[1]).as_ptr(),
            c(&grid).as_ptr(),
            8,
            &mut bundle,
        );
        answered(status, &format!("{name}: resolve"));
        if status == M5_OK {
            drop(Bundle(bundle));
        }
    }
    true
}

#[test]
fn every_case_of_the_corpus_is_read_and_validated_without_a_panic() {
    let dir = TempDir::new("corpus");
    let mut out = std::ptr::null_mut();
    ok(m5_conformance_write(cp(&dir.0).as_ptr(), &mut out));
    let manifest = take_json(out);
    let cases = manifest["cases"].as_array().unwrap();
    assert!(cases.len() > 50, "{} cases", cases.len());
    assert_eq!(cases.len(), medh5::conformance::cases().len());

    let mut opened = 0;
    for case in cases {
        let file = dir.0.join(case["file"].as_str().unwrap());
        if !file.exists() {
            continue;
        }
        let level = case["level"].as_str().unwrap();
        let report = validate(&file, level);
        let found = |severity: &str| -> BTreeSet<String> {
            report["diagnostics"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|d| d["severity"] == severity)
                .map(|d| d["code"].as_str().unwrap().to_string())
                .collect()
        };
        let expected = |key: &str| -> BTreeSet<String> {
            case[key].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
        };
        assert_eq!(found("error"), expected("expect_errors"), "{}: {report}", case["name"]);
        assert_eq!(found("warning"), expected("expect_warnings"), "{}: {report}", case["name"]);
        if file.extension().is_some_and(|e| e == "medh5c") {
            let mut out = std::ptr::null_mut();
            let status = m5_collection_list(cp(&file).as_ptr(), &mut out);
            answered(status, case["name"].as_str().unwrap());
            if status == M5_OK {
                let listed = take_json(out);
                for member in listed["members"].as_array().into_iter().flatten() {
                    let mut handle = std::ptr::null_mut();
                    let status = m5_sample_open_member(
                        cp(&file).as_ptr(),
                        c(member["name"].as_str().unwrap()).as_ptr(),
                        &mut handle,
                    );
                    answered(status, "member");
                    if status == M5_OK {
                        let member = Sample(handle);
                        let mut out = std::ptr::null_mut();
                        json_or_null(m5_sample_summary(member.0, &mut out), out, "member summary");
                    }
                }
            }
            continue;
        }
        if exercise(&file) {
            opened += 1;
        }
    }
    assert!(opened > cases.len() / 2, "{opened} of {} cases opened", cases.len());

    // The hostile files: answered within the process, never a crash.
    let robustness = manifest["robustness"].as_array().unwrap();
    assert!(!robustness.is_empty());
    for file in robustness {
        let path = dir.0.join(file.as_str().unwrap());
        exercise(&path);
        let mut out = std::ptr::null_mut();
        let status = m5_validate_file(cp(&path).as_ptr(), c("integrity").as_ptr(), &mut out);
        answered(status, file.as_str().unwrap());
        if status == M5_OK {
            m5_string_free(out);
        }
    }
}
