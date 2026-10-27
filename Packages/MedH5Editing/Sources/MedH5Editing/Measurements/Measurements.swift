import Foundation
import simd
import MedH5Core

/// A distance between two world points (in the grid's units, mm).
public struct RulerMeasurement: Sendable, Hashable {
    public var start: SIMD3<Double>
    public var end: SIMD3<Double>

    public init(start: SIMD3<Double>, end: SIMD3<Double>) {
        self.start = start
        self.end = end
    }

    /// A ruler between two continuous index positions of a grid.
    public init(startIndex: SIMD3<Double>, endIndex: SIMD3<Double>, geometry: GridGeometry) {
        self.init(start: geometry.world(fromIndex: startIndex), end: geometry.world(fromIndex: endIndex))
    }

    public var length: Double { simd_distance(start, end) }
    public var midpoint: SIMD3<Double> { (start + end) / 2 }
}

/// The angle at `vertex` between the rays to `first` and `second`.
public struct AngleMeasurement: Sendable, Hashable {
    public var first: SIMD3<Double>
    public var vertex: SIMD3<Double>
    public var second: SIMD3<Double>

    public init(first: SIMD3<Double>, vertex: SIMD3<Double>, second: SIMD3<Double>) {
        self.first = first
        self.vertex = vertex
        self.second = second
    }

    /// In 0…π; NaN when a ray has no length.
    public var radians: Double {
        let a = first - vertex, b = second - vertex
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0 && lb > 0 else { return .nan }
        // atan2 of |a × b| and a · b is accurate near 0 and π.
        return atan2(simd_length(simd_cross(a, b)), simd_dot(a, b))
    }

    public var degrees: Double { radians * 180 / .pi }
}

/// A plane in world space with in-plane coordinates: a point `origin + u ·
/// right + v · down` has plane coordinates `(u, v)` (world units).
public struct PlaneFrame: Sendable, Hashable {
    public var origin: SIMD3<Double>
    public var axes: PlaneAxes

    public init(origin: SIMD3<Double>, axes: PlaneAxes) {
        self.origin = origin
        self.axes = axes
    }

    public func world(_ uv: SIMD2<Double>) -> SIMD3<Double> {
        origin + axes.right * uv.x + axes.down * uv.y
    }

    public func planeCoordinates(of p: SIMD3<Double>) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(simd_dot(d, axes.right), simd_dot(d, axes.down))
    }

    /// Signed distance of a point from the plane, along the normal.
    public func distance(to p: SIMD3<Double>) -> Double { simd_dot(p - origin, axes.normal) }
}

/// Intensity statistics of a region of interest, with its geometric size.
public struct ROIStatistics: Sendable, Hashable {
    public var intensity: IntensityStatistics
    /// Voxels of the image inside the ROI.
    public var voxelCount: Int
    /// The ROI's area (planar, units²) or volume (sphere, units³), from its shape.
    public var size: Double
    /// Units of the values: the image's `valueUnits`, `HU` for a rescaled CT,
    /// nil for raw values.
    public var units: String?
}

/// A 2-D region of interest on a slice: an ellipse, a rectangle or a
/// freehand outline, in plane coordinates (world units) of a `PlaneFrame`.
///
/// The voxels it covers in a grid are those whose centre lies within half a
/// voxel of the plane (as for a disc brush: the voxels the plane cuts) and
/// projects into the shape.
public struct PlanarROI: Sendable, Hashable {
    public enum Shape: Sendable, Hashable {
        /// Axis-aligned in the plane: radii along `right` and `down`.
        case ellipse(center: SIMD2<Double>, radii: SIMD2<Double>)
        /// Two opposite corners.
        case rectangle(SIMD2<Double>, SIMD2<Double>)
        /// A closed outline (the last point joins the first).
        case polygon([SIMD2<Double>])
    }

    public var plane: PlaneFrame
    public var shape: Shape

    public init(plane: PlaneFrame, shape: Shape) {
        self.plane = plane
        self.shape = shape
    }

    /// Area in world units² (mm²).
    public var area: Double {
        switch shape {
        case let .ellipse(_, r): return Double.pi * abs(r.x) * abs(r.y)
        case let .rectangle(a, b): return abs((b.x - a.x) * (b.y - a.y))
        case .polygon(let p):
            guard p.count >= 3 else { return 0 }
            var s = 0.0
            for i in 0..<p.count {
                let a = p[i], b = p[(i + 1) % p.count]
                s += a.x * b.y - b.x * a.y
            }
            return abs(s) / 2
        }
    }

    /// Perimeter in world units (Ramanujan's approximation for an ellipse).
    public var perimeter: Double {
        switch shape {
        case let .ellipse(_, r):
            let a = abs(r.x), b = abs(r.y)
            return Double.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        case let .rectangle(a, b): return 2 * (abs(b.x - a.x) + abs(b.y - a.y))
        case .polygon(let p):
            guard p.count >= 2 else { return 0 }
            return (0..<p.count).reduce(0) { $0 + simd_distance(p[$1], p[($1 + 1) % p.count]) }
        }
    }

    /// Whether a point in plane coordinates is inside.
    public func contains(_ uv: SIMD2<Double>) -> Bool {
        switch shape {
        case let .ellipse(c, r):
            guard r.x != 0 && r.y != 0 else { return false }
            let d = (uv - c) / r
            return d.x * d.x + d.y * d.y <= 1
        case let .rectangle(a, b):
            let lo = simd_min(a, b), hi = simd_max(a, b)
            return uv.x >= lo.x && uv.x <= hi.x && uv.y >= lo.y && uv.y <= hi.y
        case .polygon(let p):
            return pointInPolygon(uv, p)
        }
    }

