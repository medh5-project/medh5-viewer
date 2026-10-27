import Foundation
import simd

/// A box of voxels in a grid's **padded** index space (see `GridGeometry`):
/// the voxels `lower ..< upper` on each of the three padded axes (half-open,
/// so `upper - lower` is the extent in voxels).
///
/// medh5 stores boxes at voxel *edges* (spec §8.1): a box `[lo, hi]` covers
/// `floor(lo + 0.5) ..< floor(hi + 0.5)`, rounding half up. `edgeLower` /
/// `edgeUpper` and `init(edgeLower:edgeUpper:)` convert between the two.
public struct VoxelBox: Hashable, Sendable, CustomStringConvertible {
    /// First voxel on each padded axis.
    public var lower: SIMD3<Int>
    /// One past the last voxel on each padded axis.
    public var upper: SIMD3<Int>

    public init(lower: SIMD3<Int>, upper: SIMD3<Int>) {
        self.lower = lower
        self.upper = upper
    }

    /// The whole volume of a padded shape.
    public init(shape: SIMD3<Int>) {
        self.lower = .zero
        self.upper = shape
    }

    /// One voxel.
    public init(voxel k: SIMD3<Int>) {
        self.lower = k
        self.upper = k &+ 1
    }

    /// The box covering medh5 edge coordinates `[lo, hi]` (continuous padded
    /// index, voxel centres at integers): `floor(lo + 0.5) ..< floor(hi + 0.5)`
    /// per axis, rounding half up as spec §8.1 requires.
    public init(edgeLower lo: SIMD3<Double>, edgeUpper hi: SIMD3<Double>) {
        var l = SIMD3<Int>.zero, u = SIMD3<Int>.zero
        for a in 0..<3 {
            l[a] = Int((lo[a] + 0.5).rounded(.down))
            u[a] = Int((hi[a] + 0.5).rounded(.down))
        }
        self.init(lower: l, upper: u)
    }

    public static let empty = VoxelBox(lower: .zero, upper: .zero)

    public var isEmpty: Bool { any(upper .<= lower) }

    /// Extent in voxels per axis (0 for an empty axis).
    public var size: SIMD3<Int> {
        let d = upper &- lower
        return SIMD3(Swift.max(0, d.x), Swift.max(0, d.y), Swift.max(0, d.z))
    }

    /// Number of voxels in the box.
    public var voxelCount: Int {
        let s = size
        return s.x * s.y * s.z
    }

    /// The edge coordinates of the box (spec §8.1): `lower − 0.5`.
    public var edgeLower: SIMD3<Double> { SIMD3<Double>(lower) - 0.5 }
    /// The edge coordinates of the box (spec §8.1): `upper − 0.5`.
    public var edgeUpper: SIMD3<Double> { SIMD3<Double>(upper) - 0.5 }

    /// The box's edges as medh5 stores them, `[[lo, hi], …]` per spatial
    /// axis in stored order, for a grid of spatial rank `rank` (2 or 3; a 2-D
    /// grid drops the padding axis 0).
    public func edgeBounds(rank: Int) -> [[Double]] {
        let axes = rank >= 3 ? [0, 1, 2] : [1, 2]
        return axes.map { [Double(lower[$0]) - 0.5, Double(upper[$0]) - 0.5] }
    }

    public func contains(_ k: SIMD3<Int>) -> Bool {
        all(k .>= lower) && all(k .< upper)
    }

    public func contains(_ other: VoxelBox) -> Bool {
        other.isEmpty || (all(other.lower .>= lower) && all(other.upper .<= upper))
    }

    public func intersects(_ other: VoxelBox) -> Bool {
        !intersection(other).isEmpty
    }

    /// The smallest box holding both (an empty box is the identity).
    public func union(_ other: VoxelBox) -> VoxelBox {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return VoxelBox(lower: pointwiseMin(lower, other.lower), upper: pointwiseMax(upper, other.upper))
    }

    public mutating func formUnion(_ other: VoxelBox) { self = union(other) }

    /// Grows the box to hold one voxel.
    public mutating func include(_ k: SIMD3<Int>) { formUnion(VoxelBox(voxel: k)) }

    public func intersection(_ other: VoxelBox) -> VoxelBox {
        let l = pointwiseMax(lower, other.lower)
        let u = pointwiseMin(upper, other.upper)
        let box = VoxelBox(lower: l, upper: u)
        return box.isEmpty ? .empty : box
    }

    /// The box grown by `margin` voxels on both sides of each axis.
    public func expanded(by margin: SIMD3<Int>) -> VoxelBox {
        isEmpty ? self : VoxelBox(lower: lower &- margin, upper: upper &+ margin)
    }

    public func expanded(by margin: Int) -> VoxelBox { expanded(by: SIMD3(repeating: margin)) }

    /// The part of the box inside a volume of padded shape `shape`.
    public func clamped(to shape: SIMD3<Int>) -> VoxelBox {
        intersection(VoxelBox(shape: shape))
    }

    public var description: String {
        "[\(lower.x)..<\(upper.x), \(lower.y)..<\(upper.y), \(lower.z)..<\(upper.z)]"
    }
}

@inline(__always)
func pointwiseMin(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> {
    SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
}

@inline(__always)
func pointwiseMax(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> {
    SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
}
