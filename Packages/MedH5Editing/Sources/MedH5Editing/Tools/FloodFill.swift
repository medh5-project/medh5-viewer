import Foundation
import simd
import MedH5Core

/// Flood fill and region growing from a seed voxel, in one slice or in the
/// whole volume.
///
/// The fill is a scanline fill: it extends runs along the contiguous axis
/// and seeds the neighbouring rows, so a 3-D fill of the whole volume visits
/// each voxel a few times. Membership tests are memoised (each voxel's
/// criterion is evaluated once).
public enum FloodFill {
    /// Which voxels join the region.
    public enum Criterion: Sendable {
        /// Voxels whose labels equal the seed's ("bucket"): in every layer,
        /// or in one layer.
        case sameLabels(LabelScope)
        /// Voxels whose image value is within `tolerance` of the seed's.
        case intensityTolerance(ImageVolume, tolerance: Double, physical: Bool = true)
        /// Voxels whose image value lies in `range` (inclusive).
        case intensityRange(ImageVolume, range: ClosedRange<Double>, physical: Bool = true)
    }

    /// The layers a `.sameLabels` fill compares.
    public enum LabelScope: Sendable, Hashable {
        /// Every layer: the full set of labels must match.
        case allLayers
        /// One layer.
        case layer(Int)
        /// The layer of a class (the layer the fill will paint into).
        case layerOfClass(UInt16)
    }

    /// Where the fill may spread.
    public enum Extent: Sendable, Hashable {
        /// The whole volume (3-D).
        case volume
        /// The axis-aligned slice through the seed perpendicular to a padded
        /// axis (2-D). For a view, use `FloodFill.sliceAxis(forPlaneNormal:in:)`.
        case slice(axis: Int)
    }

    /// The padded axis a 2-D fill in a view with this plane normal runs
    /// across: the grid axis nearest to the normal.
    public static func sliceAxis(forPlaneNormal normal: SIMD3<Double>, in geometry: GridGeometry) -> Int {
        geometry.nearestAxis(to: normal)
    }

    /// The region a fill from `seed` covers.
    ///
    /// - Parameters:
    ///   - seed: a padded voxel index inside the grid.
    ///   - connectivity: `.face` (6 / 4 in a slice), `.edge` (18 / 8) or
    ///     `.full` (26 / 8).
    ///   - maxVoxels: stop when the region would exceed this many voxels;
    ///     the result then has `reachedLimit` set and holds the part filled.
    /// - Throws: `outsideGrid`, `invalidArgument`, `cancelled`.
    public static func region(in model: SegmentationModel, seed: SIMD3<Int>, criterion: Criterion,
                              extent: Extent = .volume, connectivity: Connectivity = .face,
                              maxVoxels: Int = Int.max, control: OperationControl? = nil) throws -> FillResult {
        guard model.isInside(seed) else { throw EditingError.outsideGrid(seed) }
        let domain = try FillDomain(shape: model.shape, extent: extent, seed: seed)
        let seedLinear = model.linearIndex(seed)
        let d = domain.domainCoordinates(of: seed)
        switch criterion {
        case .sameLabels(let scope):
            let indices: [Int]
            switch scope {
            case .allLayers: indices = Array(0..<model.layerCount)
            case .layer(let l):
                guard l >= 0 && l < model.layerCount else { throw EditingError.invalidLayer(l) }
                indices = [l]
            case .layerOfClass(let c):
                guard let l = model.layer(of: c) else { throw EditingError.unknownClass(c) }
                indices = [l]
            }
            let ptrs = indices.map { UnsafePointer(model.layers[$0].pointer(as: UInt16.self)) }
            let seedValues = ptrs.map { $0[seedLinear] }
            let acceptor = LabelAcceptor(domain: domain, layers: ptrs, values: seedValues)
            return try run(domain: domain, seed: d, acceptor: acceptor, connectivity: connectivity,
                           maxVoxels: maxVoxels, control: control)
        case let .intensityTolerance(image, tolerance, physical):
            let sampler = ImageSampler(image: image, target: model.geometry, physical: physical)
            let v = sampler.value(at: seed, linear: seedLinear)
            guard v.isFinite else { return FillResult.empty }
            let acceptor = IntensityAcceptor(domain: domain, sampler: sampler, lo: v - abs(tolerance), hi: v + abs(tolerance))
            return try run(domain: domain, seed: d, acceptor: acceptor, connectivity: connectivity,
                           maxVoxels: maxVoxels, control: control)
        case let .intensityRange(image, range, physical):
            let sampler = ImageSampler(image: image, target: model.geometry, physical: physical)
            let acceptor = IntensityAcceptor(domain: domain, sampler: sampler, lo: range.lowerBound, hi: range.upperBound)
            return try run(domain: domain, seed: d, acceptor: acceptor, connectivity: connectivity,
                           maxVoxels: maxVoxels, control: control)
        }
    }

