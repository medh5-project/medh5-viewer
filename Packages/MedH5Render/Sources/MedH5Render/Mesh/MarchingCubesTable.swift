import Foundation

/// The marching-cubes case table, generated rather than transcribed.
///
/// Cube corners are numbered by bits `(x, y, z)` (corner `c` sits at
/// `(c & 1, c >> 1 & 1, c >> 2 & 1)`), edges join corners differing in one
/// bit. For each of the 256 inside/outside configurations the table is built
/// by walking every face counter-clockwise (seen from outside the cube) and
/// joining each exit crossing to the entry crossing before it — which cuts
/// off each run of inside corners, so ambiguous faces separate their inside
/// corners. Each crossing is the end of one face segment and the start of
/// another, so the segments chain into closed loops; each loop is
/// triangulated as a fan, wound so the normal points from inside (values at
/// or above the iso-level) to outside.
///
/// Because a face's segments depend only on its own four corners, two cubes
/// sharing a face make the same choice there: the surface is watertight and
/// consistently oriented.
enum MarchingCubesTable {
    /// Corner pairs of the 12 edges: x edges, then y edges, then z edges.
    static let edgeCorners: [(Int, Int)] = [
        (0, 1), (2, 3), (4, 5), (6, 7),
        (0, 2), (1, 3), (4, 6), (5, 7),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    /// For each edge, the offset `(dx, dy, dz)` of its lower corner and its
    /// axis (0 = x, 1 = y, 2 = z).
    static let edgeOwner: [(dx: Int, dy: Int, dz: Int, axis: Int)] = edgeCorners.map { a, b in
        let axis = (a ^ b) == 1 ? 0 : ((a ^ b) == 2 ? 1 : 2)
        let lower = min(a, b)
        return (lower & 1, (lower >> 1) & 1, (lower >> 2) & 1, axis)
    }

    /// Faces as corner loops, counter-clockwise seen from outside the cube.
    static let faces: [[Int]] = [
        [0, 4, 6, 2],   // x = 0
        [1, 3, 7, 5],   // x = 1
        [0, 1, 5, 4],   // y = 0
        [2, 6, 7, 3],   // y = 1
        [0, 2, 3, 1],   // z = 0
        [4, 5, 7, 6],   // z = 1
    ]

    /// Triangles (edge index triples, flattened) per case.
    static let triangles: [[UInt8]] = (0..<256).map { generate(case: $0) }

    private static func edgeIndex(_ a: Int, _ b: Int) -> Int {
        edgeCorners.firstIndex { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }!
    }

    private static func generate(case mask: Int) -> [UInt8] {
        func inside(_ c: Int) -> Bool { (mask >> c) & 1 == 1 }
        var next = [Int: Int]()   // segment start edge -> end edge
        for face in faces {
            var exits: [(step: Int, edge: Int)] = []
            var entries: [(step: Int, edge: Int)] = []
            for i in 0..<4 {
                let a = face[i], b = face[(i + 1) % 4]
                if inside(a) && !inside(b) { exits.append((i, edgeIndex(a, b))) }
                if !inside(a) && inside(b) { entries.append((i, edgeIndex(a, b))) }
            }
            for exit in exits {
                // The entry immediately before this exit, cyclically.
                func distance(_ entry: (step: Int, edge: Int)) -> Int { (exit.step - entry.step + 4) % 4 }
                let entry = entries.min { distance($0) < distance($1) }!
                next[exit.edge] = entry.edge
            }
        }
        var result: [UInt8] = []
        var remaining = next
        while let start = remaining.keys.min() {
            var loop = [start]
            var e = remaining.removeValue(forKey: start)!
            while e != start {
                loop.append(e)
                e = remaining.removeValue(forKey: e)!
            }
            // The chained loop winds around the inside; reverse it for outward normals.
            loop.reverse()
            for i in 1..<(loop.count - 1) {
                result += [UInt8(loop[0]), UInt8(loop[i]), UInt8(loop[i + 1])]
            }
        }
        return result
    }
}
