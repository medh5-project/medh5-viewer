import Foundation
import simd
import MedH5Core

/// Size and position of one class.
public struct ClassStatistics: Sendable, Hashable {
    public var classID: UInt16
    public var voxelCount: Int
    /// Volume in units³ (mm³); on a 2-D grid, an area in units².
    public var volume: Double
    /// The tight index box (`.empty` when the class has no voxels).
    public var bounds: VoxelBox
    /// The box as medh5 stores it (spec §8.1, edges at ±0.5): `[[lo, hi], …]`
    /// per spatial axis in stored order; nil when empty.
    public var edgeBox: [[Double]]?
    /// Mean voxel centre, padded index coordinates.
    public var centroidIndex: SIMD3<Double>?
    /// Mean voxel centre, world coordinates.
    public var centroidWorld: SIMD3<Double>?
}

/// Statistics of image values over a set of voxels.
public struct IntensityStatistics: Sendable, Hashable {
    /// Voxels sampled (inside the image, finite values).
    public var count: Int
    public var mean: Double
    /// Population standard deviation.
    public var standardDeviation: Double
    public var minimum: Double
    public var maximum: Double
    /// The middle value (the mean of the two middle values for an even count).
    public var median: Double
    public var sum: Double

    public static let empty = IntensityStatistics(count: 0, mean: .nan, standardDeviation: .nan, minimum: .nan,
                                                  maximum: .nan, median: .nan, sum: 0)
}

extension SegmentationModel {
    /// Statistics of every class of the table (see `SegmentationStatistics`).
    public func classStatistics(control: OperationControl? = nil) throws -> [ClassStatistics] {
        try SegmentationStatistics.classStatistics(self, control: control)
    }
}

public enum SegmentationStatistics {
    /// Statistics of every class of the table (zero for classes without
    /// voxels), in one parallel pass over the layers.
    public static func classStatistics(_ model: SegmentationModel,
                                       control: OperationControl? = nil) throws -> [ClassStatistics] {
        let ids = model.classes.map(\.id)
        var slotOf = [Int32](repeating: -1, count: 65536)
        for (i, id) in ids.enumerated() { slotOf[Int(id)] = Int32(i) }
        let nClasses = ids.count
        let shape = model.shape
        let ptrs = model.layers.map { UnsafePointer($0.pointer(as: UInt16.self)) }
        struct Acc {
            var count = 0
            var sum = SIMD3<Double>.zero
            var lo = SIMD3<Int>(Int.max, Int.max, Int.max)
            var hi = SIMD3<Int>(Int.min, Int.min, Int.min)
        }
        let partials: [[Acc]] = try slotOf.withUnsafeBufferPointer { slots in
            try Parallel.map(0..<shape.x, control: control) { slab -> [Acc] in
                var acc = [Acc](repeating: Acc(), count: nClasses)
                for k0 in slab {
                    for k1 in 0..<shape.y {
                        let base = (k0 * shape.y + k1) * shape.z
                        for p in ptrs {
                            var x = 0
                            while x < shape.z {
                                let v = p[base + x]
                                let slot = Int(slots[Int(v)])
                                if v == 0 || slot < 0 {
                                    x += 1
                                    continue
                                }
                                // A run of the class along the row.
                                let s = x
                                while x < shape.z && p[base + x] == v { x += 1 }
                                let len = x - s
                                acc[slot].count += len
                                acc[slot].sum += SIMD3(Double(k0), Double(k1), Double(s + x - 1) / 2) * Double(len)
                                acc[slot].lo = pointwiseMin(acc[slot].lo, SIMD3(k0, k1, s))
                                acc[slot].hi = pointwiseMax(acc[slot].hi, SIMD3(k0, k1, x - 1))
                            }
                        }
                    }
                }
                return acc
            }
        }
        let voxelVolume = model.geometry.paddedVoxelVolume
        let rank = model.geometry.spatialRank
        return ids.enumerated().map { i, id in
            var t = Acc()
            for p in partials {
                let a = p[i]
                guard a.count > 0 else { continue }
                t.count += a.count
                t.sum += a.sum
                t.lo = pointwiseMin(t.lo, a.lo)
                t.hi = pointwiseMax(t.hi, a.hi)
            }
            guard t.count > 0 else {
                return ClassStatistics(classID: id, voxelCount: 0, volume: 0, bounds: .empty, edgeBox: nil,
                                       centroidIndex: nil, centroidWorld: nil)
            }
            let box = VoxelBox(lower: t.lo, upper: t.hi &+ 1)
            let c = t.sum / Double(t.count)
            return ClassStatistics(classID: id, voxelCount: t.count, volume: Double(t.count) * voxelVolume,
                                   bounds: box, edgeBox: box.edgeBounds(rank: rank),
                                   centroidIndex: c, centroidWorld: model.geometry.world(fromIndex: c))
        }
    }

