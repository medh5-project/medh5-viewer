import Foundation
import simd
import MedH5Core

/// A paint brush: a disc in a slice plane or a sphere, with a radius in
/// world units (mm).
///
/// ## Which voxels a dab covers
/// - **Sphere**: voxels whose centre lies within `radius` of the dab centre.
/// - **Disc** in a plane through the dab centre with unit axes `right`,
///   `down` and normal `n = right × down`: voxels whose centre (a) lies
///   within half a voxel of the plane along `n` — the voxels whose cell the
///   plane cuts, i.e. exactly what a nearest-neighbour reslice of that plane
///   shows, one slice for an axis-aligned plane — and (b) projects into the
///   plane within `radius` of the centre. On a tie (a plane exactly between
///   two slices) the slice chosen is the one `floor(k + 0.5)` picks, as the
///   viewer's slice selection does.
///
/// Spacing may be anisotropic and the grid's direction arbitrary: the test
/// is made in world coordinates. When a dab covers no voxel centre (a brush
/// smaller than a voxel), it covers the voxel containing its centre.
///
/// `region(at:in:)` computes a dab as row spans: each row of voxels meets
/// the (convex) dab in one interval, found analytically and then checked
/// against the exact test above at its ends, so the region is exactly the
/// set `contains(voxel:center:in:)` defines.
public struct Brush: Sendable, Hashable {
    public enum Shape: Sendable, Hashable {
        /// A disc in the plane with these screen axes.
        case disc(PlaneAxes)
        /// A ball.
        case sphere
    }

    /// Radius in world units (mm).
    public var radius: Double
    public var shape: Shape

    public init(radius: Double, shape: Shape) {
        self.radius = radius
        self.shape = shape
    }

    /// A disc in a view's plane.
    public static func disc(radius: Double, plane: PlaneAxes) -> Brush {
        Brush(radius: radius, shape: .disc(plane))
    }

    public static func sphere(radius: Double) -> Brush {
        Brush(radius: radius, shape: .sphere)
    }

    // MARK: Stroke spacing

    /// The dab centres a stroke segment from `a` to `b` paints: evenly spaced
    /// at most `radius / 2` apart, excluding `a` (painted by the previous
    /// segment) and including `b`. Fast mouse motion therefore leaves no gaps.
    public func dabCenters(from a: SIMD3<Double>, to b: SIMD3<Double>) -> [SIMD3<Double>] {
        let d = simd_distance(a, b)
        let step = max(radius / 2, 1e-6)
        let n = max(1, Int((d / step).rounded(.up)))
        if d == 0 { return [b] }
        return (1...n).map { i in a + (b - a) * (Double(i) / Double(n)) }
    }

    // MARK: Membership

    /// The exact test: whether a dab centred at `center` covers voxel `k`.
    public func contains(voxel k: SIMD3<Int>, center: SIMD3<Double>, in geometry: GridGeometry) -> Bool {
        DabGeometry(brush: self, center: center, geometry: geometry).contains(k)
    }

    // MARK: Regions

    /// The voxels a dab centred at world point `center` covers.
    public func region(at center: SIMD3<Double>, in geometry: GridGeometry) -> VoxelRegion {
        let dab = DabGeometry(brush: self, center: center, geometry: geometry)
        let n = geometry.paddedShape
        let box = dab.indexBounds()
        var spans: [VoxelRegion.Span] = []
        if !box.isEmpty {
            spans.reserveCapacity(box.size.x * box.size.y)
            for k0 in box.lower.x..<box.upper.x {
                for k1 in box.lower.y..<box.upper.y {
                    if let (s, e) = dab.rowInterval(k0: k0, k1: k1, lo: 0, hi: n.z - 1) {
                        spans.append(VoxelRegion.Span(k0: k0, k1: k1, start: s, end: e + 1))
                    }
                }
            }
        }
        if spans.isEmpty, let k = geometry.voxel(containingWorld: center), dab.inSlab(k) {
            spans.append(VoxelRegion.Span(k0: k.x, k1: k.y, start: k.z, end: k.z + 1))
        }
        return VoxelRegion(sortedSpans: spans)
    }

    /// The union of dabs at several centres (one stroke segment).
    public func region(along centers: [SIMD3<Double>], in geometry: GridGeometry) -> VoxelRegion {
        if centers.count == 1 { return region(at: centers[0], in: geometry) }
        var spans: [VoxelRegion.Span] = []
        for c in centers { spans.append(contentsOf: region(at: c, in: geometry).spans) }
        return VoxelRegion(spans: spans)
    }
}

/// A dab's geometry in a grid's index space.
struct DabGeometry {
    let isDisc: Bool
    let radius2: Double
    let center: SIMD3<Double>
    let geometry: GridGeometry
    /// Index → world, linear part and origin.
    let m: simd_double3x3
    let origin: SIMD3<Double>
    let indexCenter: SIMD3<Double>
    // Disc only.
    let normal: SIMD3<Double>
    let right: SIMD3<Double>
    let down: SIMD3<Double>
    let halfThickness: Double
    /// +1 or −1, so that the slab test breaks ties toward the higher index of
    /// the axis most aligned with the normal (rounding half up).
    let tieSign: Double

