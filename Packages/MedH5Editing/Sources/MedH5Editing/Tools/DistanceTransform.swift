import Foundation
import simd

/// Exact Euclidean distance transforms on anisotropic grids.
///
/// `squaredDistances` gives, for every voxel of a box, the squared world
/// distance (units², e.g. mm²) from its centre to the nearest *feature*
/// voxel's centre, by Felzenszwalb and Huttenlocher's separable algorithm:
/// a 1-D transform along each axis in turn (the lower envelope of parabolas
/// `w·(p − q)² + f(q)`, with `w` the squared spacing of that axis). Each
/// pass runs in parallel over the lines of the box; total work is linear in
/// the number of voxels.
public enum DistanceTransform {
    /// Squared distances to the nearest feature voxel; `.infinity` where the
    /// box holds no feature.
    ///
    /// - Parameters:
    ///   - features: one byte per voxel of a box of size `dims`, C order.
    ///   - featureIsNonzero: whether features are the nonzero bytes (true)
    ///     or the zero bytes (false).
    ///   - spacing: voxel size along the three padded axes.
    public static func squaredDistances(features: UnsafePointer<UInt8>, featureIsNonzero: Bool = true,
                                        dims: SIMD3<Int>, spacing: SIMD3<Double>,
                                        control: OperationControl? = nil) throws -> [Float] {
        let n = dims.x * dims.y * dims.z
        var out = [Float](repeating: .infinity, count: n)
        guard n > 0 else { return out }
        try out.withUnsafeMutableBufferPointer { buf in
            try squaredDistances(features: features, featureIsNonzero: featureIsNonzero, dims: dims,
                                 spacing: spacing, into: buf.baseAddress!, control: control)
        }
        return out
    }

    /// As above, writing into `out` (`dims` elements).
    static func squaredDistances(features: UnsafePointer<UInt8>, featureIsNonzero: Bool,
                                 dims: SIMD3<Int>, spacing: SIMD3<Double>,
                                 into out: UnsafeMutablePointer<Float>, control: OperationControl?) throws {
        let d0 = dims.x, d1 = dims.y, d2 = dims.z
        guard d0 > 0 && d1 > 0 && d2 > 0 else { return }
        // Pass 1, along the contiguous axis: distance to the nearest feature
        // of the row, by two sweeps.
        let w2 = spacing.z * spacing.z
        try Parallel.forEach(0..<(d0 * d1), grain: max(1, 16384 / d2), control: control) { rows in
            for r in rows {
                let f = features + r * d2
                let o = out + r * d2
                var last = -1
                for x in 0..<d2 {
                    if (f[x] != 0) == featureIsNonzero { last = x }
                    o[x] = last < 0 ? .infinity : Float(w2 * Double((x - last) * (x - last)))
                }
                last = -1
                var x = d2 - 1
                while x >= 0 {
                    if (f[x] != 0) == featureIsNonzero { last = x }
                    if last >= 0 {
                        let d = Float(w2 * Double((last - x) * (last - x)))
                        if d < o[x] { o[x] = d }
                    }
                    x -= 1
                }
            }
        }
        // Pass 2 along axis 1, pass 3 along axis 0.
        if d1 > 1 {
            try Parallel.forEach(0..<d0, control: control) { slabs in
                var scratch = LineScratch(capacity: d1)
                for z in slabs {
                    for x in 0..<d2 {
                        scratch.transform(out + z * d1 * d2 + x, count: d1, stride: d2, weight: spacing.y * spacing.y)
                    }
                }
            }
        }
        if d0 > 1 {
            try Parallel.forEach(0..<d1, control: control) { rows in
                var scratch = LineScratch(capacity: d0)
                for y in rows {
                    for x in 0..<d2 {
                        scratch.transform(out + y * d2 + x, count: d0, stride: d1 * d2, weight: spacing.x * spacing.x)
                    }
                }
            }
        }
    }

