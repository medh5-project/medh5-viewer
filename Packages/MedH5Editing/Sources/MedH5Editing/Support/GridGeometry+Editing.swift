import Foundation
import simd
import MedH5Core

extension GridGeometry {
    /// The linear part of padded index → world: column `i` is the world step
    /// of one voxel along padded axis `i` (direction × spacing).
    public var indexToWorldLinear: simd_double3x3 {
        let d = axisDirections
        let s = paddedSpacing
        return simd_double3x3(columns: (d[0] * s[0], d[1] * s[1], d[2] * s[2]))
    }

    /// The linear part of world → padded index.
    public var worldToIndexLinear: simd_double3x3 { indexToWorldLinear.inverse }

    /// World position of a voxel centre.
    @inline(__always)
    public func worldPosition(ofVoxel k: SIMD3<Int>) -> SIMD3<Double> {
        world(fromIndex: SIMD3<Double>(k))
    }

    /// The padded axis whose world direction is most nearly parallel to
    /// `direction` (for a plane normal: the axis the slice is taken along).
    public func nearestAxis(to direction: SIMD3<Double>) -> Int {
        let d = axisDirections
        var best = 0
        var bestDot = -1.0
        for a in 0..<3 {
            // A 2-D grid has a single plane: never pick the padding axis
            // over an in-plane one unless it is the closest.
            let v = abs(simd_dot(d[a], direction))
            if v > bestDot + 1e-12 {
                bestDot = v
                best = a
            }
        }
        return best
    }

    /// Half the thickness of one voxel measured along unit direction `n`
    /// (the support function of the voxel cell): a voxel whose centre lies
    /// within this distance of a plane with normal `n` has a cell the plane
    /// cuts.
    public func voxelHalfExtent(along n: SIMD3<Double>) -> Double {
        let m = indexToWorldLinear
        return 0.5 * (abs(simd_dot(m.columns.0, n)) + abs(simd_dot(m.columns.1, n)) + abs(simd_dot(m.columns.2, n)))
    }

    /// The physical volume of one voxel in `units³` (for a 2-D grid, its
    /// area in `units²`).
    public var paddedVoxelVolume: Double {
        let s = paddedSpacing
        return is2D ? s.y * s.z : s.x * s.y * s.z
    }
}

/// Connectivity of voxel neighbourhoods.
///
/// In 3-D: `.face` = 6 neighbours, `.edge` = 18, `.full` = 26. Restricted to
/// one slice (2-D), `.face` is 4-connectivity and `.edge`/`.full` are 8.
public enum Connectivity: Int, Sendable, Hashable, Codable, CaseIterable {
    case face = 6
    case edge = 18
    case full = 26

    /// The complementary connectivity for the background of a binary object
    /// (6 ↔ 26; 18 ↔ 6), so that object and holes do not leak into each other.
    public var complement: Connectivity {
        switch self {
        case .face: return .full
        case .edge, .full: return .face
        }
    }

    /// Neighbouring rows `(dk0, dk1)` and the extra reach along the row
    /// (0 or 1 voxel) with which a run touches runs of that row.
    var rowNeighbours: [(dz: Int, dy: Int, reach: Int)] {
        var out: [(Int, Int, Int)] = []
        for dz in -1...1 {
            for dy in -1...1 where !(dz == 0 && dy == 0) {
                let offAxes = (dz != 0 ? 1 : 0) + (dy != 0 ? 1 : 0)
                switch self {
                case .face:
                    if offAxes == 1 { out.append((dz, dy, 0)) }
                case .edge:
                    if offAxes == 1 { out.append((dz, dy, 1)) } else { out.append((dz, dy, 0)) }
                case .full:
                    out.append((dz, dy, 1))
                }
            }
        }
        return out
    }
}

/// An axis-aligned plane of a grid: the voxels with padded index
/// `k[axis] == index`.
public struct GridPlane: Hashable, Sendable, Codable {
    /// Padded axis (0, 1 or 2).
    public var axis: Int
    public var index: Int

    public init(axis: Int, index: Int) {
        self.axis = axis
        self.index = index
    }

    /// The box of the plane's voxels in a volume of padded `shape`.
    public func box(in shape: SIMD3<Int>) -> VoxelBox {
        var lo = SIMD3<Int>.zero, hi = shape
        lo[axis] = index
        hi[axis] = index + 1
        return VoxelBox(lower: lo, upper: hi).clamped(to: shape)
    }
}
