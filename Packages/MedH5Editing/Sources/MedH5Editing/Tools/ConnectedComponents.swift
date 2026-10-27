import Foundation
import simd
import MedH5Core

/// Connected components of a class or of any voxel set, for splitting a
/// class into instances, keeping the largest part, or removing islands.
///
/// Components are found on row runs with union–find: each run is joined to
/// the runs it touches in the previous rows (6-, 18- or 26-connectivity), so
/// the work is proportional to the number of runs, not of voxels.
public enum ConnectedComponents {
    /// The components of a class.
    public static func label(_ model: SegmentationModel, classID: UInt16, connectivity: Connectivity = .full,
                             control: OperationControl? = nil) throws -> ComponentLabeling {
        guard let l = model.layer(of: classID) else { throw EditingError.unknownClass(classID) }
        let box = model.bounds(of: classID)
        let p = UnsafePointer(model.layers[l].pointer(as: UInt16.self))
        let n1 = model.shape.y, n2 = model.shape.z
        var spans: [VoxelRegion.Span] = []
        if !box.isEmpty {
            // Runs per slab in parallel, concatenated in order.
            let parts = try Parallel.map(box.lower.x..<box.upper.x, control: control) { slab -> [VoxelRegion.Span] in
                var out: [VoxelRegion.Span] = []
                for k0 in slab {
                    for k1 in box.lower.y..<box.upper.y {
                        let row = p + (k0 * n1 + k1) * n2
                        var x = box.lower.z
                        while x < box.upper.z {
                            while x < box.upper.z && row[x] != classID { x += 1 }
                            if x >= box.upper.z { break }
                            let s = x
                            while x < box.upper.z && row[x] == classID { x += 1 }
                            out.append(VoxelRegion.Span(k0: k0, k1: k1, start: s, end: x))
                        }
                    }
                }
                return out
            }
            spans = parts.flatMap { $0 }
        }
        return try label(runs: spans, connectivity: connectivity, geometry: model.geometry, control: control)
    }

    /// The components of any voxel set.
    public static func label(_ set: some VoxelSet, connectivity: Connectivity = .full, geometry: GridGeometry,
                             control: OperationControl? = nil) throws -> ComponentLabeling {
        let b = set.bounds.clamped(to: geometry.paddedShape)
        var spans: [VoxelRegion.Span] = []
        if !b.isEmpty {
            for k0 in b.lower.x..<b.upper.x {
                for k1 in b.lower.y..<b.upper.y {
                    set.forEachRun(k0: k0, k1: k1) { s, e in
                        let s2 = max(s, b.lower.z), e2 = min(e, b.upper.z)
                        if s2 < e2 { spans.append(VoxelRegion.Span(k0: k0, k1: k1, start: s2, end: e2)) }
                    }
                }
            }
        }
        return try label(runs: spans, connectivity: connectivity, geometry: geometry, control: control)
    }

