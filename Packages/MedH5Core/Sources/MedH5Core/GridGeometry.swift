import Foundation
import simd

/// What an array axis is (medh5 spec §3.1). Only `spatial` axes take part in
/// geometry; they are the trailing, contiguous axes of every array.
public enum AxisKind: String, Sendable, Hashable, Codable {
    case spatial
    case channel
    case time
    case other
}

/// A medh5 grid (spec §3.2): the lattice an image or voxel annotation lives on.
///
/// Field names follow the grid's HDF5 attributes, and the coding keys are their
/// snake_case spellings, so the bridge's JSON for a grid decodes into this
/// directly.
///
/// ## Index, world and texture coordinates
///
/// medh5 describes a spatial index `i` in **stored order** (axis 0 slowest),
/// with integers at voxel **centres**, and maps it to world coordinates by
///
///     x = origin + direction · (spacing ⊙ i)        (spec §3.3)
///
/// The viewer pads every grid to three spatial axes so that one code path
/// renders 2-D and 3-D data: a padded index is `k = (k0, k1, k2)`, equal to
/// `i` for a 3-D grid and to `(0, i0, i1)` for a 2-D one, whose extra axis
/// points along world `z` with unit spacing (a 2-D grid lies in the plane
/// `z = 0`, spec §3.6).
///
/// A volume of padded shape `(n0, n1, n2)` is uploaded as a 3-D texture of
/// width `n2`, height `n1` and depth `n0` (C order, so texel `(x, y, z)` is
/// index `(k2, k1, k0)`), and its normalised texture coordinate is
///
///     tc = ((k2 + 0.5) / n2, (k1 + 0.5) / n1, (k0 + 0.5) / n0)
///
/// `indexToWorld`, `worldToIndex`, `indexToTexture` and `worldToTexture`
/// give these maps as homogeneous matrices.
public struct GridGeometry: Sendable, Hashable, Codable {
    public var id: String
    /// The full array shape in stored order, every axis (spatial or not).
    public var shape: [Int]
    public var axisNames: [String]
    public var axisKinds: [AxisKind]
    /// Voxel size per spatial axis, in `units`.
    public var spacing: [Double]
    /// World coordinate of spatial index 0.
    public var origin: [Double]
    /// `S × S`, row-major: `direction[r][c]` is world component `r` of the
    /// unit direction of spatial axis `c` (spec §3.2: column `c` is the world
    /// direction of spatial axis `c`).
    public var direction: [[Double]]
    /// `"LPS"`, `"RAS"`, … or `"custom"`.
    public var coordSystem: String
    /// `"mm"`, `"um"`, `"m"` or `"px"`.
    public var units: String
    public var timepoint: String?
    public var frameUID: String?
    public var timeValues: [Double]?
    public var timeUnits: String?

    enum CodingKeys: String, CodingKey {
        case id
        case shape
        case axisNames = "axis_names"
        case axisKinds = "axis_kinds"
        case spacing
        case origin
        case direction
        case coordSystem = "coord_system"
        case units
        case timepoint
        case frameUID = "frame_uid"
        case timeValues = "time_values"
        case timeUnits = "time_units"
    }

    public init(
        id: String,
        shape: [Int],
        axisNames: [String]? = nil,
        axisKinds: [AxisKind]? = nil,
        spacing: [Double],
        origin: [Double]? = nil,
        direction: [[Double]]? = nil,
        coordSystem: String = "LPS",
        units: String = "mm",
        timepoint: String? = nil,
        frameUID: String? = nil,
        timeValues: [Double]? = nil,
        timeUnits: String? = nil
    ) {
        let s = spacing.count
        self.id = id
        self.shape = shape
        let kinds = axisKinds ?? (Array(repeating: AxisKind.other, count: max(0, shape.count - s))
            + Array(repeating: AxisKind.spatial, count: s))
        self.axisKinds = kinds
        self.axisNames = axisNames ?? GridGeometry.defaultAxisNames(kinds)
        self.spacing = spacing
        self.origin = origin ?? Array(repeating: 0, count: s)
        self.direction = direction ?? (0..<s).map { r in (0..<s).map { c in r == c ? 1.0 : 0.0 } }
        self.coordSystem = coordSystem
        self.units = units
        self.timepoint = timepoint
        self.frameUID = frameUID
        self.timeValues = timeValues
        self.timeUnits = timeUnits
    }

