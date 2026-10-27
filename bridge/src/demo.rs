//! `m5_demo_write`: a synthetic, deterministic and genuinely rich sample.
//!
//! One subject, two visits.  A CT phantom (an elliptical trunk with a fat
//! layer, liver, spleen, kidneys, aorta and spine, and a liver lesion that
//! grows from 18 mm to 27 mm between the visits) is scanned at baseline and
//! at follow-up, each on its own grid in its own frame of reference; the
//! subject moved in between, by the rigid motion the stored affine
//! `tp0_to_tp1` describes (`x_tp1 = R x_tp0 + t`).  An MR on an oblique grid of
//! its own shares the baseline frame.  Around them: a label set with colours,
//! ontology codes, a hierarchy and a skeleton; segmentations as `layers`
//! (a lesion overlapping its organ, an ignore region in band, a class that
//! can be expressed but was not examined), `labelmap`, `probmap`,
//! `instances` and a `mask`; boxes, oriented boxes, keypoints, corresponding
//! point sets, contours with a hole, polylines (format 1.2), meshes, a
//! classification change label; provenance, quality, a sampling index and a
//! clinical history (format 1.1).
//!
//! Everything is computed from fixed numbers: two runs write the same content
//! (and the same `content_id`).

use std::collections::HashMap;
use std::f64::consts::PI;
use std::ffi::c_char;
use std::path::Path;

use medh5::annotations::InstanceInput;
use medh5::array::NdArray;
use medh5::clinical::{
    Bounds, ClinicalRecords, Clock, Descriptor, Document, Event, Link, ASSESSMENT_SYSTEM, DAY, HOUR, LESION_PRESENCE,
};
use medh5::labels::{ClassKey, LabelSet};
use medh5::ndarray::{Array2, ArrayD, IxDyn};
use medh5::sample::{
    Annotated, AnnotationOptions, GridOptions, ImageOptions, QualityArg, SampleWriter, SegmentationOptions,
    SegmentationSource,
};
use serde_json::{json, Map, Value};

use crate::ffi::{self, guard, BResult, BridgeError, M5Status};

pub const FRAME0: &str = "demo:frame-tp0";
pub const FRAME1: &str = "demo:frame-tp1";
/// The follow-up motion: a rotation about world z and a translation (mm).
pub const MOTION_DEGREES: f64 = 6.0;
pub const MOTION_SHIFT: [f64; 3] = [12.0, -8.0, 15.0];
/// The lesion: centre (baseline world, mm) and radius at each visit.
pub const LESION_CENTRE: [f64; 3] = [-70.0, -10.0, 55.0];
pub const LESION_RADIUS: [f64; 2] = [18.0, 27.0];
/// A satellite lesion at baseline only.
pub const SATELLITE_CENTRE: [f64; 3] = [-35.0, 25.0, 30.0];
pub const SATELLITE_RADIUS: f64 = 9.0;

/// Options of `m5_demo_write`.
#[derive(Debug, Clone)]
pub struct DemoOptions {
    pub size: usize,
    pub clinical: bool,
    pub polylines: bool,
    pub index: bool,
    pub codec: String,
}

impl Default for DemoOptions {
    fn default() -> Self {
        DemoOptions { size: 64, clinical: true, polylines: true, index: true, codec: "balanced".into() }
    }
}

type V3 = [f64; 3];

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn scale(a: V3, s: f64) -> V3 {
    [a[0] * s, a[1] * s, a[2] * s]
}

fn norm(a: V3) -> f64 {
    (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt()
}

/// `m · v` for a row-major 3×3 matrix.
fn mul(m: &[[f64; 3]; 3], v: V3) -> V3 {
    [
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ]
}

fn transpose(m: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let mut out = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            out[r][c] = m[c][r];
        }
    }
    out
}

fn matmul(a: &[[f64; 3]; 3], b: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let mut out = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            out[r][c] = (0..3).map(|k| a[r][k] * b[k][c]).sum();
        }
    }
    out
}

