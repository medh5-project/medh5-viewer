import AppKit
import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// A measurement made in a window: a distance, an angle, or a region of
/// interest with its statistics. Measurements belong to the window and are
/// not written into the file.
struct ViewerMeasurement: Identifiable, Equatable {
    enum Shape: Equatable {
        case ruler(RulerMeasurement)
        case angle(AngleMeasurement)
        case roi(PlanarROI, kind: ROIShapeKind)
    }

    /// Its number in the window (Ruler 1, Angle 2…).
    let id: Int
    var shape: Shape
    /// The stack whose frame its points are in (`primary` or `compare`).
    var stackID: String
    /// The base image it was made on (an ROI's statistics are of it).
    var imageID: String
    /// The world units and coordinate system of its frame.
    var units: String
    var coordinateSystem: String
    /// The normal of the plane it was drawn on.
    var planeNormal: SIMD3<Double>
    /// An ROI's statistics, in the image's physical units.
    var statistics: ROIStatistics?

    var kindName: String {
        switch shape {
        case .ruler: return "Ruler"
        case .angle: return "Angle"
        case .roi(_, let kind): return "ROI (\(kind.title.lowercased()))"
        }
    }

    var title: String {
        switch shape {
        case .ruler: return "Ruler \(id)"
        case .angle: return "Angle \(id)"
        case .roi: return "ROI \(id)"
        }
    }

    var symbol: String {
        switch shape {
        case .ruler: return ViewerTool.ruler.symbol
        case .angle: return ViewerTool.angle.symbol
        case .roi(_, let kind): return kind == .ellipse ? "circle.dashed" : "rectangle.dashed"
        }
    }

    /// The main value, as text: `23.4 mm`, `37.2°`, `1 234.5 mm²`.
    var valueText: String {
        switch shape {
        case .ruler(let r): return "\(Format.number(r.length, digits: 2)) \(units)"
        case .angle(let a): return "\(Format.number(a.degrees, digits: 1))°"
        case .roi(let roi, _): return "\(Format.number(roi.area, digits: 1)) \(units)²"
        }
    }

    /// An ROI's statistics as text.
    var detailText: String? {
        guard case .roi = shape else { return nil }
        guard let s = statistics, s.intensity.count > 0 else { return "No image voxel inside" }
        let u = s.units.map { " \($0)" } ?? ""
        let i = s.intensity
        return "mean \(Format.number(i.mean, digits: 1)) ± \(Format.number(i.standardDeviation, digits: 1))\(u) · min \(Format.number(i.minimum, digits: 1)) · max \(Format.number(i.maximum, digits: 1)) · \(Format.integer(s.voxelCount)) voxels"
    }

    /// The defining points (world, its frame): a ruler's ends, an angle's
    /// arm, vertex and arm, an ROI's opposite corners.
    var points: [SIMD3<Double>] {
        switch shape {
        case .ruler(let r): return [r.start, r.end]
        case .angle(let a): return [a.first, a.vertex, a.second]
        case .roi(let roi, _):
            let (lo, hi) = roi.planeRectangle
            return [roi.plane.world(lo), roi.plane.world(hi)]
        }
    }

    /// Where the crosshair goes for it.
    var anchor: SIMD3<Double> {
        switch shape {
        case .ruler(let r): return r.midpoint
        case .angle(let a): return a.vertex
        case .roi(let roi, _):
            let (lo, hi) = roi.planeRectangle
            return roi.plane.world((lo + hi) / 2)
        }
    }

    /// Rulers and angles can become polylines (format 1.2).
    var isCurve: Bool {
        switch shape {
        case .ruler, .angle: return true
        case .roi: return false
        }
    }

    /// One line of text for the pasteboard.
    var text: String {
        var line = "\(title)\t\(valueText)"
        if let d = detailText { line += "\t\(d)" }
        return line
    }
}

