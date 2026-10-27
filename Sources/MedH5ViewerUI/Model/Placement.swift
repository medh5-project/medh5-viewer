import Foundation
import simd
import MedH5Kit
import MedH5Render

/// Where a layer sits relative to a view's reference frame (the world of the
/// base image's grid). Alignment is never assumed (spec §3.4): a layer in
/// another frame is drawn only through a transform the engine resolves.
enum PlacementState {
    /// The same grid, or another grid of the same frame: placed by its own
    /// affine.
    case identity
    /// Through a resolved transform: an affine as a matrix, anything else a
    /// displacement field sampled on the reference grid.
    case resolved(LayerPlacement, summary: String, isLinear: Bool)
    /// Being resolved.
    case pending
    /// No transform relates the frames (or it cannot be used here): not drawn.
    case refused(String)

    var isDrawable: Bool {
        switch self {
        case .identity, .resolved: return true
        case .pending, .refused: return false
        }
    }

    var placement: LayerPlacement {
        if case .resolved(let p, _, _) = self { return p }
        return .identity
    }

    /// The registration matrix, when the placement is linear.
    var matrix: simd_double4x4? {
        switch self {
        case .identity: return matrix_identity_double4x4
        case .resolved(let p, _, let linear): return linear ? (p.registration ?? matrix_identity_double4x4) : nil
        default: return nil
        }
    }

    /// How the inspector describes it.
    var summary: String {
        switch self {
        case .identity: return "Same frame"
        case .resolved(_, let s, _): return s
        case .pending: return "Resolving transform…"
        case .refused(let why): return why
        }
    }
}

/// Maps points of an annotation's frame into the reference frame.
struct PointMapper {
    var matrix: simd_double4x4?
    var field: (data: VolumeData, grid: GridGeometry)?

    static let identity = PointMapper(matrix: nil, field: nil)

    func map(_ p: SIMD3<Double>) -> SIMD3<Double> {
        if let matrix { return matrix.transformPoint(p) }
        if let field { return p + PlacementResolver.displacement(field.data, grid: field.grid, at: p) }
        return p
    }

    func map(_ points: [SIMD3<Double>]) -> [SIMD3<Double>] {
        (matrix == nil && field == nil) ? points : points.map(map)
    }

    var isIdentity: Bool { matrix == nil && field == nil }
}

/// What to resolve, and how to use the result.
enum PlacementResolver {
    /// The key that places an object on `objectGrid` (or in `objectFrame`)
    /// for sampling in the frame of `reference` (`x_object = T(x_reference)`),
    /// or `nil` when no transform is needed.
    static func samplingKey(reference: GridGeometry, objectGrid: GridGeometry?, objectFrame: String?) -> PlacementKey? {
        if let g = objectGrid {
            if g.id == reference.id || g.sharesFrame(with: reference) { return nil }
            return PlacementKey(from: reference.id, to: g.id, fieldGrid: reference.id)
        }
        if let f = objectFrame {
            if f == reference.frameUID { return nil }
            return PlacementKey(from: reference.id, to: f, fieldGrid: reference.id)
        }
        return nil
    }

    /// The key that maps an annotation's world points into the reference
    /// frame (`x_reference = T(x_annotation)`), or `nil` when none is needed.
    static func pointKey(reference: GridGeometry, annotationGrid: GridGeometry?, annotationFrame: String?) -> PlacementKey? {
        if let g = annotationGrid {
            if g.id == reference.id || g.sharesFrame(with: reference) { return nil }
            return PlacementKey(from: g.id, to: reference.id, fieldGrid: g.id)
        }
        if let f = annotationFrame {
            if f == reference.frameUID { return nil }
            return PlacementKey(from: f, to: reference.id, fieldGrid: nil)
        }
        return nil
    }

    /// The state for sampling, from the store.
    @MainActor
    static func samplingState(_ key: PlacementKey?, store: VolumeStore) -> PlacementState {
        guard let key else { return .identity }
        if let failure = store.failure(.placement(key)) { return .refused("Transform could not be resolved: \(failure)") }
        guard let r = store.ready(.placement(key), as: PlacementResource.self) else { return .pending }
        guard let t = r.transform else {
            return .refused("Not drawn: no transform relates \(key.to) to the reference frame of \(key.from)")
        }
        if t.isIdentity { return .identity }
        switch t.mapping {
        case .matrix(let m):
            return .resolved(LayerPlacement(registration: m), summary: r.summary, isLinear: true)
        case .field:
            guard let texture = r.fieldTexture else { return .refused("Not drawn: the displacement field could not be sampled") }
            return .resolved(LayerPlacement(displacement: texture), summary: r.summary + ", sampled field", isLinear: false)
        case .unsampled:
            return .refused("Not drawn: a non-linear transform without a field grid")
        }
    }

