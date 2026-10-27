import Foundation
import simd
import MedH5Core

extension SegmentationModel {
    // MARK: Voxel queries

    /// The classes at a voxel, one per layer at most, in layer order
    /// (background and ignore excluded).
    public func labels(at k: SIMD3<Int>) -> [UInt16] {
        guard isInside(k) else { return [] }
        let li = linearIndex(k)
        let ignore = ignoreValue
        var out: [UInt16] = []
        for l in layers {
            let v = l.pointer(as: UInt16.self)[li]
            if v != 0 && v != ignore { out.append(v) }
        }
        return out
    }

    /// The classes at a world position (the voxel containing it), or `[]`
    /// outside the grid.
    public func labels(atWorld p: SIMD3<Double>) -> [UInt16] {
        guard let k = geometry.voxel(containingWorld: p) else { return [] }
        return labels(at: k)
    }

    /// Whether class `classID` holds voxel `k` (spec §7.6 `contains`).
    public func contains(_ classID: UInt16, at k: SIMD3<Int>) -> Bool {
        guard isInside(k), let l = layer(of: classID) else { return false }
        return layers[l].pointer(as: UInt16.self)[linearIndex(k)] == classID
    }

    /// Whether the voxel is in the ignore region (any layer holds the ignore value).
    public func isIgnored(at k: SIMD3<Int>) -> Bool {
        guard isInside(k) else { return false }
        let li = linearIndex(k)
        return layers.contains { $0.pointer(as: UInt16.self)[li] == ignoreValue }
    }

    /// The value of one layer at a voxel.
    public func value(layer: Int, at k: SIMD3<Int>) -> UInt16 {
        layers[layer].pointer(as: UInt16.self)[linearIndex(k)]
    }

    // MARK: Class extents and masks

    /// The tight box of a class's voxels, or `.empty` when it has none.
    public func bounds(of classID: UInt16, within box: VoxelBox? = nil) -> VoxelBox {
        guard let l = layer(of: classID) else { return .empty }
        let b = (box ?? VoxelBox(shape: shape)).clamped(to: shape)
        guard !b.isEmpty else { return .empty }
        let p = UnsafePointer(layers[l].pointer(as: UInt16.self))
        let n1 = shape.y, n2 = shape.z
        let partial = (try? Parallel.map(b.lower.x..<b.upper.x, grain: max(1, 32768 / max(1, b.size.y * b.size.z))) { slab -> VoxelBox in
            var lo = SIMD3<Int>(Int.max, Int.max, Int.max)
            var hi = SIMD3<Int>(Int.min, Int.min, Int.min)
            for k0 in slab {
                for k1 in b.lower.y..<b.upper.y {
                    let row = p + (k0 * n1 + k1) * n2
                    var x = b.lower.z
                    while x < b.upper.z && row[x] != classID { x += 1 }
                    if x == b.upper.z { continue }
                    var e = b.upper.z - 1
                    while row[e] != classID { e -= 1 }
                    lo = pointwiseMin(lo, SIMD3(k0, k1, x))
                    hi = pointwiseMax(hi, SIMD3(k0, k1, e))
                }
            }
            return lo.x == Int.max ? .empty : VoxelBox(lower: lo, upper: hi &+ 1)
        }) ?? []
        return partial.reduce(VoxelBox.empty) { $0.union($1) }
    }

    /// A class's voxels as a mask over `box` (its tight bounds by default).
    public func mask(of classID: UInt16, in box: VoxelBox? = nil) -> VoxelMask {
        let b = box ?? bounds(of: classID)
        var mask = VoxelMask(bounds: b)
        guard !b.isEmpty, let l = layer(of: classID) else { return mask }
        let p = UnsafePointer(layers[l].pointer(as: UInt16.self))
        let inside = b.clamped(to: shape)
        guard !inside.isEmpty else { return mask }
        let n1 = shape.y, n2 = shape.z, s = b.size
        mask.withUnsafeMutableBytes { m in
            Parallel.perform(inside.size.x) { i in
                let k0 = inside.lower.x + i
                for k1 in inside.lower.y..<inside.upper.y {
                    let row = p + (k0 * n1 + k1) * n2
                    let out = m + ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                    for x in inside.lower.z..<inside.upper.z { out[x] = row[x] == classID ? 1 : 0 }
                }
            }
        }
        return mask
    }