    /// Signed distances (world units) of a binary mask: negative inside,
    /// positive outside, measured to the boundary halfway between voxel
    /// centres: an inside voxel holds −(distance to the nearest outside
    /// voxel − ½ step), an outside voxel +(distance to the nearest inside
    /// voxel − ½ step), with the half step along the axis of the smallest
    /// spacing. Voxels of an empty mask are +∞; of a full mask −∞.
    public static func signedDistances(mask: UnsafePointer<UInt8>, dims: SIMD3<Int>, spacing: SIMD3<Double>,
                                       control: OperationControl? = nil) throws -> [Float] {
        let n = dims.x * dims.y * dims.z
        let toInside = try squaredDistances(features: mask, featureIsNonzero: true, dims: dims, spacing: spacing,
                                            control: control)
        let toOutside = try squaredDistances(features: mask, featureIsNonzero: false, dims: dims, spacing: spacing,
                                             control: control)
        var sp = [Double]()
        if dims.x > 1 { sp.append(spacing.x) }
        if dims.y > 1 { sp.append(spacing.y) }
        if dims.z > 1 { sp.append(spacing.z) }
        let half = Float(0.5 * (sp.min() ?? min(spacing.x, spacing.y, spacing.z)))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if mask[i] != 0 {
                let d = toOutside[i]
                out[i] = d.isFinite ? -(d.squareRoot() - half) : -.infinity
            } else {
                let d = toInside[i]
                out[i] = d.isFinite ? d.squareRoot() - half : .infinity
            }
        }
        return out
    }
}

/// Work arrays for the 1-D transform of one line.
struct LineScratch {
    var f: [Double]
    var d: [Double]
    var v: [Int]
    var z: [Double]

    init(capacity n: Int) {
        f = [Double](repeating: 0, count: n)
        d = [Double](repeating: 0, count: n)
        v = [Int](repeating: 0, count: n)
        z = [Double](repeating: 0, count: n + 1)
    }

    /// Replaces the `count` values at `line[0], line[stride], …` by their
    /// 1-D squared distance transform with axis weight `weight` (spacing²).
    mutating func transform(_ line: UnsafeMutablePointer<Float>, count n: Int, stride: Int, weight w: Double) {
        var any = false
        for i in 0..<n {
            let x = line[i * stride]
            f[i] = Double(x)
            if x.isFinite { any = true }
        }
        guard any else { return }
        f.withUnsafeMutableBufferPointer { f in
            d.withUnsafeMutableBufferPointer { d in
                v.withUnsafeMutableBufferPointer { v in
                    z.withUnsafeMutableBufferPointer { z in
                        felzenszwalb1D(f.baseAddress!, d.baseAddress!, n, w, v.baseAddress!, z.baseAddress!)
                    }
                }
            }
        }
        for i in 0..<n { line[i * stride] = Float(d[i]) }
    }
}

/// d(p) = min_q ( w·(p − q)² + f(q) ), skipping infinite f.
@inline(__always)
func felzenszwalb1D(_ f: UnsafePointer<Double>, _ out: UnsafeMutablePointer<Double>, _ n: Int, _ w: Double,
                    _ v: UnsafeMutablePointer<Int>, _ z: UnsafeMutablePointer<Double>) {
    var k = -1
    for q in 0..<n {
        let fq = f[q]
        if !fq.isFinite { continue }
        if k < 0 {
            k = 0
            v[0] = q
            z[0] = -.infinity
            z[1] = .infinity
            continue
        }
        let qq = Double(q)
        var s: Double
        repeat {
            let p = v[k]
            let pp = Double(p)
            s = ((fq + w * qq * qq) - (f[p] + w * pp * pp)) / (2 * w * (qq - pp))
            if s <= z[k] { k -= 1 } else { break }
        } while k >= 0
        k += 1
        v[k] = q
        z[k] = k == 0 ? -.infinity : s
        z[k + 1] = .infinity
    }
    if k < 0 {
        for p in 0..<n { out[p] = .infinity }
        return
    }
    k = 0
    for p in 0..<n {
        let pp = Double(p)
        while z[k + 1] < pp { k += 1 }
        let dq = pp - Double(v[k])
        out[p] = w * dq * dq + f[v[k]]
    }
}
