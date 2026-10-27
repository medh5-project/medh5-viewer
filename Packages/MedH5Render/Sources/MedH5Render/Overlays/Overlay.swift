import Foundation
import simd
import MedH5Core

/// Marker shapes for points and keypoints.
public enum MarkerShape: Int, Sendable, CaseIterable, Codable {
    case circle = 0
    case square = 1
    case diamond = 2
    case triangle = 3
    /// An "×".
    case cross = 4
    /// A "+".
    case plus = 5
}

/// A dash pattern: lengths in points.
public struct DashPattern: Sendable, Hashable {
    public var on: Double
    public var off: Double
    public init(on: Double, off: Double) {
        self.on = on
        self.off = off
    }
    public static let short = DashPattern(on: 4, off: 3)
    public static let long = DashPattern(on: 8, off: 4)
}

/// How an overlay is drawn: colours are straight RGBA in `[0, 1]`, widths
/// and dash lengths in points.
public struct OverlayStyle: Sendable, Hashable {
    /// Stroke colour (lines, outlines, markers).
    public var color: SIMD4<Double>
    /// Stroke width in points.
    public var lineWidth: Double
    /// Dashes, or solid when `nil`.
    public var dash: DashPattern?
    /// Fill colour of polygons, boxes, circles and filled markers (the
    /// stroke colour for markers when `nil`).
    public var fillColor: SIMD4<Double>?

    public init(color: SIMD4<Double>, lineWidth: Double = 1.5, dash: DashPattern? = nil,
                fillColor: SIMD4<Double>? = nil) {
        self.color = color
        self.lineWidth = lineWidth
        self.dash = dash
        self.fillColor = fillColor
    }

    /// A solid stroke.
    public static func stroke(_ color: SIMD4<Double>, width: Double = 1.5) -> OverlayStyle {
        OverlayStyle(color: color, lineWidth: width)
    }
}

/// Whether overlay geometry away from the slice plane is drawn.
public enum OverlayDepthPolicy: Sendable, Hashable {
    /// Hidden beyond the scene's ``SliceScene/overlayDepthTolerance``
    /// (default: half the base image's voxel step along the normal).
    case automatic
    /// Projected onto the plane and always drawn (cursors, crosshairs).
    case always
    /// Hidden beyond `distance` mm from the plane (lines are clipped).
    case hide(beyond: Double)
    /// Fully drawn within `distance` mm, fading to invisible over the next
    /// `fade` mm.
    case fade(beyond: Double, over: Double)
}

/// An oriented box in world space: a centre and three half-axis vectors
/// (perpendicular, their lengths the half-extents).
public struct OrientedBox: Sendable, Equatable {
    public var center: SIMD3<Double>
    /// Columns are the half-axis vectors.
    public var halfAxes: simd_double3x3

    public init(center: SIMD3<Double>, halfAxes: simd_double3x3) {
        self.center = center
        self.halfAxes = halfAxes
    }

    /// The axis-aligned world box `[lower, upper]`.
    public init(lower: SIMD3<Double>, upper: SIMD3<Double>) {
        let h = (upper - lower) / 2
        center = (lower + upper) / 2
        halfAxes = simd_double3x3(diagonal: h)
    }

    /// A box in a grid's padded index coordinates at voxel edges (spec
    /// §8.1): `[lower, upper]` covers indices `floor(lower+0.5) ..<
    /// floor(upper+0.5)`; the box `[i − 0.5, j + 0.5]` covers voxels `i … j`.
    public init(indexLower lower: SIMD3<Double>, indexUpper upper: SIMD3<Double>, grid: GridGeometry) {
        let m = grid.indexToWorld
        let c = (lower + upper) / 2
        let h = (upper - lower) / 2
        center = m.transformPoint(c)
        halfAxes = simd_double3x3(columns: (m.transformVector(SIMD3(h.x, 0, 0)),
                                            m.transformVector(SIMD3(0, h.y, 0)),
                                            m.transformVector(SIMD3(0, 0, h.z))))
    }

