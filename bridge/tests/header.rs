//! The header and the library agree: every function the header declares is
//! exported, and every exported function is declared.

use std::collections::BTreeSet;

use medh5_bridge::*;

/// Every exported function, by name (a missing one does not compile).
fn exported() -> BTreeSet<&'static str> {
    let functions: &[(&str, usize)] = &[
        ("m5_last_error", m5_last_error as *const () as usize),
        ("m5_string_free", m5_string_free as *const () as usize),
        ("m5_engine_version", m5_engine_version as *const () as usize),
        ("m5_format_version", m5_format_version as *const () as usize),
        ("m5_bridge_version", m5_bridge_version as *const () as usize),
        ("m5_set_threads", m5_set_threads as *const () as usize),
        ("m5_threads", m5_threads as *const () as usize),
        ("m5_code_table", m5_code_table as *const () as usize),
        ("m5_validation_levels", m5_validation_levels as *const () as usize),
        ("m5_bundle_header", m5_bundle_header as *const () as usize),
        ("m5_bundle_array_count", m5_bundle_array_count as *const () as usize),
        ("m5_bundle_array_at", m5_bundle_array_at as *const () as usize),
        ("m5_bundle_array_named", m5_bundle_array_named as *const () as usize),
        ("m5_bundle_free", m5_bundle_free as *const () as usize),
        ("m5_sample_open", m5_sample_open as *const () as usize),
        ("m5_sample_open_member", m5_sample_open_member as *const () as usize),
        ("m5_sample_close", m5_sample_close as *const () as usize),
        ("m5_sample_summary", m5_sample_summary as *const () as usize),
        ("m5_sample_document", m5_sample_document as *const () as usize),
        ("m5_sample_verify", m5_sample_verify as *const () as usize),
        ("m5_sample_attributes", m5_sample_attributes as *const () as usize),
        ("m5_image_read", m5_image_read as *const () as usize),
        ("m5_annotation_layer_plan", m5_annotation_layer_plan as *const () as usize),
        ("m5_annotation_read_layer", m5_annotation_read_layer as *const () as usize),
        ("m5_annotation_read_mask", m5_annotation_read_mask as *const () as usize),
        ("m5_annotation_read_probability", m5_annotation_read_probability as *const () as usize),
        ("m5_annotation_instances", m5_annotation_instances as *const () as usize),
        ("m5_annotation_read_instance_map", m5_annotation_read_instance_map as *const () as usize),
        ("m5_annotation_class_stats", m5_annotation_class_stats as *const () as usize),
        ("m5_annotation_geometry", m5_annotation_geometry as *const () as usize),
        ("m5_transform_read", m5_transform_read as *const () as usize),
        ("m5_transform_resolve", m5_transform_resolve as *const () as usize),
        ("m5_clinical_records", m5_clinical_records as *const () as usize),
        ("m5_clinical_document_text", m5_clinical_document_text as *const () as usize),
        ("m5_clinical_select", m5_clinical_select as *const () as usize),
        ("m5_validate_file", m5_validate_file as *const () as usize),
        ("m5_writer_create", m5_writer_create as *const () as usize),
        ("m5_writer_amend", m5_writer_amend as *const () as usize),
        ("m5_writer_commit", m5_writer_commit as *const () as usize),
        ("m5_writer_abort", m5_writer_abort as *const () as usize),
        ("m5_writer_free", m5_writer_free as *const () as usize),
        ("m5_writer_document", m5_writer_document as *const () as usize),
        ("m5_writer_set_document", m5_writer_set_document as *const () as usize),
        ("m5_writer_set_identity", m5_writer_set_identity as *const () as usize),
        ("m5_writer_set_cohort", m5_writer_set_cohort as *const () as usize),
        ("m5_writer_add_timepoint", m5_writer_add_timepoint as *const () as usize),
        ("m5_writer_set_label_set", m5_writer_set_label_set as *const () as usize),
        ("m5_writer_set_quality", m5_writer_set_quality as *const () as usize),
        ("m5_writer_add_agent", m5_writer_add_agent as *const () as usize),
        ("m5_writer_add_activity", m5_writer_add_activity as *const () as usize),
        ("m5_writer_set_extra", m5_writer_set_extra as *const () as usize),
        ("m5_writer_set_acquisition", m5_writer_set_acquisition as *const () as usize),
        ("m5_writer_set_deidentification", m5_writer_set_deidentification as *const () as usize),
        ("m5_writer_add_grid", m5_writer_add_grid as *const () as usize),
        ("m5_writer_remove_grid", m5_writer_remove_grid as *const () as usize),
        ("m5_writer_add_image", m5_writer_add_image as *const () as usize),
        ("m5_writer_remove_image", m5_writer_remove_image as *const () as usize),
        ("m5_writer_set_image_attrs", m5_writer_set_image_attrs as *const () as usize),
        ("m5_writer_add_segmentation", m5_writer_add_segmentation as *const () as usize),
        ("m5_writer_add_segmentation_ex", m5_writer_add_segmentation_ex as *const () as usize),
        ("m5_writer_add_mask", m5_writer_add_mask as *const () as usize),
        ("m5_writer_remove_annotation", m5_writer_remove_annotation as *const () as usize),
        ("m5_writer_transcode_annotation", m5_writer_transcode_annotation as *const () as usize),
        ("m5_writer_add_geometric", m5_writer_add_geometric as *const () as usize),
        ("m5_writer_add_classification", m5_writer_add_classification as *const () as usize),
        ("m5_writer_add_affine_transform", m5_writer_add_affine_transform as *const () as usize),
        ("m5_writer_add_transform", m5_writer_add_transform as *const () as usize),
        ("m5_writer_remove_transform", m5_writer_remove_transform as *const () as usize),
        ("m5_writer_build_index", m5_writer_build_index as *const () as usize),
        ("m5_nifti_read", m5_nifti_read as *const () as usize),
        ("m5_nifti_import", m5_nifti_import as *const () as usize),
        ("m5_nifti_import_segmentation", m5_nifti_import_segmentation as *const () as usize),
        ("m5_nifti_export", m5_nifti_export as *const () as usize),
        ("m5_recompress", m5_recompress as *const () as usize),
        ("m5_collection_list", m5_collection_list as *const () as usize),
        ("m5_collection_pack", m5_collection_pack as *const () as usize),
        ("m5_demo_write", m5_demo_write as *const () as usize),
        ("m5_conformance_write", m5_conformance_write as *const () as usize),
    ];
    assert!(functions.iter().all(|(_, address)| *address != 0));
    functions.iter().map(|(name, _)| *name).collect()
}

