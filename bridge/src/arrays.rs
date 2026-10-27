//! Element types across the boundary, and moving engine arrays into and out
//! of caller buffers.
//!
//! The `M5DType` codes are `MedH5Core.ScalarType`'s raw values; elements are
//! native-endian (little-endian on every Apple silicon Mac), C order.

use medh5::array::{DType, NdArray};
use medh5::ndarray::{ArrayD, IxDyn};

use crate::ffi::{BResult, BridgeError};

pub type M5DType = i32;
pub const M5_DTYPE_NATIVE: M5DType = 0;

/// The `M5DType` code of an engine dtype.
pub fn code_of(dtype: DType) -> M5DType {
    match dtype {
        DType::Bool => 1,
        DType::U8 => 2,
        DType::I8 => 3,
        DType::U16 => 4,
        DType::I16 => 5,
        DType::U32 => 6,
        DType::I32 => 7,
        DType::U64 => 8,
        DType::I64 => 9,
        DType::F16 => 10,
        DType::F32 => 11,
        DType::F64 => 12,
    }
}

/// The engine dtype of an `M5DType` code; `None` for `M5_DTYPE_NATIVE`.
pub fn dtype_of(code: M5DType) -> BResult<Option<DType>> {
    Ok(Some(match code {
        0 => return Ok(None),
        1 => DType::Bool,
        2 => DType::U8,
        3 => DType::I8,
        4 => DType::U16,
        5 => DType::I16,
        6 => DType::U32,
        7 => DType::I32,
        8 => DType::U64,
        9 => DType::I64,
        10 => DType::F16,
        11 => DType::F32,
        12 => DType::F64,
        other => return Err(BridgeError::argument(format!("unknown element type code {other}"))),
    }))
}

/// A required (non-native) dtype.
pub fn required_dtype(code: M5DType, what: &str) -> BResult<DType> {
    dtype_of(code)?.ok_or_else(|| BridgeError::argument(format!("{what}: M5_DTYPE_NATIVE is for reads only")))
}

/// The bytes of an array in C order: borrowed when it is laid out that way.
pub fn with_bytes<R>(array: &NdArray, f: impl FnOnce(&[u8]) -> R) -> R {
    macro_rules! bytes_of {
        ($a:expr, $t:ty) => {{
            let a = $a;
            match a.as_slice() {
                Some(s) => {
                    // SAFETY: a slice of plain-old-data elements viewed as bytes.
                    let bytes =
                        unsafe { std::slice::from_raw_parts(s.as_ptr() as *const u8, std::mem::size_of_val(s)) };
                    f(bytes)
                }
                None => {
                    let owned: Vec<$t> = a.iter().copied().collect();
                    // SAFETY: as above, for the C-order copy.
                    let bytes = unsafe {
                        std::slice::from_raw_parts(owned.as_ptr() as *const u8, std::mem::size_of_val(&owned[..]))
                    };
                    f(bytes)
                }
            }
        }};
    }
    match array {
        NdArray::Bool(a) => bytes_of!(a, bool),
        NdArray::I8(a) => bytes_of!(a, i8),
        NdArray::U8(a) => bytes_of!(a, u8),
        NdArray::I16(a) => bytes_of!(a, i16),
        NdArray::U16(a) => bytes_of!(a, u16),
        NdArray::I32(a) => bytes_of!(a, i32),
        NdArray::U32(a) => bytes_of!(a, u32),
        NdArray::I64(a) => bytes_of!(a, i64),
        NdArray::U64(a) => bytes_of!(a, u64),
        NdArray::F16(a) => bytes_of!(a, half::f16),
        NdArray::F32(a) => bytes_of!(a, f32),
        NdArray::F64(a) => bytes_of!(a, f64),
    }
}

/// Copy an array's elements into `out`, which must hold exactly its bytes.
pub fn copy_to(array: &NdArray, out: &mut [u8]) -> BResult<()> {
    with_bytes(array, |bytes| {
        if bytes.len() != out.len() {
            return Err(BridgeError::engine(
                "runtime",
                format!("internal: {} bytes for a slot of {}", bytes.len(), out.len()),
            ));
        }
        out.copy_from_slice(bytes);
        Ok(())
    })
}

/// An engine array of `dtype` and `shape` from caller bytes (copied; the
/// pointer need not be aligned).  `bool` takes any nonzero byte as true.
pub fn from_bytes(dtype: DType, shape: &[usize], bytes: &[u8]) -> BResult<NdArray> {
    let n: usize = shape.iter().product();
    if bytes.len() != n * dtype.itemsize() {
        return Err(BridgeError::argument(format!("{} bytes for {} elements of {}", bytes.len(), n, dtype.name())));
    }
    fn typed<T: Copy + Default>(bytes: &[u8], n: usize) -> Vec<T> {
        let mut out = vec![T::default(); n];
        // SAFETY: `out` holds exactly `bytes.len()` bytes of plain-old-data.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.as_mut_ptr() as *mut u8, bytes.len());
        }
        out
    }
    let dim = IxDyn(shape);
    Ok(match dtype {
        DType::Bool => NdArray::Bool(ArrayD::from_shape_vec(dim, bytes.iter().map(|b| *b != 0).collect())?),
        DType::U8 => NdArray::U8(ArrayD::from_shape_vec(dim, bytes.to_vec())?),
        DType::I8 => NdArray::I8(ArrayD::from_shape_vec(dim, typed::<i8>(bytes, n))?),
        DType::U16 => NdArray::U16(ArrayD::from_shape_vec(dim, typed::<u16>(bytes, n))?),
        DType::I16 => NdArray::I16(ArrayD::from_shape_vec(dim, typed::<i16>(bytes, n))?),
        DType::U32 => NdArray::U32(ArrayD::from_shape_vec(dim, typed::<u32>(bytes, n))?),
        DType::I32 => NdArray::I32(ArrayD::from_shape_vec(dim, typed::<i32>(bytes, n))?),
        DType::U64 => NdArray::U64(ArrayD::from_shape_vec(dim, typed::<u64>(bytes, n))?),
        DType::I64 => NdArray::I64(ArrayD::from_shape_vec(dim, typed::<i64>(bytes, n))?),
        DType::F16 => NdArray::F16(ArrayD::from_shape_vec(dim, typed::<half::f16>(bytes, n))?),
        DType::F32 => NdArray::F32(ArrayD::from_shape_vec(dim, typed::<f32>(bytes, n))?),
        DType::F64 => NdArray::F64(ArrayD::from_shape_vec(dim, typed::<f64>(bytes, n))?),
    })
}
