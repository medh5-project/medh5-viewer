import Foundation
import simd
import MedH5Core

/// Mesh smoothing applied after surface extraction.
public enum MeshSmoothing: Sendable, Hashable {
    case none
    /// Laplacian smoothing: each iteration moves vertices `lambda` of the way
    /// to their neighbours' mean (shrinks the surface).
    case laplacian(iterations: Int, lambda: Double)
    /// Taubin λ|μ smoothing: alternating shrink (`lambda` > 0) and inflate
    /// (`mu` < −λ) steps, which smooths without shrinking.
    case taubin(iterations: Int, lambda: Double, mu: Double)

    /// A good default for segmentation surfaces.
    public static let standard = MeshSmoothing.taubin(iterations: 12, lambda: 0.5, mu: -0.53)
}

/// Options for ``SurfaceExtractor``.
public struct SurfaceExtractionOptions: Sendable, Hashable {
    /// Smoothing applied to the extracted mesh.
    public var smoothing: MeshSmoothing
    /// Block size for downsampling before extraction (1 = full resolution).
    /// Labels and masks become the fraction of each block inside, scalars its
    /// mean, so the surface stays smooth and volume-preserving.
    public var downsampleFactor: Int
    /// Gaussian pre-smoothing of label and mask indicators before
    /// extraction: σ in voxels along each axis (0 = off), so anisotropic
    /// grids are smoothed equally in voxel terms, which flattens the
    /// terraces of thick slices. Sheets thinner than about 1.6 σ voxels
    /// fall below the iso-level and disappear.
    public var presmoothing: Double
    /// Computes vertex normals for the result.
    public var computeNormals: Bool

    public init(smoothing: MeshSmoothing = .standard, presmoothing: Double = 0, downsampleFactor: Int = 1,
                computeNormals: Bool = true) {
        self.smoothing = smoothing
        self.presmoothing = max(0, presmoothing)
        self.downsampleFactor = max(1, downsampleFactor)
        self.computeNormals = computeNormals
    }

    /// Smooth surfaces for display: Gaussian pre-smoothing (σ = 1.2 voxels;
    /// structures thinner than about two voxels can vanish), then Taubin
    /// smoothing. On a 2 × 0.9 × 0.9 mm phantom organ this halves the RMS
    /// distance to the true surface and keeps the volume within 0.3 %.
    public static let display = SurfaceExtractionOptions(
        smoothing: .taubin(iterations: 20, lambda: 0.5, mu: -0.53), presmoothing: 1.2)

    /// The factor that keeps the voxel count at or below `maxVoxels`.
    public static func suggestedDownsampleFactor(for shape: SIMD3<Int>, maxVoxels: Int = 64_000_000) -> Int {
        var f = 1
        while (shape.x / f) * (shape.y / f) * (shape.z / f) > maxVoxels { f += 1 }
        return f
    }
}