fn rot_z(degrees: f64) -> [[f64; 3]; 3] {
    let (s, c) = (degrees * PI / 180.0).sin_cos();
    [[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]
}

fn rot_x(degrees: f64) -> [[f64; 3]; 3] {
    let (s, c) = (degrees * PI / 180.0).sin_cos();
    [[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]]
}

/// The axial stack's direction (LPS): axis 0 runs superior, axis 1
/// posterior, axis 2 to the patient's left.
const AXIAL: [[f64; 3]; 3] = [[0.0, 0.0, 1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]];

/// The baseline-to-follow-up motion `x_tp1 = R x_tp0 + t`.
pub fn motion() -> ([[f64; 3]; 3], V3) {
    (rot_z(MOTION_DEGREES), MOTION_SHIFT)
}

/// The motion as the 4×4 row-major matrix the transform stores.
pub fn motion_matrix() -> [[f64; 4]; 4] {
    let (r, t) = motion();
    let mut m = [[0.0; 4]; 4];
    for i in 0..3 {
        for j in 0..3 {
            m[i][j] = r[i][j];
        }
        m[i][3] = t[i];
    }
    m[3][3] = 1.0;
    m
}

pub fn to_follow_up(x: V3) -> V3 {
    let (r, t) = motion();
    add(mul(&r, x), t)
}

fn to_baseline(x1: V3) -> V3 {
    let (r, t) = motion();
    mul(&transpose(&r), sub(x1, t))
}

/// One grid of the demo: `x = origin + direction · (spacing ⊙ k)`.
#[derive(Debug, Clone)]
struct Geometry {
    shape: [usize; 3],
    spacing: [f64; 3],
    direction: [[f64; 3]; 3],
    origin: V3,
}

impl Geometry {
    /// A grid centred on `centre`.
    fn centred(shape: [usize; 3], spacing: [f64; 3], direction: [[f64; 3]; 3], centre: V3) -> Geometry {
        let half: V3 = [0, 1, 2].map(|a| (shape[a] as f64 - 1.0) / 2.0 * spacing[a]);
        let origin = sub(centre, mul(&direction, half));
        Geometry { shape, spacing, direction, origin }
    }

    fn world(&self, k: V3) -> V3 {
        add(self.origin, mul(&self.direction, [k[0] * self.spacing[0], k[1] * self.spacing[1], k[2] * self.spacing[2]]))
    }

    fn index(&self, x: V3) -> V3 {
        let local = mul(&transpose(&self.direction), sub(x, self.origin));
        [local[0] / self.spacing[0], local[1] / self.spacing[1], local[2] / self.spacing[2]]
    }

    fn voxels(&self) -> usize {
        self.shape.iter().product()
    }

    fn options(&self, timepoint: &str, frame: &str) -> (Vec<i64>, Vec<f64>, GridOptions) {
        let direction = Array2::from_shape_fn((3, 3), |(r, c)| self.direction[r][c]);
        (
            self.shape.iter().map(|v| *v as i64).collect(),
            self.spacing.to_vec(),
            GridOptions {
                origin: Some(self.origin.to_vec()),
                direction: Some(direction),
                coord_system: Some("LPS".into()),
                units: Some("mm".into()),
                timepoint: Some(timepoint.into()),
                frame_uid: Some(frame.into()),
                ..Default::default()
            },
        )
    }

    /// Every voxel's value, C order, from its world coordinate.
    fn fill<T>(&self, f: impl Fn(usize, V3) -> T) -> Vec<T> {
        let mut out = Vec::with_capacity(self.voxels());
        let mut linear = 0;
        for k0 in 0..self.shape[0] {
            for k1 in 0..self.shape[1] {
                for k2 in 0..self.shape[2] {
                    out.push(f(linear, self.world([k0 as f64, k1 as f64, k2 as f64])));
                    linear += 1;
                }
            }
        }
        out
    }
}

/// `((x - c) / r)²` summed: below 1 inside the ellipsoid.
fn ellipsoid(x: V3, c: V3, r: V3) -> f64 {
    (0..3).map(|a| ((x[a] - c[a]) / r[a]).powi(2)).sum()
}

fn in_cylinder(x: V3, cx: f64, cy: f64, radius: f64, z: (f64, f64)) -> bool {
    (x[0] - cx).powi(2) + (x[1] - cy).powi(2) <= radius * radius && x[2] >= z.0 && x[2] <= z.1
}

/// The phantom's anatomy, in baseline world coordinates (mm, LPS).
mod anatomy {
    pub const BODY: ([f64; 3], [f64; 3]) = ([0.0, 10.0, 0.0], [150.0, 110.0, 190.0]);
    pub const BODY_INNER: ([f64; 3], [f64; 3]) = ([0.0, 10.0, 0.0], [138.0, 98.0, 184.0]);
    pub const LIVER: ([f64; 3], [f64; 3]) = ([-60.0, 0.0, 60.0], [75.0, 65.0, 70.0]);
    pub const SPLEEN: ([f64; 3], [f64; 3]) = ([85.0, 35.0, 70.0], [35.0, 40.0, 50.0]);
    pub const RIGHT_KIDNEY: ([f64; 3], [f64; 3]) = ([-55.0, 55.0, -30.0], [25.0, 25.0, 50.0]);
    pub const LEFT_KIDNEY: ([f64; 3], [f64; 3]) = ([55.0, 55.0, -20.0], [25.0, 25.0, 50.0]);
    pub const AORTA: (f64, f64, f64, (f64, f64)) = (15.0, 35.0, 12.0, (-150.0, 170.0));
    pub const SPINE: (f64, f64, f64, f64, (f64, f64)) = (0.0, 75.0, 20.0, 7.0, (-195.0, 195.0));
}

/// What is at one point of the anatomy at a visit.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct Tissue {
    body: bool,
    fat: bool,
    liver: bool,
    spleen: bool,
    right_kidney: bool,
    left_kidney: bool,
    aorta: bool,
    bone: bool,
    canal: bool,
    lesion: bool,
    satellite: bool,
}

fn tissue(x: V3, visit: usize) -> Tissue {
    use anatomy::*;
    let mut t = Tissue { body: ellipsoid(x, BODY.0, BODY.1) <= 1.0, ..Default::default() };
    if !t.body {
        return t;
    }
    t.fat = ellipsoid(x, BODY_INNER.0, BODY_INNER.1) > 1.0;
    t.liver = ellipsoid(x, LIVER.0, LIVER.1) <= 1.0;
    t.spleen = ellipsoid(x, SPLEEN.0, SPLEEN.1) <= 1.0;
    t.right_kidney = ellipsoid(x, RIGHT_KIDNEY.0, RIGHT_KIDNEY.1) <= 1.0;
    t.left_kidney = ellipsoid(x, LEFT_KIDNEY.0, LEFT_KIDNEY.1) <= 1.0;
    t.aorta = in_cylinder(x, AORTA.0, AORTA.1, AORTA.2, AORTA.3);
    let spine = in_cylinder(x, SPINE.0, SPINE.1, SPINE.2, SPINE.4);
    t.canal = spine && in_cylinder(x, SPINE.0, SPINE.1, SPINE.3, SPINE.4);
    t.bone = spine && !t.canal;
    t.lesion = t.liver && norm(sub(x, LESION_CENTRE)) <= LESION_RADIUS[visit];
    t.satellite = visit == 0 && t.liver && norm(sub(x, SATELLITE_CENTRE)) <= SATELLITE_RADIUS;
    t
}

