//! Image reads: a region of an image, in slabs along axis 0, into the
//! caller's buffer.

use std::ffi::{c_char, c_void};

use medh5::array::{DType, Slice};

use crate::arrays::{self, M5DType};
use crate::ffi::{self, guard, BResult, BridgeError, M5ProgressFn, M5Status, Progress};
use crate::sample::{handle, M5Sample};

/// Bytes of stored data one slab reads, about.
pub const SLAB_BYTES: usize = 16 << 20;

/// A slab is aligned to the dataset's chunks along axis 0 unless a chunk
/// row is larger than this.
const ALIGN_LIMIT: usize = 256 << 20;

/// The `[start, stop)` ranges along axis 0 that cover `window` in slabs of
/// about `budget` bytes of `itemsize` elements, aligned to chunks of
/// `chunk0` rows so that no chunk is decoded twice.
pub fn plan_slabs(
    window: &[(usize, usize)],
    itemsize: usize,
    chunk0: Option<usize>,
    budget: usize,
) -> Vec<(usize, usize)> {
    let Some(&(start, stop)) = window.first() else { return Vec::new() };
    if window.iter().any(|(a, b)| b <= a) {
        return Vec::new();
    }
    let per_row: usize = window[1..].iter().map(|(a, b)| b - a).product::<usize>().saturating_mul(itemsize).max(1);
    let mut rows = (budget / per_row).max(1);
    let chunk = chunk0.filter(|c| *c > 1 && c.saturating_mul(per_row) <= ALIGN_LIMIT);
    if let Some(c) = chunk {
        rows = rows.div_ceil(c) * c;
    }
    let mut out = Vec::new();
    let mut s = start;
    while s < stop {
        let e = match chunk {
            Some(c) => (s - s % c).saturating_add(rows).min(stop),
            None => s.saturating_add(rows).min(stop),
        };
        out.push((s, e));
        s = e;
    }
    out
}

/// `slices` of a window with axis 0 replaced by `[a, b)`.
pub fn slab_slices(window: &[(usize, usize)], a: usize, b: usize) -> Vec<Slice> {
    let mut out = vec![Slice::new(a as i64, b as i64)];
    out.extend(window[1..].iter().map(|(lo, hi)| Slice::new(*lo as i64, *hi as i64)));
    out
}

/// The output buffer the caller passed, checked to hold `expected` bytes.
pub fn out_bytes<'a>(out: *mut c_void, out_bytes: usize, expected: usize) -> BResult<&'a mut [u8]> {
    if out_bytes != expected {
        return Err(BridgeError::argument(format!("the buffer holds {out_bytes} bytes; the region needs {expected}")));
    }
    if expected == 0 {
        return Ok(&mut []);
    }
    if out.is_null() {
        return Err(BridgeError::argument("out is NULL"));
    }
    // SAFETY: the caller passes a writable buffer of `out_bytes` bytes.
    Ok(unsafe { std::slice::from_raw_parts_mut(out as *mut u8, out_bytes) })
}

#[allow(clippy::too_many_arguments)]
fn read_image(
    handle: &M5Sample,
    image_id: &str,
    level: u32,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    physical: bool,
    dtype: M5DType,
    out: *mut c_void,
    out_len: usize,
    progress: Progress,
) -> BResult<()> {
    let sample = handle.sample()?;
    let base = handle.image(&sample, image_id)?;
    let image = base.level(level as usize)?;
    let shape = image.shape()?;
    let window = ffi::region(start, stop, ndim, &shape, true)?;
    let stored = image.dtype()?;
    let target: DType = match arrays::dtype_of(dtype)? {
        Some(d) => d,
        None if physical => DType::F32,
        None => stored,
    };
    let count = ffi::window_count(&window)?;
    let buffer = out_bytes(out, out_len, count.saturating_mul(target.itemsize()))?;
    let total = count as u64;
    progress.report(0, total)?;
    if count == 0 {
        return Ok(());
    }
    let chunk0 = image.chunks()?.and_then(|c| c.first().copied());
    let row_elements: usize = window[1..].iter().map(|(a, b)| b - a).product();
    let mut done = 0usize;
    for (a, b) in plan_slabs(&window, stored.itemsize().max(target.itemsize()), chunk0, SLAB_BYTES) {
        let slices = slab_slices(&window, a, b);
        let block = image.read(Some(&slices), physical, Some(target))?;
        let n = (b - a) * row_elements;
        let offset = (a - window[0].0) * row_elements * target.itemsize();
        arrays::copy_to(&block, &mut buffer[offset..offset + n * target.itemsize()])?;
        done += n;
        progress.report(done as u64, total)?;
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn m5_image_read(
    sample: *mut M5Sample,
    image_id: *const c_char,
    level: u32,
    start: *const i64,
    stop: *const i64,
    ndim: u32,
    physical: bool,
    dtype: M5DType,
    out: *mut c_void,
    out_bytes: usize,
    progress: M5ProgressFn,
    context: *mut c_void,
) -> M5Status {
    guard(|| {
        let handle = handle(sample)?;
        let image_id = ffi::arg_str(image_id, "image_id")?;
        read_image(
            handle,
            image_id,
            level,
            start,
            stop,
            ndim,
            physical,
            dtype,
            out,
            out_bytes,
            Progress::new(progress, context),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slabs_cover_the_window_and_align_to_chunks() {
        let window = [(3usize, 100usize), (0, 10), (0, 10)];
        let slabs = plan_slabs(&window, 2, Some(8), 8 * 10 * 10 * 2 * 2);
        assert_eq!(slabs.first().unwrap().0, 3);
        assert_eq!(slabs.last().unwrap().1, 100);
        for pair in slabs.windows(2) {
            assert_eq!(pair[0].1, pair[1].0);
            assert_eq!(pair[0].1 % 8, 0, "{slabs:?}");
        }
        assert!(plan_slabs(&[(0, 0), (0, 4)], 1, None, 10).is_empty());
        assert_eq!(plan_slabs(&[(0, 5), (0, 4)], 1, None, 1), vec![(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)]);
    }
}