    /// The point mapper for an annotation, from the store (`nil` while
    /// pending or when refused, with the reason).
    @MainActor
    static func pointMapper(_ key: PlacementKey?, store: VolumeStore) -> (PointMapper?, String?) {
        guard let key else { return (.identity, nil) }
        if let failure = store.failure(.placement(key)) { return (nil, "Transform could not be resolved: \(failure)") }
        guard let r = store.ready(.placement(key), as: PlacementResource.self) else { return (nil, nil) }
        guard let t = r.transform else {
            return (nil, "Not drawn: no transform relates \(key.from) to the reference frame")
        }
        if t.isIdentity { return (.identity, nil) }
        switch t.mapping {
        case .matrix(let m): return (PointMapper(matrix: m, field: nil), nil)
        case .field(let d, let g): return (PointMapper(matrix: nil, field: (d, g)), nil)
        case .unsampled: return (nil, "Not drawn: a non-linear transform cannot be applied to world-space geometry without a grid")
        }
    }

    /// The subsampling step that keeps a sampled field at most ~128 voxels
    /// along each axis.
    static func fieldStep(for grid: GridGeometry?) -> Int {
        guard let grid else { return 1 }
        let n = grid.paddedShape
        return max(1, Int((Double(max(n.x, n.y, n.z)) / 128).rounded(.up)))
    }

    /// A displacement field `(n0, n1, n2, 3)` as a vector texture.
    static func fieldTexture(context: RenderContext, displacement: VolumeData, grid: GridGeometry) throws -> VolumeTexture {
        let g = grid.spatialOnly
        let n = g.paddedShape
        let count = n.x * n.y * n.z
        guard displacement.count == count * 3 else {
            throw StoreError.unsupported("displacement field of \(displacement.shape) does not match grid \(g.spatialShape)")
        }
        let planes = (0..<3).map { _ in VolumeData(scalarType: .float32, shape: g.spatialShape) }
        let src = displacement.converted(to: .float32)
        let s = src.pointer(as: Float.self)
        let dst = planes.map { $0.pointer(as: Float.self) }
        for i in 0..<count {
            dst[0][i] = s[i * 3]
            dst[1][i] = s[i * 3 + 1]
            dst[2][i] = s[i * 3 + 2]
        }
        return try withExtendedLifetime((src, planes)) {
            try VolumeTexture(context: context, vectorPlanes: planes, geometry: g)
        }
    }

    /// Trilinear displacement at a world point (clamped to the field's grid).
    static func displacement(_ data: VolumeData, grid: GridGeometry, at p: SIMD3<Double>) -> SIMD3<Double> {
        let n = grid.paddedShape
        guard data.count == n.x * n.y * n.z * 3 else { return .zero }
        var k = grid.index(fromWorld: p)
        guard k.x.isFinite && k.y.isFinite && k.z.isFinite else { return .zero }
        for a in 0..<3 { k[a] = min(max(0, k[a]), Double(n[a] - 1)) }
        let i0 = SIMD3<Int>(Int(k.x.rounded(.down)), Int(k.y.rounded(.down)), Int(k.z.rounded(.down)))
        let f = k - SIMD3<Double>(i0)
        var out = SIMD3<Double>.zero
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let j = SIMD3(min(i0.x + dz, n.x - 1), min(i0.y + dy, n.y - 1), min(i0.z + dx, n.z - 1))
                    let w = (dz == 0 ? 1 - f.x : f.x) * (dy == 0 ? 1 - f.y : f.y) * (dx == 0 ? 1 - f.z : f.z)
                    guard w > 0 else { continue }
                    let base = ((j.x * n.y + j.y) * n.z + j.z) * 3
                    out += w * SIMD3(data.value(at: base), data.value(at: base + 1), data.value(at: base + 2))
                }
            }
        }
        return out
    }
}