/// A deterministic value in `[-1, 1)` per voxel and stream.
fn noise(linear: usize, stream: u64) -> f64 {
    let mut z = (linear as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ stream.wrapping_mul(0xD1B5_4A32_D192_ED03);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    (z >> 11) as f64 / (1u64 << 52) as f64 - 1.0
}

/// CT attenuation (HU).
fn hounsfield(t: &Tissue, visit: usize) -> f64 {
    if !t.body {
        return -1000.0;
    }
    if t.bone {
        return 650.0;
    }
    if t.canal {
        return 15.0;
    }
    if t.aorta {
        return 230.0;
    }
    if t.right_kidney || t.left_kidney {
        return 155.0;
    }
    if t.spleen {
        return 48.0;
    }
    if t.lesion {
        return if visit == 0 { 18.0 } else { 22.0 };
    }
    if t.satellite {
        return 30.0;
    }
    if t.liver {
        return 62.0;
    }
    if t.fat {
        -90.0
    } else {
        35.0
    }
}

/// T1-like MR signal (arbitrary units).
fn mr_signal(t: &Tissue) -> f64 {
    if !t.body {
        return 2.0;
    }
    if t.bone {
        return 180.0;
    }
    if t.canal {
        return 60.0;
    }
    if t.aorta {
        return 90.0;
    }
    if t.right_kidney || t.left_kidney {
        return 410.0;
    }
    if t.spleen {
        return 360.0;
    }
    if t.lesion || t.satellite {
        return 210.0;
    }
    if t.liver {
        return 520.0;
    }
    if t.fat {
        820.0
    } else {
        300.0
    }
}

/// The class a voxel holds in a mutually exclusive organ map (lesion
/// separate): 0 for none.
fn organ_class(t: &Tissue) -> u16 {
    if t.bone || t.canal {
        8
    } else if t.aorta {
        7
    } else if t.right_kidney {
        6
    } else if t.left_kidney {
        5
    } else if t.spleen {
        3
    } else if t.liver {
        2
    } else {
        0
    }
}

fn logistic(v: f64) -> f64 {
    1.0 / (1.0 + (-v).exp())
}

/// The label set: colours, ontology codes, a hierarchy, a skeleton.
pub fn label_set() -> BResult<LabelSet> {
    let sct = |code: &str, name: &str| json!([{"system": "SCT", "code": code, "name": name}]);
    let value = json!({
        "id": "medh5-viewer-demo-abdomen",
        "version": "1.0.0",
        "classes": [
            {"id": 1, "key": "body", "name": "Body", "category": "region", "color": [255, 224, 189, 255],
             "codes": sct("38266002", "Entire body as a whole")},
            {"id": 2, "key": "liver", "name": "Liver", "category": "organ", "color": [221, 130, 101, 255],
             "codes": sct("10200004", "Liver structure"), "properties": {"window": [-150, 250]}},
            {"id": 3, "key": "spleen", "name": "Spleen", "category": "organ", "color": [157, 108, 162, 255],
             "codes": sct("78961009", "Splenic structure")},
            {"id": 4, "key": "kidney", "name": "Kidney", "category": "organ", "color": [185, 102, 83, 255],
             "codes": sct("64033007", "Kidney structure")},
            {"id": 5, "key": "left_kidney", "name": "Left kidney", "category": "organ", "parents": [4],
             "laterality": "left", "color": [212, 126, 98, 255], "codes": sct("18639004", "Left kidney structure")},
            {"id": 6, "key": "right_kidney", "name": "Right kidney", "category": "organ", "parents": [4],
             "laterality": "right", "color": [166, 84, 69, 255], "codes": sct("9846003", "Right kidney structure")},
            {"id": 7, "key": "aorta", "name": "Aorta", "category": "vessel", "color": [224, 97, 76, 255],
             "codes": sct("15825003", "Aortic structure")},
            {"id": 8, "key": "vertebral_column", "name": "Vertebral column", "category": "bone",
             "color": [241, 214, 145, 255], "codes": sct("421060004", "Spinal column structure")},
            {"id": 9, "key": "liver_lesion", "name": "Liver lesion", "category": "lesion", "parents": [2],
             "color": [255, 255, 0, 255], "codes": sct("52988006", "Lesion"),
             "properties": {"recist_target": true}},
            {"id": 10, "key": "progressive_disease", "name": "Progressive disease", "category": "finding",
             "color": [230, 25, 75, 255], "codes": [{"system": "RECIST", "code": "PD", "name": "Progressive disease"}]},
            {"id": 11, "key": "stable_disease", "name": "Stable disease", "category": "finding",
             "color": [60, 180, 75, 255], "codes": [{"system": "RECIST", "code": "SD", "name": "Stable disease"}]},
            {"id": 12, "key": "biopsy_needle", "name": "Biopsy needle", "category": "device",
             "color": [0, 200, 255, 255], "codes": sct("79068005", "Needle, device")},
        ],
        "skeletons": [{"id": "abdominal-landmarks", "keypoints": [2, 3, 7, 8], "edges": [[2, 7], [3, 7], [7, 8]]}],
    });
    LabelSet::from_json(Some(&value))?.ok_or_else(|| BridgeError::engine("runtime", "the demo label set is empty"))
}

fn fields(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

fn quality(status: &str, confidence: f64) -> Option<QualityArg> {
    Some(QualityArg::Record(fields(json!({"status": status, "confidence": confidence, "reviewed_by": ["rad2"]}))))
}

fn common(prov: &str, quality_status: &str, confidence: f64, annotated: Annotated) -> AnnotationOptions {
    AnnotationOptions {
        annotated_classes: annotated,
        prov: Some(prov.into()),
        quality: quality(quality_status, confidence),
        ..Default::default()
    }
}

fn ids(values: &[i64]) -> Annotated {
    Annotated::Classes(values.iter().map(|v| ClassKey::Id(*v)).collect())
}

/// The voxel box `[lo - 0.5, hi - 0.5]` per axis (§8.1) of a mask.
fn box_of(mask: &[bool], shape: [usize; 3]) -> Option<[[f64; 2]; 3]> {
    let mut lo = [usize::MAX; 3];
    let mut hi = [0usize; 3];
    let mut found = false;
    for (linear, hit) in mask.iter().enumerate() {
        if !*hit {
            continue;
        }
        found = true;
        let k = [linear / (shape[1] * shape[2]), (linear / shape[2]) % shape[1], linear % shape[2]];
        for a in 0..3 {
            lo[a] = lo[a].min(k[a]);
            hi[a] = hi[a].max(k[a] + 1);
        }
    }
    found.then(|| [0, 1, 2].map(|a| [lo[a] as f64 - 0.5, hi[a] as f64 - 0.5]))
}

/// An icosphere: `(vertices, faces)` on the unit sphere.
pub fn icosphere(subdivisions: usize) -> (Vec<V3>, Vec<[usize; 3]>) {
    let t = (1.0 + 5f64.sqrt()) / 2.0;
    let mut vertices: Vec<V3> = [
        [-1.0, t, 0.0],
        [1.0, t, 0.0],
        [-1.0, -t, 0.0],
        [1.0, -t, 0.0],
        [0.0, -1.0, t],
        [0.0, 1.0, t],
        [0.0, -1.0, -t],
        [0.0, 1.0, -t],
        [t, 0.0, -1.0],
        [t, 0.0, 1.0],
        [-t, 0.0, -1.0],
        [-t, 0.0, 1.0],
    ]
    .iter()
    .map(|v| scale(*v, 1.0 / norm(*v)))
    .collect();
    let mut faces: Vec<[usize; 3]> = vec![
        [0, 11, 5],
        [0, 5, 1],
        [0, 1, 7],
        [0, 7, 10],
        [0, 10, 11],
        [1, 5, 9],
        [5, 11, 4],
        [11, 10, 2],
        [10, 7, 6],
        [7, 1, 8],
        [3, 9, 4],
        [3, 4, 2],
        [3, 2, 6],
        [3, 6, 8],
        [3, 8, 9],
        [4, 9, 5],
        [2, 4, 11],
        [6, 2, 10],
        [8, 6, 7],
        [9, 8, 1],
    ];
    for _ in 0..subdivisions {
        let mut midpoint: HashMap<(usize, usize), usize> = HashMap::new();
        let mut next = Vec::with_capacity(faces.len() * 4);
        for f in &faces {
            let mut mid = [0usize; 3];
            for (i, (a, b)) in [(f[0], f[1]), (f[1], f[2]), (f[2], f[0])].into_iter().enumerate() {
                let key = (a.min(b), a.max(b));
                mid[i] = *midpoint.entry(key).or_insert_with(|| {
                    let m = scale(add(vertices[a], vertices[b]), 0.5);
                    vertices.push(scale(m, 1.0 / norm(m)));
                    vertices.len() - 1
                });
            }
            next.push([f[0], mid[0], mid[2]]);
            next.push([f[1], mid[1], mid[0]]);
            next.push([f[2], mid[2], mid[1]]);
            next.push([mid[0], mid[1], mid[2]]);
        }
        faces = next;
    }
    (vertices, faces)
}

fn array2(rows: &[Vec<f64>]) -> BResult<NdArray> {
    let n = rows.len();
    let m = rows.first().map(Vec::len).unwrap_or(0);
    Ok(NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[n, m]), rows.iter().flatten().copied().collect())?))
}

