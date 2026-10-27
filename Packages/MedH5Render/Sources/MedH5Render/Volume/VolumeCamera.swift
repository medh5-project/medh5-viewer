import Foundation
import simd
import MedH5Core

/// The direction a 3-D view looks at the patient from.
public enum AnatomicalView: String, Sendable, CaseIterable, Codable {
    case anterior
    case posterior
    case left
    case right
    case superior
    case inferior
}

/// An orbit camera for the 3-D view: it looks at `target` from `distance`
/// mm away, oriented by `orientation` (camera → world rotation; the camera
/// looks along its −z with +y up and +x right, OpenGL style).
///
/// Orthographic projection shows the same height as the perspective one at
/// the target's depth, so switching keeps the image size.
public struct VolumeCamera: Sendable, Equatable {
    /// Perspective or orthographic projection.
    public enum Projection: String, Sendable, Codable {
        case perspective
        case orthographic
    }

    /// The point the camera looks at and orbits about.
    public var target: SIMD3<Double>
    /// Camera → world rotation.
    public var orientation: simd_quatd
    /// Distance from the eye to the target (mm).
    public var distance: Double
    /// Vertical field of view in degrees.
    public var fieldOfView: Double
    public var projection: Projection
    /// Drawable size in pixels.
    public var viewportSize: SIMD2<Int>
    /// Radius of the scene around `target` (sets the near and far planes).
    public var sceneRadius: Double

    public init(target: SIMD3<Double>, orientation: simd_quatd, distance: Double, fieldOfView: Double = 30,
                projection: Projection = .perspective, viewportSize: SIMD2<Int>, sceneRadius: Double) {
        self.target = target
        self.orientation = orientation
        self.distance = distance
        self.fieldOfView = fieldOfView
        self.projection = projection
        self.viewportSize = viewportSize
        self.sceneRadius = sceneRadius
    }

    /// A camera looking at a box (world bounds) from an anatomical direction,
    /// framed to fit. `system` is the world's coordinate system.
    public static func framing(
        bounds: (min: SIMD3<Double>, max: SIMD3<Double>),
        from view: AnatomicalView = .anterior,
        coordinateSystem system: CoordinateSystem = .lps,
        viewportSize: SIMD2<Int>,
        fieldOfView: Double = 30,
        projection: Projection = .perspective
    ) -> VolumeCamera {
        let center = (bounds.min + bounds.max) / 2
        let radius = max(1e-3, simd_length(bounds.max - bounds.min) / 2)
        let orientation = Self.orientation(for: view, system: system)
        let aspect = Double(max(1, viewportSize.x)) / Double(max(1, viewportSize.y))
        let halfFov = fieldOfView * .pi / 360
        // Fit the bounding sphere in the narrower of the two fields of view.
        let fit = min(tan(halfFov), tan(halfFov) * aspect)
        let distance = radius / sin(atan(fit)) * 1.02
        return VolumeCamera(target: center, orientation: orientation, distance: distance, fieldOfView: fieldOfView,
                            projection: projection, viewportSize: viewportSize, sceneRadius: radius)
    }

    /// The camera rotation for an anatomical view (anterior: patient facing
    /// the viewer, superior up, the patient's left on screen right).
    public static func orientation(for view: AnatomicalView, system: CoordinateSystem = .lps) -> simd_quatd {
        // In LPS: x = left, y = posterior, z = superior.
        let l = SIMD3<Double>(1, 0, 0), p = SIMD3<Double>(0, 1, 0), s = SIMD3<Double>(0, 0, 1)
        let (right, up): (SIMD3<Double>, SIMD3<Double>)
        switch view {
        case .anterior: (right, up) = (l, s)
        case .posterior: (right, up) = (-l, s)
        case .left: (right, up) = (p, s)
        case .right: (right, up) = (-p, s)
        case .superior: (right, up) = (l, -p)
        case .inferior: (right, up) = (l, p)
        }
        var r = right, u = up
        if let m = system.fromLPS {
            r = m * right
            u = m * up
        }
        let back = simd_cross(r, u)   // camera +z (towards the viewer)
        let rot = simd_double3x3(columns: (r, u, back))
        return simd_quatd(rot)
    }

    // MARK: Derived

    /// Camera right, up and forward (viewing direction) in world space.
    public var right: SIMD3<Double> { orientation.act(SIMD3(1, 0, 0)) }
    public var up: SIMD3<Double> { orientation.act(SIMD3(0, 1, 0)) }
    public var forward: SIMD3<Double> { orientation.act(SIMD3(0, 0, -1)) }

    /// The eye position.
    public var eye: SIMD3<Double> { target - forward * distance }

