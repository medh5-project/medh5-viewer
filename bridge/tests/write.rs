//! Writing through the C ABI: creating a sample, amending one (the
//! viewer's save), transforms, NIfTI, recompression, collections.

mod common;

use std::ffi::c_void;

use common::*;
use medh5::labels::ClassKey;
use medh5_bridge::*;
use serde_json::json;

const LABELS: &str = r#"{"id": "test-labels", "version": "1.0.0", "classes": [
  {"id": 1, "key": "organ", "name": "Organ", "color": [200, 100, 50, 255], "codes": [{"system": "SCT", "code": "1"}]},
  {"id": 2, "key": "lesion", "name": "Lesion", "parents": [1], "codes": [{"system": "SCT", "code": "2"}]},
  {"id": 3, "key": "other", "name": "Other", "codes": [{"system": "SCT", "code": "3"}]}]}"#;

fn grid_json(frame: &str, timepoint: &str) -> String {
    json!({"shape": [6, 8, 10], "spacing": [3.0, 1.5, 1.0], "origin": [10.0, -4.0, 2.0],
           "direction": [[0, 0, 1], [0, 1, 0], [1, 0, 0]], "coord_system": "LPS", "units": "mm",
           "timepoint": timepoint, "frame_uid": frame})
    .to_string()
}