    /// The eight corners (bit 0: ±axis 0, bit 1: ±axis 1, bit 2: ±axis 2).
    public var corners: [SIMD3<Double>] {
        (0..<8).map { i in
            // Typed signs: with the literals inline, Swift 6.3 gives up on
            // type-checking the sum.
            let s0: Double = (i & 1) != 0 ? 1 : -1
            let s1: Double = (i & 2) != 0 ? 1 : -1
            let s2: Double = (i & 4) != 0 ? 1 : -1
            return center + halfAxes.columns.0 * s0 + halfAxes.columns.1 * s1 + halfAxes.columns.2 * s2
        }
    }

    /// The twelve edges as corner index pairs.
    public static let edges: [(Int, Int)] = [
        (0, 1), (2, 3), (4, 5), (6, 7),
        (0, 2), (1, 3), (4, 6), (5, 7),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]
}

/// The geometry of an overlay, in world coordinates.
public enum OverlayShape: Sendable {
    /// A polyline; `closed` joins the last point to the first.
    case polyline([SIMD3<Double>], closed: Bool)
    /// A polygon with holes (rings), filled with the even-odd rule
    /// (`fillColor`) and outlined (`color`). Drawn when it lies within the
    /// depth tolerance of the plane.
    case polygon([[SIMD3<Double>]])
    /// Independent line segments: points `2i` and `2i + 1`.
    case segments([SIMD3<Double>])
    /// Point markers; `size` is the marker's diameter in points.
    case markers([SIMD3<Double>], shape: MarkerShape, size: Double, filled: Bool)
    /// A box: its intersection with the plane, or its projection while a
    /// thick slab is shown and the box overlaps it.
    case box(OrientedBox)
    /// A circle in the view plane of world radius `radius` (mm) around the
    /// projection of `center`; with `sphere`, the cross-section of a ball
    /// (a 3-D brush), which shrinks away from its centre.
    case circle(center: SIMD3<Double>, radius: Double, sphere: Bool, filled: Bool)
    /// A circle of fixed screen radius (points) at a world point.
    case screenCircle(center: SIMD3<Double>, radius: Double, filled: Bool)
}

/// A vector overlay drawn over the layers of a slice view.
public struct Overlay: Sendable {
    public var shape: OverlayShape
    public var style: OverlayStyle
    public var depthPolicy: OverlayDepthPolicy
    public var isVisible: Bool
    /// An app-defined identifier (for hit testing).
    public var tag: Int

    /// An overlay; `depthPolicy` decides what away from the plane is drawn.
    public init(_ shape: OverlayShape, style: OverlayStyle, depthPolicy: OverlayDepthPolicy = .automatic,
                tag: Int = 0) {
        self.shape = shape
        self.style = style
        self.depthPolicy = depthPolicy
        self.isVisible = true
        self.tag = tag
    }

    // MARK: Conveniences

    /// A crosshair through `point` spanning the viewport: two lines along the
    /// screen axes, with a gap of `gap` points around the centre.
    public static func crosshair(at point: SIMD3<Double>, camera: SliceCamera,
                                 color: SIMD4<Double> = SIMD4(0.3, 0.75, 1, 0.8),
                                 lineWidth: Double = 1, gap: Double = 12) -> Overlay {
        let p = camera.projectOntoPlane(point)
        let span = max(camera.extent.x, camera.extent.y) * 2
        let g = gap * camera.millimetersPerPixel * camera.pixelsPerPoint
        let r = camera.axes.right, d = camera.axes.down
        let points = [
            p - r * span, p - r * g, p + r * g, p + r * span,
            p - d * span, p - d * g, p + d * g, p + d * span,
        ]
        return Overlay(.segments(points), style: .stroke(color, width: lineWidth), depthPolicy: .always)
    }

    /// The contour of a mesh on the current plane (`MeshSlicer`), drawn as
    /// segments in the plane.
    public static func meshContour(_ slicer: MeshSlicer, camera: SliceCamera, style: OverlayStyle) -> Overlay {
        Overlay(.segments(slicer.segments(on: camera.plane)), style: style, depthPolicy: .always)
    }
}