    /// The region from a world position (the voxel containing it).
    public static func region(in model: SegmentationModel, seedWorld: SIMD3<Double>, criterion: Criterion,
                              extent: Extent = .volume, connectivity: Connectivity = .face,
                              maxVoxels: Int = Int.max, control: OperationControl? = nil) throws -> FillResult {
        guard let k = model.geometry.voxel(containingWorld: seedWorld) else {
            throw EditingError.invalidArgument("the seed lies outside the grid")
        }
        return try region(in: model, seed: k, criterion: criterion, extent: extent, connectivity: connectivity,
                          maxVoxels: maxVoxels, control: control)
    }

    /// Fills and computes the edit painting (or erasing…) the region.
    /// Returns an empty edit when the fill reached `maxVoxels` and
    /// `paintTruncated` is false.
    public static func edit(_ model: SegmentationModel, operation: VoxelOperation, seed: SIMD3<Int>,
                            criterion: Criterion, extent: Extent = .volume, connectivity: Connectivity = .face,
                            maxVoxels: Int = Int.max, paintTruncated: Bool = false,
                            options: PaintOptions = PaintOptions(),
                            control: OperationControl? = nil) throws -> (edit: VoxelEdit, fill: FillResult) {
        control.beginPhase(0, of: 2)
        let fill = try region(in: model, seed: seed, criterion: criterion, extent: extent,
                              connectivity: connectivity, maxVoxels: maxVoxels, control: control)
        if fill.voxelCount == 0 || (fill.reachedLimit && !paintTruncated) {
            return (VoxelEdit(shape: model.shape), fill)
        }
        control.beginPhase(1, of: 2)
        let edit = try model.makeEdit(operation, over: fill.region, options: options, control: control)
        return (edit, fill)
    }

    static func run<A: FillAcceptor>(domain: FillDomain, seed: SIMD3<Int>, acceptor: A, connectivity: Connectivity,
                                     maxVoxels: Int, control: OperationControl?) throws -> FillResult {
        // The state buffer is mapped lazily: a small fill touches few pages.
        let state = VolumeData(scalarType: .uint8, shape: [domain.dims.x * domain.dims.y * domain.dims.z])
        return try withExtendedLifetime(state) {
            var filler = ScanlineFiller(dims: domain.dims, state: state.pointer(as: UInt8.self), acceptor: acceptor,
                                        connectivity: connectivity, limit: maxVoxels)
            try filler.run(seeds: [seed], control: control)
            guard filler.count > 0 else {
                return FillResult(region: VoxelMask(bounds: .empty), voxelCount: 0, reachedLimit: filler.truncated)
            }
            let mask = filler.extractMask(paddedBox: domain.paddedBox(lo: filler.lo, hi: filler.hi))
            return FillResult(region: mask, voxelCount: filler.count, reachedLimit: filler.truncated)
        }
    }
}

/// The voxels a fill reached.
public struct FillResult: Sendable {
    /// The region, over its tight box.
    public var region: VoxelMask
    public var voxelCount: Int
    /// The fill stopped at its voxel limit (the region is incomplete — often
    /// a leak through a gap).
    public var reachedLimit: Bool

    static let empty = FillResult(region: VoxelMask(bounds: .empty), voxelCount: 0, reachedLimit: false)
}

// MARK: - Domain

