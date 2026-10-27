import Foundation
import simd
import MedH5Kit
import MedH5Render

/// A text label drawn by a viewport's overlay (point names, box classes).
struct ViewportLabel: Identifiable, Equatable {
    var id: String
    var text: String
    /// Position in view points (top-left origin).
    var position: CGPoint
    var color: RGBA8
    /// 0…1, for labels of geometry fading with its distance to the plane.
    var opacity: Double = 1
}

/// Turns geometric annotations into the renderer's vector overlays for one
/// slice camera: boxes and oriented boxes as their cut by the plane,
/// keypoints with their skeleton, points with names, contours filled with
/// their holes, polylines, mesh contours. Geometry in another frame is
/// mapped into the view's reference frame first (`PointMapper`).
@MainActor
struct GeometryOverlayBuilder {
    var labelSet: LabelSetInfo?
    var camera: SliceCamera
    /// One voxel step of the base grid along the normal.
    var sliceStep: Double

    static let defaultColor = RGBA8(77, 210, 255)

    func color(_ classID: Int?) -> RGBA8 {
        guard let classID else { return Self.defaultColor }
        return classColor(classID, labelSet: labelSet)
    }

    /// Fully drawn within half a slice, fading out over two more.
    var nearPlane: OverlayDepthPolicy { .fade(beyond: sliceStep * 0.5, over: sliceStep * 2) }

