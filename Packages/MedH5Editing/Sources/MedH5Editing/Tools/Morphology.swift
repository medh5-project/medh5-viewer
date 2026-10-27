import Foundation
import simd
import MedH5Core

/// Binary morphology on one class, with a ball of radius given in world
/// units (mm), exact on anisotropic grids.
///
/// Definitions, on voxel centres:
/// - **dilate**: the voxels within `radius` of a voxel of the class;
/// - **erode**: the class's voxels with no other voxel (of the grid) within
///   `radius` that is not in the class. The outside of the grid counts as
///   in the class, so an object touching the border is not eroded from it;
/// - **open** = erode, then dilate; **close** = dilate, then erode.
///
/// "Within" means a distance ≤ radius (with a relative tolerance of 10⁻⁶).
/// Distances come from an exact Euclidean distance transform computed over
/// the class's bounding box (grown by the radius), so the cost depends on the
/// object's size, not the volume's.
///
/// Each operation returns a `VoxelEdit` without applying it. Voxels added
/// to the class obey the paint policy and locks of `options`.
///
/// With `sliceAxis`, the structuring element is a disc in the slices across
/// that padded axis: each slice is processed on its own.
public enum Morphology {
    static let tolerance = 1e-6

    // MARK: Masks

    /// The voxels within `radius` of a member of `mask`, in a grid of padded
    /// `shape` and voxel `spacing` (padded axes).
    public static func dilate(_ mask: VoxelMask, radius: Double, spacing: SIMD3<Double>, shape: SIMD3<Int>,
                              sliceAxis: Int? = nil, control: OperationControl? = nil) throws -> VoxelMask {
        let src = mask.memberBounds()
        guard !src.isEmpty else { return VoxelMask(bounds: .empty) }
        let sp = effectiveSpacing(spacing, sliceAxis: sliceAxis)
        var margin = SIMD3<Int>.zero
        for a in 0..<3 where a != sliceAxis {
            margin[a] = Int((max(0, radius) / sp[a]).rounded(.up))
        }
        let box = src.expanded(by: margin).clamped(to: shape)
        let features = mask.cropped(to: box)
        let d2 = try features.withUnsafeBytes { f in
            try DistanceTransform.squaredDistances(features: f, featureIsNonzero: true, dims: box.size, spacing: sp, control: control)
        }
        let limit = Float(radius * radius * (1 + tolerance))
        var out = VoxelMask(bounds: box)
        out.withUnsafeMutableBytes { o in
            for i in 0..<d2.count where d2[i] <= limit { o[i] = 1 }
        }
        return out
    }

    /// The members of `mask` with no non-member within `radius`.
    public static func erode(_ mask: VoxelMask, radius: Double, spacing: SIMD3<Double>, shape: SIMD3<Int>,
                             sliceAxis: Int? = nil, control: OperationControl? = nil) throws -> VoxelMask {
        let src = mask.memberBounds()
        guard !src.isEmpty else { return VoxelMask(bounds: .empty) }
        let sp = effectiveSpacing(spacing, sliceAxis: sliceAxis)
        var margin = SIMD3<Int>(1, 1, 1)
        if let a = sliceAxis { margin[a] = 0 }
        let box = src.expanded(by: margin).clamped(to: shape)
        var members = mask.cropped(to: box)
        let d2 = try members.withUnsafeBytes { f in
            try DistanceTransform.squaredDistances(features: f, featureIsNonzero: false, dims: box.size, spacing: sp, control: control)
        }
        let limit = Float(radius * radius * (1 + tolerance))
        members.withUnsafeMutableBytes { o in
            for i in 0..<d2.count where o[i] != 0 && d2[i] <= limit { o[i] = 0 }
        }
        return members
    }

    /// Erode, then dilate.
    public static func open(_ mask: VoxelMask, radius: Double, spacing: SIMD3<Double>, shape: SIMD3<Int>,
                            sliceAxis: Int? = nil, control: OperationControl? = nil) throws -> VoxelMask {
        let e = try erode(mask, radius: radius, spacing: spacing, shape: shape, sliceAxis: sliceAxis, control: control)
        return try dilate(e, radius: radius, spacing: spacing, shape: shape, sliceAxis: sliceAxis, control: control)
    }

    /// Dilate, then erode.
    public static func close(_ mask: VoxelMask, radius: Double, spacing: SIMD3<Double>, shape: SIMD3<Int>,
                             sliceAxis: Int? = nil, control: OperationControl? = nil) throws -> VoxelMask {
        let d = try dilate(mask, radius: radius, spacing: spacing, shape: shape, sliceAxis: sliceAxis, control: control)
        return try erode(d, radius: radius, spacing: spacing, shape: shape, sliceAxis: sliceAxis, control: control)
    }