/// The voxels a fill runs over, as a 3-D array `(d0, d1, d2)` whose `d2`
/// rows are contiguous in the domain buffer: the whole volume, or one
/// axis-aligned slice (`d0` of extent 1).
struct FillDomain {
    let dims: SIMD3<Int>
    /// Padded axis of each domain axis.
    let axes: SIMD3<Int>
    /// Padded voxel at domain `(0, 0, 0)`.
    let origin: SIMD3<Int>
    /// Layer linear stride of each domain axis.
    let strides: SIMD3<Int>
    let base: Int

    init(shape n: SIMD3<Int>, extent: FloodFill.Extent, seed: SIMD3<Int>) throws {
        let padStrides = SIMD3(n.y * n.z, n.z, 1)
        switch extent {
        case .volume:
            dims = n
            axes = SIMD3(0, 1, 2)
            origin = .zero
            strides = padStrides
            base = 0
        case .slice(let a):
            guard a >= 0 && a < 3 else { throw EditingError.invalidArgument("slice axis \(a) is not 0, 1 or 2") }
            let others = [0, 1, 2].filter { $0 != a }
            axes = SIMD3(a, others[0], others[1])
            dims = SIMD3(1, n[others[0]], n[others[1]])
            var o = SIMD3<Int>.zero
            o[a] = seed[a]
            origin = o
            strides = SIMD3(padStrides[a], padStrides[others[0]], padStrides[others[1]])
            base = seed[a] * padStrides[a]
        }
    }

    @inline(__always)
    func padded(_ d0: Int, _ d1: Int, _ d2: Int) -> SIMD3<Int> {
        var k = origin
        k[axes.x] += d0
        k[axes.y] += d1
        k[axes.z] += d2
        return k
    }

    @inline(__always)
    func linear(_ d0: Int, _ d1: Int, _ d2: Int) -> Int {
        base + d0 * strides.x + d1 * strides.y + d2 * strides.z
    }

    func domainCoordinates(of k: SIMD3<Int>) -> SIMD3<Int> {
        let r = k &- origin
        return SIMD3(r[axes.x], r[axes.y], r[axes.z])
    }

    /// The padded box of the domain box `lo...hi` (inclusive). Its C order
    /// matches the domain's C order, the fixed axis having extent 1.
    func paddedBox(lo: SIMD3<Int>, hi: SIMD3<Int>) -> VoxelBox {
        let a = padded(lo.x, lo.y, lo.z)
        let b = padded(hi.x, hi.y, hi.z)
        return VoxelBox(lower: pointwiseMin(a, b), upper: pointwiseMax(a, b) &+ 1)
    }
}

// MARK: - Acceptors

protocol FillAcceptor {
    func accepts(_ d0: Int, _ d1: Int, _ d2: Int) -> Bool
}

struct LabelAcceptor: FillAcceptor {
    let domain: FillDomain
    let layers: [UnsafePointer<UInt16>]
    let values: [UInt16]

    @inline(__always)
    func accepts(_ d0: Int, _ d1: Int, _ d2: Int) -> Bool {
        let li = domain.linear(d0, d1, d2)
        for i in 0..<layers.count where layers[i][li] != values[i] { return false }
        return true
    }
}

struct IntensityAcceptor: FillAcceptor {
    let domain: FillDomain
    let sampler: ImageSampler
    let lo: Double
    let hi: Double

    @inline(__always)
    func accepts(_ d0: Int, _ d1: Int, _ d2: Int) -> Bool {
        let v = sampler.value(at: domain.padded(d0, d1, d2), linear: domain.linear(d0, d1, d2))
        return v >= lo && v <= hi
    }
}

/// Accepts the voxels where a byte mask (domain C order) is zero.
struct ZeroMaskAcceptor: FillAcceptor {
    let mask: UnsafePointer<UInt8>
    let dims: SIMD3<Int>

    @inline(__always)
    func accepts(_ d0: Int, _ d1: Int, _ d2: Int) -> Bool {
        mask[(d0 * dims.y + d1) * dims.z + d2] == 0
    }
}

// MARK: - Scanline engine

/// Per-voxel fill state.
enum FillState {
    static let unknown: UInt8 = 0
    static let filled: UInt8 = 1
    static let rejected: UInt8 = 2
    static let accepted: UInt8 = 3
}