fn column_i64(values: &[i64]) -> BResult<NdArray> {
    Ok(NdArray::I64(ArrayD::from_shape_vec(IxDyn(&[values.len()]), values.to_vec())?))
}

/// The polygon of an ellipse cross-section in index space, on axial slice
/// `k` of `grid`: `n` vertices, `(k, i1, i2)`.
fn ring(grid: &Geometry, k: usize, centre: [f64; 2], radii: [f64; 2], n: usize) -> Vec<Vec<f64>> {
    let z = grid.world([k as f64, 0.0, 0.0])[2];
    (0..n)
        .map(|i| {
            let phi = 2.0 * PI * i as f64 / n as f64;
            let x = [centre[0] + radii[0] * phi.cos(), centre[1] + radii[1] * phi.sin(), z];
            let index = grid.index(x);
            vec![k as f64, index[1], index[2]]
        })
        .collect()
}

/// The cross-section of an ellipsoid at world `z`: centre and radii in x, y.
fn section(c: V3, r: V3, z: f64) -> Option<([f64; 2], [f64; 2])> {
    let f = 1.0 - ((z - c[2]) / r[2]).powi(2);
    (f > 0.05).then(|| ([c[0], c[1]], [r[0] * f.sqrt(), r[1] * f.sqrt()]))
}

/// Write the demo sample.
pub fn write_demo(path: &Path, options: &DemoOptions) -> BResult<()> {
    let n = options.size;
    if !(16..=512).contains(&n) {
        return Err(BridgeError::argument(format!("size {n}: the demo is 16 to 512 voxels per axis")));
    }
    let ct_spacing = [400.0 / n as f64, 320.0 / n as f64, 320.0 / n as f64];
    let ct0 = Geometry::centred([n, n, n], ct_spacing, AXIAL, [0.0, 0.0, 0.0]);
    let ct1 = Geometry::centred([n, n, n], ct_spacing, AXIAL, [0.0, 0.0, 10.0]);
    let mr_shape = [n / 2, n * 7 / 8, n * 7 / 8];
    let mr_spacing = [300.0 / mr_shape[0] as f64, 280.0 / mr_shape[1] as f64, 280.0 / mr_shape[2] as f64];
    let mr = Geometry::centred(mr_shape, mr_spacing, matmul(&rot_x(8.0), &AXIAL), [0.0, 0.0, 20.0]);

    let mut w = medh5::sample::create(path, Some("demo-abdomen-01"), Some("DEMO-SUBJ-01"), &options.codec, &[])?;
    let result = (|| -> BResult<()> {
        build(&mut w, &ct0, &ct1, &mr, options)?;
        w.commit(true)?;
        Ok(())
    })();
    if result.is_err() {
        w.abort();
    }
    result
}

