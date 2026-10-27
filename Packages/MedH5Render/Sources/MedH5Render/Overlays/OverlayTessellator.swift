import Foundation
import simd
import MedH5Core

/// Overlay geometry ready for the GPU: vertices and the draws that use them
/// in order.
struct OverlayBatch {
    enum Command {
        /// Signed-distance primitives (lines, rings, discs, markers).
        case primitives(Range<Int>)
        /// An even-odd polygon fill: stencil fan triangles, then a cover quad.
        case fill(stencil: Range<Int>, cover: Range<Int>)
    }

    var vertices: [OverlayVertex] = []
    var commands: [Command] = []

    mutating func reset() {
        vertices.removeAll(keepingCapacity: true)
        commands.removeAll(keepingCapacity: true)
    }
}

/// Turns world-space overlays into screen-space quads for one slice camera:
/// projects, clips or fades by distance from the plane, and expands strokes
/// into quads carrying the local coordinates the fragment shader needs for
/// analytic anti-aliasing and dashes.
///
/// A renderer keeps one and calls ``begin(camera:tolerance:slab:)`` every
/// frame, so its vertex storage is reused rather than reallocated.
struct OverlayTessellator {
    private(set) var camera = SliceCamera(center: .zero, axes: PlaneAxes(right: SIMD3(1, 0, 0), down: SIMD3(0, 1, 0)),
                                          millimetersPerPixel: 1, viewportSize: SIMD2(1, 1))
    /// Distance (mm) beyond which `.automatic` geometry is hidden.
    private(set) var tolerance = 0.5
    private(set) var slab = SlabSettings()
    private(set) var batch = OverlayBatch()

    private var primitiveStart: Int?

    init() {}

    init(camera: SliceCamera, tolerance: Double, slab: SlabSettings) {
        begin(camera: camera, tolerance: tolerance, slab: slab)
    }

    /// Starts a frame: clears the geometry (keeping its storage).
    mutating func begin(camera: SliceCamera, tolerance: Double, slab: SlabSettings) {
        self.camera = camera
        self.tolerance = tolerance
        self.slab = slab
        batch.reset()
        primitiveStart = nil
    }

    // Kinds understood by overlay_fragment.
    private static let kindSolid: Float = 0
    private static let kindLine: Float = 1
    private static let kindRing: Float = 2
    private static let kindDisc: Float = 3
    private static let kindMarker: Float = 4

    private var ppp: Double { camera.pixelsPerPoint }

    /// Ends the frame's geometry; read it from ``batch``.
    mutating func finish() {
        closePrimitives()
    }

    // MARK: Overlays

    mutating func add(_ overlay: Overlay) {
        guard overlay.isVisible else { return }
        let style = overlay.style
        let policy = overlay.depthPolicy
        switch overlay.shape {
        case .polyline(let points, let closed):
            addPolyline(points, closed: closed, style: style, policy: policy)
        case .segments(let points):
            var i = 0
            while i + 1 < points.count {
                var phase = 0.0
                addWorldSegment(points[i], points[i + 1], style: style, policy: policy, phase: &phase)
                i += 2
            }
        case .polygon(let rings):
            addPolygon(rings, style: style, policy: policy)
        case .markers(let points, let shape, let size, let filled):
            for p in points {
                guard let alpha = visibility(camera.signedDistance(toPlane: p), policy) else { continue }
                addMarker(at: camera.pixel(forWorld: p), shape: shape, size: size, filled: filled, style: style,
                          alpha: alpha)
            }
        case .box(let box):
            addBox(box, style: style)
        case .circle(let center, let radius, let sphere, let filled):
            let d = camera.signedDistance(toPlane: center)
            var r = radius
            var alpha = 1.0
            if sphere {
                guard abs(d) < radius else { return }
                r = (radius * radius - d * d).squareRoot()
            } else {
                guard let a = visibility(d, policy) else { return }
                alpha = a
            }
            addCircle(center: camera.pixel(forWorld: center), radiusPixels: r / camera.millimetersPerPixel,
                      filled: filled, style: style, alpha: alpha)
        case .screenCircle(let center, let radius, let filled):
            guard let alpha = visibility(camera.signedDistance(toPlane: center), policy) else { return }
            addCircle(center: camera.pixel(forWorld: center), radiusPixels: radius * ppp, filled: filled,
                      style: style, alpha: alpha)
        }
    }

