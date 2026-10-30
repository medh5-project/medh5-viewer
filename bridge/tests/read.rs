//! Reading through the C ABI: library calls, the summary, images, voxel
//! annotations in every encoding, geometry, transforms, clinical records.

mod common;

use std::ffi::{c_void, CStr};

use common::*;
use medh5::labels::ClassKey;
use medh5_bridge::*;

// -- library --------------------------------------------------------------------------

#[test]
fn library_versions_threads_codes_and_levels() {
    let version = |p: *const std::ffi::c_char| unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    assert_eq!(version(m5_engine_version()), "2.2.4");
    assert_eq!(version(m5_engine_version()), medh5::VERSION);
    assert_eq!(version(m5_format_version()), "1.2");
    assert!(!version(m5_bridge_version()).is_empty());

    let before = m5_threads();
    m5_set_threads(3);
    assert_eq!(m5_threads(), 3);
    m5_set_threads(0);
    assert!(m5_threads() >= 1);
    m5_set_threads(before.max(1));

    let mut out = std::ptr::null_mut();
    ok(m5_code_table(&mut out));
    let codes = take_json(out);
    let codes = codes.as_array().unwrap();
    assert_eq!(codes.len(), medh5::codes::all().len());
    let w904 = codes.iter().find(|c| c["code"] == "W904").unwrap();
    assert_eq!(w904["severity"], "warning");
    assert!(w904["since"].is_string() && w904["revision"].is_number());

    let mut out = std::ptr::null_mut();
    ok(m5_validation_levels(&mut out));
    assert_eq!(take_json(out), serde_json::json!(["structural", "semantic", "integrity", "strict"]));
}

#[test]
fn errors_are_reported_per_thread_and_cleared_by_a_success() {
    let mut sample = std::ptr::null_mut();
    let error = fails(m5_sample_open(c("/nonexistent/x.medh5").as_ptr(), &mut sample), M5_ERR);
    assert!(sample.is_null());
    assert!(["file", "io"].contains(&error["kind"].as_str().unwrap()), "{error}");
    // Another thread has its own last error.
    std::thread::spawn(|| assert!(m5_last_error().is_null())).join().unwrap();
    // A success clears it.
    let mut out = std::ptr::null_mut();
    ok(m5_validation_levels(&mut out));
    m5_string_free(out);
    assert!(m5_last_error().is_null());

    let error = fails(m5_sample_open(std::ptr::null(), &mut sample), M5_ERR_ARGUMENT);
    assert_eq!(error["kind"], "argument");
    let bad = [0xffu8, 0xfe, 0];
    fails(m5_sample_open(bad.as_ptr() as *const std::ffi::c_char, &mut sample), M5_ERR_ARGUMENT);
    fails(m5_sample_open(cp(demo()).as_ptr(), std::ptr::null_mut()), M5_ERR_ARGUMENT);
    fails(m5_sample_summary(std::ptr::null_mut(), &mut out), M5_ERR_ARGUMENT);

    // NULL is safe wherever a handle or a string is released.
    m5_sample_close(std::ptr::null_mut());
    m5_writer_free(std::ptr::null_mut());
    m5_bundle_free(std::ptr::null_mut());
    m5_string_free(std::ptr::null_mut());
    assert!(m5_bundle_header(std::ptr::null()).is_null());
    assert_eq!(m5_bundle_array_count(std::ptr::null()), 0);
}

// -- the summary ----------------------------------------------------------------------