    public var aspect: Double { Double(max(1, viewportSize.x)) / Double(max(1, viewportSize.y)) }

    /// Height of the view (mm) at the target's depth.
    public var viewHeight: Double { 2 * distance * tan(fieldOfView * .pi / 360) }

    /// World → camera.
    public var viewMatrix: simd_double4x4 {
        let r = right, u = up, b = -forward, e = eye
        return simd_double4x4(rows: [
            SIMD4(r.x, r.y, r.z, -simd_dot(r, e)),
            SIMD4(u.x, u.y, u.z, -simd_dot(u, e)),
            SIMD4(b.x, b.y, b.z, -simd_dot(b, e)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// Near and far plane distances.
    public var clipRange: (near: Double, far: Double) {
        let r = max(sceneRadius, 1e-3) * 1.05
        switch projection {
        case .perspective:
            return (max(distance - r, max(1e-2, distance * 1e-3)), distance + r)
        case .orthographic:
            return (distance - r, distance + r)
        }
    }

    /// Camera → clip (Metal: depth in [0, 1]).
    public var projectionMatrix: simd_double4x4 {
        let (n, f) = clipRange
        switch projection {
        case .perspective:
            let y = 1 / tan(fieldOfView * .pi / 360)
            let x = y / aspect
            return simd_double4x4(columns: (
                SIMD4(x, 0, 0, 0),
                SIMD4(0, y, 0, 0),
                SIMD4(0, 0, f / (n - f), -1),
                SIMD4(0, 0, n * f / (n - f), 0)
            ))
        case .orthographic:
            let h = viewHeight, w = h * aspect
            return simd_double4x4(columns: (
                SIMD4(2 / w, 0, 0, 0),
                SIMD4(0, 2 / h, 0, 0),
                SIMD4(0, 0, 1 / (n - f), 0),
                SIMD4(0, 0, n / (n - f), 1)
            ))
        }
    }

    /// World → clip.
    public var viewProjection: simd_double4x4 { projectionMatrix * viewMatrix }

    /// The ray through a continuous pixel (top-left origin): origin on the
    /// near plane and unit direction.
    public func ray(atPixel p: SIMD2<Double>) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let ndc = SIMD2(p.x / Double(viewportSize.x) * 2 - 1, 1 - p.y / Double(viewportSize.y) * 2)
        let inv = viewProjection.inverse
        let a = inv * SIMD4(ndc.x, ndc.y, 0, 1)
        let b = inv * SIMD4(ndc.x, ndc.y, 1, 1)
        let o = SIMD3(a.x, a.y, a.z) / a.w
        let f = SIMD3(b.x, b.y, b.z) / b.w
        return (o, simd_normalize(f - o))
    }

    /// The pixel a world point projects to (top-left origin) and its depth
    /// in `[0, 1]`, or `nil` behind the camera.
    public func project(_ x: SIMD3<Double>) -> (pixel: SIMD2<Double>, depth: Double)? {
        let c = viewProjection * SIMD4(x, 1)
        guard c.w > 1e-12 else { return nil }
        let ndc = SIMD3(c.x, c.y, c.z) / c.w
        return (SIMD2((ndc.x + 1) / 2 * Double(viewportSize.x), (1 - ndc.y) / 2 * Double(viewportSize.y)), ndc.z)
    }

    /// World units per pixel at the target's depth.
    public var millimetersPerPixel: Double { viewHeight / Double(max(1, viewportSize.y)) }

    // MARK: Navigation

    /// Rotates the camera about the target as if dragging the scene by
    /// `delta` pixels (right drags turn the scene right).
    public mutating func orbit(byPixels delta: SIMD2<Double>, radiansPerPixel: Double = 0.008) {
        let yaw = simd_quatd(angle: -delta.x * radiansPerPixel, axis: up)
        let pitch = simd_quatd(angle: -delta.y * radiansPerPixel, axis: right)
        orientation = simd_normalize(yaw * pitch * orientation)
    }

    /// Rolls the camera about its viewing direction.
    public mutating func roll(by radians: Double) {
        orientation = simd_normalize(simd_quatd(angle: radians, axis: forward) * orientation)
    }

    /// Moves the target so the scene follows the pointer by `delta` pixels.
    public mutating func pan(byPixels delta: SIMD2<Double>) {
        let mm = millimetersPerPixel
        target += -right * (delta.x * mm) + up * (delta.y * mm)
    }

    /// Zooms by `factor` (> 1 magnifies) by moving closer.
    public mutating func zoom(by factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        distance = min(1e6, max(1e-2, distance / factor))
    }
}