    // MARK: Depth policy

    /// The opacity factor for geometry at distance `d` from the plane, or
    /// `nil` when hidden.
    private func visibility(_ d: Double, _ policy: OverlayDepthPolicy) -> Double? {
        let ad = abs(d)
        switch policy {
        case .always: return 1
        case .automatic: return ad <= tolerance ? 1 : nil
        case .hide(let limit): return ad <= limit ? 1 : nil
        case .fade(let limit, let fade):
            if ad <= limit { return 1 }
            if fade > 0 && ad < limit + fade { return 1 - (ad - limit) / fade }
            return nil
        }
    }

    /// Geometry beyond this distance is clipped away.
    private func clipDistance(_ policy: OverlayDepthPolicy) -> Double {
        switch policy {
        case .always: return .infinity
        case .automatic: return tolerance
        case .hide(let limit): return limit
        case .fade(let limit, let fade): return limit + max(0, fade)
        }
    }

    // MARK: Lines

    private mutating func addPolyline(_ points: [SIMD3<Double>], closed: Bool, style: OverlayStyle,
                                      policy: OverlayDepthPolicy) {
        guard points.count >= 2 else {
            if let p = points.first, let a = visibility(camera.signedDistance(toPlane: p), policy) {
                addScreenSegment(camera.pixel(forWorld: p), camera.pixel(forWorld: p), a, a, style: style, phase: 0)
            }
            return
        }
        var phase = 0.0
        for i in 0..<(points.count - 1) {
            addWorldSegment(points[i], points[i + 1], style: style, policy: policy, phase: &phase)
        }
        if closed && points.count > 2 {
            addWorldSegment(points[points.count - 1], points[0], style: style, policy: policy, phase: &phase)
        }
    }

