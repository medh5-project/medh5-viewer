import Foundation
import simd
import MedH5Core

/// Intersections of planes with meshes, boxes and grids, for drawing 3-D
/// geometry on slices.
public enum PlaneIntersection {
    /// The segments where `plane` cuts the triangles of `mesh`: points `2i`
    /// and `2i + 1` are the ends of segment `i`. A vertex exactly on the plane
    /// counts as in front of it, so every crossing is found once and shared
    /// edges give bit-identical points (contours chain exactly).
    public static func segments(mesh: TriangleMesh, plane: Plane) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        let triangles = 0..<mesh.triangleCount
        appendSegments(mesh: mesh, triangles: triangles, plane: plane, into: &out)
        return out
    }

    static func appendSegments<S: Sequence>(mesh: TriangleMesh, triangles: S, plane: Plane,
                                            into out: inout [SIMD3<Double>]) where S.Element == Int {
        let n = plane.normal
        let o = simd_dot(plane.point, n)
        for t in triangles {
            let i0 = mesh.indices[3 * t], i1 = mesh.indices[3 * t + 1], i2 = mesh.indices[3 * t + 2]
            let p0 = SIMD3<Double>(mesh.positions[Int(i0)])
            let p1 = SIMD3<Double>(mesh.positions[Int(i1)])
            let p2 = SIMD3<Double>(mesh.positions[Int(i2)])
            let d0 = simd_dot(p0, n) - o, d1 = simd_dot(p1, n) - o, d2 = simd_dot(p2, n) - o
            let s0 = d0 >= 0, s1 = d1 >= 0, s2 = d2 >= 0
            if s0 == s1 && s1 == s2 { continue }
            var found = 0
            func edge(_ ia: UInt32, _ pa: SIMD3<Double>, _ da: Double, _ ib: UInt32, _ pb: SIMD3<Double>, _ db: Double) {
                // Canonical order (lower vertex index first) makes the point bit-identical
                // for both triangles sharing the edge.
                if ia < ib {
                    out.append(pa + (pb - pa) * (da / (da - db)))
                } else {
                    out.append(pb + (pa - pb) * (db / (db - da)))
                }
                found += 1
            }
            if s0 != s1 { edge(i0, p0, d0, i1, p1, d1) }
            if s1 != s2 { edge(i1, p1, d1, i2, p2, d2) }
            if s2 != s0 { edge(i2, p2, d2, i0, p0, d0) }
            assert(found == 2)
        }
    }

    /// Chains segments (pairs of points) into polylines by joining equal end
    /// points (within `tolerance`). A chain that returns to its start is
    /// closed (the first point is not repeated).
    public static func polylines(fromSegments points: [SIMD3<Double>],
                                 tolerance: Double = 1e-6) -> [(points: [SIMD3<Double>], closed: Bool)] {
        let count = points.count / 2
        guard count > 0 else { return [] }
        func key(_ p: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3<Int64>(Int64((p.x / tolerance).rounded()), Int64((p.y / tolerance).rounded()),
                         Int64((p.z / tolerance).rounded()))
        }
        var ends = [SIMD3<Int64>: [Int]]()   // point key -> segment end ids (2 * segment + end)
        ends.reserveCapacity(points.count)
        for i in 0..<points.count { ends[key(points[i]), default: []].append(i) }
        var used = [Bool](repeating: false, count: count)
        var result: [(points: [SIMD3<Double>], closed: Bool)] = []

        func next(from endID: Int) -> Int? {
            // The other segment end at the same point as `endID`.
            guard let list = ends[key(points[endID])] else { return nil }
            for e in list where e != endID && !used[e / 2] { return e }
            return nil
        }

        for s in 0..<count where !used[s] {
            used[s] = true
            var chain = [points[2 * s], points[2 * s + 1]]
            // Extend forwards from the end of segment s.
            var tail = 2 * s + 1
            var closed = false
            while let e = next(from: tail) {
                let seg = e / 2
                used[seg] = true
                let other = e ^ 1
                if key(points[other]) == key(chain[0]) {
                    closed = true
                    break
                }
                chain.append(points[other])
                tail = other
            }
            if !closed {
                // Extend backwards from the start.
                var head = 2 * s
                var front: [SIMD3<Double>] = []
                while let e = next(from: head) {
                    used[e / 2] = true
                    let other = e ^ 1
                    front.append(points[other])
                    head = other
                }
                chain = front.reversed() + chain
            }
            result.append((chain, closed))
        }
        return result
    }

    /// The convex polygon where `plane` cuts `box`, ordered around the
    /// normal (counter-clockwise seen from the viewer), or empty.
    public static func polygon(box: OrientedBox, plane: Plane) -> [SIMD3<Double>] {
        let corners = box.corners
        let d = corners.map { plane.signedDistance($0) }
        var pts: [SIMD3<Double>] = []
        for (a, b) in OrientedBox.edges {
            let da = d[a], db = d[b]
            if da == 0 { pts.append(corners[a]) }
            if (da < 0 && db > 0) || (da > 0 && db < 0) {
                pts.append(corners[a] + (corners[b] - corners[a]) * (da / (da - db)))
            }
        }
        // A corner on the plane is found once per edge it starts; dedupe.
        var unique: [SIMD3<Double>] = []
        for p in pts where !unique.contains(where: { simd_distance($0, p) < 1e-9 }) { unique.append(p) }
        return orderAround(unique, normal: plane.normal)
    }

    /// The polygon where `plane` cuts the region of `grid`
    /// (`[-0.5, n - 0.5]` in index space).
    public static func polygon(grid: GridGeometry, plane: Plane) -> [SIMD3<Double>] {
        let n = SIMD3<Double>(grid.paddedShape)
        let box = OrientedBox(indexLower: SIMD3(repeating: -0.5), indexUpper: n - 0.5, grid: grid)
        return polygon(box: box, plane: plane)
    }

    /// The outline of `box` projected onto `plane` (the convex hull of its
    /// projected corners), counter-clockwise around the normal.
    public static func projectedOutline(box: OrientedBox, plane: Plane) -> [SIMD3<Double>] {
        let (u, v) = basis(plane.normal)
        let pts = box.corners.map { plane.project($0) }
        let flat = pts.map { SIMD2(simd_dot($0 - plane.point, u), simd_dot($0 - plane.point, v)) }
        let hull = convexHull(flat)
        return hull.map { plane.point + u * $0.x + v * $0.y }
    }

    // MARK: Helpers

    /// Two unit vectors completing `n` to a right-handed basis `(u, v, n)`.
    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = simd_normalize(simd_cross(n, a))
        let v = simd_cross(n, u)
        return (u, v)
    }

    static func orderAround(_ pts: [SIMD3<Double>], normal: SIMD3<Double>) -> [SIMD3<Double>] {
        guard pts.count > 2 else { return pts }
        let c = pts.reduce(SIMD3<Double>.zero, +) / Double(pts.count)
        let (u, v) = basis(normal)
        return pts.sorted { a, b in
            atan2(simd_dot(a - c, v), simd_dot(a - c, u)) < atan2(simd_dot(b - c, v), simd_dot(b - c, u))
        }
    }

    /// Andrew's monotone chain, counter-clockwise.
    static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 1e-12 { lower.removeLast() }
            lower.append(q)
        }
        var upper: [SIMD2<Double>] = []
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 1e-12 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// Cuts one mesh by many parallel planes quickly (scrolling through
/// slices): triangles are bucketed by their extent along the plane normal,
/// so each query tests only the triangles near the plane. The buckets are
/// rebuilt when the normal changes.
public final class MeshSlicer: @unchecked Sendable {
    /// The mesh (world coordinates).
    public let mesh: TriangleMesh