/// Every function the header declares: `m5_name(` outside comments.
fn declared() -> BTreeSet<String> {
    let header = include_str!("../include/medh5_bridge.h");
    let mut out = BTreeSet::new();
    let mut in_comment = false;
    for line in header.lines() {
        let mut text = line.trim();
        if in_comment {
            match text.find("*/") {
                Some(end) => {
                    in_comment = false;
                    text = &text[end + 2..];
                }
                None => continue,
            }
        }
        if let Some(start) = text.find("/*") {
            if !text[start..].contains("*/") {
                in_comment = true;
            }
            text = &text[..start];
        }
        let mut rest = text;
        while let Some(at) = rest.find("m5_") {
            let tail = &rest[at..];
            let end = tail.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).unwrap_or(tail.len());
            if tail[end..].starts_with('(') {
                out.insert(tail[..end].to_string());
            }
            rest = &tail[end..];
        }
    }
    out
}

#[test]
fn the_header_declares_exactly_what_the_library_exports() {
    let exported: BTreeSet<String> = exported().into_iter().map(str::to_string).collect();
    let declared = declared();
    assert_eq!(
        declared,
        exported,
        "declared but not exported: {:?}; exported but not declared: {:?}",
        declared.difference(&exported).collect::<Vec<_>>(),
        exported.difference(&declared).collect::<Vec<_>>()
    );
}

#[test]
fn the_dtype_codes_are_scalar_types() {
    let header = include_str!("../include/medh5_bridge.h");
    for (name, code) in [("BOOL", 1), ("UINT8", 2), ("INT16", 5), ("FLOAT16", 10), ("FLOAT64", 12)] {
        assert!(header.contains(&format!("#define M5_DTYPE_{name} {code}")), "{name}");
    }
    for dtype in medh5::array::DType::ALL {
        let code = medh5_bridge::arrays::code_of(dtype);
        assert_eq!(medh5_bridge::arrays::dtype_of(code).unwrap(), Some(dtype));
    }
}
