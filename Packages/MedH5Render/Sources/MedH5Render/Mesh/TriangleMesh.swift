import Foundation
import simd

/// An indexed triangle mesh in world coordinates (mm): positions, optional
/// per-vertex normals, and counter-clockwise triangles (seen from outside, so
/// their right-hand normal points outwards).
public struct TriangleMesh: Sendable {
    /// Vertex positions in world coordinates (mm).
    public var positions: [SIMD3<Float>]
    /// Per-vertex unit normals, or empty (``computeNormals()`` fills them).
    public var normals: [SIMD3<Float>]
    /// Three vertex indices per triangle.
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    /// An empty mesh.
    public static let empty = TriangleMesh(positions: [], indices: [])

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    /// Area-weighted vertex normals from the triangles.
    public mutating func computeNormals() {
        var acc = [SIMD3<Double>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let pa = SIMD3<Double>(positions[a]), pb = SIMD3<Double>(positions[b]), pc = SIMD3<Double>(positions[c])
            let n = simd_cross(pb - pa, pc - pa)   // length = 2 × area
            acc[a] += n
            acc[b] += n
            acc[c] += n
        }
        normals = acc.map { v in
            let l = simd_length(v)
            return l > 0 ? SIMD3<Float>(v / l) : SIMD3<Float>(0, 0, 1)
        }
    }

    /// The mesh with normals computed when it has none.
    public func withNormals() -> TriangleMesh {
        if normals.count == positions.count { return self }
        var m = self
        m.computeNormals()
        return m
    }

    /// Total triangle area (mm²).
    public func surfaceArea() -> Double {
        var area = 0.0
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let pa = SIMD3<Double>(positions[Int(indices[t])])
            let pb = SIMD3<Double>(positions[Int(indices[t + 1])])
            let pc = SIMD3<Double>(positions[Int(indices[t + 2])])
            area += simd_length(simd_cross(pb - pa, pc - pa)) / 2
        }
        return area
    }

    /// The enclosed volume (mm³) by the divergence theorem: positive for a
    /// closed mesh with outward (counter-clockwise) triangles.
    public func enclosedVolume() -> Double {
        var v = 0.0
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let pa = SIMD3<Double>(positions[Int(indices[t])])
            let pb = SIMD3<Double>(positions[Int(indices[t + 1])])
            let pc = SIMD3<Double>(positions[Int(indices[t + 2])])
            v += simd_dot(pa, simd_cross(pb, pc)) / 6
        }
        return v
    }

    /// Edges not shared by exactly two triangles, and edges whose two
    /// triangles traverse them in the same direction (inconsistent
    /// orientation). A closed, consistently oriented mesh has none of
    /// either.
    public func topologyDefects() -> (boundaryOrNonManifoldEdges: Int, misorientedEdges: Int) {
        var directed = [UInt64: Int]()
        directed.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let v = [indices[t], indices[t + 1], indices[t + 2]]
            for e in 0..<3 {
                let a = UInt64(v[e]), b = UInt64(v[(e + 1) % 3])
                directed[(a << 32) | b, default: 0] += 1
            }
        }
        var bad = 0
        var misoriented = 0
        for (key, count) in directed {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            let reverse = directed[(b << 32) | a] ?? 0
            if count != 1 { misoriented += 1 }
            if count + reverse != 2 { bad += 1 }
        }
        return (bad, misoriented)
    }

    /// Whether every edge is shared by exactly two triangles traversing it
    /// in opposite directions.
    public var isClosed: Bool {
        let d = topologyDefects()
        return d.boundaryOrNonManifoldEdges == 0 && d.misorientedEdges == 0
    }

    /// The axis-aligned bounds of the vertices.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// The mesh mapped by an affine transform (normals by its inverse
    /// transpose; triangles flipped when it mirrors).
    public func transformed(by m: simd_double4x4) -> TriangleMesh {
        let positions = self.positions.map { SIMD3<Float>(m.transformPoint(SIMD3<Double>($0))) }
        let linear = simd_double3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        let normalMatrix = linear.inverse.transpose
        let normals = self.normals.map { n -> SIMD3<Float> in
            let v = normalMatrix * SIMD3<Double>(n)
            let l = simd_length(v)
            return l > 0 ? SIMD3<Float>(v / l) : n
        }
        var indices = self.indices
        if linear.determinant < 0 {
            for t in stride(from: 0, to: indices.count - 2, by: 3) { indices.swapAt(t + 1, t + 2) }
        }
        return TriangleMesh(positions: positions, normals: normals, indices: indices)
    }

    /// Appends another mesh.
    public mutating func append(_ other: TriangleMesh) {
        let base = UInt32(positions.count)
        let selfHasNormals = normals.count == positions.count
        let otherHasNormals = other.normals.count == other.positions.count
        if positions.isEmpty {
            normals = other.normals
        } else if selfHasNormals && otherHasNormals {
            normals += other.normals
        } else {
            normals = []
        }
        positions += other.positions
        indices += other.indices.map { $0 + base }
    }

    // MARK: Primitives

    /// A geodesic sphere: an icosahedron subdivided `subdivisions` times.
    public static func icosphere(center: SIMD3<Double>, radius: Double, subdivisions: Int = 3) -> TriangleMesh {
        let t = (1 + 5.0.squareRoot()) / 2
        var verts: [SIMD3<Double>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { simd_normalize($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        for _ in 0..<max(0, subdivisions) {
            var cache = [UInt64: Int]()
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let m = cache[key] { return m }
                verts.append(simd_normalize((verts[a] + verts[b]) / 2))
                cache[key] = verts.count - 1
                return verts.count - 1
            }
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for (a, b, c) in faces {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
            faces = next
        }
        let positions = verts.map { SIMD3<Float>(center + $0 * radius) }
        let normals = verts.map { SIMD3<Float>($0) }
        let indices = faces.flatMap { [UInt32($0.0), UInt32($0.1), UInt32($0.2)] }
        return TriangleMesh(positions: positions, normals: normals, indices: indices)
    }
}
