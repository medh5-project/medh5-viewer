import Foundation
import simd
import MedH5Core

/// Sets a class where an image's value lies in a range, within the whole
/// volume, a slice, a box, and optionally only inside another class.
///
/// The image may be on any grid: each segmentation voxel samples the image
/// voxel containing its centre. Values are physical (rescaled) by default.
public enum Threshold {
    public enum Extent: Sendable, Hashable {
        case volume
        case slice(GridPlane)
        case box(VoxelBox)
    }

    /// The voxels of `extent` (inside `insideClass` when given) whose image
    /// value is in `range`, and the other voxels of that domain.
    public static func masks(model: SegmentationModel, image: ImageVolume, range: ClosedRange<Double>,
                             physical: Bool = true, frame: [Int]? = nil, extent: Extent = .volume,
                             insideClass: UInt16? = nil,
                             control: OperationControl? = nil) throws -> (inside: VoxelMask, outside: VoxelMask) {
        let box: VoxelBox
        switch extent {
        case .volume: box = VoxelBox(shape: model.shape)
        case .slice(let plane): box = plane.box(in: model.shape)
        case .box(let b): box = b.clamped(to: model.shape)
        }
        var inside = VoxelMask(bounds: box)
        var outside = VoxelMask(bounds: box)
        guard !box.isEmpty else { return (inside, outside) }
        var maskLayer: UnsafePointer<UInt16>?
        if let c = insideClass {
            guard let l = model.layer(of: c) else { throw EditingError.unknownClass(c) }
            maskLayer = UnsafePointer(model.layers[l].pointer(as: UInt16.self))
        }
        let sampler = ImageSampler(image: image, target: model.geometry, frame: frame, physical: physical)
        try inside.withUnsafeMutableBytes { inPtr in
            try outside.withUnsafeMutableBytes { outPtr in
                let kernel = ThresholdKernel(sampler: sampler, box: box, shape: model.shape, range: range,
                                             maskLayer: maskLayer, maskClass: insideClass ?? 0,
                                             inside: inPtr, outside: outPtr, control: control)
                try sampler.volume.dispatch(kernel)
            }
        }
        return (inside, outside)
    }

    /// The edit setting `classID` where the value is in range (and, with
    /// `clearOutside`, removing it from the other voxels of the domain).
    public static func edit(_ model: SegmentationModel, classID: UInt16, image: ImageVolume,
                            range: ClosedRange<Double>, physical: Bool = true, frame: [Int]? = nil,
                            extent: Extent = .volume, insideClass: UInt16? = nil, clearOutside: Bool = false,
                            options: PaintOptions = PaintOptions(),
                            control: OperationControl? = nil) throws -> VoxelEdit {
        control.beginPhase(0, of: 2)
        let (inside, outside) = try masks(model: model, image: image, range: range, physical: physical,
                                          frame: frame, extent: extent, insideClass: insideClass, control: control)
        control.beginPhase(1, of: 2)
        let paint = try model.makeEdit(.paint(classID), over: inside, options: options, control: control)
        guard clearOutside else { return paint }
        let erase = try model.makeEdit(.erase(classID), over: outside, control: control)
        // Disjoint voxels, both computed on the current state: they compose.
        return paint.followed(by: erase)
    }
}

/// Classifies the voxels of a box by image value, specialised per type.
private struct ThresholdKernel: TypedKernel {
    let sampler: ImageSampler
    let box: VoxelBox
    let shape: SIMD3<Int>
    let range: ClosedRange<Double>
    let maskLayer: UnsafePointer<UInt16>?
    let maskClass: UInt16
    let inside: UnsafeMutablePointer<UInt8>
    let outside: UnsafeMutablePointer<UInt8>
    let control: OperationControl?

    func run<T: VoxelScalar>(_ values: UnsafePointer<T>) throws {
        let b = box, s = box.size
        let n1 = shape.y, n2 = shape.z
        let slope = sampler.slope, intercept = sampler.intercept
        let lo = range.lowerBound, hi = range.upperBound
        let sampler = self.sampler
        let maskLayer = self.maskLayer, maskClass = self.maskClass
        let inside = self.inside, outside = self.outside
        try Parallel.forEach(b.lower.x..<b.upper.x, grain: max(1, 65536 / max(1, s.y * s.z)), control: control) { slab in
            for k0 in slab {
                for k1 in b.lower.y..<b.upper.y {
                    let rowBase = (k0 * n1 + k1) * n2
                    let out = ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                    for x in b.lower.z..<b.upper.z {
                        let li = rowBase + x
                        if let m = maskLayer, m[li] != maskClass { continue }
                        let i = sampler.isAligned ? li : sampler.imageIndex(for: SIMD3(k0, k1, x), linear: li)
                        if i < 0 {
                            outside[out + x] = 1
                            continue
                        }
                        let v = values[i].doubleValue * slope + intercept
                        if v >= lo && v <= hi { inside[out + x] = 1 } else { outside[out + x] = 1 }
                    }
                }
            }
        }
    }
}
