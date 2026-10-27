import Foundation
import simd
import MedH5Core

/// Shape-based interpolation between annotated slices: draw a class on a
/// few slices across an axis, and fill the slices between them.
///
/// For each pair of consecutive *key slices* (slices holding the class), the
/// signed distance transform of each (exact, in world units, anisotropic) is
/// computed over the pair's common in-plane box; a slice between them at
/// fraction `t` of the way gets the voxels where
/// `(1 − t)·φ₁ + t·φ₂ ≤ 0`. Two concentric discs of radii r₁ and r₂ thus
/// give discs of radius `(1 − t)·r₁ + t·r₂`, and a shape that moves or
/// changes between key slices morphs smoothly. Key slices are never changed.
///
/// As with any shape-based interpolation, the shapes of two consecutive key
/// slices must overlap (seen across the axis) for the slices between them to
/// get voxels: a shape that jumps aside between key slices needs a key slice
/// in between.
public enum SliceInterpolation {
    /// The slices across padded `axis` that hold voxels of the class, ascending.
    public static func keySlices(_ model: SegmentationModel, classID: UInt16, axis: Int) throws -> [Int] {
        guard model.layer(of: classID) != nil else { throw EditingError.unknownClass(classID) }
        guard axis >= 0 && axis < 3 else { throw EditingError.invalidArgument("axis \(axis) is not 0, 1 or 2") }
        let mask = model.mask(of: classID)
        return slicesHolding(mask, axis: axis)
    }

    static func slicesHolding(_ mask: VoxelMask, axis: Int) -> [Int] {
        let b = mask.bounds
        guard !b.isEmpty else { return [] }
        var has = [Bool](repeating: false, count: b.size[axis])
        let s = b.size
        mask.withUnsafeBytes { p in
            for z in 0..<s.x {
                for y in 0..<s.y {
                    let row = p + (z * s.y + y) * s.z
                    for x in 0..<s.z where row[x] != 0 {
                        has[SIMD3(z, y, x)[axis]] = true
                    }
                }
            }
        }
        return has.indices.filter { has[$0] }.map { $0 + b.lower[axis] }
    }

    /// Interpolates class `classID` across padded `axis`.
    ///
    /// - Parameters:
    ///   - keySlices: the slices to interpolate between (default: every
    ///     slice holding the class). Slices listed that hold no voxel are
    ///     skipped.
    ///   - options: paint policy for the voxels added.
    public static func interpolate(_ model: SegmentationModel, classID: UInt16, axis: Int, keySlices: [Int]? = nil,
                                   options: PaintOptions = PaintOptions(),
                                   control: OperationControl? = nil) throws -> VoxelEdit {
        guard model.layer(of: classID) != nil else { throw EditingError.unknownClass(classID) }
        if model.isLocked(classID) { throw EditingError.classLocked(classID) }
        let mask = model.mask(of: classID)
        control.beginPhase(0, of: 2)
        let filled = try interpolatedSlices(of: mask, axis: axis, keySlices: keySlices,
                                            spacing: model.geometry.paddedSpacing, control: control)
        guard !filled.bounds.isEmpty else { return VoxelEdit(shape: model.shape) }
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.paint(classID), over: filled, options: options, control: control)
    }

    /// The voxels interpolation adds between the key slices of a mask
    /// (over the mask's bounds).
    public static func interpolatedSlices(of mask: VoxelMask, axis: Int, keySlices: [Int]? = nil,
                                          spacing: SIMD3<Double>,
                                          control: OperationControl? = nil) throws -> VoxelMask {
        guard axis >= 0 && axis < 3 else { throw EditingError.invalidArgument("axis \(axis) is not 0, 1 or 2") }
        let b = mask.memberBounds()
        guard !b.isEmpty else { return VoxelMask(bounds: .empty) }
        let present = Set(slicesHolding(mask, axis: axis))
        let keys = (keySlices.map { Set($0).intersection(present) } ?? present).sorted()
        var out = VoxelMask(bounds: b)
        guard keys.count >= 2 else { return out }
        let pairs = zip(keys, keys.dropFirst()).filter { $0.1 - $0.0 > 1 }
        guard !pairs.isEmpty else { return out }

        let others = [0, 1, 2].filter { $0 != axis }
        let p = others[0], q = others[1]
        // The in-plane domain: the bounds grown by one voxel of background.
        let dims = SIMD3(1, b.size[p] + 2, b.size[q] + 2)
        var sp2 = spacing
        sp2[0] = 1
        sp2[1] = spacing[p]
        sp2[2] = spacing[q]
        let src = mask.cropped(to: b)
        let sStrides = SIMD3(b.size.y * b.size.z, b.size.z, 1)
        let plane = dims.y * dims.z

        func sliceMask(_ s: Int, _ pt: UnsafePointer<UInt8>) -> [UInt8] {
            var m = [UInt8](repeating: 0, count: plane)
            let a = s - b.lower[axis]
            for i in 0..<b.size[p] {
                for j in 0..<b.size[q] {
                    let si = a * sStrides[axis] + i * sStrides[p] + j * sStrides[q]
                    if pt[si] != 0 { m[(i + 1) * dims.z + (j + 1)] = 1 }
                }
            }
            return m
        }

        let oStrides = sStrides
        try src.withUnsafeBytes { pt in
            try out.withUnsafeMutableBytes { o in
                try Parallel.forEach(0..<pairs.count, control: control) { range in
                    for pi in range {
                        let (s1, s2) = pairs[pi]
                        let m1 = sliceMask(s1, pt), m2 = sliceMask(s2, pt)
                        let d1 = try m1.withUnsafeBufferPointer {
                            try DistanceTransform.signedDistances(mask: $0.baseAddress!, dims: dims, spacing: sp2, control: control)
                        }
                        let d2 = try m2.withUnsafeBufferPointer {
                            try DistanceTransform.signedDistances(mask: $0.baseAddress!, dims: dims, spacing: sp2, control: control)
                        }
                        for s in (s1 + 1)..<s2 {
                            let t = Float(s - s1) / Float(s2 - s1)
                            let a = s - b.lower[axis]
                            for i in 0..<b.size[p] {
                                for j in 0..<b.size[q] {
                                    let di = (i + 1) * dims.z + (j + 1)
                                    if (1 - t) * d1[di] + t * d2[di] <= 0 {
                                        o[a * oStrides[axis] + i * oStrides[p] + j * oStrides[q]] = 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