    func build(_ annotation: GeometricAnnotation, meshes: [MeshPart], layer: DisplayLayer, mapper: PointMapper)
        -> (overlays: [Overlay], labels: [ViewportLabel]) {
        let opacity = layer.opacity
        let width = layer.lineWidth
        var overlays: [Overlay] = []
        var labels: [ViewportLabel] = []
        func visible(_ classID: Int?) -> Bool {
            guard let classID else { return true }
            return layer.isClassVisible(classID)
        }
        func style(_ c: RGBA8, fill: Double? = nil, width w: Double? = nil) -> OverlayStyle {
            var rgba = c.rgba
            rgba.w *= opacity
            var s = OverlayStyle(color: rgba, lineWidth: w ?? width)
            if let fill { s.fillColor = SIMD4(rgba.x, rgba.y, rgba.z, fill * opacity) }
            return s
        }

        switch annotation {
        case .boxes(let b):
            for (i, corners) in b.worldCorners.enumerated() where i < b.classIDs.count || b.classIDs.isEmpty {
                let cls = i < b.classIDs.count ? b.classIDs[i] : nil
                guard visible(cls), let box = Self.orientedBox(corners: mapper.map(corners)) else { continue }
                let c = color(cls)
                overlays.append(Overlay(.box(box), style: style(c, fill: 0.10)))
                if layer.showsNames, let label = boxLabel(box, text: boxText(cls, score: b.scores?[safe: i]), color: c,
                                                          id: "\(b.header.annotation)#\(i)") {
                    labels.append(label)
                }
            }
        case .orientedBoxes(let b):
            for (i, corners) in b.worldCorners.enumerated() {
                let cls = i < b.classIDs.count ? b.classIDs[i] : nil
                guard visible(cls), let box = Self.orientedBox(corners: mapper.map(corners)) else { continue }
                let c = color(cls)
                overlays.append(Overlay(.box(box), style: style(c, fill: 0.10)))
                if layer.showsNames, let label = boxLabel(box, text: boxText(cls, score: b.scores?[safe: i]), color: c,
                                                          id: "\(b.header.annotation)#\(i)") {
                    labels.append(label)
                }
            }
        case .keypoints(let k):
            for (n, set) in k.worldPoints.enumerated() {
                let setClass = n < k.classIDs.count ? k.classIDs[n] : nil
                guard visible(setClass) else { continue }
                let points = mapper.map(set)
                let vis = n < k.visibility.count ? k.visibility[n] : Array(repeating: UInt8(2), count: points.count)
                var segments: [SIMD3<Double>] = []
                for edge in k.skeletonEdges where edge.count == 2 {
                    guard let a = k.keypointClassIDs.firstIndex(of: edge[0]), let b = k.keypointClassIDs.firstIndex(of: edge[1]),
                          a < points.count, b < points.count, vis[safe: a] ?? 0 > 0, vis[safe: b] ?? 0 > 0 else { continue }
                    segments += [points[a], points[b]]
                }
                if !segments.isEmpty {
                    overlays.append(Overlay(.segments(segments), style: style(color(setClass), width: max(1, width - 0.25)),
                                            depthPolicy: nearPlane))
                }
                for (j, p) in points.enumerated() where (vis[safe: j] ?? 2) > 0 {
                    let kc = j < k.keypointClassIDs.count ? k.keypointClassIDs[j] : setClass
                    let c = color(kc)
                    let occluded = vis[safe: j] == 1
                    overlays.append(Overlay(.markers([p], shape: occluded ? .circle : .diamond, size: 10, filled: !occluded),
                                            style: style(c, fill: occluded ? nil : 1), depthPolicy: nearPlane))
                    if layer.showsNames, let kc, let l = pointLabel(p, text: className(kc, labelSet: labelSet), color: c,
                                                                   id: "\(k.header.annotation)#\(n).\(j)") {
                        labels.append(l)
                    }
                }
            }
        case .points(let ps):
            let points = mapper.map(ps.worldPoints)
            for (i, p) in points.enumerated() {
                let cls = ps.classIDs?[safe: i]
                guard visible(cls) else { continue }
                let c = color(cls)
                overlays.append(Overlay(.markers([p], shape: .circle, size: 9, filled: true),
                                        style: style(c, fill: 1), depthPolicy: nearPlane))
                let name = ps.names?[safe: i] ?? cls.map { className($0, labelSet: labelSet) }
                if layer.showsNames, let name, let l = pointLabel(p, text: name, color: c, id: "\(ps.header.annotation)#\(i)") {
                    labels.append(l)
                }
            }
        case .contours(let cs):
            // A class's polygons in one plane combine by depth (§8.6): drawn
            // together with the even-odd rule, holes stay open.
            var groups: [String: (cls: Int, rings: [[SIMD3<Double>]])] = [:]
            var order: [String] = []
            for (i, poly) in cs.polygons.enumerated() where visible(poly.classID) && poly.worldVertices.count >= 3 {
                let key = poly.plane.axis >= 0 ? "\(poly.classID)@\(poly.plane.axis):\(poly.plane.index)" : "\(poly.classID)#\(i)"
                if groups[key] == nil { order.append(key); groups[key] = (poly.classID, []) }
                groups[key]?.rings.append(mapper.map(poly.worldVertices))
            }
            for key in order {
                guard let g = groups[key] else { continue }
                overlays.append(Overlay(.polygon(g.rings), style: style(color(g.cls), fill: 0.22)))
            }
        case .polylines(let pl):
            for line in pl.polylines where visible(line.classID) && line.worldVertices.count >= 2 {
                let c = color(line.classID)
                let points = mapper.map(line.worldVertices)
                let inPlane = line.plane.axis >= 0
                overlays.append(Overlay(.polyline(points, closed: false), style: style(c, width: width + 0.5),
                                        depthPolicy: inPlane ? .automatic : .fade(beyond: sliceStep * 0.5, over: sliceStep * 6)))
                // Where a 3-D curve crosses the plane.
                if !inPlane {
                    let crossings = Self.crossings(points, plane: camera.plane)
                    if !crossings.isEmpty {
                        overlays.append(Overlay(.markers(crossings, shape: .circle, size: 7, filled: true),
                                                style: style(c, fill: 1), depthPolicy: .always))
                    }
                }
            }
        case .mesh:
            for part in meshes where visible(part.classID) {
                let segments: [SIMD3<Double>]
                if let m = mapper.matrix {
                    // Cut the mesh by the plane carried into its own frame,
                    // then carry the cut back.
                    let inv = m.inverse
                    let p = inv.transformPoint(camera.center)
                    let n = simd_normalize((m.transpose * SIMD4(camera.normal, 0)).xyz)
                    segments = part.slicer.segments(on: Plane(point: p, normal: n)).map { m.transformPoint($0) }
                } else if mapper.isIdentity {
                    segments = part.slicer.segments(on: camera.plane)
                } else {
                    continue
                }
                guard !segments.isEmpty else { continue }
                overlays.append(Overlay(.segments(segments), style: style(color(part.classID), width: width + 0.25),
                                        depthPolicy: .always))
            }
        case .classification:
            break
        }
        return (overlays, labels)
    }