    /// medh5's default axis names for a list of axis kinds: spatial axes are
    /// `z, y, x` (or `y, x`), a channel axis `c`, a time axis `t`.
    public static func defaultAxisNames(_ kinds: [AxisKind]) -> [String] {
        let nSpatial = kinds.filter { $0 == .spatial }.count
        var spatialNames = Array(["z", "y", "x"].suffix(nSpatial))
        if nSpatial > 3 { spatialNames = (0..<nSpatial).map { "s\($0)" } }
        var names: [String] = []
        var spatialIndex = 0
        var otherIndex = 0
        for kind in kinds {
            switch kind {
            case .spatial:
                names.append(spatialNames[spatialIndex])
                spatialIndex += 1
            case .channel: names.append("c")
            case .time: names.append("t")
            case .other:
                names.append("o\(otherIndex)")
                otherIndex += 1
            }
        }
        return names
    }

    // MARK: Axes

    /// The number of spatial axes, S (2 or 3).
    public var spatialRank: Int { spacing.count }

    public var is2D: Bool { spatialRank == 2 }

    /// Stored indices of the spatial axes (the trailing `S`).
    public var spatialAxes: [Int] {
        axisKinds.indices.filter { axisKinds[$0] == .spatial }
    }

    /// Extent of each spatial axis, in stored order.
    public var spatialShape: [Int] {
        Array(shape.suffix(spatialRank))
    }

    /// Extent of every axis before the spatial ones (channel, time, other).
    public var leadingShape: [Int] {
        Array(shape.prefix(max(0, shape.count - spatialRank)))
    }

    public var channelAxis: Int? { axisKinds.firstIndex(of: .channel) }
    public var timeAxis: Int? { axisKinds.firstIndex(of: .time) }

    /// Voxels in one spatial frame.
    public var spatialVoxelCount: Int { spatialShape.reduce(1, *) }

    /// Number of spatial frames (the product of the leading axes).
    public var frameCount: Int { leadingShape.reduce(1, *) }

    // MARK: Padded 3-D form

    /// The spatial shape padded to three axes: `(n0, n1, n2)`; `(1, n0, n1)`
    /// for a 2-D grid.
    public var paddedShape: SIMD3<Int> {
        let s = spatialShape
        if s.count >= 3 { return SIMD3(s[s.count - 3], s[s.count - 2], s[s.count - 1]) }
        if s.count == 2 { return SIMD3(1, s[0], s[1]) }
        if s.count == 1 { return SIMD3(1, 1, s[0]) }
        return SIMD3(1, 1, 1)
    }

    /// Spacing along the padded axes; the padding axis of a 2-D grid has 1.
    public var paddedSpacing: SIMD3<Double> {
        let s = spacing
        if s.count >= 3 { return SIMD3(s[s.count - 3], s[s.count - 2], s[s.count - 1]) }
        if s.count == 2 { return SIMD3(1, s[0], s[1]) }
        if s.count == 1 { return SIMD3(1, 1, s[0]) }
        return SIMD3(1, 1, 1)
    }

    /// World unit direction of each padded axis `(k0, k1, k2)`.
    public var axisDirections: [SIMD3<Double>] {
        let s = spatialRank
        func column(_ c: Int) -> SIMD3<Double> {
            var v = SIMD3<Double>(0, 0, 0)
            for r in 0..<min(3, s) where r < direction.count && c < direction[r].count {
                v[r] = direction[r][c]
            }
            return v
        }
        if s >= 3 { return [column(0), column(1), column(2)] }
        if s == 2 {
            let a = column(0), b = column(1)
            var n = simd_cross(a, b)
            if simd_length(n) < 1e-9 { n = SIMD3(0, 0, 1) }
            return [simd_normalize(n), a, b]
        }
        return [SIMD3(0, 0, 1), SIMD3(0, 1, 0), s == 1 ? column(0) : SIMD3(1, 0, 0)]
    }

