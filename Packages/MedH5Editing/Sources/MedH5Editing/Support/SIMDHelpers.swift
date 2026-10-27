import simd

// `VoxelBox` lives in MedH5Core; these element-wise helpers stay with the
// kernels here that use them.

@inline(__always)
func pointwiseMin(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> {
    SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
}

@inline(__always)
func pointwiseMax(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> {
    SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
}