extension PlanarROI {
    /// The shape's bounding rectangle in plane coordinates.
    var planeRectangle: (SIMD2<Double>, SIMD2<Double>) {
        switch shape {
        case let .ellipse(c, r): return (c - abs(r), c + abs(r))
        case let .rectangle(a, b): return (simd_min(a, b), simd_max(a, b))
        case .polygon(let p):
            guard let f = p.first else { return (.zero, .zero) }
            return p.reduce((f, f)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        }
    }

    /// The outline in world coordinates (an ellipse as a polygon).
    func outline(segments: Int = 72) -> [SIMD3<Double>] {
        switch shape {
        case let .ellipse(c, r):
            return (0..<segments).map { i in
                let t = Double(i) / Double(segments) * 2 * .pi
                return plane.world(c + SIMD2(cos(t), sin(t)) * r)
            }
        case let .rectangle(a, b):
            let lo = simd_min(a, b), hi = simd_max(a, b)
            return [SIMD2(lo.x, lo.y), SIMD2(hi.x, lo.y), SIMD2(hi.x, hi.y), SIMD2(lo.x, hi.y)].map { plane.world($0) }
        case .polygon(let p):
            return p.map { plane.world($0) }
        }
    }
}

/// The CSV export of measurements (File ▸ Export ▸ Measurements).
///
/// One row per measurement under a fixed header; numbers are plain decimals
/// with a point (a value that does not apply is empty), text is quoted
/// when it holds a comma, quote or line break (RFC 4180), lines end with
/// LF. Points are world coordinates of the measurement's frame, in its
/// units: a ruler's ends, an angle's first arm, vertex and second arm, an
/// ROI's opposite corners on its plane.
enum MeasurementCSV {
    static let header = ["number", "kind", "value", "unit", "mean", "sd", "min", "max", "voxels", "value_unit", "image",
                         "coordinate_system", "x1", "y1", "z1", "x2", "y2", "z2", "x3", "y3", "z3"]