    /// Number of voxels of a class.
    public func voxelCount(of classID: UInt16) -> Int {
        guard let l = layer(of: classID) else { return 0 }
        let p = UnsafePointer(layers[l].pointer(as: UInt16.self))
        let n = voxelCount
        let counts = (try? Parallel.map(0..<n, grain: 1 << 18) { r -> Int in
            var c = 0
            for i in r where p[i] == classID { c += 1 }
            return c
        }) ?? []
        return counts.reduce(0, +)
    }

    /// The ignore region as a mask over the whole grid (or `box`).
    public func ignoreMask(in box: VoxelBox? = nil) -> VoxelMask {
        let b = (box ?? VoxelBox(shape: shape)).clamped(to: shape)
        var mask = VoxelMask(bounds: b)
        guard !b.isEmpty else { return mask }
        let ptrs = layers.map { UnsafePointer($0.pointer(as: UInt16.self)) }
        let ignore = ignoreValue
        let n1 = shape.y, n2 = shape.z, s = b.size
        mask.withUnsafeMutableBytes { m in
            ptrs.withUnsafeBufferPointer { lp in
                Parallel.perform(b.size.x) { i in
                    let k0 = b.lower.x + i
                    for k1 in b.lower.y..<b.upper.y {
                        let base = (k0 * n1 + k1) * n2
                        let out = m + ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                        for x in b.lower.z..<b.upper.z {
                            var ig: UInt8 = 0
                            for p in lp where p[base + x] == ignore { ig = 1; break }
                            out[x] = ig
                        }
                    }
                }
            }
        }
        return mask
    }

    // MARK: Flattening

    /// The segmentation as one labelmap, for formats that hold a single
    /// class per voxel (NIfTI export, a `labelmap` annotation).
    ///
    /// Where classes overlap, the first of `priority` wins; classes not in
    /// `priority` rank after it, in `classIDs` order. A voxel with no class
    /// and in the ignore region holds the ignore value.
    public func flattened(priority: [UInt16] = []) -> FlattenedLabelmap {
        var rank = [Int32](repeating: Int32.max, count: 65536)
        var r: Int32 = 0
        for id in priority where rank[Int(id)] == Int32.max {
            rank[Int(id)] = r
            r += 1
        }
        for id in classIDs where rank[Int(id)] == Int32.max {
            rank[Int(id)] = r
            r += 1
        }
        for c in classes where rank[Int(c.id)] == Int32.max {
            rank[Int(c.id)] = r
            r += 1
        }
        let out = VolumeData(scalarType: .uint16, shape: geometry.spatialShape)
        let dst = out.pointer(as: UInt16.self)
        let ptrs = layers.map { UnsafePointer($0.pointer(as: UInt16.self)) }
        let ignore = ignoreValue
        let n = voxelCount
        let overlapCounts: [Int] = ptrs.withUnsafeBufferPointer { lp in
            rank.withUnsafeBufferPointer { rk in
                (try? Parallel.map(0..<n, grain: 1 << 16) { range -> Int in
                    var overlaps = 0
                    for i in range {
                        var best: UInt16 = 0
                        var bestRank = Int32.max
                        var ignored = false
                        var classesHere = 0
                        for p in lp {
                            let v = p[i]
                            if v == 0 { continue }
                            if v == ignore { ignored = true; continue }
                            classesHere += 1
                            let rv = rk[Int(v)]
                            if best == 0 || rv < bestRank {
                                best = v
                                bestRank = rv
                            }
                        }
                        if classesHere > 1 { overlaps += 1 }
                        dst[i] = best != 0 ? best : (ignored ? ignore : 0)
                    }
                    return overlaps
                }) ?? []
            }
        }
        return FlattenedLabelmap(labels: out, overlappingVoxels: overlapCounts.reduce(0, +))
    }
}

/// A segmentation flattened to one class per voxel.
public struct FlattenedLabelmap: @unchecked Sendable {
    /// `uint16`, the grid's spatial shape.
    public var labels: VolumeData
    /// Voxels where more than one class was present (all but one were dropped).
    public var overlappingVoxels: Int
}