    var planeBounds: (SIMD2<Double>, SIMD2<Double>) {
        switch shape {
        case let .ellipse(c, r): return (c - abs(r), c + abs(r))
        case let .rectangle(a, b): return (simd_min(a, b), simd_max(a, b))
        case .polygon(let p):
            guard let f = p.first else { return (.zero, .zero) }
            return p.reduce((f, f)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        }
    }

    /// The voxels of a grid inside the ROI.
    public func region(in geometry: GridGeometry) -> VoxelRegion {
        let n = geometry.paddedShape
        let slab = DabGeometry(brush: Brush(radius: 1e12, shape: .disc(plane.axes)), center: plane.origin, geometry: geometry)
        let (lo, hi) = planeBounds
        // Index box of the shape's rectangle, thickened by the slab.
        var kLo = SIMD3<Double>(repeating: .infinity), kHi = SIMD3<Double>(repeating: -.infinity)
        for u in [lo.x, hi.x] {
            for v in [lo.y, hi.y] {
                for t in [-1.0, 1.0] {
                    let w = plane.world(SIMD2(u, v)) + plane.axes.normal * (t * slab.halfThickness)
                    let k = geometry.index(fromWorld: w)
                    kLo = simd_min(kLo, k)
                    kHi = simd_max(kHi, k)
                }
            }
        }
        guard kLo.x.isFinite && kHi.x.isFinite else { return .empty }
        let box = VoxelBox(lower: SIMD3(Int(kLo.x.rounded(.down)) - 1, Int(kLo.y.rounded(.down)) - 1, Int(kLo.z.rounded(.down)) - 1),
                           upper: SIMD3(Int(kHi.x.rounded(.up)) + 2, Int(kHi.y.rounded(.up)) + 2, Int(kHi.z.rounded(.up)) + 2))
            .clamped(to: n)
        guard !box.isEmpty else { return .empty }
        var spans: [VoxelRegion.Span] = []
        for k0 in box.lower.x..<box.upper.x {
            for k1 in box.lower.y..<box.upper.y {
                guard let (s, e) = slab.rowInterval(k0: k0, k1: k1, lo: box.lower.z, hi: box.upper.z - 1) else { continue }
                var runStart = -1
                for x in s...e {
                    let inside = contains(plane.planeCoordinates(of: geometry.world(fromIndex: SIMD3<Double>(SIMD3(k0, k1, x)))))
                    if inside && runStart < 0 { runStart = x }
                    if !inside && runStart >= 0 {
                        spans.append(VoxelRegion.Span(k0: k0, k1: k1, start: runStart, end: x))
                        runStart = -1
                    }
                }
                if runStart >= 0 { spans.append(VoxelRegion.Span(k0: k0, k1: k1, start: runStart, end: e + 1)) }
            }
        }
        return VoxelRegion(sortedSpans: spans)
    }

    /// Image statistics inside the ROI (physical values, e.g. HU, unless
    /// `physical` is false), over the image's own voxels.
    public func statistics(image: ImageVolume, physical: Bool = true, frame: [Int]? = nil,
                           control: OperationControl? = nil) throws -> ROIStatistics {
        let grid = image.geometry.spatialOnly
        let region = region(in: grid)
        let s = try SegmentationStatistics.intensity(over: region, grid: grid, image: image, physical: physical,
                                                     frame: frame, control: control)
        return ROIStatistics(intensity: s, voxelCount: region.memberCount, size: area,
                             units: valueUnits(of: image, physical: physical))
    }
}

/// A ball-shaped region of interest.
public struct SphereROI: Sendable, Hashable {
    public var center: SIMD3<Double>
    /// World units (mm).
    public var radius: Double

    public init(center: SIMD3<Double>, radius: Double) {
        self.center = center
        self.radius = radius
    }

    /// Volume in world units³ (mm³).
    public var volume: Double { 4.0 / 3.0 * Double.pi * radius * radius * radius }

    /// The voxels of a grid whose centre lies within the ball.
    public func region(in geometry: GridGeometry) -> VoxelRegion {
        let r = Brush.sphere(radius: radius).region(at: center, in: geometry)
        // A brush paints at least one voxel; a ball holding no centre holds none.
        if r.memberCount == 1, let s = r.spans.first,
           !Brush.sphere(radius: radius).contains(voxel: SIMD3(Int(s.k0), Int(s.k1), Int(s.start)), center: center, in: geometry) {
            return .empty
        }
        return r
    }

    public func statistics(image: ImageVolume, physical: Bool = true, frame: [Int]? = nil,
                           control: OperationControl? = nil) throws -> ROIStatistics {
        let grid = image.geometry.spatialOnly
        let region = region(in: grid)
        let s = try SegmentationStatistics.intensity(over: region, grid: grid, image: image, physical: physical,
                                                     frame: frame, control: control)
        return ROIStatistics(intensity: s, voxelCount: region.memberCount, size: volume,
                             units: valueUnits(of: image, physical: physical))
    }
}

/// The value of an image at a world point (the voxel containing it):
/// physical (HU for CT) unless `physical` is false; nil outside the image.
public func imageValue(_ image: ImageVolume, atWorld p: SIMD3<Double>, physical: Bool = true,
                       frame: [Int]? = nil) -> Double? {
    let grid = image.geometry.spatialOnly
    guard let k = grid.voxel(containingWorld: p) else { return nil }
    let sampler = ImageSampler(image: image, target: grid, frame: frame, physical: physical)
    let v = sampler.value(at: k, targetShape: grid.paddedShape)
    return v.isNaN ? nil : v
}

func valueUnits(of image: ImageVolume, physical: Bool) -> String? {
    guard physical else { return nil }
    if let u = image.valueUnits { return u }
    return image.modality.uppercased() == "CT" ? "HU" : nil
}
