import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// What the editing tools draw over a slice view: the brush cursor sized in
/// millimetres, rubber bands and curves in progress, the window's
/// measurements with their values, annotations with unsaved changes (drawn
/// from the pending edits), and the selected items of the listed
/// annotation. Part of the view's scene (`SliceSceneBuilder`), so it reaches
/// screenshots and snapshots too.
@MainActor
struct ToolOverlayBuilder {
    let workspace: Workspace
    let viewport: ViewportID
    let camera: SliceCamera
    let reference: GridGeometry
    /// One voxel step of the base grid along the normal.
    let sliceStep: Double

    var session: EditingSession { workspace.editing }
    var summary: SampleSummary { workspace.summary }

    nonisolated static let measurementColor = SIMD4<Double>(1, 0.80, 0.22, 1)
    nonisolated static let measurementText = RGBA8(255, 206, 64)
    nonisolated static let previewColor = SIMD4<Double>(1, 1, 1, 0.9)
    nonisolated static let selectionColor = SIMD4<Double>(1, 1, 1, 0.95)

    struct Built {
        var overlays: [Overlay] = []
        var labels: [ViewportLabel] = []
        var notes: [String] = []
    }

    /// The tools' overlays of this view.
    func build() -> Built {
        _ = session.revision
        var out = Built()
        measurements(&out)
        selection(&out)
        gesture(&out)
        return out
    }

    // MARK: Measurements

    /// Whether something drawn on a plane with normal `n` through `p` lies on
    /// this view's slice.
    private func onSlice(_ p: SIMD3<Double>, normal n: SIMD3<Double>) -> Bool {
        abs(simd_dot(simd_normalize(n), camera.normal)) > 0.999 && abs(camera.signedDistance(toPlane: p)) <= sliceStep * 0.5 + 1e-6
    }

    private func label(_ id: String, _ text: String, at p: SIMD3<Double>, dx: Double = 8, dy: Double = -6,
                       color: RGBA8 = ToolOverlayBuilder.measurementText) -> ViewportLabel {
        let q = camera.pixel(forWorld: p)
        let s = max(1, camera.pixelsPerPoint)
        return ViewportLabel(id: id, text: text, position: CGPoint(x: q.x / s + dx, y: q.y / s + dy), color: color)
    }

    private func measurements(_ out: inout Built) {
        let stackID = workspace.stack(for: viewport).id
        for m in session.measurements where m.stackID == stackID && onSlice(m.anchor, normal: m.planeNormal) {
            let selected = session.selectedMeasurements.contains(m.id)
            let style = OverlayStyle(color: Self.measurementColor, lineWidth: selected ? 2.5 : 1.5)
            let markers = OverlayStyle(color: Self.measurementColor, lineWidth: 1, fillColor: Self.measurementColor)
            switch m.shape {
            case .ruler(let r):
                out.overlays.append(Overlay(.segments([r.start, r.end]), style: style, depthPolicy: .always))
                out.overlays.append(Overlay(.markers([r.start, r.end], shape: .plus, size: 9, filled: false), style: style,
                                            depthPolicy: .always))
                out.labels.append(label("m\(m.id)", m.valueText, at: r.midpoint))
            case .angle(let a):
                out.overlays.append(Overlay(.polyline([a.first, a.vertex, a.second], closed: false), style: style, depthPolicy: .always))
                out.overlays.append(Overlay(.markers([a.first, a.vertex, a.second], shape: .circle, size: 6, filled: true),
                                            style: markers, depthPolicy: .always))
                out.labels.append(label("m\(m.id)", m.valueText, at: a.vertex))
            case .roi(let roi, _):
                out.overlays.append(Overlay(.polyline(roi.outline(), closed: true), style: style, depthPolicy: .always))
                let (lo, hi) = roi.planeRectangle
                let corner = roi.plane.world(SIMD2(min(lo.x, hi.x), min(lo.y, hi.y)))
                var text = "\(m.title) · \(m.valueText)"
                if let s = m.statistics, s.intensity.count > 0 {
                    text += " · \(Format.number(s.intensity.mean, digits: 1)) ± \(Format.number(s.intensity.standardDeviation, digits: 1))\(s.units.map { " \($0)" } ?? "")"
                }
                out.labels.append(label("m\(m.id)", text, at: corner, dx: 0, dy: -10))
            }
        }
    }

