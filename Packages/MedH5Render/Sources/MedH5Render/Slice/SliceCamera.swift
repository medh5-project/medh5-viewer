import Foundation
import simd
import MedH5Core

/// Whether standard slice planes are true anatomical planes (reformatting an
/// oblique acquisition) or aligned with the base image's index axes.
public enum PlaneOrientationMode: String, Sendable, CaseIterable, Codable {
    case anatomical
    case aligned
}

/// The plane a slice view shows and how it maps to the drawable: a world
/// point at the viewport's centre, the world directions of screen-right and
/// screen-down (`PlaneAxes`), the zoom in millimetres per drawable pixel and
/// the viewport in pixels.
///
/// **Pixel coordinates** are drawable pixels with the origin at the top-left
/// corner and `y` growing downwards; pixel `(i, j)` covers
/// `[i, i+1) × [j, j+1)`, so its centre is `(i + 0.5, j + 0.5)` — the point
/// the renderer samples. The world point at continuous pixel `p` is
///
///     center + (p.x − W/2) · mm · right + (p.y − H/2) · mm · down
///
/// `pixelsPerPoint` is the backing scale factor (2 on Retina): line widths
/// and marker sizes are in points and scaled by it.
public struct SliceCamera: Sendable, Hashable {
    /// The world point at the viewport's centre (on the plane).
    public var center: SIMD3<Double>
    /// World directions of screen-right and screen-down.
    public var axes: PlaneAxes
    /// Zoom: millimetres (world units) per drawable pixel.
    public var millimetersPerPixel: Double
    /// Drawable size in pixels.
    public var viewportSize: SIMD2<Int>
    /// Backing scale factor (pixels per point).
    public var pixelsPerPoint: Double

    /// A camera from its plane, zoom and viewport.
    public init(center: SIMD3<Double>, axes: PlaneAxes, millimetersPerPixel: Double,
                viewportSize: SIMD2<Int>, pixelsPerPoint: Double = 1) {
        self.center = center
        self.axes = axes
        self.millimetersPerPixel = millimetersPerPixel
        self.viewportSize = viewportSize
        self.pixelsPerPoint = pixelsPerPoint
    }

    /// A standard plane through `grid`'s centre, sized to fit it.
    public static func standard(
        _ plane: ViewPlane,
        grid: GridGeometry,
        orientation: PlaneOrientationMode = .anatomical,
        convention: DisplayConvention = .radiological,
        viewportSize: SIMD2<Int>,
        pixelsPerPoint: Double = 1
    ) -> SliceCamera {
        let axes: PlaneAxes
        switch orientation {
        case .anatomical: axes = PlaneAxes.standard(plane, in: grid.coordinateSystem, convention: convention)
        case .aligned: axes = PlaneAxes.aligned(plane, to: grid, convention: convention)
        }
        var camera = SliceCamera(center: grid.worldCenter, axes: axes, millimetersPerPixel: 1,
                                 viewportSize: viewportSize, pixelsPerPoint: pixelsPerPoint)
        camera.fit(grid)
        camera.snapToVoxelCenters(of: grid)
        return camera
    }

    // MARK: Geometry

    /// The plane normal (`right × down`, pointing away from the viewer).
    public var normal: SIMD3<Double> { axes.normal }

    /// The plane as point and normal.
    public var plane: Plane { Plane(point: center, normal: normal) }

    /// Width and height of the viewport in millimetres.
    public var extent: SIMD2<Double> {
        SIMD2(Double(viewportSize.x), Double(viewportSize.y)) * millimetersPerPixel
    }

    /// Continuous pixel → world, homogeneous: `(px, py, 0, 1)` ↦ world. The
    /// third column is the plane normal (so `(px, py, d, 1)` is `d` mm in
    /// front of / behind the plane).
    public var pixelToWorld: simd_double4x4 {
        let r = axes.right * millimetersPerPixel
        let d = axes.down * millimetersPerPixel
        let origin = center - r * (Double(viewportSize.x) / 2) - d * (Double(viewportSize.y) / 2)
        return simd_double4x4(columns: (SIMD4(r, 0), SIMD4(d, 0), SIMD4(normal, 0), SIMD4(origin, 1)))
    }

    /// The world point at a continuous pixel position (on the plane).
    public func world(atPixel p: SIMD2<Double>) -> SIMD3<Double> {
        center + axes.right * ((p.x - Double(viewportSize.x) / 2) * millimetersPerPixel)
            + axes.down * ((p.y - Double(viewportSize.y) / 2) * millimetersPerPixel)
    }

    /// The pixel a world point projects to (along the normal).
    public func pixel(forWorld x: SIMD3<Double>) -> SIMD2<Double> {
        let v = x - center
        return SIMD2(simd_dot(v, axes.right) / millimetersPerPixel + Double(viewportSize.x) / 2,
                     simd_dot(v, axes.down) / millimetersPerPixel + Double(viewportSize.y) / 2)
    }

    /// Signed distance (mm) of a world point from the plane, positive away
    /// from the viewer.
    public func signedDistance(toPlane x: SIMD3<Double>) -> Double {
        simd_dot(x - center, normal)
    }

    /// The point's orthogonal projection onto the plane.
    public func projectOntoPlane(_ x: SIMD3<Double>) -> SIMD3<Double> {
        x - normal * signedDistance(toPlane: x)
    }

    /// The world corners of the viewport: top-left, top-right, bottom-right,
    /// bottom-left.
    public var worldCorners: [SIMD3<Double>] {
        let w = Double(viewportSize.x), h = Double(viewportSize.y)
        return [world(atPixel: SIMD2(0, 0)), world(atPixel: SIMD2(w, 0)),
                world(atPixel: SIMD2(w, h)), world(atPixel: SIMD2(0, h))]
    }