    static func make(_ measurements: [ViewerMeasurement]) -> String {
        var lines = [header.joined(separator: ",")]
        for m in measurements {
            var row: [String] = [String(m.id)]
            switch m.shape {
            case .ruler(let r): row += ["ruler", number(r.length), m.units]
            case .angle(let a): row += ["angle", number(a.degrees), "deg"]
            case .roi(let roi, let kind): row += ["roi-\(kind.rawValue)", number(roi.area), "\(m.units)2"]
            }
            if case .roi = m.shape, let s = m.statistics, s.intensity.count > 0 {
                let i = s.intensity
                row += [number(i.mean, digits: 4), number(i.standardDeviation, digits: 4), number(i.minimum, digits: 4),
                        number(i.maximum, digits: 4), String(s.voxelCount), s.units ?? ""]
            } else if case .roi = m.shape {
                row += ["", "", "", "", String(m.statistics?.voxelCount ?? 0), m.statistics?.units ?? ""]
            } else {
                row += ["", "", "", "", "", ""]
            }
            row += [m.imageID, m.coordinateSystem]
            let p = m.points
            for i in 0..<3 {
                if i < p.count {
                    row += [number(p[i].x), number(p[i].y), number(p[i].z)]
                } else {
                    row += ["", "", ""]
                }
            }
            lines.append(row.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func number(_ v: Double, digits: Int = 3) -> String {
        guard v.isFinite else { return "" }
        var s = String(format: "%.\(digits)f", v)
        if s.hasPrefix("-"), Double(s) == 0 { s.removeFirst() }
        return s
    }

    static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension EditingSession {
    // MARK: Measurements

    /// What the measuring tools need of a view: its stack's base image and
    /// frame.
    private func measurementContext(_ viewport: ViewportID) throws -> (stack: LayerStack, image: String, grid: GridGeometry) {
        let stack = workspace.stack(for: viewport)
        guard let base = stack.base, let grid = workspace.referenceGrid(of: stack) else {
            throw EditingFailure("There is no image to measure")
        }
        return (stack, base.id, grid)
    }

    private func newMeasurement(_ shape: ViewerMeasurement.Shape, viewport: ViewportID, normal: SIMD3<Double>) throws -> ViewerMeasurement {
        let c = try measurementContext(viewport)
        let m = ViewerMeasurement(id: nextMeasurementNumber, shape: shape, stackID: c.stack.id, imageID: c.image,
                                  units: c.grid.units, coordinateSystem: c.grid.coordSystem, planeNormal: normal)
        nextMeasurementNumber += 1
        return m
    }

    @discardableResult
    func addRuler(from a: SIMD3<Double>, to b: SIMD3<Double>, viewport: ViewportID, normal: SIMD3<Double>) throws -> ViewerMeasurement {
        let m = try newMeasurement(.ruler(RulerMeasurement(start: a, end: b)), viewport: viewport, normal: normal)
        measurements.append(m)
        selectedMeasurements = [m.id]
        return m
    }

    @discardableResult
    func addAngle(_ first: SIMD3<Double>, vertex: SIMD3<Double>, _ second: SIMD3<Double>, viewport: ViewportID,
                  normal: SIMD3<Double>) throws -> ViewerMeasurement {
        let m = try newMeasurement(.angle(AngleMeasurement(first: first, vertex: vertex, second: second)), viewport: viewport,
                                   normal: normal)
        measurements.append(m)
        selectedMeasurements = [m.id]
        return m
    }

    /// An ROI dragged from corner `a` to `b` on a view's plane; its
    /// statistics are of the base image (physical values) when it is loaded.
    @discardableResult
    func addROI(_ kind: ROIShapeKind, from a: SIMD3<Double>, to b: SIMD3<Double>, camera: SliceCamera,
                viewport: ViewportID) throws -> ViewerMeasurement {
        let plane = PlaneFrame(origin: camera.center, axes: camera.axes)
        let ua = plane.planeCoordinates(of: a), ub = plane.planeCoordinates(of: b)
        let shape: PlanarROI.Shape = kind == .ellipse
            ? .ellipse(center: (ua + ub) / 2, radii: abs(ub - ua) / 2)
            : .rectangle(ua, ub)
        let roi = PlanarROI(plane: plane, shape: shape)
        var m = try newMeasurement(.roi(roi, kind: kind), viewport: viewport, normal: camera.normal)
        m.statistics = roiStatistics(roi, viewport: viewport)
        measurements.append(m)
        selectedMeasurements = [m.id]
        return m
    }

    /// The statistics of an ROI over the view's base image.
    func roiStatistics(_ roi: PlanarROI, viewport: ViewportID) -> ROIStatistics? {
        let stack = workspace.stack(for: viewport)
        guard let base = stack.base, let image = store.ready(.image(base.id), as: ImageResource.self)?.volume else { return nil }
        return try? roi.statistics(image: image, physical: true, frame: base.frameIndex(for: image.geometry))
    }

    func deleteMeasurements(_ ids: Set<Int>) {
        measurements.removeAll { ids.contains($0.id) }
        selectedMeasurements.subtract(ids)
    }

    /// The measurements selected, else every one.
    var measurementsForCommands: [ViewerMeasurement] {
        let selected = measurements.filter { selectedMeasurements.contains($0.id) }
        return selected.isEmpty ? measurements : selected
    }

    /// Copies measurements as text (one per line) and CSV.
    @discardableResult
    func copyMeasurements(_ list: [ViewerMeasurement], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !list.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("public.comma-separated-values-text")], owner: nil)
        pasteboard.setString(list.map(\.text).joined(separator: "\n"), forType: .string)
        pasteboard.setString(MeasurementCSV.make(list), forType: NSPasteboard.PasteboardType("public.comma-separated-values-text"))
        return true
    }

    /// Moves the crosshair to a measurement.
    func jump(toMeasurement id: Int) {
        guard let m = measurements.first(where: { $0.id == id }) else { return }
        let viewport: ViewportID
        if m.stackID == workspace.compare?.id, workspace.viewer.layout == .compare {
            viewport = .compareRight
        } else {
            viewport = workspace.viewer.activeViewport.isSlice && workspace.viewer.activeViewport != .compareRight
                ? workspace.viewer.activeViewport : .slice(.axial)
        }
        workspace.setCursor(m.anchor, from: viewport)
    }

    /// Stores rulers and angles as polylines of the active polyline
    /// annotation (or a new one), one undo step (format 1.2).
    func saveMeasurementsAsPolylines(_ ids: Set<Int>) throws {
        let list = measurements.filter { ids.contains($0.id) && $0.isCurve }
        guard let first = list.first else { throw EditingFailure("Choose rulers or angles") }
        let viewport: ViewportID = first.stackID == workspace.compare?.id ? .compareRight : .slice(.axial)
        let t = try drawingTarget(.polyline, viewport: viewport)
        guard case .polylines(var set) = t.draft else { throw EditingFailure("\(t.id) holds no polylines") }
        guard let cls = annotationClass(for: .polyline) else { throw EditingFailure("Choose a class for new items in the Annotations tab") }
        let before = set.polylines.count
        for m in list where m.stackID == first.stackID {
            let vertices = m.points.map { Self.own($0, space: set.space, grid: t.grid) }
            set.polylines.append(Polyline(vertices: vertices, classID: UInt16(cls)))
        }
        if set.polylines.count > before, before > 0, set.polylines[..<before].allSatisfy({ $0.instanceID != nil }) {
            var next = (set.polylines.compactMap(\.instanceID).max() ?? 0) + 1
            for i in before..<set.polylines.count {
                set.polylines[i].instanceID = next
                next += 1
            }
        }
        try store(.polylines(set), target: t, name: "Save as Polyline Annotation", select: Set(before..<set.polylines.count))
    }
}