    // MARK: Gestures

    private func gesture(_ out: inout Built) {
        let state = session.viewState(viewport)
        let tool = workspace.viewer.tool
        if (tool == .brush || tool == .eraser), let p = state.pointer {
            let color = tool == .eraser ? SIMD4<Double>(1, 1, 1, 0.9) : brushColor()
            out.overlays.append(Overlay(.circle(center: p, radius: session.brush.radius, sphere: session.brush.isSphere, filled: false),
                                        style: OverlayStyle(color: color, lineWidth: 1.25, dash: tool == .eraser ? .short : nil),
                                        depthPolicy: .always))
        }
        guard let preview = state.preview, preview.belongs(to: tool) else { return }
        let dashed = OverlayStyle(color: Self.previewColor, lineWidth: 1.25, dash: .short)
        switch preview {
        case .box(let a, let b):
            out.overlays.append(Overlay(.polyline(rectangle(a, b), closed: true), style: dashed, depthPolicy: .always))
        case .roi(let kind, let a, let b):
            let points = kind == .rectangle ? rectangle(a, b) : ellipse(a, b)
            out.overlays.append(Overlay(.polyline(points, closed: true),
                                        style: OverlayStyle(color: Self.measurementColor, lineWidth: 1.25, dash: .short),
                                        depthPolicy: .always))
        case .ruler(let a, let b):
            out.overlays.append(Overlay(.segments([a, b]), style: OverlayStyle(color: Self.measurementColor, lineWidth: 1.5),
                                        depthPolicy: .always))
            out.labels.append(label("ruler-preview", "\(Format.number(simd_distance(a, b), digits: 2)) \(reference.units)",
                                    at: (a + b) / 2))
        case .angle(let p):
            out.overlays.append(Overlay(.polyline(p, closed: false), style: OverlayStyle(color: Self.measurementColor, lineWidth: 1.5),
                                        depthPolicy: .always))
            out.overlays.append(Overlay(.markers(p, shape: .circle, size: 6, filled: true),
                                        style: OverlayStyle(color: Self.measurementColor, lineWidth: 1, fillColor: Self.measurementColor),
                                        depthPolicy: .always))
            if p.count == 3 {
                let deg = AngleMeasurement(first: p[0], vertex: p[1], second: p[2]).degrees
                out.labels.append(label("angle-preview", "\(Format.number(deg, digits: 1))°", at: p[1]))
            }
        case .path(let vertices, let closed):
            let color = curveColor()
            var line = vertices
            if let p = state.pointer, let last = vertices.last, simd_distance(p, last) > 1e-9 { line.append(p) }
            out.overlays.append(Overlay(.polyline(line, closed: false), style: OverlayStyle(color: color, lineWidth: 1.75),
                                        depthPolicy: .always))
            if closed, line.count >= 3 {
                out.overlays.append(Overlay(.segments([line[line.count - 1], line[0]]),
                                            style: OverlayStyle(color: color, lineWidth: 1, dash: .short), depthPolicy: .always))
            }
            out.overlays.append(Overlay(.markers(vertices, shape: .square, size: 6, filled: true),
                                        style: OverlayStyle(color: color, lineWidth: 1, fillColor: color), depthPolicy: .always))
            if closed, vertices.count >= 3, let first = vertices.first {
                out.overlays.append(Overlay(.screenCircle(center: first, radius: 6, filled: false),
                                            style: OverlayStyle(color: Self.previewColor, lineWidth: 1.5), depthPolicy: .always))
            }
        }
    }

    /// The colour of the class the brush paints.
    private func brushColor() -> SIMD4<Double> {
        guard let id = session.activeSegmentation, let model = session.segmentationResource(id)?.model,
              let cls = session.activeClass(of: id, model: model), let c = model.classInfo(cls)?.color else {
            return SIMD4(1, 1, 1, 0.9)
        }
        var rgba = c.rgba
        rgba.w = 0.95
        return rgba
    }

    private func curveColor() -> SIMD4<Double> {
        guard let c = session.annotationClass(for: workspace.viewer.tool) else { return Self.previewColor }
        return classColor(c, labelSet: summary.labelSet).rgba
    }