    // MARK: Navigation

    /// Moves the view so the content follows the pointer by `delta` pixels.
    public mutating func pan(byPixels delta: SIMD2<Double>) {
        center -= axes.right * (delta.x * millimetersPerPixel) + axes.down * (delta.y * millimetersPerPixel)
    }

    /// Zooms by `factor` (> 1 magnifies), keeping the world point under
    /// `pixel` fixed (the centre when `nil`).
    public mutating func zoom(by factor: Double, aboutPixel pixel: SIMD2<Double>? = nil) {
        guard factor > 0, factor.isFinite else { return }
        let anchor = pixel ?? SIMD2(Double(viewportSize.x) / 2, Double(viewportSize.y) / 2)
        let before = world(atPixel: anchor)
        millimetersPerPixel = min(1e4, max(1e-4, millimetersPerPixel / factor))
        let after = world(atPixel: anchor)
        center += before - after
    }

    /// Moves the plane along its normal by `distance` mm.
    public mutating func moveAlongNormal(by distance: Double) {
        center += normal * distance
    }

    /// Centres the view on a grid and zooms so its whole region fits with
    /// `margin` (a fraction of the viewport) to spare.
    public mutating func fit(_ grid: GridGeometry, margin: Double = 0.04) {
        fit(points: grid.worldCorners, margin: margin)
    }

    /// Centres the view on the points' in-plane bounding box and zooms to fit.
    public mutating func fit(points: [SIMD3<Double>], margin: Double = 0.04) {
        guard !points.isEmpty, viewportSize.x > 0, viewportSize.y > 0 else { return }
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for p in points {
            let v = SIMD2(simd_dot(p - center, axes.right), simd_dot(p - center, axes.down))
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        let size = hi - lo
        let mid = (lo + hi) / 2
        center += axes.right * mid.x + axes.down * mid.y
        let usable = SIMD2(Double(viewportSize.x), Double(viewportSize.y)) * (1 - 2 * margin)
        let mm = max(size.x / max(1, usable.x), size.y / max(1, usable.y))
        if mm > 0, mm.isFinite { millimetersPerPixel = mm }
    }

    /// Moves the plane along its normal to the nearest voxel centre of
    /// `grid` along the index axis closest to the normal, so a slice
    /// through an aligned grid samples voxel centres rather than blending
    /// two slices.
    public mutating func snapToVoxelCenters(of grid: GridGeometry) {
        let dirs = grid.axisDirections
        guard let axis = (0..<3).max(by: { abs(simd_dot(dirs[$0], normal)) < abs(simd_dot(dirs[$1], normal)) }),
              abs(simd_dot(dirs[axis], normal)) > 1e-6 else { return }
        let k = grid.index(fromWorld: center)
        let n = Double(grid.paddedShape[axis])
        let target = min(n - 1, max(0, k[axis].rounded()))
        let deltaIndex = target - k[axis]
        // Move along the normal by the distance that changes k[axis] by deltaIndex.
        let rate = simd_dot(dirs[axis], normal) / grid.paddedSpacing[axis]   // index per mm along the normal
        center += normal * (deltaIndex / rate)
    }

    /// The distance (mm) along the normal between consecutive voxel
    /// layers of `grid`: the step at which the index changes by at most one
    /// along every axis (the slice thickness for an aligned plane).
    public func voxelStep(of grid: GridGeometry) -> Double {
        let dirs = grid.axisDirections
        let sp = grid.paddedSpacing
        var rate = 0.0
        for a in 0..<3 where grid.paddedShape[a] > 1 || grid.spatialRank == 3 {
            rate = max(rate, abs(simd_dot(dirs[a], normal)) / sp[a])
        }
        return rate > 1e-12 ? 1 / rate : sp.min()
    }

    /// Moves the plane along its normal to slice `index` (clamped) of
    /// `grid`, counted along the index axis closest to the normal.
    public mutating func moveToSlice(_ index: Double, of grid: GridGeometry) {
        let s = sliceIndex(in: grid)
        let target = min(Double(s.count - 1), max(0, index))
        let dir = grid.axisDirections[s.axis]
        let rate = simd_dot(dir, normal) / grid.paddedSpacing[s.axis]   // index per mm along the normal
        guard abs(rate) > 1e-12 else { return }
        center += normal * ((target - s.index) / rate)
    }

    /// The slice index of the plane in `grid` along the index axis closest
    /// to the normal, and the number of slices along it.
    public func sliceIndex(in grid: GridGeometry) -> (index: Double, count: Int, axis: Int) {
        let dirs = grid.axisDirections
        let axis = (0..<3).max(by: { abs(simd_dot(dirs[$0], normal)) < abs(simd_dot(dirs[$1], normal)) }) ?? 0
        let k = grid.index(fromWorld: center)
        return (k[axis], grid.paddedShape[axis], axis)
    }
}

/// A plane in world space: a point on it and its unit normal.
public struct Plane: Sendable, Hashable {
    public var point: SIMD3<Double>
    public var normal: SIMD3<Double>

    public init(point: SIMD3<Double>, normal: SIMD3<Double>) {
        self.point = point
        let l = simd_length(normal)
        self.normal = l > 0 ? normal / l : SIMD3(0, 0, 1)
    }

    /// Signed distance, positive on the side the normal points to.
    public func signedDistance(_ p: SIMD3<Double>) -> Double { simd_dot(p - point, normal) }

    /// The orthogonal projection of `p` onto the plane.
    public func project(_ p: SIMD3<Double>) -> SIMD3<Double> { p - normal * signedDistance(p) }
}