fn add_image(w: &Writer, id: &str, grid: &str, values: &[i16]) {
    let shape = [6i64, 8, 10];
    ok(m5_writer_add_image(w.0, c(id).as_ptr(), c(grid).as_ptr(),
        c(r#"{"modality": "CT", "value_type": "quantitative", "value_units": "HU", "rescale_intercept": -1024.0, "window_center": [40], "window_width": [400]}"#).as_ptr(),
        5, shape.as_ptr(), 3, values.as_ptr() as *const c_void, values.len() * 2));
}

fn add_layers(w: &Writer, id: &str, grid: &str, options: &str, layers: &[Vec<u16>]) -> serde_json::Value {
    let pointers: Vec<*const u16> = layers.iter().map(|l| l.as_ptr()).collect();
    let mut out = std::ptr::null_mut();
    ok(m5_writer_add_segmentation_ex(
        w.0,
        c(id).as_ptr(),
        c(grid).as_ptr(),
        c(options).as_ptr(),
        pointers.len() as u32,
        pointers.as_ptr(),
        layers[0].len(),
        &mut out,
    ));
    take_json(out)
}

#[test]
fn a_sample_written_from_scratch_reads_back() {
    let dir = TempDir::new("create");
    let path = dir.path("case.medh5");
    let n = 6 * 8 * 10;
    let ct: Vec<i16> = (0..n).map(|i| (i % 97) as i16 + 1000).collect();
    let flat: Vec<u16>;
    let content_id = {
        let w = Writer::create(&path, r#"{"sample_id": "case_0001", "subject_id": "SUBJ-1", "codec": "portable"}"#);
        ok(m5_writer_add_timepoint(
            w.0,
            c("tp0").as_ptr(),
            c(r#"{"label": "baseline", "days_from_baseline": 0}"#).as_ptr(),
        ));
        ok(m5_writer_add_timepoint(w.0, c("tp1").as_ptr(), c(r#"{"days_from_baseline": 30}"#).as_ptr()));
        ok(m5_writer_set_identity(w.0, c(r#"{"sex": "M"}"#).as_ptr()));
        ok(m5_writer_set_cohort(w.0, c(r#"{"dataset_id": "bridge-tests", "site_id": "s1"}"#).as_ptr()));
        ok(m5_writer_set_label_set(w.0, c(LABELS).as_ptr()));
        let mut out = std::ptr::null_mut();
        ok(m5_writer_add_agent(
            w.0,
            c(r#"{"type": "person", "name": "pseudonym:A", "id": "a1", "role": "annotator"}"#).as_ptr(),
            &mut out,
        ));
        assert_eq!(take_json(out)["id"], "a1");
        let mut out = std::ptr::null_mut();
        ok(m5_writer_add_activity(
            w.0,
            c(r#"{"type": "annotate", "agent": "a1", "tool": "medh5-viewer"}"#).as_ptr(),
            &mut out,
        ));
        let activity = take_json(out);
        let activity_id = activity["id"].as_str().unwrap().to_string();
        ok(m5_writer_set_quality(w.0, c("seg").as_ptr(), c(r#"{"status": "reviewed", "confidence": 0.9}"#).as_ptr()));
        ok(m5_writer_set_extra(w.0, c("org.example").as_ptr(), c(r#"{"note": 1, "ratio": 1.0}"#).as_ptr()));
        ok(m5_writer_set_deidentification(w.0, c(r#"{"method": "synthetic"}"#).as_ptr()));
        ok(m5_writer_add_grid(w.0, c("g0").as_ptr(), c(&grid_json("f0", "tp0")).as_ptr()));
        ok(m5_writer_add_grid(w.0, c("g1").as_ptr(), c(&grid_json("f1", "tp1")).as_ptr()));
        add_image(&w, "CT0", "g0", &ct);
        add_image(&w, "CT1", "g1", &ct);
        ok(m5_writer_set_acquisition(w.0, c("CT0").as_ptr(), c(r#"{"KVP": 120}"#).as_ptr()));
        ok(m5_writer_set_image_attrs(
            w.0,
            c("CT1").as_ptr(),
            c(r#"{"value_units": "HU", "window_center": [50], "window_width": [350]}"#).as_ptr(),
        ));

        // An organ with a lesion inside it: two layers, overlapping.
        let mut organ = vec![0u16; n];
        let mut lesion = vec![0u16; n];
        for z in 1..5 {
            for y in 2..7 {
                for x in 2..9 {
                    organ[z * 80 + y * 10 + x] = 1;
                }
            }
        }
        for z in 2..4 {
            for y in 3..5 {
                for x in 4..6 {
                    lesion[z * 80 + y * 10 + x] = 2;
                }
            }
        }
        let chose = add_layers(
            &w,
            "seg",
            "g0",
            &json!({"class_ids": [1, 2, 3], "annotated_classes": [1, 2, 3], "quality": "seg", "prov": activity_id})
                .to_string(),
            &[organ.clone(), lesion.clone()],
        );
        assert_ne!(chose["kind"], "labelmap", "an overlap cannot be a labelmap: {chose}");
        assert_eq!(chose["stats"]["edges"], 1, "one overlapping pair: {chose}");
        // One layer of disjoint classes, given as a labelmap.
        flat = (0..n).map(|v| if lesion[v] != 0 { 2 } else { organ[v] }).collect();
        let chose = add_layers(
            &w,
            "flat",
            "g1",
            r#"{"encoding": "labelmap", "annotated_classes": "present"}"#,
            std::slice::from_ref(&flat),
        );
        assert_eq!(chose["kind"], "labelmap");
        let mask: Vec<u8> = organ.iter().map(|v| u8::from(*v != 0)).collect();
        ok(m5_writer_add_mask(
            w.0,
            c("roi").as_ptr(),
            c("g0").as_ptr(),
            c(r#"{"task": "other"}"#).as_ptr(),
            mask.as_ptr(),
            n,
        ));

        let boxes =
            [Owned::f64("boxes", &[1, 3, 2], &[1.5, 3.5, 2.5, 4.5, 3.5, 5.5]), Owned::i64("class_ids", &[1], &[2])];
        let v = views(&boxes);
        ok(m5_writer_add_geometric(
            w.0,
            c("boxes").as_ptr(),
            c("lesion_box").as_ptr(),
            c(r#"{"grid": "g0", "space": "index", "attributes": [{"confirmed": true}]}"#).as_ptr(),
            v.as_ptr(),
            v.len(),
        ));
        let points = [Owned::f64("points", &[2, 3], &[12.0, 1.0, 5.0, 14.0, 2.0, 6.0])];
        let v = views(&points);
        ok(m5_writer_add_geometric(
            w.0,
            c("points").as_ptr(),
            c("marks").as_ptr(),
            c(r#"{"grid": "g0", "space": "world", "names": ["a", "b"]}"#).as_ptr(),
            v.as_ptr(),
            v.len(),
        ));
        let lines = [
            Owned::f64("vertices", &[3, 3], &[1.0, 1.0, 1.0, 2.0, 3.0, 4.0, 3.0, 5.0, 7.0]),
            Owned::i64("polyline_offsets", &[2], &[0, 3]),
        ];
        let v = views(&lines);
        ok(m5_writer_add_geometric(
            w.0,
            c("polylines").as_ptr(),
            c("track").as_ptr(),
            c(r#"{"grid": "g0", "polyline_class_ids": ["other"]}"#).as_ptr(),
            v.as_ptr(),
            v.len(),
        ));
        ok(m5_writer_add_classification(w.0, c("finding").as_ptr(),
            c(r#"{"scope": "sample", "assertions": [{"class_id": "lesion", "value": 1.0}, {"class_id": 3, "value": 0.0}]}"#).as_ptr()));
        let matrix = [1.0, 0.0, 0.0, 5.0, 0.0, 1.0, 0.0, -3.0, 0.0, 0.0, 1.0, 2.0, 0.0, 0.0, 0.0, 1.0];
        ok(m5_writer_add_affine_transform(
            w.0,
            c("t01").as_ptr(),
            c(r#"{"from_frame": "f0", "to_frame": "f1"}"#).as_ptr(),
            matrix.as_ptr(),
            4,
        ));
        ok(m5_writer_build_index(w.0, c(r#"{"annotations": ["seg"], "seed": 3}"#).as_ptr()));

        // Refusals leave the writer usable.
        let bad = [6i64, 8];
        fails(
            m5_writer_add_image(
                w.0,
                c("X").as_ptr(),
                c("g0").as_ptr(),
                std::ptr::null(),
                5,
                bad.as_ptr(),
                2,
                ct.as_ptr() as *const c_void,
                ct.len() * 2,
            ),
            M5_ERR_ARGUMENT,
        );
        let shape = [6i64, 8, 10];
        let error = fails(
            m5_writer_add_image(
                w.0,
                c("X").as_ptr(),
                c("nogrid").as_ptr(),
                std::ptr::null(),
                5,
                shape.as_ptr(),
                3,
                ct.as_ptr() as *const c_void,
                ct.len() * 2,
            ),
            M5_ERR,
        );
        assert_eq!(error["code"], "E101");
        fails(m5_writer_add_grid(w.0, c("g2").as_ptr(), c(r#"{"spacing": [1, 1, 1]}"#).as_ptr()), M5_ERR_ARGUMENT);
        fails(
            m5_writer_add_image(
                w.0,
                c("X").as_ptr(),
                c("g0").as_ptr(),
                std::ptr::null(),
                0,
                shape.as_ptr(),
                3,
                ct.as_ptr() as *const c_void,
                ct.len() * 2,
            ),
            M5_ERR_ARGUMENT,
        );
        fails(m5_writer_set_identity(w.0, c("not json").as_ptr()), M5_ERR_ARGUMENT);
        fails(
            m5_writer_add_geometric(w.0, c("blobs").as_ptr(), c("x").as_ptr(), std::ptr::null(), std::ptr::null(), 0),
            M5_ERR_ARGUMENT,
        );

        // The document round-trips through the writer.
        let mut out = std::ptr::null_mut();
        ok(m5_writer_document(w.0, &mut out));
        let document = take(out);
        let parsed: serde_json::Value = serde_json::from_str(&document).unwrap();
        assert_eq!(parsed["extra"]["org.example"]["ratio"], 1.0);
        ok(m5_writer_set_document(w.0, c(&document).as_ptr()));
        w.commit()
    };
    assert!(content_id.starts_with("sha256:"));

    let report = validate(&path, "strict");
    assert_eq!(report["ok"], true, "{report}");
    let sample = Sample::open(&path);
    let s = sample.summary();
    assert_eq!(s["content_id"], content_id.as_str());
    assert_eq!(s["identity"]["sex"], "M");
    assert_eq!(s["cohort"]["dataset_id"], "bridge-tests");
    assert_eq!(s["extra"]["org.example"]["note"], 1);
    assert_eq!(s["acquisition"]["CT0"]["KVP"], 120);
    let ct1 = s["images"].as_array().unwrap().iter().find(|i| i["id"] == "CT1").unwrap();
    assert_eq!(ct1["window_center"], json!([50.0]));
    assert_eq!(sample.image_i16("CT0", n), ct);
    let seg = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "seg").unwrap();
    assert_eq!(seg["class_ids"], json!([1, 2, 3]));
    assert_eq!(seg["annotated_class_ids"], json!([1, 2, 3]));
    assert_eq!(seg["quality"], "seg");
    let flat_info = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "flat").unwrap();
    assert_eq!(flat_info["annotated_class_ids"], json!([1, 2]));
    let plan = sample.plan("seg");
    let layers: Vec<Vec<u16>> =
        (0..plan["layers"].as_array().unwrap().len() as u32).map(|l| sample.layer("seg", l, n)).collect();
    let engine_seg = engine(&path);
    for class in [1i64, 2, 3] {
        let dense: Vec<bool> = engine_seg
            .annotation("seg")
            .unwrap()
            .dense(Some(&[ClassKey::Id(class)]), None)
            .unwrap()
            .iter()
            .copied()
            .collect();
        let from: Vec<bool> = (0..n).map(|v| layers.iter().any(|l| l[v] == class as u16)).collect();
        assert_eq!(from, dense, "class {class}");
    }
    assert_eq!(sample.layer("flat", 0, n), flat);
    let b = geometry(&sample, "lesion_box");
    assert_eq!(b.f64s("boxes"), vec![1.5, 3.5, 2.5, 4.5, 3.5, 5.5]);
    let t = geometry(&sample, "track");
    assert_eq!(t.f64s("polyline_class_ids"), vec![3.0]);
    assert_eq!(s["format_version"], "1.2");
    assert!(s["profiles"].as_array().unwrap().iter().any(|p| p == "training"));
}

#[test]
fn commit_refusals_leave_the_writer_open_and_abort_discards() {
    let dir = TempDir::new("refuse");
    let path = dir.path("empty.medh5");
    let w = Writer::create(&path, "");
    let mut id = std::ptr::null_mut();
    let error = fails(m5_writer_commit(w.0, true, &mut id), M5_ERR);
    assert_eq!(error["code"], "E201");
    assert!(!path.exists(), "nothing is visible before a commit");
    m5_writer_abort(w.0);
    fails(m5_writer_commit(w.0, true, &mut id), M5_ERR);
    assert!(!path.exists());
    drop(w);
    // An amendment of a file that is not there.
    let mut out = std::ptr::null_mut();
    fails(m5_writer_amend(cp(&dir.path("none.medh5")).as_ptr(), std::ptr::null(), std::ptr::null(), &mut out), M5_ERR);
}

/// What the viewer does on save: amend the file, dropping the segmentation
/// being replaced, write the edited layers back with the coverage they had.
#[test]
fn amending_an_edited_segmentation_preserves_coverage_and_everything_else() {
    let dir = TempDir::new("amend");
    let path = demo_copy(&dir, "demo.medh5");
    let before = Sample::open(&path);
    let s0 = before.summary();
    let plan = before.plan("organs_tp0");
    let n = 64 * 64 * 64;
    let mut layers: Vec<Vec<u16>> = (0..2).map(|l| before.layer("organs_tp0", l, n)).collect();
    let info0 = s0["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "organs_tp0").unwrap().clone();
    drop(before);

    // Paint a new lesion voxel, erase the whole spleen (examined: it stays
    // annotated, now absent).
    let painted = 40 * 4096 + 30 * 64 + 30;
    layers[1][painted] = 9;
    for v in layers[0].iter_mut() {
        if *v == 3 {
            *v = 0;
        }
    }
    let options = json!({
        "class_ids": plan["class_ids"],
        "annotated_classes": plan["annotated_class_ids"],
        "prov": info0["prov"],
        "quality": info0["quality"],
        "timepoints": info0["declared_timepoints"],
    })
    .to_string();
    let new_id = {
        let w = Writer::amend(&path, None, r#"{"without": ["annotations/organs_tp0"]}"#);
        let chose = add_layers(&w, "organs_tp0", "ct_tp0", &options, &layers);
        assert_eq!(chose["kind"], "layers", "{chose}");
        w.commit()
    };
    let after = Sample::open(&path);
    let s1 = after.summary();
    assert_eq!(s1["content_id"], new_id.as_str());
    assert_ne!(s1["content_id"], s0["content_id"]);
    let info1 = s1["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "organs_tp0").unwrap();
    for key in
        ["kind", "class_ids", "annotated_class_ids", "closure", "ignore_id", "prov", "quality", "grid", "timepoints"]
    {
        assert_eq!(info1[key], info0[key], "{key}");
    }
    let plan1 = after.plan("organs_tp0");
    assert_eq!(plan1["ignore_in_band"], true, "the ignore region stays in band");
    let read: Vec<Vec<u16>> = (0..2).map(|l| after.layer("organs_tp0", l, n)).collect();
    for class in [2u16, 3, 5, 6, 8, 9, 65535] {
        let want: Vec<bool> = (0..n).map(|v| layers.iter().any(|l| l[v] == class)).collect();
        let got: Vec<bool> = (0..n).map(|v| read.iter().any(|l| l[v] == class)).collect();
        assert_eq!(got, want, "class {class}");
    }
    let stats = after.json_call(m5_annotation_class_stats, "organs_tp0");
    assert_eq!(stats["3"]["voxels"], 0, "the spleen: examined, absent");

    // Every other object is untouched: same digests, same voxels.
    for group in ["images", "annotations"] {
        for o0 in s0[group].as_array().unwrap() {
            if o0["id"] == "organs_tp0" {
                continue;
            }
            let o1 = s1[group].as_array().unwrap().iter().find(|o| o["id"] == o0["id"]).unwrap();
            assert_eq!(o1["digest"], o0["digest"], "{} {}", group, o0["id"]);
        }
    }
    for key in ["grids", "transforms", "label_set", "timepoints", "identity", "provenance", "quality", "clinical"] {
        assert_eq!(s1[key], s0[key], "{key}");
    }
    let mut out = std::ptr::null_mut();
    ok(m5_sample_verify(after.0, &mut out));
    assert_eq!(take_json(out)["ok"], true);
    // The index entry went with the annotation it indexed; the rest holds.
    assert_eq!(s1["index"], json!([]));
    let report = validate(&path, "strict");
    assert_eq!(report["ok"], true, "{report}");
}

#[test]
fn without_leaves_objects_behind_and_out_path_leaves_the_source() {
    let dir = TempDir::new("without");
    let path = demo_copy(&dir, "demo.medh5");
    let out_path = dir.path("copy.medh5");
    let source_id = Sample::open(&path).summary()["content_id"].clone();
    {
        let w = Writer::amend(
            &path,
            Some(&out_path),
            r#"{"without": ["clinical", "annotations/response", "transforms/tp0_to_tp1"]}"#,
        );
        // The transform is written again, as itself.
        let matrix: Vec<f64> = medh5_bridge::demo::motion_matrix().iter().flatten().copied().collect();
        ok(m5_writer_add_affine_transform(w.0, c("tp0_to_tp1").as_ptr(),
            c(r#"{"from_frame": "demo:frame-tp0", "to_frame": "demo:frame-tp1", "from_grid": "ct_tp0", "to_grid": "ct_tp1", "invertible": true, "prov": "act_register"}"#).as_ptr(),
            matrix.as_ptr(), 4));
        ok(m5_writer_remove_annotation(w.0, c("mr_fov").as_ptr()));
        // The MR names the mask as its valid region: it must go too, or the
        // commit refuses a dangling reference.
        ok(m5_writer_set_image_attrs(w.0, c("MR_tp0").as_ptr(), c(r#"{"valid_mask": null}"#).as_ptr()));
        w.commit();
    }
    let source = Sample::open(&path).summary();
    assert_eq!(source["content_id"], source_id, "the source is left alone");
    let copy = Sample::open(&out_path).summary();
    assert_eq!(copy["clinical"]["present"], false);
    assert_eq!(copy["format_version"], "1.2", "the polylines keep it at 1.2");
    let ids: Vec<&str> = copy["annotations"].as_array().unwrap().iter().map(|a| a["id"].as_str().unwrap()).collect();
    assert!(!ids.contains(&"response") && !ids.contains(&"mr_fov"));
    assert_eq!(copy["transforms"][0]["id"], "tp0_to_tp1");
    assert_eq!(validate(&out_path, "integrity")["ok"], true);
    // An entry naming no object is refused before anything is written.
    let mut out = std::ptr::null_mut();
    fails(
        m5_writer_amend(
            cp(&path).as_ptr(),
            cp(&dir.path("x.medh5")).as_ptr(),
            c(r#"{"without": ["annotations/nope"]}"#).as_ptr(),
            &mut out,
        ),
        M5_ERR,
    );
    fails(
        m5_writer_amend(
            cp(&path).as_ptr(),
            cp(&dir.path("x.medh5")).as_ptr(),
            c(r#"{"without": ["meta/x"]}"#).as_ptr(),
            &mut out,
        ),
        M5_ERR_ARGUMENT,
    );
}

#[test]
fn a_corrupted_copy_fails_verification_validation_and_amendment() {
    let dir = TempDir::new("corrupt");
    let path = demo_copy(&dir, "corrupt.medh5");
    {
        // Change voxels behind the library's back.
        let file = medh5::hdf5::File::open_rw(&path).unwrap();
        let ds = file.dataset("images/CT_tp1").unwrap();
        let mut values: medh5::ndarray::ArrayD<i16> = ds.read_dyn().unwrap();
        values.iter_mut().take(100).for_each(|v| *v = v.wrapping_add(7));
        ds.write(&values).unwrap();
    }
    let sample = Sample::open(&path);
    let mut out = std::ptr::null_mut();
    ok(m5_sample_verify(sample.0, &mut out));
    let verified = take_json(out);
    assert_eq!(verified["ok"], false);
    assert!(verified["mismatched"].as_array().unwrap().iter().any(|p| p == "images/CT_tp1"), "{verified}");
    let report = validate(&path, "integrity");
    assert_eq!(report["ok"], false);
    assert!(report["codes"].as_array().unwrap().iter().any(|c| c == "E701"), "{report}");
    let diagnostic = report["diagnostics"].as_array().unwrap().iter().find(|d| d["code"] == "E701").unwrap();
    assert!(diagnostic["summary"].as_str().unwrap().len() > 5);
    // An amendment would restamp bytes nobody verified: its commit refuses
    // (E701) and leaves the file as it was.
    {
        let w = Writer::amend(&path, None, "");
        let mut id = std::ptr::null_mut();
        let error = fails(m5_writer_commit(w.0, true, &mut id), M5_ERR);
        assert_eq!(error["code"], "E701", "{error}");
    }
    let still = validate(&path, "integrity");
    assert!(still["codes"].as_array().unwrap().iter().any(|c| c == "E701"));
    // Not an HDF5 file at all: reported, not refused.
    let junk = dir.path("junk.medh5");
    std::fs::write(&junk, b"this is not hdf5").unwrap();
    let report = validate(&junk, "structural");
    assert_eq!(report["ok"], false);
    assert_eq!(report["codes"], json!(["E001"]));
}

#[test]
fn transforms_of_every_kind_resolve_to_matrices_or_fields() {
    let dir = TempDir::new("fields");
    let path = dir.path("fields.medh5");
    let n = 6 * 8 * 10;
    {
        let w = Writer::create(&path, r#"{"sample_id": "fields"}"#);
        for (g, f) in [("ga", "fa"), ("gb", "fb"), ("gc", "fc")] {
            ok(m5_writer_add_grid(w.0, c(g).as_ptr(), c(&grid_json(f, "tp0")).as_ptr()));
        }
        add_image(&w, "A", "ga", &vec![0i16; n]);
        // A constant displacement field (1, 2, 3) mm from fa to fb.
        let mut field = vec![0f32; 3 * n];
        for (component, value) in [1.0f32, 2.0, 3.0].iter().enumerate() {
            field[component * n..(component + 1) * n].fill(*value);
        }
        let arrays = [Owned::f32("field", &[3, 6, 8, 10], &field)];
        let v = views(&arrays);
        ok(m5_writer_add_transform(
            w.0,
            c("warp").as_ptr(),
            c("displacement").as_ptr(),
            c(r#"{"from_frame": "fa", "to_frame": "fb", "field_grid": "ga", "vector_space": "world"}"#).as_ptr(),
            v.as_ptr(),
            v.len(),
        ));
        let matrix = [Owned::f64(
            "matrix",
            &[4, 4],
            &[2.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, -5.0, 0.0, 0.0, 0.0, 1.0],
        )];
        let v = views(&matrix);
        ok(m5_writer_add_transform(
            w.0,
            c("scale").as_ptr(),
            c("affine").as_ptr(),
            c(r#"{"from_frame": "fb", "to_frame": "fc"}"#).as_ptr(),
            v.as_ptr(),
            v.len(),
        ));
        w.commit();
    }
    let sample = Sample::open(&path);
    let mut out = std::ptr::null_mut();
    ok(m5_transform_read(sample.0, c("warp").as_ptr(), &mut out));
    let stored = Bundle(out);
    assert_eq!(stored.shape("field"), vec![3, 6, 8, 10]);
    assert_eq!(stored.header()["field_grid"], "ga");

    // fa -> fb: not linear; sampled on ga it is the constant field.
    let mut out = std::ptr::null_mut();
    ok(m5_transform_resolve(sample.0, c("fa").as_ptr(), c("fb").as_ptr(), c("ga").as_ptr(), 2, &mut out));
    let r = Bundle(out);
    let h = r.header();
    assert_eq!(h["found"], true);
    assert_eq!(h["linear"], false);
    assert_eq!(h["field_grid"]["shape"], json!([3, 4, 5]));
    assert_eq!(h["field_grid"]["spacing"], json!([6.0, 3.0, 2.0]));
    assert_eq!(r.shape("displacement"), vec![3, 4, 5, 3]);
    let d = r.f64s("displacement");
    assert!(d.chunks(3).all(|v| (v[0] - 1.0).abs() < 1e-5 && (v[1] - 2.0).abs() < 1e-5 && (v[2] - 3.0).abs() < 1e-5));
    assert!(r.view("matrix").is_none());
    // Without a field grid: the header alone.
    let mut out = std::ptr::null_mut();
    ok(m5_transform_resolve(sample.0, c("fa").as_ptr(), c("fb").as_ptr(), std::ptr::null(), 1, &mut out));
    assert_eq!(m5_bundle_array_count(Bundle(out).0), 0);
    // fb -> fc is linear; fa -> fc chains the field and the affine.
    let mut out = std::ptr::null_mut();
    ok(m5_transform_resolve(sample.0, c("gb").as_ptr(), c("gc").as_ptr(), std::ptr::null(), 1, &mut out));
    let r = Bundle(out);
    assert_eq!(r.header()["linear"], true);
    assert_eq!(r.f64s("matrix")[0], 2.0);
    let mut out = std::ptr::null_mut();
    ok(m5_transform_resolve(sample.0, c("ga").as_ptr(), c("gc").as_ptr(), c("ga").as_ptr(), 1, &mut out));
    let r = Bundle(out);
    let h = r.header();
    assert_eq!(h["path"], json!(["warp", "scale"]));
    assert_eq!(h["linear"], false);
    let d = r.f64s("displacement");
    // T(x) = A(x + u), so T(x) - x = (x + 1)·2 + 1 - x in the first axis.
    let grid = engine(&path).grid("ga").unwrap().clone();
    let x0 = grid.index_to_world(&[0.0, 0.0, 0.0]).unwrap();
    assert!((d[0] - ((x0[0] + 1.0) * 2.0 + 1.0 - x0[0])).abs() < 1e-4, "{} vs {:?}", d[0], x0);
    // A field grid must lie in the frame the points come from.
    let mut out = std::ptr::null_mut();
    let error = fails(
        m5_transform_resolve(sample.0, c("fa").as_ptr(), c("fb").as_ptr(), c("gb").as_ptr(), 1, &mut out),
        M5_ERR,
    );
    assert_eq!(error["code"], "E414");
}

#[test]
fn nifti_export_read_import_and_segmentation() {
    let dir = TempDir::new("nifti");
    let ct = dir.path("ct.nii.gz");
    let mut out = std::ptr::null_mut();
    ok(m5_nifti_export(
        cp(demo()).as_ptr(),
        c(&json!({"object": "images/CT_tp0", "out": ct.to_str().unwrap()}).to_string()).as_ptr(),
        &mut out,
    ));
    let report = take_json(out);
    assert!(report["path"].as_str().unwrap().ends_with("ct.nii.gz"), "{report}");

    let mut bundle = std::ptr::null_mut();
    ok(m5_nifti_read(cp(&ct).as_ptr(), &mut bundle));
    let read = Bundle(bundle);
    let h = read.header();
    assert_eq!(read.shape("data"), vec![64, 64, 64]);
    assert_eq!(h["grid"]["coord_system"], "LPS");
    // The voxels: the CT's physical values.
    let sample = Sample::open(demo());
    let raw = sample.image_i16("CT_tp0", 64 * 64 * 64);
    let values = read.f64s("data");
    assert!(values.iter().zip(&raw).all(|(v, r)| (*v - (f64::from(*r) - 1024.0)).abs() < 1e-3));
    // The geometry: the grid's affine, in LPS.
    let s = sample.summary();
    let grid = s["grids"].as_array().unwrap().iter().find(|g| g["id"] == "ct_tp0").unwrap();
    for key in ["spacing", "origin"] {
        let a: Vec<f64> = h["grid"][key].as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).collect();
        let b: Vec<f64> = grid[key].as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).collect();
        assert!(a.iter().zip(&b).all(|(x, y)| (x - y).abs() < 1e-4), "{key}: {a:?} {b:?}");
    }
    assert_eq!(h["grid"]["direction"], grid["direction"]);

    // Import it, then add one class of the follow-up organs as a mask.
    let imported = dir.path("imported.medh5");
    let mut out = std::ptr::null_mut();
    ok(m5_nifti_import(
        cp(&imported).as_ptr(),
        c(&json!({"images": {"CT": ct.to_str().unwrap()}, "modality": "CT", "sample_id": "imported"}).to_string())
            .as_ptr(),
        &mut out,
    ));
    assert!(take_json(out)["notes"].is_array());
    let back = Sample::open(&imported);
    let mut f = vec![0f32; 64 * 64 * 64];
    ok(m5_image_read(
        back.0,
        c("CT").as_ptr(),
        0,
        std::ptr::null(),
        std::ptr::null(),
        0,
        true,
        11,
        f.as_mut_ptr() as *mut c_void,
        f.len() * 4,
        None,
        std::ptr::null_mut(),
    ));
    assert!(f.iter().zip(&raw).all(|(v, r)| (f64::from(*v) - (f64::from(*r) - 1024.0)).abs() < 1e-3));
    drop(back);

    let liver = dir.path("liver.nii.gz");
    let mut out = std::ptr::null_mut();
    // The follow-up's liver: the CT's grid is the follow-up's too in shape,
    // and the import takes the voxels where the geometries agree.
    ok(m5_nifti_export(
        cp(demo()).as_ptr(),
        c(&json!({"object": "annotations/organs_tp1", "class": 2, "out": liver.to_str().unwrap()}).to_string())
            .as_ptr(),
        &mut out,
    ));
    m5_string_free(out);
    // A one-class mask of a class never examined, or of an annotation that
    // ignores voxels, would read its 0 as "examined, absent": refused.
    for class in [7, 2] {
        let mut out = std::ptr::null_mut();
        let status = m5_nifti_export(cp(demo()).as_ptr(),
            c(&json!({"object": "annotations/organs_tp0", "class": class, "out": dir.path("x.nii.gz").to_str().unwrap()}).to_string()).as_ptr(), &mut out);
        let error = fails(status, M5_ERR);
        let message = error["message"].as_str().unwrap();
        assert!(message.contains("examined") || message.contains("ignore"), "{error}");
    }
    let mut out = std::ptr::null_mut();
    ok(m5_nifti_import_segmentation(
        cp(&imported).as_ptr(),
        c(&json!({"masks": {"liver": liver.to_str().unwrap()}, "annotation_id": "liver_seg", "assume_aligned": true})
            .to_string())
        .as_ptr(),
        &mut out,
    ));
    m5_string_free(out);
    let back = Sample::open(&imported);
    let s = back.summary();
    let seg = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "liver_seg").unwrap();
    assert_eq!(seg["class_ids"].as_array().unwrap().len(), 1);
    let plan = back.plan("liver_seg");
    let layer = back.layer("liver_seg", 0, 64 * 64 * 64);
    let organs = sample.layer("organs_tp1", 0, 64 * 64 * 64);
    let class = plan["layers"][0][0].as_u64().unwrap() as u16;
    assert!(layer.iter().zip(&organs).all(|(a, b)| (*a == class) == (*b == 2)));
    let mut bundle = std::ptr::null_mut();
    fails(m5_nifti_read(cp(&dir.path("none.nii")).as_ptr(), &mut bundle), M5_ERR);
}

#[test]
fn recompression_keeps_every_digest() {
    let dir = TempDir::new("recompress");
    let path = demo_copy(&dir, "demo.medh5");
    let out_path = dir.path("portable.medh5");
    let mut out = std::ptr::null_mut();
    ok(m5_recompress(
        cp(&path).as_ptr(),
        c(&json!({"profile": "portable", "out": out_path.to_str().unwrap()}).to_string()).as_ptr(),
        &mut out,
    ));
    let result = take_json(out);
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["content_id_preserved"], true);
    let a = Sample::open(&path).summary();
    let b = Sample::open(&out_path).summary();
    assert_eq!(a["content_id"], b["content_id"]);
    let codec = b["images"][0]["codec"].as_str().unwrap().to_string();
    assert_ne!(codec, a["images"][0]["codec"].as_str().unwrap());
}

#[test]
fn collections_pack_list_and_open_a_member() {
    let dir = TempDir::new("collection");
    let a = demo_copy(&dir, "a.medh5");
    let b = dir.path("b.medh5");
    ok(m5_demo_write(cp(&b).as_ptr(), c(r#"{"size": 16, "clinical": false}"#).as_ptr()));
    let shard = dir.path("shard.medh5c");
    let mut out = std::ptr::null_mut();
    ok(m5_collection_pack(
        cp(&shard).as_ptr(),
        c(&json!({"sources": [a.to_str().unwrap(), b.to_str().unwrap()], "keys": ["first", "second"]}).to_string())
            .as_ptr(),
        &mut out,
    ));
    assert_eq!(take_json(out)["members"], json!(["first", "second"]));
    let mut out = std::ptr::null_mut();
    ok(m5_collection_list(cp(&shard).as_ptr(), &mut out));
    let listed = take_json(out);
    let members = listed["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    assert_eq!(members[0]["name"], "first");
    let mut member = std::ptr::null_mut();
    ok(m5_sample_open_member(cp(&shard).as_ptr(), c("second").as_ptr(), &mut member));
    let second = Sample(member);
    let s = second.summary();
    assert_eq!(s["grids"][0]["shape"], json!([16, 16, 16]));
    let layer = second.layer("organs_tp1", 0, 16 * 16 * 16);
    assert!(layer.contains(&2));
    let mut out = std::ptr::null_mut();
    ok(m5_sample_document(second.0, &mut out));
    m5_string_free(out);
    let mut member = std::ptr::null_mut();
    let error = fails(m5_sample_open_member(cp(&shard).as_ptr(), c("third").as_ptr(), &mut member), M5_ERR);
    assert_eq!(error["kind"], "key");
    // A sample is not a collection.
    let mut out = std::ptr::null_mut();
    fails(m5_collection_list(cp(&a).as_ptr(), &mut out), M5_ERR);
}

#[test]
fn the_demo_is_deterministic() {
    let dir = TempDir::new("determinism");
    let (a, b) = (dir.path("a.medh5"), dir.path("b.medh5"));
    for p in [&a, &b] {
        ok(m5_demo_write(cp(p).as_ptr(), c(r#"{"size": 20}"#).as_ptr()));
    }
    assert_eq!(Sample::open(&a).summary()["content_id"], Sample::open(&b).summary()["content_id"]);
    assert_eq!(validate(&a, "strict")["ok"], true);
}

/// Removing an image, its grid and a transform, and writing a segmentation
/// with the plain call, in one amendment: what is removed is gone, what is
/// added reads back, and a removal of what is not there is refused.
#[test]
fn removing_images_grids_and_transforms_and_the_plain_segmentation_call() {
    let dir = TempDir::new("remove");
    let path = demo_copy(&dir, "demo.medh5");
    {
        // A clinical event attests the MR: what an event version attests is
        // immutable (1.1 §7.3), so the commit refuses its removal.
        let w = Writer::amend(&path, None, "");
        ok(m5_writer_remove_annotation(w.0, c("mr_fov").as_ptr()));
        ok(m5_writer_remove_image(w.0, c("MR_tp0").as_ptr()));
        let mut id = std::ptr::null_mut();
        let error = fails(m5_writer_commit(w.0, true, &mut id), M5_ERR);
        assert_eq!(error["code"], "E809", "{error}");
    }
    {
        // Without the clinical history, they can go.
        let w = Writer::amend(&path, None, r#"{"without": ["clinical"]}"#);
        // The MR, its grid and the mask on it go together.
        ok(m5_writer_remove_annotation(w.0, c("mr_fov").as_ptr()));
        ok(m5_writer_remove_image(w.0, c("MR_tp0").as_ptr()));
        ok(m5_writer_remove_grid(w.0, c("mr_tp0").as_ptr()));
        ok(m5_writer_remove_transform(w.0, c("tp0_to_tp1").as_ptr()));
        fails(m5_writer_remove_image(w.0, c("MR_tp0").as_ptr()), M5_ERR);
        fails(m5_writer_remove_grid(w.0, c("nope").as_ptr()), M5_ERR);
        fails(m5_writer_remove_transform(w.0, c("nope").as_ptr()), M5_ERR);
        // The registration again, as an identity-free affine of another id.
        let matrix: Vec<f64> = medh5_bridge::demo::motion_matrix().iter().flatten().copied().collect();
        ok(m5_writer_add_affine_transform(
            w.0,
            c("registration").as_ptr(),
            c(r#"{"from_frame": "demo:frame-tp0", "to_frame": "demo:frame-tp1"}"#).as_ptr(),
            matrix.as_ptr(),
            4,
        ));
        // A one-layer segmentation through the plain call.
        let n = 64 * 64 * 64;
        let mut layer = vec![0u16; n];
        layer[1000..1100].fill(3);
        let pointers = [layer.as_ptr()];
        ok(m5_writer_add_segmentation(
            w.0,
            c("spleen_patch").as_ptr(),
            c("ct_tp0").as_ptr(),
            c(r#"{"annotated_classes": [3, 6]}"#).as_ptr(),
            1,
            pointers.as_ptr(),
            n,
        ));
        fails(
            m5_writer_add_segmentation(
                w.0,
                c("x").as_ptr(),
                c("ct_tp0").as_ptr(),
                std::ptr::null(),
                1,
                pointers.as_ptr(),
                n - 1,
            ),
            M5_ERR_ARGUMENT,
        );
        fails(
            m5_writer_add_segmentation(
                w.0,
                c("x").as_ptr(),
                c("ct_tp0").as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
            ),
            M5_ERR_ARGUMENT,
        );
        w.commit();
    }
    let sample = Sample::open(&path);
    let s = sample.summary();
    assert!(s["images"].as_array().unwrap().iter().all(|i| i["id"] != "MR_tp0"));
    assert!(s["grids"].as_array().unwrap().iter().all(|g| g["id"] != "mr_tp0"));
    assert_eq!(s["transforms"][0]["id"], "registration");
    let patch = s["annotations"].as_array().unwrap().iter().find(|a| a["id"] == "spleen_patch").unwrap();
    // Examined and absent (6) stays apart from what was found (3).
    assert_eq!(patch["class_ids"], json!([3, 6]));
    assert_eq!(patch["annotated_class_ids"], json!([3, 6]));
    let layer = sample.layer("spleen_patch", 0, 64 * 64 * 64);
    assert!(layer[1000..1100].iter().all(|v| *v == 3));
    assert_eq!(layer.iter().filter(|v| **v != 0).count(), 100);
    assert_eq!(validate(&path, "integrity")["ok"], true);
}