    /// The rectangle on the plane with opposite corners `a` and `b`.
    private func rectangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [SIMD3<Double>] {
        let r = camera.axes.right, d = camera.axes.down
        let pa = camera.projectOntoPlane(a), pb = camera.projectOntoPlane(b)
        let du = simd_dot(pb - pa, r), dv = simd_dot(pb - pa, d)
        return [pa, pa + r * du, pa + r * du + d * dv, pa + d * dv]
    }

    private func ellipse(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [SIMD3<Double>] {
        let r = camera.axes.right, d = camera.axes.down
        let pa = camera.projectOntoPlane(a), pb = camera.projectOntoPlane(b)
        let c = (pa + pb) / 2
        let ru = abs(simd_dot(pb - pa, r)) / 2, rv = abs(simd_dot(pb - pa, d)) / 2
        return (0..<72).map { i in
            let t = Double(i) / 72 * 2 * .pi
            return c + r * (cos(t) * ru) + d * (sin(t) * rv)
        }
    }

    // MARK: Annotations

    /// The point mapper of an annotation into this view's frame (`nil` while
    /// its transform resolves, or when none relates them, with why).
    private func mapper(_ info: AnnotationInfo) -> (PointMapper?, String?) {
        let grid = info.grid.flatMap { summary.grid($0) }
        let key = PlacementResolver.pointKey(reference: reference, annotationGrid: grid, annotationFrame: info.frameUID)
        return PlacementResolver.pointMapper(key, store: workspace.store)
    }

    /// An annotation with unsaved changes, drawn from its pending edit.
    func pendingDraft(_ layer: DisplayLayer, info: AnnotationInfo) -> Built {
        var out = Built()
        guard let draft = session.draft(layer.id) else { return out }
        let (mapper, why) = mapper(info)
        guard let mapper else {
            if let why { out.notes.append("\(layer.id): \(why)") }
            return out
        }
        guard workspace.viewer.showsOverlays else { return out }
        let grid = info.grid.flatMap { summary.grid($0) }
        DraftOverlays(labelSet: summary.labelSet, camera: camera, sliceStep: sliceStep, grid: grid, mapper: mapper)
            .draw(draft, layer: layer, id: layer.id, into: &out)
        return out
    }

    /// The selected items of the listed annotation, outlined.
    private func selection(_ out: inout Built) {
        guard let id = session.listedAnnotation, !session.currentSelection.isEmpty,
              let layer = workspace.stack(for: viewport).layer(id), layer.isVisible, workspace.viewer.showsOverlays,
              let info = summary.annotation(id), let draft = session.draft(id) else { return }
        guard let mapper = mapper(info).0 else { return }
        let grid = info.grid.flatMap { summary.grid($0) }
        DraftOverlays(labelSet: summary.labelSet, camera: camera, sliceStep: sliceStep, grid: grid, mapper: mapper)
            .highlight(draft, items: session.currentSelection, into: &out)
    }
}

/// Draws an annotation draft (the editing library's sets) as the renderer's
/// overlays, as `GeometryOverlayBuilder` draws what the engine read.
@MainActor
struct DraftOverlays {
    var labelSet: LabelSetInfo?
    var camera: SliceCamera
    var sliceStep: Double
    var grid: GridGeometry?
    var mapper: PointMapper

    var nearPlane: OverlayDepthPolicy { .fade(beyond: sliceStep * 0.5, over: sliceStep * 2) }

    func color(_ classID: Int?) -> RGBA8 {
        guard let classID else { return GeometryOverlayBuilder.defaultColor }
        return classColor(classID, labelSet: labelSet)
    }

    /// A point of the draft's space in this view's frame.
    func world(_ p: SIMD3<Double>, space: AnnotationSpace) -> SIMD3<Double> {
        mapper.map(space == .index ? (grid?.world(fromIndex: p) ?? p) : p)
    }

    /// A box's eight corners in this view's frame (a box on a slice is one
    /// voxel thick).
    func corners(_ b: BoxAnnotation, space: AnnotationSpace) -> [SIMD3<Double>] {
        var lo = simd_min(b.lower, b.upper), hi = simd_max(b.lower, b.upper)
        for a in 0..<3 where lo[a] == hi[a] {
            let half = space == .index ? 0.5 : max(sliceStep * 0.5, 1e-3)
            lo[a] -= half
            hi[a] += half
        }
        return (0..<8).map { i in
            world(SIMD3((i & 4) != 0 ? hi.x : lo.x, (i & 2) != 0 ? hi.y : lo.y, (i & 1) != 0 ? hi.z : lo.z), space: space)
        }
    }

