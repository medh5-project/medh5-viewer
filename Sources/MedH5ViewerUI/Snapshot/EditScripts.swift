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

    /// The point `x` mm right of and `y` mm below `c` in the camera's plane.
    /// Typed offsets keep the scripts quick to type-check: a list of sums like
    /// `c - r * 60 + d * 40` can be more than Swift 6.3 will solve.
    private static func offsetPoints(from c: SIMD3<Double>, in cam: SliceCamera) -> (Double, Double) -> SIMD3<Double> {
        let r = cam.axes.right, d = cam.axes.down
        return { x, y in c + r * x + d * y }
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
        let at = offsetPoints(from: c, in: cam)
        let ring = (0...24).map { i -> SIMD3<Double> in
            let t = Double(i) / 24 * 2 * .pi
            return at(16 * cos(t), 16 * sin(t))
        }
        drag(w, ring, cam)
        s.operation.holesIn2D = true
        await s.runOperation(.fillHoles)?.value
        s.viewState(.slice(.axial)).pointer = at(34, 8)
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
        let at = offsetPoints(from: c, in: cam)

        s.annotationTarget = .new
        s.select(.box)
        drag(w, [at(-26, -22), c, at(26, 22)], cam)
        let boxes = s.listedAnnotation

        s.annotationTarget = .new
        s.select(.point)
        click(w, at(48, -30), cam)

        if w.summary.labelSet?.labelClass(id: 2) != nil { s.annotationClassID = 2 }
        s.annotationTarget = .new
        s.select(.contour)
        for p in [at(-60, 40), at(-20, 70), at(30, 62), at(10, 34)] { click(w, p, cam) }
        click(w, at(-60, 40), cam)

        if w.summary.labelSet?.labelClass(id: 7) != nil { s.annotationClassID = 7 }
        s.annotationTarget = .new
        s.select(.polyline)
        for p in [at(-70, -50), at(-35, -62), at(5, -58)] { click(w, p, cam) }
        send(w, .keyDown, c, cam, key: ToolEvent.returnKey)
        // A second polyline, in progress.
        for p in [at(40, 70), at(70, 55)] { click(w, p, cam) }
        s.viewState(.slice(.axial)).pointer = at(85, 80)

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
        let at = offsetPoints(from: c, in: cam)
        s.select(.ruler)
        drag(w, [at(30, -40), at(50, -35), at(75, -30)], cam)
        s.select(.angle)
        for p in [at(-80, 10), at(-55, 40), at(-25, 15)] { click(w, p, cam) }
        s.select(.roi)
        s.roiShape = .ellipse
        drag(w, [at(-18, -18), at(18, 18)], cam)
        s.roiShape = .rectangle
        drag(w, [at(45, 25), at(80, 55)], cam)
        // An ROI being dragged.
        s.roiShape = .ellipse
        send(w, .mouseDown, at(-70, -60), cam)
        send(w, .mouseDragged, at(-40, -35), cam)
    }
}