/// Surface extraction by marching cubes on the CPU, multi-threaded over
/// slices, with vertices shared between triangles (one per crossed voxel
/// edge), consistent outward orientation, optional smoothing and
/// downsampling. Results are in world coordinates through the grid's
/// affine.
public enum SurfaceExtractor {
    /// The surface of one class of a label (segmentation layer) volume.
    public static func surface(labels: VolumeData, geometry: GridGeometry, classID: UInt16,
                               options: SurfaceExtractionOptions = SurfaceExtractionOptions()) -> TriangleMesh {
        struct V: VoxelVisitor {
            let dims: SIMD3<Int>
            let classID: Double
            let geometry: GridGeometry
            let options: SurfaceExtractionOptions
            func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) -> TriangleMesh {
                let field = IndicatorField(dims: dims, values: values, target: classID)
                return SurfaceExtractor.extract(field, iso: 0.5, binary: true, geometry: geometry, options: options)
            }
        }
        let g = geometry.spatialOnly
        return labels.visit(V(dims: g.paddedShape, classID: Double(classID), geometry: g, options: options))
    }

    /// One surface per class of a label volume (classes absent from the
    /// volume are left out), for per-class meshes in the 3-D view.
    public static func surfaces(labels: VolumeData, geometry: GridGeometry, classIDs: [UInt16],
                                options: SurfaceExtractionOptions = SurfaceExtractionOptions()) -> [UInt16: TriangleMesh] {
        var result: [UInt16: TriangleMesh] = [:]
        for id in classIDs where id != 0 {
            let mesh = surface(labels: labels, geometry: geometry, classID: id, options: options)
            if !mesh.isEmpty { result[id] = mesh }
        }
        return result
    }

    /// The surface of a binary mask (nonzero voxels inside).
    public static func surface(mask: VolumeData, geometry: GridGeometry,
                               options: SurfaceExtractionOptions = SurfaceExtractionOptions()) -> TriangleMesh {
        struct V: VoxelVisitor {
            let dims: SIMD3<Int>
            let geometry: GridGeometry
            let options: SurfaceExtractionOptions
            func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) -> TriangleMesh {
                let field = IndicatorField(dims: dims, values: values, target: nil)
                return SurfaceExtractor.extract(field, iso: 0.5, binary: true, geometry: geometry, options: options)
            }
        }
        let g = geometry.spatialOnly
        return mask.visit(V(dims: g.paddedShape, geometry: g, options: options))
    }

    /// The iso-surface of a scalar volume at `isoLevel` (raw stored values;
    /// voxels at or above the level are inside).
    public static func surface(scalars: VolumeData, geometry: GridGeometry, isoLevel: Double,
                               options: SurfaceExtractionOptions = SurfaceExtractionOptions(smoothing: .none)) -> TriangleMesh {
        struct V: VoxelVisitor {
            let dims: SIMD3<Int>
            let iso: Double
            let geometry: GridGeometry
            let options: SurfaceExtractionOptions
            func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) -> TriangleMesh {
                let field = ScalarField(dims: dims, values: values, iso: Float(iso))
                return SurfaceExtractor.extract(field, iso: Float(iso), binary: false, geometry: geometry,
                                                options: options)
            }
        }
        let g = geometry.spatialOnly
        return scalars.visit(V(dims: g.paddedShape, iso: isoLevel, geometry: g, options: options))
    }

    // MARK: Pipeline

    static func extract<F: MarchingField>(_ field: F, iso: Float, binary: Bool, geometry: GridGeometry,
                                          options: SurfaceExtractionOptions) -> TriangleMesh {
        var indexToWorld = geometry.indexToWorld
        var result: (positions: [SIMD3<Float>], indices: [UInt32])
        if options.downsampleFactor > 1 {
            let f = options.downsampleFactor
            let coarse = DenseField.downsample(field, factor: f, binary: binary)
            // Coarse index c covers fine indices f·c … f·c + f − 1: centre f·c + (f − 1)/2.
            let half = Double(f - 1) / 2
            let s = simd_double4x4(columns: (SIMD4(Double(f), 0, 0, 0), SIMD4(0, Double(f), 0, 0),
                                             SIMD4(0, 0, Double(f), 0), SIMD4(half, half, half, 1)))
            indexToWorld = indexToWorld * s
            result = MarchingCubes.run(coarse, iso: binary ? 0.5 : iso)
        } else if binary && options.presmoothing > 0 {
            let sigma = SIMD3<Double>(repeating: options.presmoothing)
            guard let smoothed = DenseField.smoothedIndicator(field, sigma: sigma) else { return .empty }
            result = MarchingCubes.run(smoothed.field, iso: 0.5)
            let o = SIMD3<Float>(Float(smoothed.origin.z), Float(smoothed.origin.y), Float(smoothed.origin.x))
            for i in result.positions.indices { result.positions[i] += o }
        } else {
            result = MarchingCubes.run(field, iso: iso)
        }
        guard !result.indices.isEmpty else { return .empty }
        // Index space (k0, k1, k2) → world.
        let m = indexToWorld
        var positions = result.positions
        positions.withUnsafeMutableBufferPointer { buf in
            let count = buf.count
            DispatchQueue.concurrentPerform(iterations: max(1, (count + 65535) / 65536)) { c in
                let lo = c * 65536, hi = min(count, lo + 65536)
                for i in lo..<hi { buf[i] = SIMD3<Float>(m.transformPoint(SIMD3<Double>(buf[i]))) }
            }
        }
        var indices = result.indices
        // The table winds triangles for a right-handed (x, y, z) = (k2, k1, k0);
        // (k0, k1, k2) is mirrored, so the winding flips unless the affine mirrors too.
        let linear = simd_double3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        if linear.determinant > 0 {
            for t in stride(from: 0, to: indices.count - 2, by: 3) { indices.swapAt(t + 1, t + 2) }
        }
        var mesh = TriangleMesh(positions: positions, indices: indices)
        MeshSmoother.apply(options.smoothing, to: &mesh)
        if options.computeNormals { mesh.computeNormals() }
        return mesh
    }
}