    init(brush: Brush, center: SIMD3<Double>, geometry: GridGeometry) {
        let r = max(0, brush.radius)
        radius2 = r * r
        self.center = center
        self.geometry = geometry
        m = geometry.indexToWorldLinear
        origin = geometry.paddedOrigin
        indexCenter = geometry.index(fromWorld: center)
        switch brush.shape {
        case .sphere:
            isDisc = false
            normal = .zero
            right = .zero
            down = .zero
            halfThickness = 0
            tieSign = 1
        case .disc(let plane):
            isDisc = true
            let n = plane.normal
            normal = n
            right = plane.right
            down = plane.down
            halfThickness = geometry.voxelHalfExtent(along: n)
            let dots = [simd_dot(m.columns.0, n), simd_dot(m.columns.1, n), simd_dot(m.columns.2, n)]
            var best = 0
            for a in 1..<3 where abs(dots[a]) > abs(dots[best]) { best = a }
            tieSign = dots[best] < 0 ? -1 : 1
        }
    }

    @inline(__always)
    func offset(_ k: SIMD3<Int>) -> SIMD3<Double> {
        geometry.world(fromIndex: SIMD3<Double>(k)) - center
    }

    @inline(__always)
    func inSlab(_ k: SIMD3<Int>) -> Bool {
        guard isDisc else { return true }
        let d = tieSign * simd_dot(offset(k), normal)
        return d > -halfThickness && d <= halfThickness
    }

    @inline(__always)
    func contains(_ k: SIMD3<Int>) -> Bool {
        let q = offset(k)
        if !isDisc { return simd_length_squared(q) <= radius2 }
        let d = tieSign * simd_dot(q, normal)
        guard d > -halfThickness && d <= halfThickness else { return false }
        let u = simd_dot(q, right), v = simd_dot(q, down)
        return u * u + v * v <= radius2
    }

    /// The index box the dab may touch, clamped to the grid.
    func indexBounds() -> VoxelBox {
        let g = m.inverse.transpose // columns = rows of the inverse
        let rows = [g.columns.0, g.columns.1, g.columns.2]
        let r = radius2.squareRoot()
        var lo = SIMD3<Int>.zero, hi = SIMD3<Int>.zero
        for a in 0..<3 {
            let gi = rows[a]
            let extent: Double
            if isDisc {
                let ur = simd_dot(gi, right), ud = simd_dot(gi, down)
                extent = r * (ur * ur + ud * ud).squareRoot() + halfThickness * abs(simd_dot(gi, normal))
            } else {
                extent = r * simd_length(gi)
            }
            lo[a] = Int((indexCenter[a] - extent).rounded(.down)) - 1
            hi[a] = Int((indexCenter[a] + extent).rounded(.up)) + 2
        }
        return VoxelBox(lower: lo, upper: hi).clamped(to: geometry.paddedShape)
    }

    /// The interval of `k2` in `[lo, hi]` covered on row `(k0, k1)`, or nil.
    func rowInterval(k0: Int, k1: Int, lo: Int, hi: Int) -> (Int, Int)? {
        // Offset of the row's k2 = 0 voxel from the centre, and its step.
        let q0 = origin + m.columns.0 * Double(k0) + m.columns.1 * Double(k1) - center
        let step = m.columns.2
        var tLo = -Double.infinity, tHi = Double.infinity

        func clip(quadratic a: Double, _ b: Double, _ c: Double) -> Bool {
            // a t² + b t + c ≤ 0
            if a < 1e-14 {
                if abs(b) < 1e-14 { return c <= 1e-9 * max(1, radius2) }
                let t = -c / b
                if b > 0 { tHi = min(tHi, t) } else { tLo = max(tLo, t) }
                return true
            }
            let disc = b * b - 4 * a * c
            if disc < 0 {
                // Tangent within rounding: keep the vertex as a candidate.
                let t = -b / (2 * a)
                if disc > -1e-9 * max(1, b * b) {
                    tLo = max(tLo, t)
                    tHi = min(tHi, t)
                    return true
                }
                return false
            }
            let s = disc.squareRoot()
            tLo = max(tLo, (-b - s) / (2 * a))
            tHi = min(tHi, (-b + s) / (2 * a))
            return true
        }

        if isDisc {
            let qn = simd_dot(q0, normal), sn = simd_dot(step, normal)
            if abs(sn) < 1e-14 {
                let d = tieSign * qn
                if !(d > -halfThickness && d <= halfThickness) { return nil }
            } else {
                // −h < σ (qn + sn t) ≤ h
                let t1 = (-halfThickness / tieSign - qn) / sn
                let t2 = (halfThickness / tieSign - qn) / sn
                tLo = max(tLo, min(t1, t2))
                tHi = min(tHi, max(t1, t2))
            }
            let u0 = simd_dot(q0, right), v0 = simd_dot(q0, down)
            let al = simd_dot(step, right), be = simd_dot(step, down)
            if !clip(quadratic: al * al + be * be, 2 * (al * u0 + be * v0), u0 * u0 + v0 * v0 - radius2) { return nil }
        } else {
            if !clip(quadratic: simd_length_squared(step), 2 * simd_dot(q0, step), simd_length_squared(q0) - radius2) {
                return nil
            }
        }
        guard tLo <= tHi + 1 else { return nil }
        // Integer candidates, then exact refinement at both ends.
        var s = max(lo, Int((tLo - 1e-9).rounded(.up)))
        var e = min(hi, Int((tHi + 1e-9).rounded(.down)))
        let test = { (x: Int) in self.contains(SIMD3(k0, k1, x)) }
        if s > e {
            let mid = Int(((tLo + tHi) / 2).rounded())
            guard mid >= lo && mid <= hi && test(mid) else { return nil }
            s = mid
            e = mid
        }
        while s <= e && !test(s) { s += 1 }
        while e >= s && !test(e) { e -= 1 }
        guard s <= e else { return nil }
        while s - 1 >= lo && test(s - 1) { s -= 1 }
        while e + 1 <= hi && test(e + 1) { e += 1 }
        return (s, e)
    }
}
