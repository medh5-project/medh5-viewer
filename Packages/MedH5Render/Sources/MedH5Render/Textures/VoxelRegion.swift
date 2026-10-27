import Foundation
import simd

/// A box of voxels in **padded index order** `(k0, k1, k2)` — slowest axis
/// first, as `GridGeometry.paddedShape` — given by its first voxel and its
/// extent. The segmentation editor reports the voxels it changed as one of
/// these (a dirty box) so only that part of a texture is re-uploaded.
public struct VoxelRegion: Sendable, Hashable, CustomStringConvertible {
    /// The first voxel, `(k0, k1, k2)`.
    public var origin: SIMD3<Int>
    /// The number of voxels along `(k0, k1, k2)`.
    public var size: SIMD3<Int>

    public init(origin: SIMD3<Int>, size: SIMD3<Int>) {
        self.origin = origin
        self.size = size
    }

    /// The region `lower ..< upper` (upper bound exclusive).
    public init(lower: SIMD3<Int>, upper: SIMD3<Int>) {
        origin = lower
        size = simd_max(upper &- lower, SIMD3(repeating: 0))
    }

    /// Every voxel of a volume of padded shape `dimensions`.
    public static func whole(_ dimensions: SIMD3<Int>) -> VoxelRegion {
        VoxelRegion(origin: SIMD3(repeating: 0), size: dimensions)
    }

    /// One past the last voxel.
    public var upper: SIMD3<Int> { origin &+ size }

    public var isEmpty: Bool { size.x <= 0 || size.y <= 0 || size.z <= 0 }

    public var voxelCount: Int { isEmpty ? 0 : size.x * size.y * size.z }

    /// The part of the region inside a volume of padded shape `dimensions`,
    /// or `nil` when nothing is.
    public func clamped(to dimensions: SIMD3<Int>) -> VoxelRegion? {
        let lo = simd_max(origin, SIMD3(repeating: 0))
        let hi = simd_min(upper, dimensions)
        let r = VoxelRegion(lower: lo, upper: hi)
        return r.isEmpty ? nil : r
    }

    /// The smallest region holding both.
    public func union(_ other: VoxelRegion) -> VoxelRegion {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return VoxelRegion(lower: simd_min(origin, other.origin), upper: simd_max(upper, other.upper))
    }

    /// Grows the region by `margin` voxels on every side.
    public func expanded(by margin: Int) -> VoxelRegion {
        VoxelRegion(origin: origin &- SIMD3(repeating: margin), size: size &+ SIMD3(repeating: 2 * margin))
    }

    public func contains(_ voxel: SIMD3<Int>) -> Bool {
        all(voxel .>= origin) && all(voxel .< upper)
    }

    public var description: String {
        "[\(origin.x)..<\(upper.x), \(origin.y)..<\(upper.y), \(origin.z)..<\(upper.z)]"
    }
}