#[test]
fn summary_describes_the_whole_demo() {
    let sample = Sample::open(demo());
    let s = sample.summary();
    assert_eq!(s["format_version"], "1.2");
    assert_eq!(s["support"], "full");
    assert_eq!(s["kind"], "sample");
    assert!(s["content_id"].as_str().unwrap().starts_with("sha256:"));
    for p in ["core", "seg", "det", "cls", "reg", "longitudinal", "clinical", "training"] {
        assert!(s["profiles"].as_array().unwrap().iter().any(|v| v == p), "{p}: {}", s["profiles"]);
    }
    assert_eq!(s["identity"]["sample_id"], "demo-abdomen-01");
    assert_eq!(s["identity"]["subject_id"], "DEMO-SUBJ-01");
    assert_eq!(s["timepoints"].as_array().unwrap().len(), 2);
    assert_eq!(s["label_set"]["classes"].as_array().unwrap().len(), 12);
    let lesion = s["label_set"]["classes"].as_array().unwrap().iter().find(|c| c["key"] == "liver_lesion").unwrap();
    assert_eq!(lesion["parents"], serde_json::json!([2]));
    assert_eq!(lesion["color"], serde_json::json!([255, 255, 0, 255]));
    assert_eq!(s["grids"].as_array().unwrap().len(), 3);
    let ct = s["grids"].as_array().unwrap().iter().find(|g| g["id"] == "ct_tp0").unwrap();
    assert_eq!(ct["frame_uid"], "demo:frame-tp0");
    assert_eq!(ct["timepoint"], "tp0");
    assert_eq!(ct["shape"], serde_json::json!([64, 64, 64]));
    let images = s["images"].as_array().unwrap();
    assert_eq!(images.len(), 3);
    let ct_image = images.iter().find(|i| i["id"] == "CT_tp0").unwrap();
    assert_eq!(ct_image["dtype"], "int16");
    assert_eq!(ct_image["rescale_intercept"], -1024.0);
    assert!(ct_image["digest"].as_str().unwrap().starts_with("sha256:"));
    let kinds: std::collections::BTreeMap<String, String> = s["annotations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| (a["id"].as_str().unwrap().to_string(), a["kind"].as_str().unwrap().to_string()))
        .collect();
    for (id, kind) in [
        ("organs_tp0", "layers"),
        ("organs_tp1", "labelmap"),
        ("lesion_prob_tp1", "probmap"),
        ("lesions_tp0", "instances"),
        ("mr_fov", "mask"),
        ("lesion_boxes_tp0", "boxes"),
        ("kidney_obb_tp0", "obb"),
        ("landmarks_tp0", "keypoints"),
        ("fiducials_tp0", "points"),
        ("fiducials_tp1", "points"),
        ("liver_contours_tp0", "contours"),
        ("centrelines_tp0", "polylines"),
        ("surfaces_tp0", "mesh"),
        ("response", "classification"),
    ] {
        assert_eq!(kinds.get(id).map(String::as_str), Some(kind), "{id}");
    }
    let organs = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "organs_tp0").unwrap();
    assert_eq!(organs["class_ids"], serde_json::json!([2, 3, 5, 6, 7, 8, 9]));
    assert_eq!(organs["annotated_class_ids"], serde_json::json!([2, 3, 5, 6, 8, 9]));
    assert_eq!(organs["fully_covered"], false);
    assert!(organs["digest"].as_str().unwrap().starts_with("sha256:"));
    assert_eq!(s["transforms"][0]["id"], "tp0_to_tp1");
    assert_eq!(s["clinical"]["present"], true);
    assert_eq!(s["index"][0]["annotation"], "organs_tp0");
    assert_eq!(s["index"][0]["fresh"], true);
    assert_eq!(s["left_out"], serde_json::json!({}));
}

#[test]
fn document_is_the_stored_text_and_verify_reports_every_digest() {
    let sample = Sample::open(demo());
    let mut out = std::ptr::null_mut();
    ok(m5_sample_document(sample.0, &mut out));
    let text = take(out);
    let stored = medh5::sample::read_document_text(&engine(demo()).root).unwrap();
    assert_eq!(text, stored);

    let mut out = std::ptr::null_mut();
    ok(m5_sample_verify(sample.0, &mut out));
    let report = take_json(out);
    assert_eq!(report["ok"], true, "{report}");
    assert_eq!(report["content_id"]["ok"], true);
    assert!(report["objects"].as_array().unwrap().len() > 20);
    assert!(report["objects"].as_array().unwrap().iter().all(|o| o["ok"] == true));
}

#[test]
fn attributes_of_groups_datasets_and_the_root() {
    let sample = Sample::open(demo());
    let ct = sample.json_call(m5_sample_attributes, "images/CT_tp0");
    assert_eq!(ct["modality"], "CT");
    assert_eq!(ct["rescale_intercept"], -1024.0);
    assert_eq!(ct["grid"], "ct_tp0");
    let root = sample.json_call(m5_sample_attributes, "/");
    assert_eq!(root["medh5_version"], "1.2");
    let data = sample.json_call(m5_sample_attributes, "annotations/organs_tp0/data");
    assert!(data["digest"].as_str().unwrap().starts_with("sha256:"));
    let grid = sample.json_call(m5_sample_attributes, "grids/ct_tp0");
    assert_eq!(grid["frame_uid"], "demo:frame-tp0");
    let mut out = std::ptr::null_mut();
    let error = fails(m5_sample_attributes(sample.0, c("images/nope").as_ptr(), &mut out), M5_ERR);
    assert_eq!(error["kind"], "key");
}

// -- images ---------------------------------------------------------------------------

extern "C" fn count_progress(context: *mut c_void, done: u64, total: u64) -> bool {
    let calls = unsafe { &mut *(context as *mut Vec<(u64, u64)>) };
    calls.push((done, total));
    true
}

extern "C" fn cancel_at_once(_: *mut c_void, _: u64, _: u64) -> bool {
    false
}

extern "C" fn cancel_after_first(context: *mut c_void, done: u64, _: u64) -> bool {
    let calls = unsafe { &mut *(context as *mut u32) };
    *calls += 1;
    done == 0
}

