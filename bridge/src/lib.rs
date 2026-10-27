//! medh5-bridge: the C interface between the medh5 format engine (the
//! `medh5` crate) and the medh5 Viewer.
//!
//! `include/medh5_bridge.h` is the contract and `docs/BRIDGE.md` its
//! reference.  Every exported function catches panics, checks its arguments,
//! and reports failures through a status and the thread-local
//! `m5_last_error()`; handles are thread-safe.

// The crate is a C ABI: its exported functions take raw pointers from C
// (which has no `unsafe`), check every one for NULL and size, and document
// the rest in the header; the helpers they share do the same.
#![allow(clippy::missing_safety_doc, clippy::not_unsafe_ptr_arg_deref, clippy::too_many_arguments)]

pub mod arrays;
pub mod bundle;
pub mod clinical;
pub mod conformance;
pub mod convert;
pub mod demo;
pub mod ffi;
pub mod geometry;
pub mod image;
pub mod library;
pub mod sample;
pub mod summary;
pub mod transform;
pub mod voxel;
pub mod writer;

pub use arrays::{M5DType, M5_DTYPE_NATIVE};
pub use bundle::*;
pub use clinical::*;
pub use conformance::m5_conformance_write;
pub use convert::{
    m5_collection_list, m5_collection_pack, m5_nifti_export, m5_nifti_import, m5_nifti_import_segmentation,
    m5_nifti_read, m5_recompress, m5_validate_file,
};
pub use demo::m5_demo_write;
pub use ffi::{
    M5ProgressFn, M5Status, M5_ERR, M5_ERR_ARGUMENT, M5_ERR_CANCELLED, M5_ERR_NOT_FOUND, M5_ERR_PANIC, M5_OK,
};
pub use geometry::m5_annotation_geometry;
pub use image::m5_image_read;
pub use library::*;
pub use sample::{
    m5_sample_attributes, m5_sample_close, m5_sample_document, m5_sample_open, m5_sample_open_member,
    m5_sample_summary, m5_sample_verify, M5Sample,
};
pub use transform::{m5_transform_read, m5_transform_resolve};
pub use voxel::{
    m5_annotation_class_stats, m5_annotation_instances, m5_annotation_layer_plan, m5_annotation_read_instance_map,
    m5_annotation_read_layer, m5_annotation_read_mask, m5_annotation_read_probability,
};
pub use writer::*;