    /// Statistics of one class.
    public static func classStatistics(_ model: SegmentationModel, classID: UInt16) throws -> ClassStatistics {
        guard model.layer(of: classID) != nil else { throw EditingError.unknownClass(classID) }
        let all = try classStatistics(model)
        return all.first { $0.classID == classID }!
    }

    /// Image statistics over a class's voxels. The image may be on any grid:
    /// each voxel samples the image voxel containing its centre (world
    /// position, nearest); voxels outside the image are skipped. Values are
    /// physical (rescaled) unless `physical` is false.
    public static func intensity(of classID: UInt16, in model: SegmentationModel, image: ImageVolume,
                                 physical: Bool = true, frame: [Int]? = nil,
                                 control: OperationControl? = nil) throws -> IntensityStatistics {
        guard model.layer(of: classID) != nil else { throw EditingError.unknownClass(classID) }
        let box = model.bounds(of: classID)
        guard !box.isEmpty else { return .empty }
        let region = model.mask(of: classID, in: box)
        return try intensity(over: region, grid: model.geometry, image: image, physical: physical, frame: frame,
                             control: control)
    }

    /// Image statistics over a voxel set of grid `grid`.
    public static func intensity(over region: some VoxelSet, grid: GridGeometry, image: ImageVolume,
                                 physical: Bool = true, frame: [Int]? = nil,
                                 control: OperationControl? = nil) throws -> IntensityStatistics {
        let sampler = ImageSampler(image: image, target: grid, frame: frame, physical: physical)
        let box = region.bounds.clamped(to: grid.paddedShape)
        guard !box.isEmpty else { return .empty }
        let shape = grid.paddedShape
        let kernel = IntensityKernel(sampler: sampler, region: region, box: box, shape: shape, control: control)
        return try sampler.volume.dispatch(kernel)
    }
}

/// Moments, extremes and the median of the sampled raw values.
private struct IntensityKernel<S: VoxelSet>: TypedKernel {
    let sampler: ImageSampler
    let region: S
    let box: VoxelBox
    let shape: SIMD3<Int>
    let control: OperationControl?

    struct Partial {
        var n = 0
        var mean = 0.0
        var m2 = 0.0
        var lo = Double.infinity
        var hi = -Double.infinity
        var sum = 0.0
        var values: [Double] = []
        var histogram: [Int32] = []

        mutating func add(_ v: Double) {
            n += 1
            sum += v
            let d = v - mean
            mean += d / Double(n)
            m2 += d * (v - mean)
            if v < lo { lo = v }
            if v > hi { hi = v }
        }

        mutating func merge(_ o: Partial) {
            values.append(contentsOf: o.values)
            if histogram.isEmpty {
                histogram = o.histogram
            } else if !o.histogram.isEmpty {
                for i in 0..<o.histogram.count { histogram[i] += o.histogram[i] }
            }
            guard o.n > 0 else { return }
            guard n > 0 else {
                (n, mean, m2, lo, hi, sum) = (o.n, o.mean, o.m2, o.lo, o.hi, o.sum)
                return
            }
            let total = n + o.n
            let d = o.mean - mean
            mean += d * Double(o.n) / Double(total)
            m2 += o.m2 + d * d * Double(n) * Double(o.n) / Double(total)
            n = total
            lo = min(lo, o.lo)
            hi = max(hi, o.hi)
            sum += o.sum
        }
    }

