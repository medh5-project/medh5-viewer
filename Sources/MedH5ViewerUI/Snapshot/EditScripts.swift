import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// Scripted edits of the snapshot mode (`--edit`): the editing tools driven
/// through their handlers with synthetic events in the axial view, so a
/// capture shows what they draw — strokes, operations, annotation items,
/// measurements, and gestures left in progress.
@MainActor
enum EditScript {
    nonisolated static let names = ["segment", "annotate", "measure", "all"]

    static func run(_ name: String, workspace w: Workspace) async throws {
        try await waitForViews(w)
        let c = focus(w)
        w.setCursor(c, from: .slice(.axial))
        w.viewer.activeViewport = .slice(.axial)
        switch name {
        case "segment": try await segment(w, c)
        case "annotate": try annotate(w, c)
        case "measure": try measure(w, c)
        default:
            try await segment(w, c)
            try annotate(w, c)
            try measure(w, c)
        }
        if let m = w.editing.message, m.isError { throw SnapshotError("--edit \(name): \(m.text)") }
        try await waitForViews(w)
    }

    /// Waits for what the views need (the base image, shown segmentations).
    static func waitForViews(_ w: Workspace) async throws {
        for _ in 0..<3 {
            for key in w.neededResources() where w.store.failure(key) == nil {
                _ = try? await w.store.resource(key)
            }
        }
    }

    /// The demo's lesion when the base grid holds it, else the grid's centre.
    static func focus(_ w: Workspace) -> SIMD3<Double> {
        guard let grid = w.referenceGrid(of: w.primary) else { return w.viewer.cursor }
        return grid.voxel(containingWorld: Demo.lesionCentre) != nil ? Demo.lesionCentre : grid.worldCenter
    }

    /// The axial view's camera (at the crosshair).
    static func camera(_ w: Workspace) throws -> SliceCamera {
        guard let cam = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(800, 800), scale: 1).camera else {
            throw SnapshotError("--edit: no axial view")
        }
        return cam
    }

    private static func send(_ w: Workspace, _ kind: ViewEventKind, _ p: SIMD3<Double>, _ cam: SliceCamera,
                             clicks: Int = 1, key: UInt16? = nil) {
        _ = w.editing.handle(ToolEvent(kind: kind, world: p, pixel: cam.pixel(forWorld: p), clickCount: clicks, keyCode: key),
                             viewport: .slice(.axial), camera: cam)
    }

    private static func drag(_ w: Workspace, _ points: [SIMD3<Double>], _ cam: SliceCamera) {
        guard let first = points.first, let last = points.last else { return }
        send(w, .mouseDown, first, cam)
        for p in points.dropFirst() { send(w, .mouseDragged, p, cam) }
        send(w, .mouseUp, last, cam)
    }

    private static func click(_ w: Workspace, _ p: SIMD3<Double>, _ cam: SliceCamera, clicks: Int = 1) {
        send(w, .mouseDown, p, cam, clicks: clicks)
        send(w, .mouseUp, p, cam, clicks: clicks)
    }

    // MARK: Scripts

    /// A new segmentation; a brush stroke around the lesion; Fill Holes
    /// (2-D) closing it into a disc; the brush cursor left beside it.
    static func segment(_ w: Workspace, _ c: SIMD3<Double>) async throws {
        let s = w.editing
        let labels = w.summary.labelSet
        var request = s.defaultNewSegmentation()
        request.id = s.uniqueID("viewer_segmentation")
        request.classIDs = [2, 9].filter { labels?.labelClass(id: $0) != nil }
        try s.createSegmentation(request)
        if request.classIDs.isEmpty {
            try s.createClass(name: "Lesion", color: RGBA8(230, 80, 60), segmentation: request.id)
        }
        guard let model = s.segmentationResource(request.id)?.model, let last = model.classes.last else {
            throw SnapshotError("--edit segment: no segmentation")
        }
        s.activeClasses[request.id] = last.id
        s.brush.radius = 6
        s.brush.isSphere = false
        s.select(.brush)
        let cam = try camera(w)
        let r = cam.axes.right, d = cam.axes.down
        let ring = (0...24).map { i -> SIMD3<Double> in
            let t = Double(i) / 24 * 2 * .pi
            return c + r * (16 * cos(t)) + d * (16 * sin(t))
        }
        drag(w, ring, cam)
        s.operation.holesIn2D = true
        await s.runOperation(.fillHoles)?.value
        s.viewState(.slice(.axial)).pointer = c + r * 34 + d * 8
    }

    /// A box around the lesion, a point, a polyline and a contour (each a
    /// new annotation), the box selected, and a polyline left in progress.
    static func annotate(_ w: Workspace, _ c: SIMD3<Double>) throws {
        let s = w.editing
        if s.annotationClass(for: .box) == nil {
            try s.createClass(name: "Finding", color: RGBA8(240, 200, 60), segmentation: nil)
        }
        if w.summary.labelSet?.labelClass(id: 9) != nil { s.annotationClassID = 9 }
        let cam = try camera(w)
        let r = cam.axes.right, d = cam.axes.down

        s.annotationTarget = .new
        s.select(.box)
        drag(w, [c - r * 26 - d * 22, c, c + r * 26 + d * 22], cam)
        let boxes = s.listedAnnotation

        s.annotationTarget = .new
        s.select(.point)
        click(w, c + r * 48 - d * 30, cam)

        if w.summary.labelSet?.labelClass(id: 2) != nil { s.annotationClassID = 2 }
        s.annotationTarget = .new
        s.select(.contour)
        for p in [c - r * 60 + d * 40, c - r * 20 + d * 70, c + r * 30 + d * 62, c + r * 10 + d * 34] { click(w, p, cam) }
        click(w, c - r * 60 + d * 40, cam)

        if w.summary.labelSet?.labelClass(id: 7) != nil { s.annotationClassID = 7 }
        s.annotationTarget = .new
        s.select(.polyline)
        for p in [c - r * 70 - d * 50, c - r * 35 - d * 62, c + r * 5 - d * 58] { click(w, p, cam) }
        send(w, .keyDown, c, cam, key: ToolEvent.returnKey)
        // A second polyline, in progress.
        for p in [c + r * 40 + d * 70, c + r * 70 + d * 55] { click(w, p, cam) }
        s.viewState(.slice(.axial)).pointer = c + r * 85 + d * 80

        // The tab lists the boxes, with the box selected.
        if let boxes {
            s.annotationTarget = .existing(boxes)
            s.select(items: [0], of: boxes)
        }
    }

    /// A ruler, an angle, an ellipse and a rectangle ROI, and an ROI being
    /// dragged.
    static func measure(_ w: Workspace, _ c: SIMD3<Double>) throws {
        let s = w.editing
        let cam = try camera(w)
        let r = cam.axes.right, d = cam.axes.down
        s.select(.ruler)
        drag(w, [c + r * 30 - d * 40, c + r * 50 - d * 35, c + r * 75 - d * 30], cam)
        s.select(.angle)
        for p in [c - r * 80 + d * 10, c - r * 55 + d * 40, c - r * 25 + d * 15] { click(w, p, cam) }
        s.select(.roi)
        s.roiShape = .ellipse
        drag(w, [c - r * 18 - d * 18, c + r * 18 + d * 18], cam)
        s.roiShape = .rectangle
        drag(w, [c + r * 45 + d * 25, c + r * 80 + d * 55], cam)
        // An ROI being dragged.
        s.roiShape = .ellipse
        send(w, .mouseDown, c - r * 70 - d * 60, cam)
        send(w, .mouseDragged, c - r * 40 - d * 35, cam)
    }
}