    /// World coordinate of padded index `(0, 0, 0)`.
    public var paddedOrigin: SIMD3<Double> {
        var o = SIMD3<Double>(0, 0, 0)
        for r in 0..<min(3, origin.count) { o[r] = origin[r] }
        return o
    }

    /// Padded index → world, homogeneous (`simd` matrices are column-major:
    /// column `j` is the world step for one unit of `k_j`).
    public var indexToWorld: simd_double4x4 {
        let d = axisDirections
        let sp = paddedSpacing
        let o = paddedOrigin
        return simd_double4x4(columns: (
            SIMD4(d[0] * sp[0], 0),
            SIMD4(d[1] * sp[1], 0),
            SIMD4(d[2] * sp[2], 0),
            SIMD4(o, 1)
        ))
    }

    /// World → padded index.
    public var worldToIndex: simd_double4x4 { indexToWorld.inverse }

    /// Padded index → normalised 3-D texture coordinate (see the type's
    /// documentation for the texture layout).
    public var indexToTexture: simd_double4x4 {
        let n = SIMD3<Double>(paddedShape)
        // u = (k2 + 0.5)/n2, v = (k1 + 0.5)/n1, w = (k0 + 0.5)/n0
        return simd_double4x4(columns: (
            SIMD4(0, 0, 1 / n[0], 0),
            SIMD4(0, 1 / n[1], 0, 0),
            SIMD4(1 / n[2], 0, 0, 0),
            SIMD4(0.5 / n[2], 0.5 / n[1], 0.5 / n[0], 1)
        ))
    }

    /// World → normalised texture coordinate.
    public var worldToTexture: simd_double4x4 { indexToTexture * worldToIndex }

    /// Normalised texture coordinate → world.
    public var textureToWorld: simd_double4x4 { worldToTexture.inverse }

    // MARK: Points