#[test]
fn images_read_whole_by_region_physical_and_converted() {
    let sample = Sample::open(demo());
    let oracle = engine(demo());
    let image = oracle.image("CT_tp0").unwrap();
    let expected: Vec<i16> = image.read(None, false, None).unwrap().cast::<i16>().iter().copied().collect();
    let n = 64 * 64 * 64;
    let mut calls: Vec<(u64, u64)> = Vec::new();
    let mut raw = vec![0i16; n];
    ok(m5_image_read(
        sample.0,
        c("CT_tp0").as_ptr(),
        0,
        std::ptr::null(),
        std::ptr::null(),
        0,
        false,
        M5_DTYPE_NATIVE,
        raw.as_mut_ptr() as *mut c_void,
        n * 2,
        Some(count_progress),
        &mut calls as *mut _ as *mut c_void,
    ));
    assert_eq!(raw, expected);
    assert_eq!(calls.first(), Some(&(0, n as u64)));
    assert_eq!(calls.last(), Some(&(n as u64, n as u64)));
    assert!(calls.windows(2).all(|w| w[0].0 <= w[1].0));

    // Physical values: raw + intercept, as float32.
    let mut physical = vec![0f32; n];
    ok(m5_image_read(
        sample.0,
        c("CT_tp0").as_ptr(),
        0,
        std::ptr::null(),
        std::ptr::null(),
        0,
        true,
        M5_DTYPE_NATIVE,
        physical.as_mut_ptr() as *mut c_void,
        n * 4,
        None,
        std::ptr::null_mut(),
    ));
    for (p, r) in physical.iter().zip(&raw) {
        assert_eq!(*p, f32::from(*r) - 1024.0);
    }
    // Body (about 35 HU) at the centre, air at the corner.
    assert!((physical[32 * 4096 + 32 * 64 + 32] - 35.0).abs() < 20.0);
    assert!((physical[0] + 1000.0).abs() < 10.0);

    // A region: the slice of the whole, in any element type.
    let (start, stop) = ([10i64, 20, 5], [14i64, 30, 25]);
    let mut part = vec![0f64; 4 * 10 * 20];
    ok(m5_image_read(
        sample.0,
        c("CT_tp0").as_ptr(),
        0,
        start.as_ptr(),
        stop.as_ptr(),
        3,
        false,
        12,
        part.as_mut_ptr() as *mut c_void,
        part.len() * 8,
        None,
        std::ptr::null_mut(),
    ));
    let mut i = 0;
    for z in 10..14 {
        for y in 20..30 {
            for x in 5..25 {
                assert_eq!(part[i], f64::from(raw[z * 4096 + y * 64 + x]));
                i += 1;
            }
        }
    }

    // Wrong size, unknown image, a level that does not exist, a bad region.
    let error = fails(
        m5_image_read(
            sample.0,
            c("CT_tp0").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            n * 2 - 2,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );
    assert!(error["message"].as_str().unwrap().contains("bytes"));
    let error = fails(
        m5_image_read(
            sample.0,
            c("XR").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            n * 2,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR,
    );
    assert_eq!(error["kind"], "key");
    assert!(error["message"].as_str().unwrap().contains("CT_tp0"), "names the images there are: {error}");
    fails(
        m5_image_read(
            sample.0,
            c("CT_tp0").as_ptr(),
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            n * 2,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR,
    );
    let bad = [0i64, 0, 0];
    let past = [65i64, 1, 1];
    fails(
        m5_image_read(
            sample.0,
            c("CT_tp0").as_ptr(),
            0,
            bad.as_ptr(),
            past.as_ptr(),
            3,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            65 * 2,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );
    fails(
        m5_image_read(
            sample.0,
            c("CT_tp0").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            99,
            raw.as_mut_ptr() as *mut c_void,
            n * 2,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );

    // A callback that says stop cancels the read.
    let error = fails(
        m5_image_read(
            sample.0,
            c("CT_tp0").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            n * 2,
            Some(cancel_at_once),
            std::ptr::null_mut(),
        ),
        M5_ERR_CANCELLED,
    );
    assert_eq!(error["kind"], "cancelled");
    let mut calls = 0u32;
    fails(
        m5_image_read(
            sample.0,
            c("MR_tp0").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            false,
            0,
            raw.as_mut_ptr() as *mut c_void,
            32 * 56 * 56 * 4,
            Some(cancel_after_first),
            &mut calls as *mut u32 as *mut c_void,
        ),
        M5_ERR_CANCELLED,
    );
    assert_eq!(calls, 2);
}

#[test]
fn concurrent_reads_of_one_handle_agree() {
    let sample = std::sync::Arc::new(Sample::open(demo()));
    let first = sample.image_i16("CT_tp1", 64 * 64 * 64);
    let threads: Vec<_> = (0..4)
        .map(|i| {
            let sample = sample.clone();
            std::thread::spawn(move || {
                if i % 2 == 0 {
                    sample.image_i16("CT_tp1", 64 * 64 * 64)
                } else {
                    sample.layer("organs_tp0", 0, 64 * 64 * 64).iter().map(|v| *v as i16).collect()
                }
            })
        })
        .collect();
    let results: Vec<Vec<i16>> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(results[0], first);
    assert_eq!(results[2], first);
    assert_eq!(results[1], results[3]);
}

// -- voxel annotations ----------------------------------------------------------------

/// Every class's voxels from the layers: where some layer holds it.
fn from_layers(layers: &[Vec<u16>], class: u16) -> Vec<bool> {
    (0..layers[0].len()).map(|v| layers.iter().any(|l| l[v] == class)).collect()
}

/// The engine's `contains` for every voxel of a class, closure aside.
fn dense(path: &std::path::Path, ann: &str, class: i64) -> Vec<bool> {
    let s = engine(path);
    let a = s.annotation(ann).unwrap();
    a.dense(Some(&[ClassKey::Id(class)]), None).unwrap().iter().copied().collect()
}

fn read_all_layers(sample: &Sample, ann: &str) -> (serde_json::Value, Vec<Vec<u16>>) {
    let plan = sample.plan(ann);
    let count: usize = plan["spatial_shape"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as usize).product();
    let layers = (0..plan["layers"].as_array().unwrap().len() as u32).map(|l| sample.layer(ann, l, count)).collect();
    (plan, layers)
}

/// Check that the layers of an annotation say what the engine's `contains`
/// says for every class, and that each layer holds only its own classes.
fn layers_agree(path: &std::path::Path, ann: &str) -> serde_json::Value {
    let sample = Sample::open(path);
    let (plan, layers) = read_all_layers(&sample, ann);
    for (l, classes) in plan["layers"].as_array().unwrap().iter().enumerate() {
        let classes: Vec<u16> = classes.as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as u16).collect();
        let ignore = plan["ignore_id"].as_u64().unwrap() as u16;
        assert!(
            layers[l].iter().all(|v| *v == 0 || *v == ignore || classes.contains(v)),
            "{ann}: layer {l} holds a class outside {classes:?}"
        );
    }
    for class in plan["class_ids"].as_array().unwrap() {
        let class = class.as_i64().unwrap();
        assert_eq!(from_layers(&layers, class as u16), dense(path, ann, class), "{ann}: class {class}");
    }
    plan
}

#[test]
fn layers_of_a_layers_annotation_are_its_own() {
    let plan = layers_agree(demo(), "organs_tp0");
    assert_eq!(plan["kind"], "layers");
    assert_eq!(plan["layers"].as_array().unwrap().len(), 2);
    assert_eq!(plan["ignore_in_band"], true);
    assert_eq!(plan["ignore_id"], 65535);
    // The in-band ignore region, as the engine reads it.
    let sample = Sample::open(demo());
    let (_, layers) = read_all_layers(&sample, "organs_tp0");
    let n = layers[0].len();
    let mut region = vec![0u8; n];
    ok(m5_annotation_read_mask(
        sample.0,
        c("organs_tp0").as_ptr(),
        true,
        std::ptr::null(),
        std::ptr::null(),
        0,
        region.as_mut_ptr(),
        n,
    ));
    let in_band: Vec<u8> = (0..n).map(|v| u8::from(layers.iter().any(|l| l[v] == 65535))).collect();
    assert_eq!(region, in_band);
    assert!(region.contains(&1));
    let oracle = engine(demo());
    let expected: Vec<u8> = oracle.ignore_region("organs_tp0", None).unwrap().iter().map(|v| u8::from(*v)).collect();
    assert_eq!(region, expected);
}

#[test]
fn layers_of_a_labelmap_probmap_and_instances() {
    let plan = layers_agree(demo(), "organs_tp1");
    assert_eq!(plan["layers"], serde_json::json!([[2, 3, 5, 6, 7, 8, 9]]));
    // The liver and the lesion overlap in the probmap: two layers.
    let plan = layers_agree(demo(), "lesion_prob_tp1");
    assert_eq!(plan["threshold"], 0.5);
    assert_eq!(plan["layers"].as_array().unwrap().len(), 2);
    assert_eq!(plan["overlaps"], serde_json::json!([[2, 9]]));
    let plan = layers_agree(demo(), "lesions_tp0");
    assert_eq!(plan["instances"], true);
    assert_eq!(plan["layers"], serde_json::json!([[9]]));
}

#[test]
fn layers_of_a_bitmask_after_a_transcode() {
    let dir = TempDir::new("bitmask");
    let path = demo_copy(&dir, "bitmask.medh5");
    {
        let w = Writer::amend(&path, None, "");
        // The baseline organs carry an ignore region in band, which a
        // bitmask cannot hold: refused, not dropped (§7.7).
        let error =
            fails(m5_writer_transcode_annotation(w.0, c("organs_tp0").as_ptr(), c("bitmask").as_ptr(), false), M5_ERR);
        assert_eq!(error["code"], "E404");
        // The probmap's liver and lesion overlap: kept as two bits.
        ok(m5_writer_transcode_annotation(w.0, c("lesion_prob_tp1").as_ptr(), c("bitmask").as_ptr(), false));
        ok(m5_writer_transcode_annotation(w.0, c("organs_tp1").as_ptr(), c("layers").as_ptr(), false));
        // Dense to instances is refused: identity cannot be invented.
        let error = fails(
            m5_writer_transcode_annotation(w.0, c("organs_tp1").as_ptr(), c("instances").as_ptr(), false),
            M5_ERR,
        );
        assert_eq!(error["kind"], "validation");
        w.commit();
    }
    let sample = Sample::open(&path);
    let s = sample.summary();
    let prob = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "lesion_prob_tp1").unwrap();
    assert_eq!(prob["kind"], "bitmask");
    // Coverage survives the transcode.
    assert_eq!(prob["class_ids"], serde_json::json!([2, 9]));
    assert_eq!(prob["annotated_class_ids"], serde_json::json!([2, 9]));
    let plan = layers_agree(&path, "lesion_prob_tp1");
    assert_eq!(plan["kind"], "bitmask");
    assert_eq!(plan["layers"].as_array().unwrap().len(), 2);
    assert_eq!(plan["overlaps"], serde_json::json!([[2, 9]]));
    let plan = layers_agree(&path, "organs_tp1");
    assert_eq!(plan["kind"], "layers");
    assert_eq!(validate(&path, "strict")["ok"], true);
}

#[test]
fn layer_regions_errors_and_cancellation() {
    let sample = Sample::open(demo());
    let whole = sample.layer("organs_tp1", 0, 64 * 64 * 64);
    let (start, stop) = ([30i64, 10, 0], [33i64, 50, 64]);
    let count = 3 * 40 * 64;
    let mut part = vec![0u16; count];
    ok(m5_annotation_read_layer(
        sample.0,
        c("organs_tp1").as_ptr(),
        0,
        start.as_ptr(),
        stop.as_ptr(),
        3,
        part.as_mut_ptr(),
        count,
        None,
        std::ptr::null_mut(),
    ));
    let mut i = 0;
    for z in 30..33 {
        for y in 10..50 {
            for x in 0..64 {
                assert_eq!(part[i], whole[z * 4096 + y * 64 + x]);
                i += 1;
            }
        }
    }
    fails(
        m5_annotation_read_layer(
            sample.0,
            c("organs_tp1").as_ptr(),
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            part.as_mut_ptr(),
            64 * 64 * 64,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );
    fails(
        m5_annotation_read_layer(
            sample.0,
            c("organs_tp1").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            part.as_mut_ptr(),
            17,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );
    let mut big = vec![0u16; 64 * 64 * 64];
    fails(
        m5_annotation_read_layer(
            sample.0,
            c("organs_tp1").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            big.as_mut_ptr(),
            big.len(),
            Some(cancel_at_once),
            std::ptr::null_mut(),
        ),
        M5_ERR_CANCELLED,
    );
    let error = fails(
        m5_annotation_read_layer(
            sample.0,
            c("mr_fov").as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
            big.as_mut_ptr(),
            32 * 56 * 56,
            None,
            std::ptr::null_mut(),
        ),
        M5_ERR_ARGUMENT,
    );
    assert!(error["message"].as_str().unwrap().contains("layer"), "{error}");
    let plan = sample.plan("mr_fov");
    assert_eq!(plan["layers"], serde_json::json!([]));
    let mut out = std::ptr::null_mut();
    fails(m5_annotation_layer_plan(sample.0, c("lesion_boxes_tp0").as_ptr(), &mut out), M5_ERR);
}

#[test]
fn masks_probabilities_instances_and_class_statistics() {
    let sample = Sample::open(demo());
    let oracle = engine(demo());
    let n = 32 * 56 * 56;
    let mut mask = vec![0u8; n];
    ok(m5_annotation_read_mask(
        sample.0,
        c("mr_fov").as_ptr(),
        false,
        std::ptr::null(),
        std::ptr::null(),
        0,
        mask.as_mut_ptr(),
        n,
    ));
    let expected: Vec<u8> =
        oracle.annotation("mr_fov").unwrap().read_mask(None).unwrap().iter().map(|v| u8::from(*v)).collect();
    assert_eq!(mask, expected);
    assert!(mask.contains(&1) && mask.contains(&0));
    // A class annotation is no mask.
    let mut volume = vec![0u8; 64 * 64 * 64];
    let error = fails(
        m5_annotation_read_mask(
            sample.0,
            c("organs_tp1").as_ptr(),
            false,
            std::ptr::null(),
            std::ptr::null(),
            0,
            volume.as_mut_ptr(),
            volume.len(),
        ),
        M5_ERR,
    );
    assert_eq!(error["kind"], "type");
    // A buffer of the wrong size is the caller's error.
    fails(
        m5_annotation_read_mask(
            sample.0,
            c("mr_fov").as_ptr(),
            false,
            std::ptr::null(),
            std::ptr::null(),
            0,
            mask.as_mut_ptr(),
            n - 1,
        ),
        M5_ERR_ARGUMENT,
    );

    let n = 64 * 64 * 64;
    let mut p = vec![0f32; n];
    ok(m5_annotation_read_probability(
        sample.0,
        c("lesion_prob_tp1").as_ptr(),
        9,
        std::ptr::null(),
        std::ptr::null(),
        0,
        p.as_mut_ptr(),
        n,
    ));
    let expected: Vec<f32> = oracle
        .annotation("lesion_prob_tp1")
        .unwrap()
        .probabilities(Some(&[ClassKey::Id(9)]), None)
        .unwrap()
        .iter()
        .copied()
        .collect();
    assert_eq!(p, expected);
    assert!(p.iter().cloned().fold(0f32, f32::max) > 0.9);
    fails(
        m5_annotation_read_probability(
            sample.0,
            c("lesion_prob_tp1").as_ptr(),
            3,
            std::ptr::null(),
            std::ptr::null(),
            0,
            p.as_mut_ptr(),
            n,
        ),
        M5_ERR,
    );

    let objects = sample.json_call(m5_annotation_instances, "lesions_tp0");
    let objects = objects.as_array().unwrap();
    assert_eq!(objects.len(), 2);
    assert_eq!(objects[0]["instance_id"], 1);
    assert_eq!(objects[1]["instance_id"], 2);
    assert!(objects.iter().all(|o| o["class_id"] == 9 && o["has_mask"] == true));
    let mut map = vec![0u32; n];
    ok(m5_annotation_read_instance_map(
        sample.0,
        c("lesions_tp0").as_ptr(),
        std::ptr::null(),
        std::ptr::null(),
        0,
        map.as_mut_ptr(),
        n,
    ));
    let engine_objects = oracle.annotation("lesions_tp0").unwrap().instances().unwrap();
    for (i, o) in objects.iter().enumerate() {
        let painted = map.iter().filter(|v| **v == i as u32 + 1).count() as u64;
        assert_eq!(painted, o["voxel_count"].as_u64().unwrap());
        assert_eq!(painted, engine_objects[i].voxel_count().unwrap());
    }
    let lesion: Vec<bool> = dense(demo(), "lesions_tp0", 9);
    assert_eq!(lesion, map.iter().map(|v| *v != 0).collect::<Vec<_>>());
    // A dense encoding has no objects.
    let mut out = std::ptr::null_mut();
    fails(m5_annotation_instances(sample.0, c("organs_tp0").as_ptr(), &mut out), M5_ERR);
    fails(
        m5_annotation_read_instance_map(
            sample.0,
            c("organs_tp0").as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            map.as_mut_ptr(),
            n,
        ),
        M5_ERR,
    );
    let boxes = sample.json_call(m5_annotation_instances, "lesion_boxes_tp0");
    assert_eq!(boxes.as_array().unwrap().len(), 3);

    let stats = sample.json_call(m5_annotation_class_stats, "organs_tp0");
    let counts = oracle.annotation("organs_tp0").unwrap().voxel_counts(None).unwrap();
    for (class, count) in counts {
        assert_eq!(stats[class.to_string()]["voxels"], count, "class {class}");
    }
    assert_eq!(stats["7"]["voxels"], 0);
    assert!(stats["7"]["bbox"].is_null());
    assert_eq!(stats["9"]["bbox"].as_array().unwrap().len(), 3);
}

// -- geometric annotations ------------------------------------------------------------

/// `x = origin + direction · (spacing ⊙ k)` of the demo's baseline CT grid.
fn ct0_world(k: [f64; 3]) -> [f64; 3] {
    let s = engine(demo());
    let g = s.grid("ct_tp0").unwrap();
    let w = g.index_to_world(&k).unwrap();
    [w[0], w[1], w[2]]
}

#[test]
fn geometry_of_every_kind_with_world_coordinates() {
    let sample = Sample::open(demo());
    let near = |a: f64, b: f64| (a - b).abs() < 1e-6 * (1.0 + b.abs());

    let boxes = geometry(&sample, "lesion_boxes_tp0");
    let h = boxes.header();
    assert_eq!(h["kind"], "boxes");
    assert_eq!(h["space"], "index");
    assert_eq!(h["items"], 3);
    assert_eq!(h["attributes"][0]["segment"], "VIII");
    assert_eq!(boxes.shape("boxes"), vec![3, 3, 2]);
    assert_eq!(boxes.shape("world_corners"), vec![3, 8, 3]);
    assert_eq!(boxes.f64s("class_ids"), vec![9.0, 9.0, 3.0]);
    assert_eq!(boxes.f64s("instance_ids"), vec![1.0, 2.0, 3.0]);
    let stored = boxes.f64s("boxes");
    let corners = boxes.f64s("world_corners");
    // Corner 0 is every lower bound, corner 7 every upper one.
    let lo = ct0_world([stored[0], stored[2], stored[4]]);
    let hi = ct0_world([stored[1], stored[3], stored[5]]);
    for a in 0..3 {
        assert!(near(corners[a], lo[a]), "{corners:?} {lo:?}");
        assert!(near(corners[7 * 3 + a], hi[a]));
    }
    assert!(boxes.view("nope").is_none());
    let names = boxes.names();
    assert!(names.contains(&"scores".to_string()));

    let obb = geometry(&sample, "kidney_obb_tp0");
    assert_eq!(obb.header()["space"], "world");
    assert_eq!(obb.shape("corners"), vec![2, 8, 3]);
    assert_eq!(obb.f64s("corners"), obb.f64s("world_corners"));

    let keypoints = geometry(&sample, "landmarks_tp0");
    let h = keypoints.header();
    assert_eq!(h["skeleton"], "abdominal-landmarks");
    assert_eq!(h["skeleton_edges"], serde_json::json!([[2, 7], [3, 7], [7, 8]]));
    assert_eq!(keypoints.shape("points"), vec![1, 4, 3]);
    assert_eq!(keypoints.f64s("visibility"), vec![2.0, 2.0, 2.0, 1.0]);
    let points = keypoints.f64s("points");
    let world = keypoints.f64s("world_points");
    let expected = ct0_world([points[0], points[1], points[2]]);
    assert!((0..3).all(|a| near(world[a], expected[a])));
    // The liver dome, as the demo placed it.
    assert!(near(world[0], -60.0) && near(world[1], 0.0) && near(world[2], 125.0), "{world:?}");

    let fiducials = geometry(&sample, "fiducials_tp0");
    let h = fiducials.header();
    assert_eq!(h["correspondence"], "fiducials_tp1");
    assert_eq!(h["names"][2], "lesion_centre");
    assert_eq!(
        fiducials.f64s("points").iter().map(|v| *v as f32).collect::<Vec<_>>(),
        fiducials.f64s("world_points").iter().map(|v| *v as f32).collect::<Vec<_>>()
    );

    let contours = geometry(&sample, "liver_contours_tp0");
    let offsets = contours.f64s("contour_offsets");
    let roles = contours.f64s("contour_role");
    assert_eq!(offsets.len(), roles.len() + 1);
    assert_eq!(roles.iter().filter(|r| **r == 1.0).count(), 1, "one hole");
    let planes = contours.f64s("contour_plane");
    assert!(planes.chunks(2).all(|p| p[0] == 0.0));

    let lines = geometry(&sample, "centrelines_tp0");
    assert_eq!(lines.f64s("polyline_class_ids"), vec![7.0, 12.0]);
    assert_eq!(lines.f64s("polyline_offsets"), vec![0.0, 12.0, 15.0]);
    assert_eq!(lines.f64s("instance_ids"), vec![21.0, 22.0]);
    let world = lines.f64s("world_vertices");
    let last = &world[world.len() - 3..];
    assert!(near(last[0], -70.0) && near(last[1], -10.0) && near(last[2], 55.0), "the needle ends in the lesion");

    let mesh = geometry(&sample, "surfaces_tp0");
    assert_eq!(mesh.header()["submeshes"], 2);
    assert_eq!(mesh.shape("faces"), vec![640, 3]);
    assert_eq!(mesh.f64s("mesh_offsets"), vec![0.0, 320.0, 640.0]);
    assert_eq!(mesh.f64s("mesh_class_ids"), vec![9.0, 2.0]);
    let vertices = mesh.f64s("world_vertices");
    let r = ((vertices[0] + 70.0).powi(2) + (vertices[1] + 10.0).powi(2) + (vertices[2] - 55.0).powi(2)).sqrt();
    assert!((r - 18.0).abs() < 1e-3, "the lesion sphere: {r}");
    assert_eq!(mesh.shape("world_normals"), vec![324, 3]);

    let response = geometry(&sample, "response");
    let h = response.header();
    assert_eq!(h["scope"], "sample");
    assert_eq!(h["change_label"], true);
    assert_eq!(h["assertions"][0]["key"], "progressive_disease");
    assert_eq!(h["positives"], serde_json::json!(["progressive_disease"]));
    assert_eq!(m5_bundle_array_count(response.0), 0);

    let mut out = std::ptr::null_mut();
    let error = fails(m5_annotation_geometry(sample.0, c("organs_tp0").as_ptr(), &mut out), M5_ERR);
    assert_eq!(error["kind"], "type");
    let mut view = M5ArrayView::default();
    fails(m5_bundle_array_at(boxes.0, 99, &mut view), M5_ERR_ARGUMENT);
    fails(m5_bundle_array_named(boxes.0, c("nope").as_ptr(), &mut view), M5_ERR_NOT_FOUND);
}

// -- transforms -----------------------------------------------------------------------

fn resolve(sample: &Sample, from: &str, to: &str, grid: Option<&str>, step: u32) -> Bundle {
    let mut out = std::ptr::null_mut();
    let grid_c = grid.map(c);
    ok(m5_transform_resolve(
        sample.0,
        c(from).as_ptr(),
        c(to).as_ptr(),
        grid_c.as_ref().map_or(std::ptr::null(), |g| g.as_ptr()),
        step,
        &mut out,
    ));
    Bundle(out)
}

fn apply(m: &[f64], x: [f64; 3]) -> [f64; 3] {
    [0, 1, 2].map(|r| m[r * 4] * x[0] + m[r * 4 + 1] * x[1] + m[r * 4 + 2] * x[2] + m[r * 4 + 3])
}

#[test]
fn transforms_read_and_resolve_between_visits() {
    let sample = Sample::open(demo());
    let mut out = std::ptr::null_mut();
    ok(m5_transform_read(sample.0, c("tp0_to_tp1").as_ptr(), &mut out));
    let stored = Bundle(out);
    assert_eq!(stored.header()["kind"], "affine");
    assert_eq!(stored.shape("matrix"), vec![4, 4]);
    let expected: Vec<f64> = medh5_bridge::demo::motion_matrix().iter().flatten().copied().collect();
    assert_eq!(stored.f64s("matrix"), expected);

    // Baseline points land on the follow-up's: the lesion's centre.
    for (from, to) in [("tp0", "tp1"), ("ct_tp0", "ct_tp1"), ("demo:frame-tp0", "demo:frame-tp1")] {
        let resolved = resolve(&sample, from, to, None, 1);
        let h = resolved.header();
        assert_eq!(h["found"], true, "{from} -> {to}");
        assert_eq!(h["linear"], true);
        assert_eq!(h["path"], serde_json::json!(["tp0_to_tp1"]));
        let m = resolved.f64s("matrix");
        let moved = apply(&m, medh5_bridge::demo::LESION_CENTRE);
        let truth = medh5_bridge::demo::to_follow_up(medh5_bridge::demo::LESION_CENTRE);
        assert!((0..3).all(|a| (moved[a] - truth[a]).abs() < 1e-9), "{moved:?} {truth:?}");
    }
    // The other way is the inverse.
    let back = resolve(&sample, "tp1", "tp0", None, 1);
    assert_eq!(back.header()["inverted"], serde_json::json!([true]));
    let m = back.f64s("matrix");
    let truth = medh5_bridge::demo::to_follow_up(medh5_bridge::demo::LESION_CENTRE);
    let home = apply(&m, truth);
    assert!((0..3).all(|a| (home[a] - medh5_bridge::demo::LESION_CENTRE[a]).abs() < 1e-9));
    // The MR shares the baseline frame: no transform, the identity.
    let same = resolve(&sample, "ct_tp0", "mr_tp0", None, 1);
    assert_eq!(same.header()["found"], false);
    assert_eq!(same.header()["same_frame"], true);
    assert_eq!(m5_bundle_array_count(same.0), 0);
    // Unknown keys are refused.
    let mut out = std::ptr::null_mut();
    let error = fails(
        m5_transform_resolve(sample.0, c("tp9").as_ptr(), c("tp0").as_ptr(), std::ptr::null(), 1, &mut out),
        M5_ERR,
    );
    assert_eq!(error["kind"], "key");
    fails(m5_transform_read(sample.0, c("nope").as_ptr(), &mut out), M5_ERR);
}

// -- clinical -------------------------------------------------------------------------

#[test]
fn clinical_records_text_and_selection_at_a_cutoff() {
    let sample = Sample::open(demo());
    let mut out = std::ptr::null_mut();
    ok(m5_clinical_records(sample.0, &mut out));
    let records = take_json(out);
    assert_eq!(records["present"], true);
    assert_eq!(records["events"].as_array().unwrap().len(), 11);
    assert_eq!(records["documents"].as_array().unwrap().len(), 3);
    assert_eq!(records["clock"]["reference"], "relative");
    let report = records["documents"].as_array().unwrap().iter().find(|d| d["document_id"] == "report1_text").unwrap();
    assert_eq!(report["bytes"], medh5_bridge::demo::REPORT_TP1.len());

    let mut out = std::ptr::null_mut();
    ok(m5_clinical_document_text(sample.0, c("report1_text").as_ptr(), &mut out));
    assert_eq!(take(out), medh5_bridge::demo::REPORT_TP1);
    fails(m5_clinical_document_text(sample.0, c("nope").as_ptr(), &mut out), M5_ERR);

    // One day after the baseline CT: the labs, the scans and the amended
    // baseline report are known; nothing of the follow-up is.
    let mut out = std::ptr::null_mut();
    ok(m5_clinical_select(sample.0, c(r#"{"cutoff_hours": 36}"#).as_ptr(), &mut out));
    let selected = take_json(out);
    let ids: Vec<&str> = selected["event_ids"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    for id in ["alt0", "afp0", "ct0", "mr0", "report0_v2"] {
        assert!(ids.contains(&id), "{id} in {ids:?}");
    }
    for id in ["ct1", "report1", "afp1", "response1", "report0_v1"] {
        assert!(!ids.contains(&id), "{id} not in {ids:?}");
    }
    assert!(selected["documents"].as_array().unwrap().iter().any(|d| d == "report0_text_v2"));
    let mut out = std::ptr::null_mut();
    fails(m5_clinical_select(sample.0, c("{}").as_ptr(), &mut out), M5_ERR_ARGUMENT);
}

#[test]
fn summary_and_layers_of_a_small_demo_without_clinical_history() {
    let dir = TempDir::new("small");
    let path = dir.path("small.medh5");
    ok(m5_demo_write(cp(&path).as_ptr(), c(r#"{"size": 24, "clinical": false, "polylines": false}"#).as_ptr()));
    let report = validate(&path, "strict");
    assert_eq!(report["ok"], true, "{report}");
    let sample = Sample::open(&path);
    let s = sample.summary();
    assert_eq!(s["format_version"], "1.0", "imaging alone is 1.0");
    assert_eq!(s["clinical"]["present"], false);
    let mut out = std::ptr::null_mut();
    ok(m5_clinical_records(sample.0, &mut out));
    assert_eq!(take_json(out), serde_json::json!({"present": false}));
    layers_agree(&path, "organs_tp0");
    let mut out = std::ptr::null_mut();
    fails(m5_clinical_select(sample.0, c(r#"{"cutoff_hours": 1}"#).as_ptr(), &mut out), M5_ERR);
    // Out of range sizes are refused.
    fails(m5_demo_write(cp(&dir.path("x.medh5")).as_ptr(), c(r#"{"size": 4}"#).as_ptr()), M5_ERR_ARGUMENT);
}
