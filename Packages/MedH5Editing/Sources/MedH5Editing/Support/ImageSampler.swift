import Foundation
import simd
import MedH5Core

/// Nearest-neighbour sampling of an image at the voxel centres of another
/// grid (the segmentation's), by world position.
///
/// Voxel `k` of the target grid samples the image voxel whose cell holds the
/// target voxel's centre (`floor(i + 0.5)` per axis, half up, as
/// `GridGeometry.voxel(containingIndex:)` does). When the two grids are
/// congruent the mapping is the identity and sampling is a direct read.
///
/// Values are physical (`raw × slope + intercept`, spec §4.2) unless the
/// sampler is made with `physical: false`. Outside the image a sample is NaN.
public struct ImageSampler: @unchecked Sendable {
    public let image: ImageVolume
    /// The spatial frame sampled.
    public let volume: VolumeData
    /// Whether target and image share one lattice (sampling is a direct read).
    public let isAligned: Bool
    public let usesPhysicalValues: Bool
    let imageShape: SIMD3<Int>
    /// Target padded index → image padded index.
    let map: simd_double4x4
    let slope: Double
    let intercept: Double

    /// - Parameters:
    ///   - image: the image to sample.
    ///   - target: the grid whose voxel centres are sampled.
    ///   - frame: the leading index (channel, time…) of the spatial frame to
    ///     sample; the first frame by default.
    ///   - physical: whether to apply the image's rescale.
    public init(image: ImageVolume, target: GridGeometry, frame: [Int]? = nil, physical: Bool = true) {
        self.image = image
        let lead = frame ?? Array(repeating: 0, count: image.leadingShape.count)
        self.volume = image.spatialFrame(lead)
        self.imageShape = image.geometry.paddedShape
        self.isAligned = target.isCongruent(with: image.geometry)
        self.map = image.geometry.worldToIndex * target.indexToWorld
        self.usesPhysicalValues = physical
        self.slope = physical ? image.rescaleSlope : 1
        self.intercept = physical ? image.rescaleIntercept : 0
    }

    /// Linear index (in the sampled frame) of the image voxel sampled for
    /// target voxel `k` with target linear index `linear`, or `-1` outside
    /// the image.
    @inline(__always)
    public func imageIndex(for k: SIMD3<Int>, linear: Int) -> Int {
        if isAligned { return linear }
        let p = map * SIMD4<Double>(Double(k.x), Double(k.y), Double(k.z), 1)
        let i0 = Int((p.x + 0.5).rounded(.down))
        let i1 = Int((p.y + 0.5).rounded(.down))
        let i2 = Int((p.z + 0.5).rounded(.down))
        let n = imageShape
        if i0 < 0 || i0 >= n.x || i1 < 0 || i1 >= n.y || i2 < 0 || i2 >= n.z { return -1 }
        return (i0 * n.y + i1) * n.z + i2
    }

    /// The value at target voxel `k` (linear index `linear` in the target
    /// grid), or NaN outside the image.
    @inline(__always)
    public func value(at k: SIMD3<Int>, linear: Int) -> Double {
        let i = imageIndex(for: k, linear: linear)
        if i < 0 { return .nan }
        return volume.value(at: i) * slope + intercept
    }

    /// The value at a target voxel, or NaN outside the image.
    public func value(at k: SIMD3<Int>, targetShape: SIMD3<Int>) -> Double {
        value(at: k, linear: (k.x * targetShape.y + k.y) * targetShape.z + k.z)
    }

    /// Physical value of a raw stored value.
    @inline(__always)
    func physical(_ raw: Double) -> Double { raw * slope + intercept }
}

/// Restricts painting to voxels whose image value lies in `range`.
///
/// The image may be on any grid: each segmentation voxel samples the image
/// voxel containing its centre (nearest, by world position). Voxels outside
/// the image are never painted.
public struct IntensityConstraint: @unchecked Sendable {
    public var image: ImageVolume
    /// Accepted values, inclusive, in physical units (HU for CT) unless
    /// `usesPhysicalValues` is false.
    public var range: ClosedRange<Double>
    public var usesPhysicalValues: Bool
    /// Leading index of the frame to sample (first frame when nil).
    public var frame: [Int]?

    public init(image: ImageVolume, range: ClosedRange<Double>, usesPhysicalValues: Bool = true, frame: [Int]? = nil) {
        self.image = image
        self.range = range
        self.usesPhysicalValues = usesPhysicalValues
        self.frame = frame
    }

    func sampler(for target: GridGeometry) -> ImageSampler {
        ImageSampler(image: image, target: target, frame: frame, physical: usesPhysicalValues)
    }
}