fn build(w: &mut SampleWriter, ct0: &Geometry, ct1: &Geometry, mr: &Geometry, options: &DemoOptions) -> BResult<()> {
    // -- the document -----------------------------------------------------------------
    w.identity(fields(json!({"sex": "F", "bodypart": "ABDOMEN"})))?;
    w.cohort(fields(json!({
        "dataset_id": "medh5-viewer-demo",
        "site_id": "synthetic-site",
        "scanner_id": "phantom-ct",
        "acquisition_protocol": "abdomen-portal-venous",
    })))?;
    w.add_timepoint(
        "tp0",
        fields(json!({"label": "baseline", "days_from_baseline": 0, "description": "Baseline staging CT and MR"})),
    )?;
    w.add_timepoint(
        "tp1",
        fields(json!({"label": "follow-up", "days_from_baseline": 92, "description": "Follow-up CT after 3 months"})),
    )?;
    w.label_set(label_set()?);
    w.software("medh5-viewer-demo", Some(env!("CARGO_PKG_VERSION")), Map::new())?;
    w.software("phantom-segmenter", Some("0.1.0"), Map::new())?;
    w.person("pseudonym:RAD-01", Some("rad1"), fields(json!({"role": "annotator"})))?;
    w.person("pseudonym:RAD-02", Some("rad2"), fields(json!({"role": "reviewer"})))?;
    w.activity(
        "import",
        Some("s1"),
        Some("act_import"),
        fields(json!({"tool": "medh5-bridge demo phantom", "outputs": ["images/CT_tp0", "images/CT_tp1", "images/MR_tp0"]})),
    )?;
    w.activity(
        "annotate",
        Some("rad1"),
        Some("act_annotate"),
        fields(json!({"inputs": ["images/CT_tp0", "images/CT_tp1"]})),
    )?;
    w.activity("review", Some("rad2"), Some("act_review"), Map::new())?;
    w.activity("predict", Some("s2"), Some("act_predict"), fields(json!({"inputs": ["images/CT_tp1"]})))?;
    w.activity(
        "register",
        Some("s1"),
        Some("act_register"),
        fields(json!({"params": {"method": "rigid", "metric": "known motion"}})),
    )?;
    if options.clinical {
        w.activity("import", Some("s1"), Some("act_clinical_import"), Map::new())?;
    }
    w.deidentification(fields(json!({"method": "synthetic"})))?;

    // -- grids and images -------------------------------------------------------------
    for (id, grid, tp, frame) in
        [("ct_tp0", ct0, "tp0", FRAME0), ("ct_tp1", ct1, "tp1", FRAME1), ("mr_tp0", mr, "tp0", FRAME0)]
    {
        let (shape, spacing, opts) = grid.options(tp, frame);
        w.add_grid(id, &shape, &spacing, opts)?;
    }
    let shape = |g: &Geometry| g.shape.to_vec();
    let ct_options = || ImageOptions {
        value_type: Some("quantitative".into()),
        value_units: Some("HU".into()),
        rescale_slope: Some(1.0),
        rescale_intercept: Some(-1024.0),
        window_center: Some(vec![50.0, 400.0]),
        window_width: Some(vec![400.0, 1800.0]),
        prov: Some("act_import".into()),
        ..Default::default()
    };
    let ct_tp0: Vec<i16> = ct0.fill(|i, x| (hounsfield(&tissue(x, 0), 0) + 8.0 * noise(i, 1) + 1024.0).round() as i16);
    w.add_image(
        "CT_tp0",
        &NdArray::I16(ArrayD::from_shape_vec(IxDyn(&shape(ct0)), ct_tp0)?),
        "ct_tp0",
        "CT",
        ct_options(),
    )?;
    let ct_tp1: Vec<i16> =
        ct1.fill(|i, x| (hounsfield(&tissue(to_baseline(x), 1), 1) + 8.0 * noise(i, 2) + 1024.0).round() as i16);
    w.add_image(
        "CT_tp1",
        &NdArray::I16(ArrayD::from_shape_vec(IxDyn(&shape(ct1)), ct_tp1)?),
        "ct_tp1",
        "CT",
        ct_options(),
    )?;

    // The MR's field of view: a cylinder about its own slice axis.
    let fov: Vec<bool> = {
        let (c1, c2) = ((mr.shape[1] as f64 - 1.0) / 2.0, (mr.shape[2] as f64 - 1.0) / 2.0);
        let radius = 0.47 * mr.shape[1].min(mr.shape[2]) as f64;
        (0..mr.voxels())
            .map(|linear| {
                let k1 = ((linear / mr.shape[2]) % mr.shape[1]) as f64;
                let k2 = (linear % mr.shape[2]) as f64;
                (k1 - c1).powi(2) + (k2 - c2).powi(2) <= radius * radius
            })
            .collect()
    };
    w.add_mask(
        "mr_fov",
        ArrayD::from_shape_vec(IxDyn(&shape(mr)), fov.clone())?,
        "mr_tp0",
        "other",
        Some("act_import"),
        None,
    )?;
    let mr_values: Vec<f32> =
        mr.fill(
            |i, x| {
                if fov[i] {
                    (mr_signal(&tissue(x, 0)) * (1.0 + 0.02 * noise(i, 3)) + 0.37) as f32
                } else {
                    0.0
                }
            },
        );
    w.add_image(
        "MR_tp0",
        &NdArray::F32(ArrayD::from_shape_vec(IxDyn(&shape(mr)), mr_values)?),
        "mr_tp0",
        "MR",
        ImageOptions {
            value_type: Some("intensity".into()),
            window_center: Some(vec![420.0]),
            window_width: Some(vec![900.0]),
            valid_mask: Some("mr_fov".into()),
            prov: Some("act_import".into()),
            ..Default::default()
        },
    )?;
    w.acquisition(
        "CT_tp0",
        fields(json!({"KVP": 120, "SliceThickness": ct0.spacing[0], "ContrastBolusAgent": "iodinated"})),
    );
    w.acquisition(
        "CT_tp1",
        fields(json!({"KVP": 120, "SliceThickness": ct1.spacing[0], "ContrastBolusAgent": "iodinated"})),
    );
    w.acquisition(
        "MR_tp0",
        fields(json!({"MagneticFieldStrength": 1.5, "SequenceName": "T1 VIBE", "RepetitionTime": 4.1})),
    );

    // -- voxel annotations ------------------------------------------------------------
    let t0: Vec<Tissue> = ct0.fill(|_, x| tissue(x, 0));
    let t1: Vec<Tissue> = ct1.fill(|_, x| tissue(to_baseline(x), 1));
    // The top slices were not reviewed: their unlabelled voxels are ignored.
    let top = ct0.shape[0] - (ct0.shape[0] / 16).max(2);
    let plane = ct0.shape[1] * ct0.shape[2];

    // Baseline organs as layers: the lesions (layer 1) lie inside the liver
    // (layer 0); the aorta can be expressed and was not examined, and the
    // top slices, which the annotator did not review, are an ignore region.
    let organs0: Vec<u16> = t0
        .iter()
        .enumerate()
        .map(|(i, t)| match organ_class(t) {
            7 => 0,
            0 if i / plane >= top => u16::MAX,
            c => c,
        })
        .collect();
    let lesions0: Vec<u16> = t0.iter().map(|t| if t.lesion || t.satellite { 9 } else { 0 }).collect();
    let layered = json!({
        "encoding": "layers",
        "class_ids": [2, 3, 5, 6, 7, 8, 9],
        "annotated_classes": [2, 3, 5, 6, 8, 9],
        "prov": "act_annotate",
        "quality": {"status": "reviewed", "confidence": 0.93, "reviewed_by": ["rad2"]},
        "timepoints": ["tp0"],
    });
    crate::writer::add_segmentation(
        w,
        "organs_tp0",
        "ct_tp0",
        layered.as_object().expect("an object"),
        &[&organs0, &lesions0],
    )?;

    // Follow-up organs as one mutually exclusive labelmap, fully covered.
    let organs1: Vec<u16> = t1.iter().map(|t| if t.lesion { 9 } else { organ_class(t) }).collect();
    let labelmap = json!({
        "encoding": "labelmap",
        "class_ids": [2, 3, 5, 6, 7, 8, 9],
        "annotated_classes": [2, 3, 5, 6, 7, 8, 9],
        "prov": "act_annotate",
        "derived_from": ["lesion_prob_tp1"],
        "quality": {"status": "approved", "confidence": 0.97, "reviewed_by": ["rad2"]},
    });
    crate::writer::add_segmentation(w, "organs_tp1", "ct_tp1", labelmap.as_object().expect("an object"), &[&organs1])?;

    // The model's soft lesion and liver at follow-up.
    let (lesion1, r1) = (to_follow_up(LESION_CENTRE), LESION_RADIUS[1]);
    let liver = anatomy::LIVER;
    let p_lesion: Vec<f64> = ct1.fill(|_, x| logistic((r1 - norm(sub(x, lesion1))) / 2.5));
    let p_liver: Vec<f64> = ct1.fill(|_, x| {
        let b = to_baseline(x);
        let rho = ellipsoid(b, liver.0, liver.1).sqrt();
        logistic((1.0 - rho) * 65.0 / 3.0)
    });
    let spatial = IxDyn(&ct1.shape);
    w.add_segmentation(
        "lesion_prob_tp1",
        "ct_tp1",
        SegmentationSource::Probabilities(vec![
            (ClassKey::Id(2), ArrayD::from_shape_vec(spatial.clone(), p_liver)?),
            (ClassKey::Id(9), ArrayD::from_shape_vec(spatial, p_lesion)?),
        ]),
        SegmentationOptions {
            threshold: Some(0.5),
            common: common("act_predict", "draft", 0.71, Annotated::AllGiven),
            ..Default::default()
        },
    )?;

    // The baseline lesions as objects: tracked by instance id.
    let main: Vec<bool> = t0.iter().map(|t| t.lesion).collect();
    let satellite: Vec<bool> = t0.iter().map(|t| t.satellite).collect();
    // At a coarse size a small lesion may hold no voxel centre: an object
    // is written only where it has voxels.
    let mut objects = Vec::new();
    for (instance_id, mask, score) in [(1u64, &main, 0.98), (2, &satellite, 0.64)] {
        if mask.iter().any(|v| *v) {
            objects.push(InstanceInput {
                class_id: 9,
                instance_id,
                mask: Some(ArrayD::from_shape_vec(IxDyn(&ct0.shape), mask.clone())?),
                bbox: None,
                crop: None,
                score: Some(score),
            });
        }
    }
    w.add_segmentation(
        "lesions_tp0",
        "ct_tp0",
        SegmentationSource::Instances(objects),
        SegmentationOptions { common: common("act_annotate", "reviewed", 0.9, ids(&[9])), ..Default::default() },
    )?;

    // -- geometric annotations --------------------------------------------------------
    let spleen0: Vec<bool> = t0.iter().map(|t| organ_class(t) == 3).collect();
    /// A box at voxel edges, its class, instance id, score and attributes.
    type FoundBox = ([[f64; 2]; 3], i64, u64, f32, Value);
    let mut found: Vec<FoundBox> = Vec::new();
    for (mask, class, id, score, attributes) in [
        (&main, 9, 1u64, 0.97f32, json!({"confirmed": true, "segment": "VIII"})),
        (&satellite, 9, 2, 0.62, json!({"confirmed": false})),
        (&spleen0, 3, 3, 0.99, json!({})),
    ] {
        if let Some(b) = box_of(mask, ct0.shape) {
            found.push((b, class, id, score, attributes));
        }
    }
    let k = found.len();
    let mut arrays: HashMap<String, NdArray> = HashMap::new();
    arrays.insert(
        "boxes".into(),
        NdArray::F64(ArrayD::from_shape_vec(
            IxDyn(&[k, 3, 2]),
            found.iter().flat_map(|f| f.0.into_iter().flatten()).collect(),
        )?),
    );
    arrays.insert("class_ids".into(), column_i64(&found.iter().map(|f| f.1).collect::<Vec<_>>())?);
    arrays.insert(
        "instance_ids".into(),
        NdArray::U64(ArrayD::from_shape_vec(IxDyn(&[k]), found.iter().map(|f| f.2).collect())?),
    );
    arrays.insert(
        "scores".into(),
        NdArray::F32(ArrayD::from_shape_vec(IxDyn(&[k]), found.iter().map(|f| f.3).collect())?),
    );
    let box_options = json!({
        "grid": "ct_tp0", "space": "index", "prov": "act_annotate", "annotated_classes": [3, 9],
        "quality": {"status": "reviewed", "confidence": 0.95, "reviewed_by": ["rad2"]},
        "attributes": found.iter().map(|f| f.4.clone()).collect::<Vec<_>>(),
    });
    crate::writer::add_geometric(w, "boxes", "lesion_boxes_tp0", box_options.as_object().expect("object"), arrays)?;

    // The kidneys as oriented boxes, in world (the baseline frame).
    let mut arrays = HashMap::new();
    let kidneys = [anatomy::RIGHT_KIDNEY, anatomy::LEFT_KIDNEY];
    arrays.insert("centers".into(), array2(&kidneys.iter().map(|k| k.0.to_vec()).collect::<Vec<_>>())?);
    arrays.insert("sizes".into(), array2(&kidneys.iter().map(|k| scale(k.1, 2.0).to_vec()).collect::<Vec<_>>())?);
    let rotations: Vec<f64> = [-12.0, 12.0].iter().flat_map(|d| rot_z(*d).into_iter().flatten()).collect();
    arrays.insert("rotations".into(), NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[2, 3, 3]), rotations)?));
    arrays.insert("class_ids".into(), column_i64(&[6, 5])?);
    let obb_options = json!({"grid": "ct_tp0", "space": "world", "frame_uid": FRAME0, "prov": "act_annotate",
        "quality": {"status": "submitted", "confidence": 0.8, "reviewed_by": []}});
    crate::writer::add_geometric(w, "obb", "kidney_obb_tp0", obb_options.as_object().expect("object"), arrays)?;

    // Anatomical landmarks as one keypoint set, in index space.
    let landmarks0: [V3; 4] = [[-60.0, 0.0, 125.0], [85.0, 35.0, 25.0], [15.0, 35.0, -30.0], [0.0, 75.0, -30.0]];
    let mut arrays = HashMap::new();
    let points: Vec<f64> = landmarks0.iter().flat_map(|x| ct0.index(*x)).collect();
    arrays.insert("points".into(), NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[1, 4, 3]), points)?));
    arrays.insert("keypoint_class_ids".into(), column_i64(&[2, 3, 7, 8])?);
    arrays.insert("class_ids".into(), column_i64(&[1])?);
    arrays.insert("visibility".into(), NdArray::I64(ArrayD::from_shape_vec(IxDyn(&[1, 4]), vec![2, 2, 2, 1])?));
    let kp_options = json!({"grid": "ct_tp0", "space": "index", "skeleton": "abdominal-landmarks", "prov": "act_annotate",
        "quality": {"status": "submitted", "confidence": 0.85, "reviewed_by": []}});
    crate::writer::add_geometric(w, "keypoints", "landmarks_tp0", kp_options.as_object().expect("object"), arrays)?;

    // Corresponding fiducials in each visit's world: the follow-up's are the
    // baseline's moved by the motion the transform stores.
    let fiducials0: Vec<V3> =
        vec![[-60.0, 0.0, 125.0], [85.0, 35.0, 25.0], LESION_CENTRE, [55.0, 55.0, 25.0], [15.0, 35.0, -100.0]];
    let names = ["liver_dome", "spleen_tip", "lesion_centre", "left_kidney_upper_pole", "aorta_infrarenal"];
    for (id, grid, frame, other, points) in [
        ("fiducials_tp0", "ct_tp0", FRAME0, "fiducials_tp1", fiducials0.clone()),
        ("fiducials_tp1", "ct_tp1", FRAME1, "fiducials_tp0", fiducials0.iter().map(|x| to_follow_up(*x)).collect()),
    ] {
        let mut arrays = HashMap::new();
        arrays.insert("points".into(), array2(&points.iter().map(|p| p.to_vec()).collect::<Vec<_>>())?);
        arrays.insert("class_ids".into(), column_i64(&[2, 3, 9, 5, 7])?);
        arrays.insert(
            "weights".into(),
            NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[5]), vec![1.0, 1.0, 2.0, 1.0, 1.0])?),
        );
        let point_options = json!({"grid": grid, "space": "world", "frame_uid": frame, "names": names,
            "correspondence": other, "prov": "act_annotate", "task": "registration",
            "quality": {"status": "reviewed", "confidence": 0.9, "reviewed_by": ["rad2"]}});
        crate::writer::add_geometric(w, "points", id, point_options.as_object().expect("object"), arrays)?;
    }

    // Contours of the liver and the lesion on three slices; on the lesion's
    // central slice the liver's polygon has the lesion cut out as a hole.
    let centre_index = ct0.index(LESION_CENTRE);
    let kc = centre_index[0].round() as usize;
    let mut vertices: Vec<Vec<f64>> = Vec::new();
    let (mut offsets, mut classes, mut planes, mut roles) = (vec![0i64], Vec::new(), Vec::new(), Vec::new());
    let mut push = |polygon: Vec<Vec<f64>>, class: i64, k: usize, role: i64| {
        vertices.extend(polygon);
        offsets.push(vertices.len() as i64);
        classes.push(class);
        planes.extend([0i64, k as i64]);
        roles.push(role);
    };
    for k in [kc - 1, kc, kc + 1] {
        let z = ct0.world([k as f64, 0.0, 0.0])[2];
        if let Some((c, r)) = section(liver.0, liver.1, z) {
            push(ring(ct0, k, c, r, 48), 2, k, 0);
        }
        let dz = z - LESION_CENTRE[2];
        let r0 = LESION_RADIUS[0];
        if dz.abs() < 0.9 * r0 {
            let rr = (r0 * r0 - dz * dz).sqrt();
            let lesion_ring = ring(ct0, k, [LESION_CENTRE[0], LESION_CENTRE[1]], [rr, rr], 32);
            push(lesion_ring.clone(), 9, k, 0);
            if k == kc {
                push(lesion_ring.into_iter().rev().collect(), 2, k, 1);
            }
        }
    }
    let m = classes.len();
    let mut arrays = HashMap::new();
    arrays.insert("vertices".into(), array2(&vertices)?);
    arrays.insert("contour_offsets".into(), column_i64(&offsets)?);
    arrays.insert("contour_class_ids".into(), column_i64(&classes)?);
    arrays.insert("contour_plane".into(), NdArray::I64(ArrayD::from_shape_vec(IxDyn(&[m, 2]), planes)?));
    arrays.insert("contour_role".into(), column_i64(&roles)?);
    let contour_options = json!({"grid": "ct_tp0", "space": "index", "prov": "act_annotate",
        "quality": {"status": "reviewed", "confidence": 0.88, "reviewed_by": ["rad2"]}});
    crate::writer::add_geometric(
        w,
        "contours",
        "liver_contours_tp0",
        contour_options.as_object().expect("object"),
        arrays,
    )?;

    // Open curves (format 1.2): the aortic centreline, and a biopsy needle's
    // track from the skin to the lesion.
    if options.polylines {
        let mut line: Vec<Vec<f64>> = (0..12)
            .map(|i| {
                let z = -150.0 + 320.0 * i as f64 / 11.0;
                ct0.index([15.0 + 3.0 * (z / 80.0).sin(), 35.0 + 2.0 * (z / 120.0).cos(), z]).to_vec()
            })
            .collect();
        let aorta_count = line.len() as i64;
        let skin = [-95.0, -85.0, 60.0];
        for p in [skin, scale(add(skin, LESION_CENTRE), 0.5), LESION_CENTRE] {
            line.push(ct0.index(p).to_vec());
        }
        let mut arrays = HashMap::new();
        arrays.insert("vertices".into(), array2(&line)?);
        arrays.insert("polyline_offsets".into(), column_i64(&[0, aorta_count, aorta_count + 3])?);
        arrays.insert("polyline_class_ids".into(), column_i64(&[7, 12])?);
        arrays.insert("instance_ids".into(), NdArray::U64(ArrayD::from_shape_vec(IxDyn(&[2]), vec![21u64, 22])?));
        let line_options = json!({"grid": "ct_tp0", "space": "index", "prov": "act_annotate",
            "quality": {"status": "submitted", "confidence": 0.8, "reviewed_by": []}});
        crate::writer::add_geometric(
            w,
            "polylines",
            "centrelines_tp0",
            line_options.as_object().expect("object"),
            arrays,
        )?;
    }

    // Surfaces in world: the lesion (an icosphere) and the liver.
    let (unit, faces) = icosphere(2);
    let mut vertices: Vec<Vec<f64>> = Vec::new();
    let mut normals: Vec<Vec<f64>> = Vec::new();
    for v in &unit {
        vertices.push(add(LESION_CENTRE, scale(*v, LESION_RADIUS[0])).to_vec());
        normals.push(v.to_vec());
    }
    for v in &unit {
        let p = [liver.0[0] + liver.1[0] * v[0], liver.0[1] + liver.1[1] * v[1], liver.0[2] + liver.1[2] * v[2]];
        let g = [v[0] / liver.1[0], v[1] / liver.1[1], v[2] / liver.1[2]];
        normals.push(scale(g, 1.0 / norm(g)).to_vec());
        vertices.push(p.to_vec());
    }
    let nv = unit.len();
    let face_rows: Vec<i64> = faces
        .iter()
        .flat_map(|f| f.map(|i| i as i64))
        .chain(faces.iter().flat_map(|f| f.map(|i| (i + nv) as i64)))
        .collect();
    let nf = faces.len();
    let mut arrays = HashMap::new();
    arrays.insert("vertices".into(), array2(&vertices)?);
    arrays.insert("normals".into(), array2(&normals)?);
    arrays.insert("faces".into(), NdArray::I64(ArrayD::from_shape_vec(IxDyn(&[2 * nf, 3]), face_rows)?));
    arrays.insert("mesh_offsets".into(), column_i64(&[0, nf as i64, 2 * nf as i64])?);
    arrays.insert("mesh_class_ids".into(), column_i64(&[9, 2])?);
    let mesh_options = json!({"grid": "ct_tp0", "space": "world", "frame_uid": FRAME0, "prov": "act_annotate",
        "quality": {"status": "submitted", "confidence": 0.75, "reviewed_by": []}});
    crate::writer::add_geometric(w, "mesh", "surfaces_tp0", mesh_options.as_object().expect("object"), arrays)?;

    // A change label across the visits.
    let response = json!({
        "scope": "sample", "multilabel": false, "timepoints": ["tp0", "tp1"],
        "assertions": [{"class_id": 10, "value": 1.0}, {"class_id": 11, "value": 0.0}],
        "annotated_classes": [10, 11], "prov": "act_review",
        "quality": {"status": "approved", "confidence": 0.9, "reviewed_by": ["rad2"]},
    });
    crate::writer::add_classification(w, "response", response.as_object().expect("object"))?;

    // -- the registration -------------------------------------------------------------
    let matrix = motion_matrix();
    let mut arrays = HashMap::new();
    arrays.insert(
        "matrix".to_string(),
        NdArray::F64(ArrayD::from_shape_vec(IxDyn(&[4, 4]), matrix.iter().flatten().copied().collect())?),
    );
    let transform = json!({"from_frame": FRAME0, "to_frame": FRAME1, "from_grid": "ct_tp0", "to_grid": "ct_tp1",
        "invertible": true, "prov": "act_register"});
    crate::writer::add_transform(w, "tp0_to_tp1", "affine", transform.as_object().expect("object"), arrays)?;

    if options.index {
        w.build_index(Some(&["organs_tp0".to_string()]), None, None, 7)?;
    }
    if options.clinical {
        w.add_records(clinical_records())?;
    }
    Ok(())
}