    func draw(_ draft: AnnotationDraft, layer: DisplayLayer, id: String, into out: inout ToolOverlayBuilder.Built) {
        let opacity = layer.opacity
        let width = layer.lineWidth
        func style(_ c: RGBA8, fill: Double? = nil, width w: Double? = nil) -> OverlayStyle {
            var rgba = c.rgba
            rgba.w *= opacity
            var s = OverlayStyle(color: rgba, lineWidth: w ?? width)
            if let fill { s.fillColor = SIMD4(rgba.x, rgba.y, rgba.z, fill * opacity) }
            return s
        }
        func visible(_ c: Int?) -> Bool { c.map { layer.isClassVisible($0) } ?? true }
        switch draft {
        case .boxes(let set):
            for (i, b) in set.boxes.enumerated() where visible(Int(b.classID)) {
                guard let box = GeometryOverlayBuilder.orientedBox(corners: corners(b, space: set.space)) else { continue }
                let c = color(Int(b.classID))
                out.overlays.append(Overlay(.box(box), style: style(c, fill: 0.10)))
                if layer.showsNames, let l = boxLabel(box, text: className(Int(b.classID), labelSet: labelSet), color: c, id: "\(id)#\(i)") {
                    out.labels.append(l)
                }
            }
        case .points(let set):
            for (i, p) in set.points.enumerated() where visible(p.classID.map(Int.init)) {
                let c = color(p.classID.map(Int.init))
                let w = world(p.position, space: set.space)
                out.overlays.append(Overlay(.markers([w], shape: .circle, size: 9, filled: true), style: style(c, fill: 1),
                                            depthPolicy: nearPlane))
                let name = p.name ?? p.classID.map { className(Int($0), labelSet: labelSet) }
                if layer.showsNames, let name, let l = pointLabel(w, text: name, color: c, id: "\(id)#\(i)") { out.labels.append(l) }
            }
        case .keypoints(let set):
            let edges = labelSet?.skeletons.first { $0.id == set.skeleton }?.edges ?? []
            for (n, o) in set.objects.enumerated() where visible(Int(o.classID)) {
                let points = o.points.map { world($0, space: set.space) }
                func placed(_ j: Int) -> Bool { j < o.visibility.count && o.visibility[j] != .unlabelled }
                var segments: [SIMD3<Double>] = []
                for e in edges where e.count == 2 {
                    guard let a = set.slotClassIDs.firstIndex(of: UInt16(clamping: e[0])),
                          let b = set.slotClassIDs.firstIndex(of: UInt16(clamping: e[1])), placed(a), placed(b) else { continue }
                    segments += [points[a], points[b]]
                }
                if !segments.isEmpty {
                    out.overlays.append(Overlay(.segments(segments), style: style(color(Int(o.classID)), width: max(1, width - 0.25)),
                                                depthPolicy: nearPlane))
                }
                for j in points.indices where placed(j) {
                    let kc = j < set.slotClassIDs.count ? Int(set.slotClassIDs[j]) : Int(o.classID)
                    let occluded = o.visibility[j] == .occluded
                    out.overlays.append(Overlay(.markers([points[j]], shape: occluded ? .circle : .diamond, size: 10, filled: !occluded),
                                                style: style(color(kc), fill: occluded ? nil : 1), depthPolicy: nearPlane))
                    if layer.showsNames, let l = pointLabel(points[j], text: className(kc, labelSet: labelSet), color: color(kc),
                                                            id: "\(id)#\(n).\(j)") {
                        out.labels.append(l)
                    }
                }
            }
        case .polylines(let set):
            for line in set.polylines where visible(Int(line.classID)) && line.vertices.count >= 2 {
                let points = line.vertices.map { world($0, space: set.space) }
                out.overlays.append(Overlay(.polyline(points, closed: false), style: style(color(Int(line.classID)), width: width + 0.5),
                                            depthPolicy: line.plane != nil ? .automatic : .fade(beyond: sliceStep * 0.5, over: sliceStep * 6)))
                if line.plane == nil {
                    let crossings = GeometryOverlayBuilder.crossings(points, plane: camera.plane)
                    if !crossings.isEmpty {
                        out.overlays.append(Overlay(.markers(crossings, shape: .circle, size: 7, filled: true),
                                                    style: style(color(Int(line.classID)), fill: 1), depthPolicy: .always))
                    }
                }
            }
        case .contours(let set):
            var groups: [String: (cls: Int, rings: [[SIMD3<Double>]])] = [:]
            var order: [String] = []
            for (i, c) in set.contours.enumerated() where visible(Int(c.classID)) && c.vertices.count >= 3 {
                let key = c.plane.map { "\(c.classID)@\($0.axis):\($0.index)" } ?? "\(c.classID)#\(i)"
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = (Int(c.classID), [])
                }
                groups[key]?.rings.append(c.vertices.map { world($0, space: set.space) })
            }
            for key in order {
                guard let g = groups[key] else { continue }
                out.overlays.append(Overlay(.polygon(g.rings), style: style(color(g.cls), fill: 0.22)))
            }
        }
    }