    private let lock = NSLock()
    private var normal: SIMD3<Double>?
    private var low = 0.0
    private var width = 1.0
    private var buckets: [[Int32]] = []

    /// A slicer for a mesh in world coordinates.
    public init(mesh: TriangleMesh) {
        self.mesh = mesh
    }

    /// The segments where `plane` cuts the mesh (pairs of points).
    public func segments(on plane: Plane) -> [SIMD3<Double>] {
        lock.lock()
        defer { lock.unlock() }
        guard mesh.triangleCount > 0 else { return [] }
        if normal == nil || simd_dot(normal!, plane.normal) < 1 - 1e-12 { rebuild(for: plane.normal) }
        let d = simd_dot(plane.point, plane.normal)
        let b = Int(((d - low) / width).rounded(.down))
        guard b >= 0, b < buckets.count else { return [] }
        var out: [SIMD3<Double>] = []
        PlaneIntersection.appendSegments(mesh: mesh, triangles: buckets[b].lazy.map { Int($0) }, plane: plane, into: &out)
        return out
    }

    /// The cut chained into polylines.
    public func contours(on plane: Plane) -> [(points: [SIMD3<Double>], closed: Bool)] {
        PlaneIntersection.polylines(fromSegments: segments(on: plane))
    }

    private func rebuild(for n: SIMD3<Double>) {
        normal = n
        let count = mesh.triangleCount
        var lo = [Double](repeating: 0, count: count)
        var hi = [Double](repeating: 0, count: count)
        var gmin = Double.infinity, gmax = -Double.infinity
        for t in 0..<count {
            let a = simd_dot(SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t])]), n)
            let b = simd_dot(SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 1])]), n)
            let c = simd_dot(SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 2])]), n)
            lo[t] = min(a, min(b, c))
            hi[t] = max(a, max(b, c))
            gmin = min(gmin, lo[t])
            gmax = max(gmax, hi[t])
        }
        let bucketCount = max(1, min(8192, count / 4))
        low = gmin
        width = max(1e-9, (gmax - gmin) / Double(bucketCount)) * (1 + 1e-9)
        buckets = [[Int32]](repeating: [], count: bucketCount)
        for t in 0..<count {
            let b0 = max(0, min(bucketCount - 1, Int(((lo[t] - low) / width).rounded(.down))))
            let b1 = max(0, min(bucketCount - 1, Int(((hi[t] - low) / width).rounded(.down))))
            for b in b0...b1 { buckets[b].append(Int32(t)) }
        }
    }
}