    /// Spacing with a slice axis made so long that no distance crosses it.
    private static func effectiveSpacing(_ s: SIMD3<Double>, sliceAxis: Int?) -> SIMD3<Double> {
        var sp = s
        if let a = sliceAxis { sp[a] = 1e9 }
        return sp
    }

    // MARK: Edits on a class

    public static func dilate(_ model: SegmentationModel, classID: UInt16, radius: Double, sliceAxis: Int? = nil,
                              options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        control.beginPhase(0, of: 2)
        let r = try dilate(m, radius: radius, spacing: model.geometry.paddedSpacing, shape: model.shape,
                           sliceAxis: sliceAxis, control: control)
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.paint(classID), over: r.subtracting(m), options: options, control: control)
    }

    public static func erode(_ model: SegmentationModel, classID: UInt16, radius: Double, sliceAxis: Int? = nil,
                             control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        control.beginPhase(0, of: 2)
        let r = try erode(m, radius: radius, spacing: model.geometry.paddedSpacing, shape: model.shape,
                          sliceAxis: sliceAxis, control: control)
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.erase(classID), over: m.subtracting(r), control: control)
    }

    /// Opening removes protrusions and specks narrower than the ball.
    public static func open(_ model: SegmentationModel, classID: UInt16, radius: Double, sliceAxis: Int? = nil,
                            control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        control.beginPhase(0, of: 2)
        let r = try open(m, radius: radius, spacing: model.geometry.paddedSpacing, shape: model.shape,
                         sliceAxis: sliceAxis, control: control)
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.erase(classID), over: m.subtracting(r), control: control)
    }

    /// Closing fills gaps and dents narrower than the ball.
    public static func close(_ model: SegmentationModel, classID: UInt16, radius: Double, sliceAxis: Int? = nil,
                             options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        control.beginPhase(0, of: 2)
        let r = try close(m, radius: radius, spacing: model.geometry.paddedSpacing, shape: model.shape,
                          sliceAxis: sliceAxis, control: control)
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.paint(classID), over: r.subtracting(m), options: options, control: control)
    }

    static func classMask(_ model: SegmentationModel, _ classID: UInt16) throws -> VoxelMask {
        guard model.layer(of: classID) != nil else { throw EditingError.unknownClass(classID) }
        if model.isLocked(classID) { throw EditingError.classLocked(classID) }
        return model.mask(of: classID)
    }

    // MARK: Holes

    /// Where holes are looked for.
    public enum HoleScope: Sendable, Hashable {
        /// Cavities enclosed in 3-D.
        case volume
        /// Holes of each slice across a padded axis (2-D).
        case slices(axis: Int)
    }

    /// Fills the holes of a class: background voxels not connected to the
    /// outside of the class's bounding box. The grid's border counts as
    /// outside, so a cavity open to it is not a hole.
    ///
    /// - Parameter connectivity: connectivity of the *background* (`.face`
    ///   by default, the complement of the object's 26-connectivity).
    public static func fillHoles(_ model: SegmentationModel, classID: UInt16, scope: HoleScope = .volume,
                                 connectivity: Connectivity = .face, options: PaintOptions = PaintOptions(),
                                 control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        guard !m.bounds.isEmpty else { return VoxelEdit(shape: model.shape) }
        // A 2-D grid has a single slice: its holes are the slice's.
        let effectiveScope: HoleScope = model.shape.x == 1 && scope == .volume ? .slices(axis: 0) : scope
        control.beginPhase(0, of: 2)
        let h = try holes(of: m, scope: effectiveScope, connectivity: connectivity, control: control)
        control.beginPhase(1, of: 2)
        return try model.makeEdit(.paint(classID), over: h, options: options, control: control)
    }

    /// The holes of a mask (over the mask's bounds).
    public static func holes(of mask: VoxelMask, scope: HoleScope = .volume, connectivity: Connectivity = .face,
                             control: OperationControl? = nil) throws -> VoxelMask {
        let b = mask.memberBounds()
        guard !b.isEmpty else { return VoxelMask(bounds: .empty) }
        // The bounds grown by one voxel of background all round.
        let e = b.expanded(by: 1)
        let grown = mask.cropped(to: e)
        let es = e.size
        var out = VoxelMask(bounds: b)
        switch scope {
        case .volume:
            let state = VolumeData(scalarType: .uint8, shape: [es.x * es.y * es.z])
            try withExtendedLifetime(state) {
                let st = state.pointer(as: UInt8.self)
                try grown.withUnsafeBytes { g in
                    var filler = ScanlineFiller(dims: es, state: st, acceptor: ZeroMaskAcceptor(mask: g, dims: es),
                                                connectivity: connectivity, limit: Int.max)
                    try filler.run(seeds: [.zero], control: control)
                    out.withUnsafeMutableBytes { o in
                        for z in b.lower.x..<b.upper.x {
                            for y in b.lower.y..<b.upper.y {
                                for x in b.lower.z..<b.upper.z {
                                    let gi = ((z - e.lower.x) * es.y + (y - e.lower.y)) * es.z + (x - e.lower.z)
                                    if g[gi] == 0 && st[gi] != FillState.filled {
                                        o[((z - b.lower.x) * b.size.y + (y - b.lower.y)) * b.size.z + (x - b.lower.z)] = 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .slices(let axis):
            guard axis >= 0 && axis < 3 else { throw EditingError.invalidArgument("slice axis \(axis) is not 0, 1 or 2") }
            let others = [0, 1, 2].filter { $0 != axis }
            let strides = SIMD3(es.y * es.z, es.z, 1)
            let dims = SIMD3(1, es[others[0]], es[others[1]])
            let sA = strides[axis], sB = strides[others[0]], sC = strides[others[1]]
            let outStrides = SIMD3(b.size.y * b.size.z, b.size.z, 1)
            let oA = outStrides[axis], oB = outStrides[others[0]], oC = outStrides[others[1]]
            try grown.withUnsafeBytes { g in
                try out.withUnsafeMutableBytes { o in
                    try Parallel.forEach(b.lower[axis]..<b.upper[axis], control: control) { slices in
                        let plane = dims.y * dims.z
                        var slice = [UInt8](repeating: 0, count: plane)
                        var state = [UInt8](repeating: 0, count: plane)
                        for s in slices {
                            let ea = s - e.lower[axis]
                            for i in 0..<dims.y {
                                for j in 0..<dims.z { slice[i * dims.z + j] = g[ea * sA + i * sB + j * sC] }
                            }
                            for i in 0..<plane { state[i] = 0 }
                            try slice.withUnsafeBufferPointer { sl in
                                try state.withUnsafeMutableBufferPointer { st in
                                    var filler = ScanlineFiller(dims: dims, state: st.baseAddress!,
                                                                acceptor: ZeroMaskAcceptor(mask: sl.baseAddress!, dims: dims),
                                                                connectivity: connectivity, limit: Int.max)
                                    try filler.run(seeds: [.zero], control: nil)
                                }
                            }
                            // Interior of the slice (skip the one-voxel margin).
                            let ba = s - b.lower[axis]
                            for i in 1..<(dims.y - 1) {
                                for j in 1..<(dims.z - 1) {
                                    let si = i * dims.z + j
                                    if slice[si] == 0 && state[si] != FillState.filled {
                                        o[ba * oA + (i - 1) * oB + (j - 1) * oC] = 1
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

    // MARK: Components

    /// Keeps the largest connected component of a class, erasing the others.
    public static func keepLargestComponent(_ model: SegmentationModel, classID: UInt16,
                                            connectivity: Connectivity = .full,
                                            control: OperationControl? = nil) throws -> VoxelEdit {
        _ = try classMask(model, classID)
        let labeling = try ConnectedComponents.label(model, classID: classID, connectivity: connectivity, control: control)
        guard labeling.components.count > 1 else { return VoxelEdit(shape: model.shape) }
        let remove = labeling.region(ofComponents: Set(labeling.components.dropFirst().map(\.label)))
        return try model.makeEdit(.erase(classID), over: remove, control: control)
    }

    /// Erases the connected components of a class smaller than
    /// `minimumVoxels` voxels.
    public static func removeSmallComponents(_ model: SegmentationModel, classID: UInt16, minimumVoxels: Int,
                                             connectivity: Connectivity = .full,
                                             control: OperationControl? = nil) throws -> VoxelEdit {
        _ = try classMask(model, classID)
        let labeling = try ConnectedComponents.label(model, classID: classID, connectivity: connectivity, control: control)
        let small = labeling.components.filter { $0.voxelCount < minimumVoxels }.map(\.label)
        guard !small.isEmpty else { return VoxelEdit(shape: model.shape) }
        return try model.makeEdit(.erase(classID), over: labeling.region(ofComponents: Set(small)), control: control)
    }

    /// Erases the connected components of a class whose volume is below
    /// `minimumVolume` (units³, mm³; for a 2-D grid, an area in units²).
    public static func removeSmallComponents(_ model: SegmentationModel, classID: UInt16, minimumVolume: Double,
                                             connectivity: Connectivity = .full,
                                             control: OperationControl? = nil) throws -> VoxelEdit {
        let voxel = model.geometry.paddedVoxelVolume
        let n = Int((minimumVolume / voxel * (1 - tolerance)).rounded(.up))
        return try removeSmallComponents(model, classID: classID, minimumVoxels: n, connectivity: connectivity,
                                         control: control)
    }

    // MARK: Smoothing

    /// Smooths a class with a majority (binary median) filter over a box of
    /// half-size `radius` (mm) per axis — `floor(radius / spacing)` voxels:
    /// a voxel is in the class when more than half of the grid voxels of its
    /// window are. Removes specks and fills pinholes; corners round off.
    public static func smooth(_ model: SegmentationModel, classID: UInt16, radius: Double,
                              options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        let m = try classMask(model, classID)
        guard !m.bounds.isEmpty else { return VoxelEdit(shape: model.shape) }
        control.beginPhase(0, of: 2)
        let r = try majority(m, radius: radius, spacing: model.geometry.paddedSpacing, shape: model.shape, control: control)
        control.beginPhase(1, of: 2)
        let add = try model.makeEdit(.paint(classID), over: r.subtracting(m), options: options, control: control)
        let remove = try model.makeEdit(.erase(classID), over: m.subtracting(r), control: control)
        return add.followed(by: remove)
    }

    /// The majority filter of a mask (see `smooth`), over the mask's bounds
    /// grown by the window.
    public static func majority(_ mask: VoxelMask, radius: Double, spacing: SIMD3<Double>, shape: SIMD3<Int>,
                                control: OperationControl? = nil) throws -> VoxelMask {
        let src = mask.memberBounds()
        guard !src.isEmpty else { return VoxelMask(bounds: .empty) }
        var rv = SIMD3<Int>.zero
        for a in 0..<3 { rv[a] = min(max(0, Int((radius / spacing[a] * (1 + tolerance)).rounded(.down))), max(0, shape[a] - 1)) }
        let box = src.expanded(by: rv).clamped(to: shape)
        let s = box.size
        let n = s.x * s.y * s.z
        var counts = [Int32](repeating: 0, count: n)
        let members = mask.cropped(to: box)
        members.withUnsafeBytes { mb in
            for i in 0..<n { counts[i] = mb[i] != 0 ? 1 : 0 }
        }
        try counts.withUnsafeMutableBufferPointer { c in
            let p = c.baseAddress!
            // Box sums along each axis (values outside the box are 0: the
            // box holds every member within a window of each voxel).
            try boxSum(p, dims: s, axis: 2, radius: rv.z, control: control)
            try boxSum(p, dims: s, axis: 1, radius: rv.y, control: control)
            try boxSum(p, dims: s, axis: 0, radius: rv.x, control: control)
        }
        var out = VoxelMask(bounds: box)
        out.withUnsafeMutableBytes { o in
            func window(_ k: Int, _ a: Int) -> Int {
                min(k + rv[a], shape[a] - 1) - max(k - rv[a], 0) + 1
            }
            for z in 0..<s.x {
                let wz = window(box.lower.x + z, 0)
                for y in 0..<s.y {
                    let wzy = wz * window(box.lower.y + y, 1)
                    for x in 0..<s.z {
                        let w = wzy * window(box.lower.z + x, 2)
                        let i = (z * s.y + y) * s.z + x
                        if Int(counts[i]) * 2 > w { o[i] = 1 }
                    }
                }
            }
        }
        return out
    }

    /// In-place sliding-window sums of half-width `radius` along one axis.
    private static func boxSum(_ p: UnsafeMutablePointer<Int32>, dims: SIMD3<Int>, axis: Int, radius r: Int,
                               control: OperationControl?) throws {
        guard r > 0 else { return }
        let len = dims[axis]
        let strides = SIMD3(dims.y * dims.z, dims.z, 1)
        let stride = strides[axis]
        let others = [0, 1, 2].filter { $0 != axis }
        let nA = dims[others[0]], nB = dims[others[1]]
        let sA = strides[others[0]], sB = strides[others[1]]
        try Parallel.forEach(0..<nA, control: control) { rows in
            var prefix = [Int32](repeating: 0, count: len + 1)
            for i in rows {
                for j in 0..<nB {
                    let line = p + i * sA + j * sB
                    for t in 0..<len { prefix[t + 1] = prefix[t] + line[t * stride] }
                    for t in 0..<len {
                        let a = max(0, t - r), b = min(len, t + r + 1)
                        line[t * stride] = prefix[b] - prefix[a]
                    }
                }
            }
        }
    }
}