// MARK: - Fields

/// A scalar field marching cubes runs on: values on a grid of `dims`
/// `(n0, n1, n2)`, addressed `(x, y, z) = (k2, k1, k0)`.
protocol MarchingField {
    var dims: SIMD3<Int> { get }
    /// Whether the voxel is inside (value at or above the level).
    func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool
    /// The value, for interpolating crossings.
    func value(_ x: Int, _ y: Int, _ z: Int) -> Float
}

/// 1 where the value equals `target` (or is nonzero when `target` is
/// `nil`), else 0.
struct IndicatorField<T: VoxelScalar>: MarchingField {
    let dims: SIMD3<Int>
    let values: UnsafeBufferPointer<T>
    let target: Double?

    @inline(__always) func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        let v = values[(z * dims.y + y) * dims.z + x].doubleValue
        if let target { return v == target }
        return v != 0
    }

    @inline(__always) func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        inside(x, y, z) ? 1 : 0
    }
}

struct ScalarField<T: VoxelScalar>: MarchingField {
    let dims: SIMD3<Int>
    let values: UnsafeBufferPointer<T>
    let iso: Float

    @inline(__always) func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        Float(values[(z * dims.y + y) * dims.z + x].doubleValue)
    }

    @inline(__always) func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        value(x, y, z) >= iso
    }
}

/// A dense float field (a downsampled volume).
struct DenseField: MarchingField {
    let dims: SIMD3<Int>
    let values: [Float]
    let iso: Float