    public func world(fromIndex k: SIMD3<Double>) -> SIMD3<Double> {
        let p = indexToWorld * SIMD4(k, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    public func index(fromWorld p: SIMD3<Double>) -> SIMD3<Double> {
        let k = worldToIndex * SIMD4(p, 1)
        return SIMD3(k.x, k.y, k.z)
    }

    /// The voxel whose cell `[k - 0.5, k + 0.5)` holds the continuous padded
    /// index, rounding half up as the spec's box convention does (§8.1), or
    /// `nil` outside the grid.
    public func voxel(containingIndex k: SIMD3<Double>) -> SIMD3<Int>? {
        let n = paddedShape
        var v = SIMD3<Int>(0, 0, 0)
        for a in 0..<3 {
            let r = Int((k[a] + 0.5).rounded(.down))
            if r < 0 || r >= n[a] { return nil }
            v[a] = r
        }
        return v
    }

    public func voxel(containingWorld p: SIMD3<Double>) -> SIMD3<Int>? {
        voxel(containingIndex: index(fromWorld: p))
    }

    /// Whether a continuous padded index lies in the volume's closed region
    /// `[-0.5, n - 0.5]` on every axis (spec §3.3 (2)).
    public func contains(index k: SIMD3<Double>, tolerance: Double = 1e-6) -> Bool {
        let n = SIMD3<Double>(paddedShape)
        for a in 0..<3 where k[a] < -0.5 - tolerance || k[a] > n[a] - 0.5 + tolerance {
            return false
        }
        return true
    }

    /// Linear offset of a padded voxel index within one spatial frame (C order).
    @inline(__always)
    public func linearOffset(_ v: SIMD3<Int>) -> Int {
        let n = paddedShape
        return (v[0] * n[1] + v[1]) * n[2] + v[2]
    }

    /// The eight world corners of the volume's region `[-0.5, n - 0.5]`.
    public var worldCorners: [SIMD3<Double>] {
        let n = SIMD3<Double>(paddedShape)
        var corners: [SIMD3<Double>] = []
        corners.reserveCapacity(8)
        for a in [-0.5, n[0] - 0.5] {
            for b in [-0.5, n[1] - 0.5] {
                for c in [-0.5, n[2] - 0.5] {
                    corners.append(world(fromIndex: SIMD3(a, b, c)))
                }
            }
        }
        return corners
    }

    /// Axis-aligned world bounds of the volume's region.
    public var worldBounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        let corners = worldCorners
        var lo = corners[0], hi = corners[0]
        for c in corners.dropFirst() {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        return (lo, hi)
    }

    /// World coordinate of the volume's centre.
    public var worldCenter: SIMD3<Double> {
        let n = SIMD3<Double>(paddedShape)
        return world(fromIndex: (n - 1) / 2)
    }

    /// Physical size of one voxel (`units³`, or `units²` for a 2-D grid).
    public var voxelVolume: Double { spacing.reduce(1, *) }

    /// Physical extent per spatial axis (`shape × spacing`).
    public var physicalSize: [Double] {
        zip(spatialShape, spacing).map { Double($0) * $1 }
    }

    /// Whether two grids' world coordinates agree without a transform
    /// (spec §3.3 (4)): one `frame_uid` (an absent one shares nothing), one
    /// `coord_system` and one spatial rank.
    public func sharesFrame(with other: GridGeometry) -> Bool {
        guard let a = frameUID, let b = other.frameUID else { return false }
        return a == b && coordSystem == other.coordSystem && spatialRank == other.spatialRank
    }

    /// Whether two grids describe the same lattice: same spatial shape and,
    /// to `tolerance`, the same index→world map.
    public func isCongruent(with other: GridGeometry, tolerance: Double = 1e-4) -> Bool {
        guard spatialShape == other.spatialShape else { return false }
        let a = indexToWorld, b = other.indexToWorld
        for c in 0..<4 {
            for r in 0..<4 where abs(a[c][r] - b[c][r]) > tolerance * max(1, abs(a[c][r])) {
                return false
            }
        }
        return true
    }

    /// A geometry for the same grid with only the spatial axes (the frame a
    /// texture holds).
    public var spatialOnly: GridGeometry {
        var g = self
        g.shape = spatialShape
        g.axisKinds = Array(repeating: .spatial, count: spatialRank)
        g.axisNames = Array(axisNames.suffix(spatialRank))
        g.timeValues = nil
        g.timeUnits = nil
        return g
    }

    /// The coordinate system this grid's world coordinates are in.
    public var coordinateSystem: CoordinateSystem { CoordinateSystem(coordSystem) }
}

extension simd_double4x4 {
    /// The same matrix in single precision, for GPU uniforms.
    public var float4x4: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(columns.0.x), Float(columns.0.y), Float(columns.0.z), Float(columns.0.w)),
            SIMD4<Float>(Float(columns.1.x), Float(columns.1.y), Float(columns.1.z), Float(columns.1.w)),
            SIMD4<Float>(Float(columns.2.x), Float(columns.2.y), Float(columns.2.z), Float(columns.2.w)),
            SIMD4<Float>(Float(columns.3.x), Float(columns.3.y), Float(columns.3.z), Float(columns.3.w))
        ))
    }

    /// Builds a homogeneous matrix from a row-major `(S+1) × (S+1)` matrix
    /// (S = 2 or 3), as medh5 stores an affine transform (spec §10.3). A 2-D
    /// affine acts on world `(x, y)` and leaves `z` alone.
    public init?(rowMajorHomogeneous m: [[Double]]) {
        let n = m.count
        guard n == 3 || n == 4, m.allSatisfy({ $0.count == n }) else { return nil }
        var out = matrix_identity_double4x4
        if n == 4 {
            for r in 0..<4 { for c in 0..<4 { out[c][r] = m[r][c] } }
        } else {
            for r in 0..<2 { for c in 0..<2 { out[c][r] = m[r][c] } }
            out[3][0] = m[0][2]
            out[3][1] = m[1][2]
        }
        self = out
    }

    /// Row-major nested arrays, the inverse of `init(rowMajorHomogeneous:)`
    /// for a 3-D affine.
    public var rowMajor: [[Double]] {
        (0..<4).map { r in (0..<4).map { c in self[c][r] } }
    }

    /// Applies the matrix to a point (w = 1).
    public func transformPoint(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let q = self * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z) / (q.w == 0 ? 1 : q.w)
    }

    /// Applies the linear part to a direction (w = 0).
    public func transformVector(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let q = self * SIMD4(v, 0)
        return SIMD3(q.x, q.y, q.z)
    }
}