    private func boxText(_ cls: Int?, score: Float?) -> String {
        var t = cls.map { className($0, labelSet: labelSet) } ?? "box"
        if let score { t += " " + Format.number(Double(score), digits: 2) }
        return t
    }

    /// A label at the top-left of a box's cut by the plane, when it cuts it.
    private func boxLabel(_ box: OrientedBox, text: String, color: RGBA8, id: String) -> ViewportLabel? {
        let polygon = PlaneIntersection.polygon(box: box, plane: camera.plane)
        guard polygon.count >= 3 else { return nil }
        let pixels = polygon.map { camera.pixel(forWorld: $0) }
        guard let top = pixels.min(by: { ($0.y, $0.x) < ($1.y, $1.x) }) else { return nil }
        let left = pixels.map(\.x).min() ?? top.x
        let s = camera.pixelsPerPoint
        return ViewportLabel(id: id, text: text, position: CGPoint(x: left / s, y: top.y / s - 2), color: color)
    }

    /// A label beside a point near the plane.
    private func pointLabel(_ p: SIMD3<Double>, text: String, color: RGBA8, id: String) -> ViewportLabel? {
        let d = abs(camera.signedDistance(toPlane: p))
        let near = sliceStep * 0.5, fade = sliceStep * 2
        guard d <= near + fade else { return nil }
        let opacity = d <= near ? 1 : max(0, 1 - (d - near) / fade)
        let q = camera.pixel(forWorld: p)
        let s = camera.pixelsPerPoint
        return ViewportLabel(id: id, text: text, position: CGPoint(x: q.x / s + 8, y: q.y / s - 7), color: color,
                             opacity: opacity)
    }

    /// The box through `2^S` corners in odometer order (first axis slowest;
    /// corner 0 every lower bound): centre and half-axis vectors. A 2-D box
    /// gets a thickness of one unit across its plane.
    static func orientedBox(corners c: [SIMD3<Double>]) -> OrientedBox? {
        if c.count == 8 {
            let a0 = (c[4] - c[0]) / 2, a1 = (c[2] - c[0]) / 2, a2 = (c[1] - c[0]) / 2
            let center = c.reduce(SIMD3<Double>.zero, +) / 8
            return OrientedBox(center: center, halfAxes: simd_double3x3(columns: (a0, a1, a2)))
        }
        if c.count == 4 {
            let a0 = (c[2] - c[0]) / 2, a1 = (c[1] - c[0]) / 2
            var n = simd_cross(a0, a1)
            n = simd_length(n) > 1e-12 ? simd_normalize(n) * 0.5 : SIMD3(0, 0, 0.5)
            let center = c.reduce(SIMD3<Double>.zero, +) / 4
            return OrientedBox(center: center, halfAxes: simd_double3x3(columns: (a0, a1, n)))
        }
        return nil
    }

    /// The points where a polyline crosses a plane.
    static func crossings(_ points: [SIMD3<Double>], plane: Plane) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let da = plane.signedDistance(a), db = plane.signedDistance(b)
            if (da <= 0 && db > 0) || (da > 0 && db <= 0) {
                let t = da / (da - db)
                out.append(a + (b - a) * t)
            }
        }
        return out
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension GeometricAnnotation {
    /// The header of a geometric annotation (`nil` for a classification).
    var header: Header? {
        switch self {
        case .boxes(let a): return a.header
        case .orientedBoxes(let a): return a.header
        case .keypoints(let a): return a.header
        case .points(let a): return a.header
        case .contours(let a): return a.header
        case .polylines(let a): return a.header
        case .mesh(let a): return a.header
        case .classification: return nil
        }
    }
}

extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}