    @inline(__always) func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        values[(z * dims.y + y) * dims.z + x]
    }

    @inline(__always) func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        value(x, y, z) >= iso
    }

    /// Block averages of `field` (of its indicator when `binary`).
    static func downsample<F: MarchingField>(_ field: F, factor f: Int, binary: Bool) -> DenseField {
        let n = field.dims
        let c = SIMD3((n.x + f - 1) / f, (n.y + f - 1) / f, (n.z + f - 1) / f)
        var out = [Float](repeating: 0, count: c.x * c.y * c.z)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: c.x) { cz in
                for cy in 0..<c.y {
                    for cx in 0..<c.z {
                        var sum: Float = 0
                        var count: Float = 0
                        for z in (cz * f)..<min(n.x, cz * f + f) {
                            for y in (cy * f)..<min(n.y, cy * f + f) {
                                for x in (cx * f)..<min(n.z, cx * f + f) {
                                    sum += binary ? (field.inside(x, y, z) ? 1 : 0) : field.value(x, y, z)
                                    count += 1
                                }
                            }
                        }
                        buf[(cz * c.y + cy) * c.z + cx] = count > 0 ? sum / count : 0
                    }
                }
            }
        }
        return DenseField(dims: c, values: out, iso: binary ? 0.5 : 0)
    }

    /// The indicator of `field` over its inside box grown by 3σ (voxels per
    /// axis, (x, y, z)), blurred by a separable Gaussian; values outside the
    /// grid are 0. `origin` is the (x, y, z) index of the field's first voxel.
    static func smoothedIndicator<F: MarchingField>(_ field: F, sigma: SIMD3<Double>)
        -> (field: DenseField, origin: SIMD3<Int>)? {
        guard let box = MarchingCubes.insideBounds(field) else { return nil }
        let radius = SIMD3(Int((3 * sigma.x).rounded(.up)), Int((3 * sigma.y).rounded(.up)),
                           Int((3 * sigma.z).rounded(.up)))
        let lo = box.lo &- radius &- 1
        let hi = box.hi &+ radius &+ 1
        let size = hi &- lo &+ 1   // (x, y, z)
        let n = field.dims          // (n0, n1, n2) = (z, y, x)
        var values = [Float](repeating: 0, count: size.x * size.y * size.z)
        values.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: size.z) { Z in
                let z = Z + lo.z
                guard z >= 0 && z < n.x else { return }
                for Y in 0..<size.y {
                    let y = Y + lo.y
                    guard y >= 0 && y < n.y else { continue }
                    for X in 0..<size.x {
                        let x = X + lo.x
                        if x >= 0 && x < n.z && field.inside(x, y, z) { buf[(Z * size.y + Y) * size.x + X] = 1 }
                    }
                }
            }
        }
        for axis in 0..<3 where sigma[axis] > 0.25 {
            gaussianBlur(&values, size: size, axis: axis, sigma: sigma[axis])
        }
        return (DenseField(dims: SIMD3(size.z, size.y, size.x), values: values, iso: 0.5), lo)
    }

    /// Blurs a (x, y, z) volume along one axis in place.
    private static func gaussianBlur(_ values: inout [Float], size: SIMD3<Int>, axis: Int, sigma: Double) {
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        let length = size[axis]
        let stride = axis == 0 ? 1 : (axis == 1 ? size.x : size.x * size.y)
        // Lines along `axis`: enumerate their start offsets.
        let (a, b) = axis == 0 ? (size.y, size.z) : (axis == 1 ? (size.x, size.z) : (size.x, size.y))
        let source = values
        values.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: b) { j in
                    var line = [Float](repeating: 0, count: length)
                    for i in 0..<a {
                        let start: Int
                        switch axis {
                        case 0: start = (j * size.y + i) * size.x
                        case 1: start = j * size.x * size.y + i
                        default: start = j * size.x + i
                        }
                        for k in 0..<length { line[k] = src[start + k * stride] }
                        for k in 0..<length {
                            var acc: Float = 0
                            for t in -r...r {
                                let q = k + t
                                if q >= 0 && q < length { acc += kernel[t + r] * line[q] }
                            }
                            out[start + k * stride] = acc
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Marching cubes

enum MarchingCubes {
    /// Runs marching cubes; positions are in padded index space `(k0, k1, k2)`.
    /// Everything outside the grid counts as outside, so surfaces touching
    /// the border are closed there (at the border, half a voxel out).
    static func run<F: MarchingField>(_ field: F, iso: Float) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let n = field.dims   // (n0, n1, n2) = (nz, ny, nx)
        let nx = n.z, ny = n.y, nz = n.x
        guard nx > 0, ny > 0, nz > 0, let box = insideBounds(field) else { return ([], []) }
        // The working grid: the inside box grown by one voxel on every side.
        let x0 = box.lo.x - 1, y0 = box.lo.y - 1, z0 = box.lo.z - 1
        let wx = box.hi.x - box.lo.x + 3, wy = box.hi.y - box.lo.y + 3, wz = box.hi.z - box.lo.z + 3

        // Inside mask of the working grid.
        var mask = [UInt8](repeating: 0, count: wx * wy * wz)
        mask.withUnsafeMutableBufferPointer { m in
            DispatchQueue.concurrentPerform(iterations: wz) { Z in
                let z = Z + z0
                guard z >= 0 && z < nz else { return }
                for Y in 0..<wy {
                    let y = Y + y0
                    guard y >= 0 && y < ny else { continue }
                    let row = (Z * wy + Y) * wx
                    for X in 0..<wx {
                        let x = X + x0
                        if x >= 0 && x < nx && field.inside(x, y, z) { m[row + X] = 1 }
                    }
                }
            }
        }

        // Vertices: one per crossed edge, owned by the edge's lower voxel; keys
        // ((Y * wx + X) * 3 + axis) are generated in increasing order per slice.
        var sliceKeys = [[UInt32]](repeating: [], count: wz)
        var slicePositions = [[SIMD3<Float>]](repeating: [], count: wz)
        mask.withUnsafeBufferPointer { m in
            sliceKeys.withUnsafeMutableBufferPointer { keysOut in
                slicePositions.withUnsafeMutableBufferPointer { posOut in
                    DispatchQueue.concurrentPerform(iterations: wz) { Z in
                        var keys: [UInt32] = []
                        var pos: [SIMD3<Float>] = []
                        for Y in 0..<wy {
                            for X in 0..<wx {
                                let i = (Z * wy + Y) * wx + X
                                let a = m[i]
                                for axis in 0..<3 {
                                    let (X1, Y1, Z1) = axis == 0 ? (X + 1, Y, Z) : (axis == 1 ? (X, Y + 1, Z) : (X, Y, Z + 1))
                                    if X1 >= wx || Y1 >= wy || Z1 >= wz { continue }
                                    let b = m[(Z1 * wy + Y1) * wx + X1]
                                    if a == b { continue }
                                    let x = X + x0, y = Y + y0, z = Z + z0
                                    let xb = X1 + x0, yb = Y1 + y0, zb = Z1 + z0
                                    var t: Float = 0.5
                                    if x >= 0, y >= 0, z >= 0, x < nx, y < ny, z < nz,
                                       xb >= 0, yb >= 0, zb >= 0, xb < nx, yb < ny, zb < nz {
                                        let va = field.value(x, y, z), vb = field.value(xb, yb, zb)
                                        if vb != va { t = min(1, max(0, (iso - va) / (vb - va))) }
                                    }
                                    var p = SIMD3<Float>(Float(z), Float(y), Float(x))   // (k0, k1, k2)
                                    switch axis {
                                    case 0: p.z += t
                                    case 1: p.y += t
                                    default: p.x += t
                                    }
                                    keys.append(UInt32((Y * wx + X) * 3 + axis))
                                    pos.append(p)
                                }
                            }
                        }
                        keysOut[Z] = keys
                        posOut[Z] = pos
                    }
                }
            }
        }
        var sliceOffset = [Int](repeating: 0, count: wz + 1)
        for Z in 0..<wz { sliceOffset[Z + 1] = sliceOffset[Z] + sliceKeys[Z].count }

        // Triangles per cell slice.
        let table = MarchingCubesTable.triangles
        let owners = MarchingCubesTable.edgeOwner
        var sliceTriangles = [[UInt32]](repeating: [], count: max(0, wz - 1))
        mask.withUnsafeBufferPointer { m in
            sliceTriangles.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: max(0, wz - 1)) { Z in
                    var tris: [UInt32] = []
                    for Y in 0..<(wy - 1) {
                        for X in 0..<(wx - 1) {
                            var cube = 0
                            for c in 0..<8 {
                                let i = ((Z + (c >> 2 & 1)) * wy + Y + (c >> 1 & 1)) * wx + X + (c & 1)
                                cube |= Int(m[i]) << c
                            }
                            if cube == 0 || cube == 255 { continue }
                            for e in table[cube] {
                                let o = owners[Int(e)]
                                let s = Z + o.dz
                                let key = UInt32(((Y + o.dy) * wx + X + o.dx) * 3 + o.axis)
                                let local = lowerBound(sliceKeys[s], key)
                                tris.append(UInt32(sliceOffset[s] + local))
                            }
                        }
                    }
                    out[Z] = tris
                }
            }
        }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(sliceOffset[wz])
        for p in slicePositions { positions += p }
        var indices: [UInt32] = []
        indices.reserveCapacity(sliceTriangles.reduce(0) { $0 + $1.count })
        for t in sliceTriangles { indices += t }
        return (positions, indices)
    }

    @inline(__always)
    private static func lowerBound(_ keys: [UInt32], _ key: UInt32) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if keys[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The bounding box of inside voxels in (x, y, z), or `nil` when empty.
    static func insideBounds<F: MarchingField>(_ field: F) -> (lo: SIMD3<Int>, hi: SIMD3<Int>)? {
        let n = field.dims
        let nx = n.z, ny = n.y, nz = n.x
        var partial = [(lo: SIMD3<Int>, hi: SIMD3<Int>)?](repeating: nil, count: nz)
        partial.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: nz) { z in
                var lo = SIMD3<Int>(Int.max, Int.max, z), hi = SIMD3<Int>(Int.min, Int.min, z)
                var any = false
                for y in 0..<ny {
                    for x in 0..<nx where field.inside(x, y, z) {
                        any = true
                        lo.x = min(lo.x, x)
                        lo.y = min(lo.y, y)
                        hi.x = max(hi.x, x)
                        hi.y = max(hi.y, y)
                    }
                }
                out[z] = any ? (lo, hi) : nil
            }
        }
        var result: (lo: SIMD3<Int>, hi: SIMD3<Int>)?
        for p in partial {
            guard let p else { continue }
            if let r = result {
                result = (simd_min(r.lo, p.lo), simd_max(r.hi, p.hi))
            } else {
                result = p
            }
        }
        return result
    }
}