    /// Labels runs sorted in C order.
    static func label(runs: [VoxelRegion.Span], connectivity: Connectivity, geometry: GridGeometry,
                      control: OperationControl?) throws -> ComponentLabeling {
        let n = runs.count
        guard n > 0 else {
            return ComponentLabeling(runs: [], runLabels: [], components: [], geometry: geometry)
        }
        // Row index: the runs of row (k0, k1) are contiguous.
        var rowKeys: [Int64] = []
        var rowStarts: [Int] = []
        for (i, r) in runs.enumerated() {
            let key = Int64(r.k0) << 32 | Int64(r.k1)
            if rowKeys.last != key {
                rowKeys.append(key)
                rowStarts.append(i)
            }
        }
        rowStarts.append(n)
        func rowRange(_ k0: Int32, _ k1: Int32) -> Range<Int>? {
            let key = Int64(k0) << 32 | Int64(k1)
            var lo = 0, hi = rowKeys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if rowKeys[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            guard lo < rowKeys.count, rowKeys[lo] == key else { return nil }
            return rowStarts[lo]..<rowStarts[lo + 1]
        }
        var parent = [Int32](0..<Int32(n))
        func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x {
                parent[Int(x)] = parent[Int(parent[Int(x)])]
                x = parent[Int(x)]
            }
            return x
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb } }
        }
        let earlier = connectivity.rowNeighbours.filter { $0.dz < 0 || ($0.dz == 0 && $0.dy < 0) }
        for r in 0..<rowKeys.count {
            if r & 0x3FFF == 0, control.isCancelled { throw EditingError.cancelled }
            let current = rowStarts[r]..<rowStarts[r + 1]
            let k0 = runs[current.lowerBound].k0, k1 = runs[current.lowerBound].k1
            for nb in earlier {
                guard let other = rowRange(k0 + Int32(nb.dz), k1 + Int32(nb.dy)) else { continue }
                let reach = Int32(nb.reach)
                // Two-pointer sweep over the two sorted rows.
                var i = current.lowerBound, j = other.lowerBound
                while i < current.upperBound && j < other.upperBound {
                    let a = runs[i], b = runs[j]
                    if b.start < a.end + reach && a.start < b.end + reach { union(Int32(i), Int32(j)) }
                    if a.end + reach <= b.end { i += 1 } else { j += 1 }
                }
            }
        }
        // Collect components.
        var rootIndex = [Int32](repeating: -1, count: n)
        var stats: [(count: Int, lo: SIMD3<Int>, hi: SIMD3<Int>, sum: SIMD3<Double>)] = []
        var runComponent = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let root = Int(find(Int32(i)))
            var c = rootIndex[root]
            if c < 0 {
                c = Int32(stats.count)
                rootIndex[root] = c
                stats.append((0, SIMD3(Int.max, Int.max, Int.max), SIMD3(Int.min, Int.min, Int.min), .zero))
            }
            runComponent[i] = c
            let s = runs[i]
            let len = Int(s.end - s.start)
            stats[Int(c)].count += len
            stats[Int(c)].lo = pointwiseMin(stats[Int(c)].lo, SIMD3(Int(s.k0), Int(s.k1), Int(s.start)))
            stats[Int(c)].hi = pointwiseMax(stats[Int(c)].hi, SIMD3(Int(s.k0), Int(s.k1), Int(s.end) - 1))
            let midX = Double(Int(s.start) + Int(s.end) - 1) / 2
            stats[Int(c)].sum += SIMD3(Double(s.k0), Double(s.k1), midX) * Double(len)
        }
        // Order by size (descending), then by first voxel.
        let order = stats.indices.sorted { a, b in
            stats[a].count != stats[b].count ? stats[a].count > stats[b].count
                : (stats[a].lo.x, stats[a].lo.y, stats[a].lo.z) < (stats[b].lo.x, stats[b].lo.y, stats[b].lo.z)
        }
        var labelOf = [Int32](repeating: 0, count: stats.count)
        var components: [ComponentLabeling.Component] = []
        let voxelVolume = geometry.paddedVoxelVolume
        for (rank, c) in order.enumerated() {
            labelOf[c] = Int32(rank + 1)
            let s = stats[c]
            let centroid = s.sum / Double(s.count)
            components.append(.init(label: rank + 1, voxelCount: s.count, volume: Double(s.count) * voxelVolume,
                                    bounds: VoxelBox(lower: s.lo, upper: s.hi &+ 1),
                                    centroidIndex: centroid, centroidWorld: geometry.world(fromIndex: centroid)))
        }
        let runLabels = runComponent.map { labelOf[Int($0)] }
        return ComponentLabeling(runs: runs, runLabels: runLabels, components: components, geometry: geometry)
    }
}

/// The connected components of a voxel set.
public struct ComponentLabeling: Sendable {
    public struct Component: Sendable, Hashable {
        /// 1-based label; 1 is the largest component.
        public var label: Int
        public var voxelCount: Int
        /// Volume in units³ (area in units² on a 2-D grid).
        public var volume: Double
        public var bounds: VoxelBox
        public var centroidIndex: SIMD3<Double>
        public var centroidWorld: SIMD3<Double>
    }

    /// Row runs of the set, C order.
    public let runs: [VoxelRegion.Span]
    /// The component label of each run.
    public let runLabels: [Int32]
    /// Components, largest first (label = index + 1).
    public let components: [Component]
    public let geometry: GridGeometry

    public var count: Int { components.count }

    /// The voxels of one component.
    public func region(ofComponent label: Int) -> VoxelRegion {
        region(ofComponents: [label])
    }

    /// The voxels of several components.
    public func region(ofComponents labels: Set<Int>) -> VoxelRegion {
        var spans: [VoxelRegion.Span] = []
        for (i, s) in runs.enumerated() where labels.contains(Int(runLabels[i])) { spans.append(s) }
        return VoxelRegion(sortedSpans: spans)
    }

    /// A `uint32` volume of the grid's spatial shape holding each voxel's
    /// component label (0 outside the set).
    public func labelVolume() -> VolumeData {
        let out = VolumeData(scalarType: .uint32, shape: geometry.spatialShape)
        let p = out.pointer(as: UInt32.self)
        let n = geometry.paddedShape
        for (i, s) in runs.enumerated() {
            let base = (Int(s.k0) * n.y + Int(s.k1)) * n.z
            let label = UInt32(runLabels[i])
            for x in Int(s.start)..<Int(s.end) { p[base + x] = label }
        }
        return out
    }
}