/// The follow-up report, as its document holds it.
pub const REPORT_TP1: &str = "CT abdomen, portal venous phase. Comparison: baseline of 92 days earlier. \
The segment VIII liver lesion now measures 54 mm (previously 36 mm), consistent with progression. \
The satellite lesion seen at baseline is no longer visible. Spleen and kidneys unremarkable.";
const REPORT_TP0_PRELIMINARY: &str = "CT abdomen (preliminary): a 36 mm hypodense lesion in liver segment VIII.";
const REPORT_TP0_FINAL: &str = "CT abdomen (amended): a 36 mm hypodense lesion in liver segment VIII and an 18 mm \
satellite lesion; MR to follow.";

fn point_event(id: &str, record: &str, kind: &str, at: i64, available: i64, status: &str) -> Event {
    Event {
        event_id: id.into(),
        record_id: record.into(),
        kind: kind.into(),
        temporal_type: "point".into(),
        effective_start: Some(Bounds::exact(at)),
        available: Some(Bounds::exact(available)),
        status: status.into(),
        prov: Some("act_clinical_import".into()),
        ..Default::default()
    }
}

fn lab(id: &str, code: &str, value: f64, unit: &str, at: i64) -> Event {
    let mut e = point_event(id, id, "observation", at, at + 2 * HOUR, "final");
    e.code_system = Some("http://loinc.org".into());
    e.code = Some(code.into());
    e.value_num = Some(value);
    e.unit = Some(unit.into());
    e
}