    func run<T: VoxelScalar>(_ values: UnsafePointer<T>) throws -> IntensityStatistics {
        // Integer types of at most 16 bits: exact median from a histogram of raw values.
        let st = T.scalarType
        let histogramOffset: Int? = switch st {
        case .bool, .uint8, .uint16: 0
        case .int8: 128
        case .int16: 32768
        default: nil
        }
        let bins = st.byteSize == 1 ? 256 : 65536
        let slope = sampler.slope, intercept = sampler.intercept
        let sampler = self.sampler, region = self.region, box = self.box, shape = self.shape
        let partials = try Parallel.map(box.lower.x..<box.upper.x, control: control) { slab -> Partial in
            var p = Partial()
            if histogramOffset != nil { p.histogram = [Int32](repeating: 0, count: bins) }
            for k0 in slab {
                for k1 in box.lower.y..<box.upper.y {
                    let base = (k0 * shape.y + k1) * shape.z
                    region.forEachRun(k0: k0, k1: k1) { s, e in
                        for x in max(s, box.lower.z)..<min(e, box.upper.z) {
                            let li = base + x
                            let i = sampler.isAligned ? li : sampler.imageIndex(for: SIMD3(k0, k1, x), linear: li)
                            if i < 0 { continue }
                            let raw = values[i]
                            let v = raw.doubleValue * slope + intercept
                            guard v.isFinite else { continue }
                            p.add(v)
                            if let off = histogramOffset {
                                p.histogram[Int(raw.doubleValue) + off] += 1
                            } else {
                                p.values.append(v)
                            }
                        }
                    }
                }
            }
            return p
        }
        var total = Partial()
        for p in partials { total.merge(p) }
        guard total.n > 0 else { return .empty }
        let median: Double
        if let off = histogramOffset {
            // Raw values are integers; the k-th smallest by walking the histogram.
            func kth(_ k: Int) -> Double {
                var acc = 0
                for (b, c) in total.histogram.enumerated() {
                    acc += Int(c)
                    if acc > k { return Double(b - off) * slope + intercept }
                }
                return total.hi
            }
            let n = total.n
            let a = kth((n - 1) / 2), b = kth(n / 2)
            // With a negative slope the order reverses, but the middle pair is the same.
            median = (a + b) / 2
        } else {
            median = medianOf(&total.values)
        }
        return IntensityStatistics(count: total.n, mean: total.mean,
                                   standardDeviation: (total.m2 / Double(total.n)).squareRoot(),
                                   minimum: total.lo, maximum: total.hi, median: median, sum: total.sum)
    }
}

/// The median of `values` (reordered in place), by quickselect.
func medianOf(_ values: inout [Double]) -> Double {
    let n = values.count
    guard n > 0 else { return .nan }
    let hi = select(&values, n / 2)
    if n % 2 == 1 { return hi }
    // The largest of the lower half.
    var lo = -Double.infinity
    for i in 0..<(n / 2) where values[i] > lo { lo = values[i] }
    return (lo + hi) / 2
}

/// Rearranges `a` so that `a[k]` is the k-th smallest, smaller values before it.
func select(_ a: inout [Double], _ k: Int) -> Double {
    var lo = 0, hi = a.count - 1
    var seed: UInt64 = 0x9E3779B97F4A7C15
    while lo < hi {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let pivotIndex = lo + Int(seed >> 33) % (hi - lo + 1)
        let pivot = a[pivotIndex]
        // Three-way partition.
        var lt = lo, i = lo, gt = hi
        while i <= gt {
            if a[i] < pivot {
                a.swapAt(lt, i)
                lt += 1
                i += 1
            } else if a[i] > pivot {
                a.swapAt(i, gt)
                gt -= 1
            } else {
                i += 1
            }
        }
        if k < lt { hi = lt - 1 } else if k > gt { lo = gt + 1 } else { return a[k] }
    }
    return a[k]
}
