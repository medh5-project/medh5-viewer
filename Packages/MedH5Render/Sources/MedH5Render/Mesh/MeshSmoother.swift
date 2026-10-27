import Foundation
import simd

/// Laplacian and Taubin smoothing over a mesh's vertex adjacency
/// (umbrella operator, uniform weights), multi-threaded.
enum MeshSmoother {
    static func apply(_ smoothing: MeshSmoothing, to mesh: inout TriangleMesh) {
        switch smoothing {
        case .none:
            return
        case .laplacian(let iterations, let lambda):
            guard iterations > 0 else { return }
            let adjacency = Adjacency(mesh)
            for _ in 0..<iterations { step(&mesh.positions, adjacency, Float(lambda)) }
        case .taubin(let iterations, let lambda, let mu):
            guard iterations > 0 else { return }
            let adjacency = Adjacency(mesh)
            for _ in 0..<iterations {
                step(&mesh.positions, adjacency, Float(lambda))
                step(&mesh.positions, adjacency, Float(mu))
            }
        }
        mesh.normals = []
    }

    /// Compressed neighbour lists.
    struct Adjacency {
        var offsets: [Int32]
        var neighbours: [Int32]

        init(_ mesh: TriangleMesh) {
            let n = mesh.positions.count
            var degree = [Int32](repeating: 0, count: n + 1)
            for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                for k in 0..<3 { degree[Int(mesh.indices[t + k])] += 2 }
            }
            var offsets = [Int32](repeating: 0, count: n + 1)
            for i in 0..<n { offsets[i + 1] = offsets[i] + degree[i] }
            var fill = offsets
            var raw = [Int32](repeating: -1, count: Int(offsets[n]))
            for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let v = [Int32(mesh.indices[t]), Int32(mesh.indices[t + 1]), Int32(mesh.indices[t + 2])]
                for k in 0..<3 {
                    let a = Int(v[k])
                    raw[Int(fill[a])] = v[(k + 1) % 3]
                    raw[Int(fill[a]) + 1] = v[(k + 2) % 3]
                    fill[a] += 2
                }
            }
            // Deduplicate each vertex's list (each neighbour appears twice on a manifold).
            var compactOffsets = [Int32](repeating: 0, count: n + 1)
            var compact: [Int32] = []
            compact.reserveCapacity(raw.count / 2)
            for i in 0..<n {
                let slice = raw[Int(offsets[i])..<Int(offsets[i + 1])].sorted()
                var last: Int32 = -1
                for v in slice where v != last {
                    compact.append(v)
                    last = v
                }
                compactOffsets[i + 1] = Int32(compact.count)
            }
            self.offsets = compactOffsets
            self.neighbours = compact
        }
    }

    private static func step(_ positions: inout [SIMD3<Float>], _ adj: Adjacency, _ factor: Float) {
        let source = positions
        let count = positions.count
        positions.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { src in
                adj.offsets.withUnsafeBufferPointer { off in
                    adj.neighbours.withUnsafeBufferPointer { nb in
                        let chunk = 16384
                        DispatchQueue.concurrentPerform(iterations: max(1, (count + chunk - 1) / chunk)) { c in
                            for i in (c * chunk)..<min(count, c * chunk + chunk) {
                                let a = Int(off[i]), b = Int(off[i + 1])
                                guard b > a else { continue }
                                var mean = SIMD3<Float>(repeating: 0)
                                for k in a..<b { mean += src[Int(nb[k])] }
                                mean /= Float(b - a)
                                out[i] = src[i] + factor * (mean - src[i])
                            }
                        }
                    }
                }
            }
        }
    }
}