    /// A world segment, clipped to the visible slab and split where its
    /// fade changes slope; `phase` (dash arc length in pixels) advances by
    /// the segment's projected length.
    private mutating func addWorldSegment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, style: OverlayStyle,
                                          policy: OverlayDepthPolicy, phase: inout Double) {
        let pa = camera.pixel(forWorld: a), pb = camera.pixel(forWorld: b)
        let length = simd_distance(pa, pb)
        defer { phase += length }
        if case .always = policy {
            addScreenSegment(pa, pb, 1, 1, style: style, phase: phase)
            return
        }
        let da = camera.signedDistance(toPlane: a), db = camera.signedDistance(toPlane: b)
        let limit = clipDistance(policy)
        var s0 = 0.0, s1 = 1.0
        if abs(db - da) < 1e-12 {
            if abs(da) > limit { return }
        } else {
            let u = (limit - da) / (db - da), v = (-limit - da) / (db - da)
            s0 = max(0, min(u, v))
            s1 = min(1, max(u, v))
            if s0 >= s1 { return }
        }
        // Break points where the fade is not linear in s.
        var breaks = [s0, s1]
        if case .fade(let full, _) = policy, abs(db - da) > 1e-12 {
            for target in [-full, 0, full] {
                let s = (target - da) / (db - da)
                if s > s0 && s < s1 { breaks.append(s) }
            }
        }
        breaks.sort()
        for k in 0..<(breaks.count - 1) {
            let sa = breaks[k], sb = breaks[k + 1]
            guard sb - sa > 1e-9 else { continue }
            let alphaA = visibility(da + (db - da) * sa, policy) ?? 0
            let alphaB = visibility(da + (db - da) * sb, policy) ?? 0
            addScreenSegment(pa + (pb - pa) * sa, pa + (pb - pa) * sb, alphaA, alphaB, style: style,
                             phase: phase + length * sa)
        }
    }

    /// One anti-aliased stroke quad from `p0` to `p1` (pixels).
    private mutating func addScreenSegment(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ alpha0: Double,
                                           _ alpha1: Double, style: OverlayStyle, phase: Double) {
        let hw = max(0.25, style.lineWidth * ppp / 2)
        let e = hw + 1.5
        var dir = p1 - p0
        let len = simd_length(dir)
        dir = len > 1e-9 ? dir / len : SIMD2(1, 0)
        let nrm = SIMD2(-dir.y, dir.x)
        let c0 = color(style.color, alpha: alpha0)
        let c1 = color(style.color, alpha: alpha1)
        let shape = SIMD4<Float>(Float(len), Float(hw), 0, 0)
        let dashOn = Float((style.dash?.on ?? 0) * ppp), dashOff = Float((style.dash?.off ?? 0) * ppp)
        let st = SIMD4<Float>(dashOn, dashOff, Float(phase), Self.kindLine)
        func v(_ along: Double, _ across: Double, _ c: SIMD4<Float>) -> OverlayVertex {
            let p = p0 + dir * along + nrm * across
            return OverlayVertex(position: SIMD2<Float>(p), local: SIMD2<Float>(Float(along), Float(across)),
                                 color: c, shape: shape, style: st)
        }
        let a = v(-e, -e, c0), b = v(-e, e, c0), c = v(len + e, e, c1), d = v(len + e, -e, c1)
        appendPrimitiveQuad(a, b, c, d)
    }

    // MARK: Polygons and boxes

    private mutating func addPolygon(_ rings: [[SIMD3<Double>]], style: OverlayStyle, policy: OverlayDepthPolicy) {
        let valid = rings.filter { $0.count >= 3 }
        guard !valid.isEmpty else { return }
        var inPlane = true
        if case .always = policy {} else {
            inPlane = valid.allSatisfy { ring in
                ring.allSatisfy { visibility(camera.signedDistance(toPlane: $0), policy) != nil }
            }
        }
        if inPlane, let fill = style.fillColor {
            addFill(valid.map { $0.map { camera.pixel(forWorld: $0) } }, color: fill)
        }
        for ring in valid {
            addPolyline(ring, closed: true, style: style, policy: policy)
        }
    }

    private mutating func addBox(_ box: OrientedBox, style: OverlayStyle) {
        let plane = camera.plane
        var outline: [SIMD3<Double>] = []
        if slab.isActive {
            let d = box.corners.map { plane.signedDistance($0) }
            let half = slab.thickness / 2
            if (d.min() ?? 0) <= half && (d.max() ?? 0) >= -half {
                outline = PlaneIntersection.projectedOutline(box: box, plane: plane)
            }
        } else {
            outline = PlaneIntersection.polygon(box: box, plane: plane)
        }
        guard outline.count >= 3 else { return }
        if let fill = style.fillColor {
            addFill([outline.map { camera.pixel(forWorld: $0) }], color: fill)
        }
        addPolyline(outline, closed: true, style: style, policy: .always)
    }

    /// Even-odd fill of pixel-space rings: a fan per ring into the stencil,
    /// then a cover quad over their bounds.
    private mutating func addFill(_ rings: [[SIMD2<Double>]], color fillColor: SIMD4<Double>) {
        closePrimitives()
        let c = color(fillColor, alpha: 1)
        let zero = SIMD4<Float>(0, 0, 0, 0)
        let solid = SIMD4<Float>(0, 0, 0, Self.kindSolid)
        func v(_ p: SIMD2<Double>) -> OverlayVertex {
            OverlayVertex(position: SIMD2<Float>(p), local: .zero, color: c, shape: zero, style: solid)
        }
        let stencilStart = batch.vertices.count
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for ring in rings {
            for p in ring {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            for i in 1..<(ring.count - 1) {
                batch.vertices.append(v(ring[0]))
                batch.vertices.append(v(ring[i]))
                batch.vertices.append(v(ring[i + 1]))
            }
        }
        let coverStart = batch.vertices.count
        lo -= 1
        hi += 1
        let q = [v(lo), v(SIMD2(hi.x, lo.y)), v(hi), v(lo), v(hi), v(SIMD2(lo.x, hi.y))]
        batch.vertices += q
        batch.commands.append(.fill(stencil: stencilStart..<coverStart, cover: coverStart..<batch.vertices.count))
    }

    // MARK: Markers and circles

    private mutating func addMarker(at p: SIMD2<Double>, shape: MarkerShape, size: Double, filled: Bool,
                                    style: OverlayStyle, alpha: Double) {
        let r = max(1, size * ppp / 2)
        let hw = max(0.5, style.lineWidth * ppp / 2)
        let strokeOnly = shape == .cross || shape == .plus
        if filled && !strokeOnly {
            addMarkerQuad(p, r: r, shape: shape, filled: true, hw: hw, color: color(style.fillColor ?? style.color, alpha: alpha))
            if style.fillColor != nil {
                addMarkerQuad(p, r: r, shape: shape, filled: false, hw: hw, color: color(style.color, alpha: alpha))
            }
        } else {
            addMarkerQuad(p, r: r, shape: shape, filled: false, hw: hw, color: color(style.color, alpha: alpha))
        }
    }

    private mutating func addMarkerQuad(_ p: SIMD2<Double>, r: Double, shape: MarkerShape, filled: Bool, hw: Double,
                                        color c: SIMD4<Float>) {
        let e = r * 1.25 + hw + 1.5
        let sh = SIMD4<Float>(Float(r), Float(shape.rawValue), filled ? 1 : 0, Float(hw))
        let st = SIMD4<Float>(0, 0, 0, Self.kindMarker)
        func v(_ dx: Double, _ dy: Double) -> OverlayVertex {
            OverlayVertex(position: SIMD2<Float>(p + SIMD2(dx, dy)), local: SIMD2<Float>(Float(dx), Float(dy)),
                          color: c, shape: sh, style: st)
        }
        appendPrimitiveQuad(v(-e, -e), v(e, -e), v(e, e), v(-e, e))
    }

    private mutating func addCircle(center p: SIMD2<Double>, radiusPixels r: Double, filled: Bool,
                                    style: OverlayStyle, alpha: Double) {
        let hw = max(0.25, style.lineWidth * ppp / 2)
        let e = r + hw + 1.5
        func quad(kind: Float, shape: SIMD4<Float>, color c: SIMD4<Float>, dash: SIMD2<Float>) {
            let st = SIMD4<Float>(dash.x, dash.y, 0, kind)
            func v(_ dx: Double, _ dy: Double) -> OverlayVertex {
                OverlayVertex(position: SIMD2<Float>(p + SIMD2(dx, dy)), local: SIMD2<Float>(Float(dx), Float(dy)),
                              color: c, shape: shape, style: st)
            }
            appendPrimitiveQuad(v(-e, -e), v(e, -e), v(e, e), v(-e, e))
        }
        if filled {
            quad(kind: Self.kindDisc, shape: SIMD4(Float(r), 0, 0, 0),
                 color: color(style.fillColor ?? style.color, alpha: alpha), dash: .zero)
        }
        if !filled || style.fillColor != nil {
            let dash = SIMD2<Float>(Float((style.dash?.on ?? 0) * ppp), Float((style.dash?.off ?? 0) * ppp))
            quad(kind: Self.kindRing, shape: SIMD4(Float(r), Float(hw), 0, 0), color: color(style.color, alpha: alpha),
                 dash: dash)
        }
    }

    // MARK: Emission

    private func color(_ c: SIMD4<Double>, alpha: Double) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(min(1, max(0, c.w * alpha))))
    }

    private mutating func appendPrimitiveQuad(_ a: OverlayVertex, _ b: OverlayVertex, _ c: OverlayVertex,
                                              _ d: OverlayVertex) {
        if primitiveStart == nil { primitiveStart = batch.vertices.count }
        batch.vertices += [a, b, c, a, c, d]
    }

    private mutating func closePrimitives() {
        if let start = primitiveStart, start < batch.vertices.count {
            batch.commands.append(.primitives(start..<batch.vertices.count))
        }
        primitiveStart = nil
    }
}