struct ScanlineFiller<A: FillAcceptor> {
    let dims: SIMD3<Int>
    let state: UnsafeMutablePointer<UInt8>
    let acceptor: A
    let neighbours: [(dz: Int, dy: Int, reach: Int)]
    let limit: Int
    private(set) var count = 0
    private(set) var truncated = false
    private(set) var lo = SIMD3<Int>(Int.max, Int.max, Int.max)
    private(set) var hi = SIMD3<Int>(Int.min, Int.min, Int.min)

    init(dims: SIMD3<Int>, state: UnsafeMutablePointer<UInt8>, acceptor: A, connectivity: Connectivity, limit: Int) {
        self.dims = dims
        self.state = state
        self.acceptor = acceptor
        self.neighbours = connectivity.rowNeighbours
        self.limit = limit
    }

    /// Whether the voxel is a candidate (accepted and not yet filled),
    /// evaluating and memoising the criterion on first visit.
    @inline(__always)
    private func candidate(_ di: Int, _ d0: Int, _ d1: Int, _ d2: Int) -> Bool {
        let s = state[di]
        if s == FillState.accepted { return true }
        if s != FillState.unknown { return false }
        let ok = acceptor.accepts(d0, d1, d2)
        state[di] = ok ? FillState.accepted : FillState.rejected
        return ok
    }

    mutating func run(seeds: [SIMD3<Int>], control: OperationControl?) throws {
        try control.checkCancellation()
        let d0n = dims.x, d1n = dims.y, d2n = dims.z
        var stack: [Int] = []
        stack.reserveCapacity(1024)
        for s in seeds where all(s .>= 0) && all(s .< dims) {
            stack.append((s.x * d1n + s.y) * d2n + s.z)
        }
        var iterations = 0
        while let di = stack.popLast() {
            iterations += 1
            if iterations & 0xFFF == 0, let control {
                if control.isCancelled { throw EditingError.cancelled }
                // The region's final size is unknown: report the share of the domain filled.
                control.reportPhase(Double(count) / Double(max(1, d0n * d1n * d2n)))
            }
            let row = di / d2n
            let x = di - row * d2n
            let z = row / d1n
            let y = row - z * d1n
            guard candidate(di, z, y, x) else { continue }
            let rowBase = row * d2n
            var xl = x, xr = x
            while xl > 0 && candidate(rowBase + xl - 1, z, y, xl - 1) { xl -= 1 }
            while xr < d2n - 1 && candidate(rowBase + xr + 1, z, y, xr + 1) { xr += 1 }
            let length = xr - xl + 1
            if count + length > limit {
                truncated = true
                return
            }
            (state + rowBase + xl).update(repeating: FillState.filled, count: length)
            count += length
            lo = pointwiseMin(lo, SIMD3(z, y, xl))
            hi = pointwiseMax(hi, SIMD3(z, y, xr))
            for nb in neighbours {
                let nz = z + nb.dz, ny = y + nb.dy
                if nz < 0 || nz >= d0n || ny < 0 || ny >= d1n { continue }
                let nBase = (nz * d1n + ny) * d2n
                var xx = max(0, xl - nb.reach)
                let xEnd = min(d2n - 1, xr + nb.reach)
                while xx <= xEnd {
                    if candidate(nBase + xx, nz, ny, xx) {
                        stack.append(nBase + xx)
                        xx += 1
                        while xx <= xEnd && candidate(nBase + xx, nz, ny, xx) { xx += 1 }
                    } else {
                        xx += 1
                    }
                }
            }
        }
    }

    /// The filled voxels within `lo...hi`, as a mask over `paddedBox` (whose
    /// C order matches the domain's).
    func extractMask(paddedBox: VoxelBox) -> VoxelMask {
        var mask = VoxelMask(bounds: paddedBox)
        let size = hi &- lo &+ 1
        let state = UnsafePointer(self.state)
        let d1n = dims.y, d2n = dims.z
        let lo = self.lo
        mask.withUnsafeMutableBytes { out in
            Parallel.perform(size.x) { i in
                let z = lo.x + i
                for y in lo.y..<(lo.y + size.y) {
                    let src = state + (z * d1n + y) * d2n + lo.z
                    let dst = out + ((z - lo.x) * size.y + (y - lo.y)) * size.z
                    for x in 0..<size.z { dst[x] = src[x] == FillState.filled ? 1 : 0 }
                }
            }
        }
        return mask
    }
}