/// The clinical history: labs, the scans, reports (one revised), an
/// assessment, and the links that tie them to the images and the lesion.
pub fn clinical_records() -> ClinicalRecords {
    let mut records = ClinicalRecords::new(Descriptor::new(Clock::relative(
        "demo-subject-clock",
        "acquisition start of the baseline CT (timepoint tp0)",
    )));
    let follow_up = 92 * DAY;
    let mut ct0 = point_event("ct0", "ct0", "imaging", 0, HOUR, "final");
    ct0.timepoint_id = Some("tp0".into());
    let mut mr0 = point_event("mr0", "mr0", "imaging", 2 * HOUR, 3 * HOUR, "final");
    mr0.timepoint_id = Some("tp0".into());
    let mut ct1 = point_event("ct1", "ct1", "imaging", follow_up, follow_up + HOUR, "final");
    ct1.timepoint_id = Some("tp1".into());
    let mut response = point_event("response1", "response1", "assessment", follow_up, follow_up + 24 * HOUR, "final");
    response.code_system = Some(ASSESSMENT_SYSTEM.into());
    response.code = Some(LESION_PRESENCE.into());
    response.value_text = Some("present".into());
    response.timepoint_id = Some("tp1".into());
    response.prov = Some("act_review".into());
    let mut grounding = point_event("grounding1", "grounding1", "other", follow_up, follow_up + 30 * HOUR, "final");
    grounding.temporal_type = "unknown".into();
    grounding.effective_start = None;
    records.events = vec![
        lab("alt0", "1742-6", 34.0, "U/L", -72 * HOUR),
        lab("afp0", "1834-1", 210.0, "ng/mL", -48 * HOUR),
        ct0,
        mr0,
        point_event("report0_v1", "report0", "document", 0, 6 * HOUR, "preliminary"),
        point_event("report0_v2", "report0", "document", 0, 30 * HOUR, "amended"),
        lab("afp1", "1834-1", 480.0, "ng/mL", 60 * DAY),
        ct1,
        point_event("report1", "report1", "document", follow_up, follow_up + 5 * HOUR, "final"),
        response,
        grounding,
    ];
    let text = |id: &str, body: &str| {
        let mut d = Document::text(id, body);
        d.language = Some("en".into());
        d.source_type = Some("radiology_report".into());
        d
    };
    records.documents = vec![
        text("report0_text_v1", REPORT_TP0_PRELIMINARY),
        text("report0_text_v2", REPORT_TP0_FINAL),
        text("report1_text", REPORT_TP1),
    ];
    let asserted = |mut link: Link, by: &str| {
        link.asserted_by_event_id = Some(by.into());
        link
    };
    let phrase = "54 mm";
    let start = REPORT_TP1.find(phrase).expect("the phrase is in the report") as u64;
    let mut grounded = Link::new(("document", "report1_text"), "describes", ("instance", "1"));
    grounded.source_span = Some((start, start + phrase.len() as u64));
    grounded.target_annotation_id = Some("lesions_tp0".into());
    let mut assessed = Link::new(("event", "response1"), "assesses", ("instance", "1"));
    assessed.target_annotation_id = Some("lesions_tp0".into());
    records.links = vec![
        Link::new(("event", "ct0"), "describes", ("image", "CT_tp0")),
        Link::new(("event", "mr0"), "describes", ("image", "MR_tp0")),
        Link::new(("event", "ct1"), "describes", ("image", "CT_tp1")),
        Link::new(("event", "report0_v1"), "describes", ("document", "report0_text_v1")),
        Link::new(("event", "report0_v2"), "describes", ("document", "report0_text_v2")),
        Link::new(("event", "report0_v2"), "supersedes", ("event", "report0_v1")),
        Link::new(("event", "report1"), "describes", ("document", "report1_text")),
        asserted(assessed, "response1"),
        asserted(Link::new(("event", "response1"), "derived_from", ("image", "CT_tp1")), "response1"),
        asserted(Link::new(("event", "response1"), "compares_with", ("timepoint", "tp0")), "response1"),
        asserted(grounded, "grounding1"),
    ];
    records
}

/// Options from JSON: `{"size", "clinical", "polylines", "index", "codec"}`.
pub fn demo_options(options: &Map<String, Value>) -> BResult<DemoOptions> {
    let mut out = DemoOptions::default();
    if let Some(size) = crate::convert::opt_i64(options, "size")? {
        out.size = usize::try_from(size).map_err(|_| BridgeError::argument("size must be positive"))?;
    }
    if let Some(v) = crate::convert::opt_bool(options, "clinical")? {
        out.clinical = v;
    }
    if let Some(v) = crate::convert::opt_bool(options, "polylines")? {
        out.polylines = v;
    }
    if let Some(v) = crate::convert::opt_bool(options, "index")? {
        out.index = v;
    }
    if let Some(v) = crate::convert::opt_str(options, "codec")? {
        out.codec = v;
    }
    Ok(out)
}

#[no_mangle]
pub extern "C" fn m5_demo_write(path: *const c_char, options_json: *const c_char) -> M5Status {
    guard(|| {
        let path = ffi::arg_str(path, "path")?;
        let options = demo_options(&ffi::arg_json(options_json, "options_json")?)?;
        write_demo(Path::new(path), &options)
    })
}