    /// Outlines of the selected items.
    func highlight(_ draft: AnnotationDraft, items: Set<Int>, into out: inout ToolOverlayBuilder.Built) {
        let s = OverlayStyle(color: ToolOverlayBuilder.selectionColor, lineWidth: 2.5)
        switch draft {
        case .boxes(let set):
            for i in items.sorted() where i < set.boxes.count {
                if let box = GeometryOverlayBuilder.orientedBox(corners: corners(set.boxes[i], space: set.space)) {
                    out.overlays.append(Overlay(.box(box), style: s))
                }
            }
        case .points(let set):
            let points = items.sorted().filter { $0 < set.points.count }.map { world(set.points[$0].position, space: set.space) }
            if !points.isEmpty {
                out.overlays.append(Overlay(.markers(points, shape: .circle, size: 16, filled: false), style: s, depthPolicy: nearPlane))
            }
        case .keypoints(let set):
            var points: [SIMD3<Double>] = []
            for i in items.sorted() where i < set.objects.count {
                let o = set.objects[i]
                for j in o.points.indices where j < o.visibility.count && o.visibility[j] != .unlabelled {
                    points.append(world(o.points[j], space: set.space))
                }
            }
            if !points.isEmpty {
                out.overlays.append(Overlay(.markers(points, shape: .circle, size: 16, filled: false), style: s, depthPolicy: nearPlane))
            }
        case .polylines(let set):
            for i in items.sorted() where i < set.polylines.count {
                let line = set.polylines[i]
                out.overlays.append(Overlay(.polyline(line.vertices.map { world($0, space: set.space) }, closed: false), style: s,
                                            depthPolicy: line.plane != nil ? .automatic : nearPlane))
            }
        case .contours(let set):
            for i in items.sorted() where i < set.contours.count {
                out.overlays.append(Overlay(.polyline(set.contours[i].vertices.map { world($0, space: set.space) }, closed: true),
                                            style: s))
            }
        }
    }

    private func boxLabel(_ box: OrientedBox, text: String, color: RGBA8, id: String) -> ViewportLabel? {
        let polygon = PlaneIntersection.polygon(box: box, plane: camera.plane)
        guard polygon.count >= 3 else { return nil }
        let pixels = polygon.map { camera.pixel(forWorld: $0) }
        guard let top = pixels.min(by: { ($0.y, $0.x) < ($1.y, $1.x) }) else { return nil }
        let left = pixels.map(\.x).min() ?? top.x
        let s = max(1, camera.pixelsPerPoint)
        return ViewportLabel(id: id, text: text, position: CGPoint(x: left / s, y: top.y / s - 2), color: color)
    }

    private func pointLabel(_ p: SIMD3<Double>, text: String, color: RGBA8, id: String) -> ViewportLabel? {
        let d = abs(camera.signedDistance(toPlane: p))
        let near = sliceStep * 0.5, fade = sliceStep * 2
        guard d <= near + fade else { return nil }
        let q = camera.pixel(forWorld: p)
        let s = max(1, camera.pixelsPerPoint)
        return ViewportLabel(id: id, text: text, position: CGPoint(x: q.x / s + 8, y: q.y / s - 7), color: color,
                             opacity: d <= near ? 1 : max(0, 1 - (d - near) / fade))
    }
}
