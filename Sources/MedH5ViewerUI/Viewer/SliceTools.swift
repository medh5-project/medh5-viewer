import AppKit
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// An input event as the slice tools see it: what happened, where (world
/// point on the view's plane, drawable pixel), with which modifiers.
/// Made from a `SliceViewEvent`, or directly by tests and the snapshot
/// mode's scripted edits.
struct ToolEvent {
    var kind: ViewEventKind
    var world: SIMD3<Double>
    var pixel: SIMD2<Double>
    /// ⌥ ⌃ ⇧ ⌘ only.
    var modifiers: NSEvent.ModifierFlags = []
    /// 2 for the second click of a double-click.
    var clickCount = 1
    /// The key of a key event.
    var keyCode: UInt16?

    init(kind: ViewEventKind, world: SIMD3<Double>, pixel: SIMD2<Double> = .zero, modifiers: NSEvent.ModifierFlags = [],
         clickCount: Int = 1, keyCode: UInt16? = nil) {
        self.kind = kind
        self.world = world
        self.pixel = pixel
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.keyCode = keyCode
    }

    init(_ e: SliceViewEvent) {
        kind = e.kind
        world = e.world
        pixel = e.pixel
        modifiers = e.modifierFlags.intersection([.option, .control, .shift, .command])
        switch e.kind {
        case .mouseDown, .mouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            clickCount = e.event.clickCount
        default:
            clickCount = 0
        }
        keyCode = e.kind == .keyDown || e.kind == .keyUp ? e.event.keyCode : nil
    }

    /// A plain left-button event (modified ones belong to navigation).
    var isPlain: Bool { modifiers.isEmpty }

    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let escapeKey: UInt16 = 53
    static let deleteKey: UInt16 = 51
    static let forwardDeleteKey: UInt16 = 117
}

/// What a tool knows of the view an event happened in.
@MainActor
struct SliceToolContext {
    let session: EditingSession
    let viewport: ViewportID
    let camera: SliceCamera

    var workspace: Workspace { session.workspace }
    var state: ToolViewState { session.viewState(viewport) }

    /// The distance in points between two world points as the view shows them.
    func points(between a: SIMD3<Double>, and b: SIMD3<Double>) -> Double {
        simd_length(camera.pixel(forWorld: a) - camera.pixel(forWorld: b)) / max(1, camera.pixelsPerPoint)
    }
}

/// A tool working in slice views. The view offers it every event first;
/// what it does not use (modified drags, scrolling, keys it ignores) goes on
/// to the default navigation.
@MainActor
protocol SliceTool: AnyObject {
    /// Handles an event; returns whether it used it.
    func handle(_ event: ToolEvent, in context: SliceToolContext) -> Bool
    /// Ends a gesture in progress without effect.
    func cancel()
}

/// The handlers of the tools that are not viewing tools (one each, shared by
/// the views: a gesture happens in one view at a time).
@MainActor
final class SliceToolSet {
    let brush = BrushTool(erases: false)
    let eraser = BrushTool(erases: true)
    let fill = FillTool()
    let box = BoxTool()
    let point = PointTool()
    let polyline = PathTool(tool: .polyline)
    let contour = PathTool(tool: .contour)
    let ruler = RulerTool()
    let angle = AngleTool()
    let roi = ROITool()

    func handler(for tool: ViewerTool) -> SliceTool? {
        switch tool {
        case .navigate, .windowLevel, .pan, .zoom: return nil
        case .brush: return brush
        case .eraser: return eraser
        case .fill: return fill
        case .box: return box
        case .point: return point
        case .polyline: return polyline
        case .contour: return contour
        case .ruler: return ruler
        case .angle: return angle
        case .roi: return roi
        }
    }

    func cancelAll() {
        let all: [SliceTool] = [brush, eraser, fill, box, point, polyline, contour, ruler, angle, roi]
        all.forEach { $0.cancel() }
    }
}

// MARK: - Segmentation

/// Brush and Eraser: a stroke paints (or erases) dabs of the brush along
/// the pointer's path, interpolated between mouse samples, straight into
/// the segmentation; mouse-up records the stroke as one undo step.
@MainActor
final class BrushTool: SliceTool {
    let erases: Bool
    private var stroke: BrushStroke?
    private var target: SegmentationTarget?
    private var viewport: ViewportID?
    private weak var session: EditingSession?

    init(erases: Bool) { self.erases = erases }

    var isStroking: Bool { stroke != nil }

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseMoved:
            c.state.pointer = e.world
            return false
        case .mouseExited:
            c.state.pointer = nil
            return false
        case .mouseDown:
            guard e.isPlain else { return false }
            c.state.pointer = e.world
            begin(at: e.world, c)
            return true
        case .mouseDragged:
            guard stroke != nil else { return false }
            if viewport == c.viewport {
                c.state.pointer = e.world
                paint(to: e.world, c)
            }
            return true
        case .mouseUp:
            guard stroke != nil else { return false }
            finish(c)
            return true
        default:
            return false
        }
    }

    private func begin(at p: SIMD3<Double>, _ c: SliceToolContext) {
        let s = c.session
        let erasesAll = erases && s.brush.eraserErasesAll
        do {
            let t = try s.segmentationTarget(for: c.viewport, needsClass: !erasesAll)
            let operation: VoxelOperation
            if erasesAll {
                operation = .eraseAll
            } else {
                guard let cls = t.classID else { throw EditingFailure("Choose a class") }
                operation = erases ? .erase(cls) : .paint(cls)
            }
            let options = erases ? PaintOptions() : try s.paintOptions(model: t.model, stack: c.workspace.stack(for: c.viewport))
            let shape: Brush.Shape = s.brush.isSphere ? .sphere : .disc(c.camera.axes)
            stroke = try BrushStroke(model: t.model, operation: operation, brush: Brush(radius: s.brush.radius, shape: shape),
                                     options: options)
            target = t
            viewport = c.viewport
            session = s
            paint(to: p, c)
        } catch {
            s.report(error)
        }
    }

    private func paint(to p: SIMD3<Double>, _ c: SliceToolContext) {
        guard let stroke else { return }
        do {
            if !(try stroke.add(p)).isEmpty { c.workspace.noteVoxelsChanged() }
        } catch {
            cancel()
            c.session.report(error)
        }
    }

    private func finish(_ c: SliceToolContext) {
        guard let stroke, let target else { return }
        let edit = stroke.finish()
        self.stroke = nil
        self.target = nil
        viewport = nil
        c.session.recordVoxelEdit(edit, segmentation: target.id, model: target.model, name: erases ? "Erase" : "Paint")
    }

    func cancel() {
        guard let stroke else { return }
        stroke.cancel()
        self.stroke = nil
        target = nil
        viewport = nil
        session?.workspace.noteVoxelsChanged()
    }
}

/// Fill: a click fills (2-D or 3-D) from the clicked voxel.
@MainActor
final class FillTool: SliceTool {
    private var pressed = false

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            pressed = true
            c.session.fill(at: e.world, viewport: c.viewport, planeNormal: c.camera.normal)
            return true
        case .mouseDragged:
            return pressed
        case .mouseUp:
            defer { pressed = false }
            return pressed
        default:
            return false
        }
    }

    func cancel() { pressed = false }
}

// MARK: - Annotations

/// Box: a drag draws a box on the slice (or `boxDepth` slices deep).
@MainActor
final class BoxTool: SliceTool {
    private var start: SIMD3<Double>?
    private var viewport: ViewportID?

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            start = e.world
            viewport = c.viewport
            c.state.preview = .box(e.world, e.world)
            return true
        case .mouseDragged:
            guard let start else { return false }
            if viewport == c.viewport { c.state.preview = .box(start, e.world) }
            return true
        case .mouseUp:
            guard let start else { return false }
            defer { cancel(c) }
            guard viewport == c.viewport, c.points(between: start, and: e.world) >= 3 else { return true }
            do {
                try c.session.addBox(from: start, to: e.world, planeNormal: c.camera.normal, viewport: c.viewport)
            } catch {
                c.session.report(error)
            }
            return true
        default:
            return false
        }
    }

    private func cancel(_ c: SliceToolContext) {
        c.state.preview = nil
        cancel()
    }

    func cancel() {
        start = nil
        viewport = nil
    }
}

/// Point: a click places a point (or the next keypoint).
@MainActor
final class PointTool: SliceTool {
    private var pressed = false

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            pressed = true
            do {
                try c.session.addPoint(at: e.world, viewport: c.viewport)
            } catch {
                c.session.report(error)
            }
            return true
        case .mouseDragged:
            return pressed
        case .mouseUp:
            defer { pressed = false }
            return pressed
        default:
            return false
        }
    }

    func cancel() { pressed = false }
}

/// Polyline and Contour: clicks add vertices; Return or a double-click
/// finishes (a contour also by clicking its first vertex); ⌫ removes the
/// last vertex; Escape cancels.
@MainActor
final class PathTool: SliceTool {
    let tool: ViewerTool
    private(set) var vertices: [SIMD3<Double>] = []
    private var viewport: ViewportID?
    private weak var state: ToolViewState?

    init(tool: ViewerTool) { self.tool = tool }

    var isClosed: Bool { tool == .contour }
    var minimumVertices: Int { isClosed ? 3 : 2 }

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseMoved:
            c.state.pointer = e.world
            return false
        case .mouseExited:
            c.state.pointer = nil
            return false
        case .mouseDown:
            guard e.isPlain else { return false }
            if viewport != nil && viewport != c.viewport { cancel() }
            if e.clickCount >= 2, !vertices.isEmpty {
                finish(c)
                return true
            }
            if isClosed, vertices.count >= minimumVertices, c.points(between: vertices[0], and: e.world) <= 6 {
                finish(c)
                return true
            }
            vertices.append(e.world)
            viewport = c.viewport
            state = c.state
            c.state.pointer = e.world
            c.state.preview = .path(vertices, closed: isClosed)
            return true
        case .mouseDragged, .mouseUp:
            return !vertices.isEmpty
        case .keyDown:
            guard !vertices.isEmpty, let key = e.keyCode else { return false }
            switch key {
            case ToolEvent.returnKey, ToolEvent.enterKey:
                finish(c)
            case ToolEvent.escapeKey:
                cancel()
            case ToolEvent.deleteKey:
                vertices.removeLast()
                if vertices.isEmpty { cancel() } else { c.state.preview = .path(vertices, closed: isClosed) }
            default:
                return false
            }
            return true
        default:
            return false
        }
    }

    private func finish(_ c: SliceToolContext) {
        let points = vertices
        cancel()
        guard points.count >= minimumVertices else {
            c.session.report(.error("A \(isClosed ? "contour" : "polyline") needs at least \(minimumVertices) points"))
            return
        }
        do {
            try c.session.addCurve(tool, points: points, planeNormal: c.camera.normal, viewport: c.viewport)
        } catch {
            c.session.report(error)
        }
    }

    func cancel() {
        vertices = []
        viewport = nil
        state?.preview = nil
        state = nil
    }
}

// MARK: - Measurements

/// Ruler: drag from one end to the other, or click both ends.
@MainActor
final class RulerTool: SliceTool {
    private var start: SIMD3<Double>?
    private var dragged = false
    private var viewport: ViewportID?
    private weak var state: ToolViewState?

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            if let start, viewport == c.viewport {
                finish(start, e.world, c)
                return true
            }
            cancel()
            start = e.world
            dragged = false
            viewport = c.viewport
            state = c.state
            c.state.preview = .ruler(e.world, e.world)
            return true
        case .mouseDragged:
            guard let start else { return false }
            if viewport == c.viewport {
                dragged = true
                c.state.preview = .ruler(start, e.world)
            }
            return true
        case .mouseUp:
            guard let start else { return false }
            if dragged, viewport == c.viewport, c.points(between: start, and: e.world) >= 3 { finish(start, e.world, c) }
            return true
        case .mouseMoved:
            if let start, viewport == c.viewport { c.state.preview = .ruler(start, e.world) }
            return false
        case .keyDown:
            guard start != nil, e.keyCode == ToolEvent.escapeKey else { return false }
            cancel()
            return true
        default:
            return false
        }
    }

    private func finish(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SliceToolContext) {
        cancel()
        do {
            try c.session.addRuler(from: a, to: b, viewport: c.viewport, normal: c.camera.normal)
        } catch {
            c.session.report(error)
        }
    }

    func cancel() {
        start = nil
        dragged = false
        viewport = nil
        state?.preview = nil
        state = nil
    }
}

/// Angle: click the end of the first arm, the vertex, then the end of the
/// second arm.
@MainActor
final class AngleTool: SliceTool {
    private var points: [SIMD3<Double>] = []
    private var viewport: ViewportID?
    private weak var state: ToolViewState?

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            if viewport != nil && viewport != c.viewport { cancel() }
            points.append(e.world)
            viewport = c.viewport
            state = c.state
            if points.count == 3 {
                let p = points
                cancel()
                do {
                    try c.session.addAngle(p[0], vertex: p[1], p[2], viewport: c.viewport, normal: c.camera.normal)
                } catch {
                    c.session.report(error)
                }
            } else {
                c.state.preview = .angle(points)
            }
            return true
        case .mouseDragged, .mouseUp:
            return !points.isEmpty
        case .mouseMoved:
            if !points.isEmpty, viewport == c.viewport { c.state.preview = .angle(points + [e.world]) }
            return false
        case .keyDown:
            guard !points.isEmpty, e.keyCode == ToolEvent.escapeKey else { return false }
            cancel()
            return true
        default:
            return false
        }
    }

    func cancel() {
        points = []
        viewport = nil
        state?.preview = nil
        state = nil
    }
}

/// ROI: a drag draws an ellipse or a rectangle on the slice.
@MainActor
final class ROITool: SliceTool {
    private var start: SIMD3<Double>?
    private var viewport: ViewportID?
    private weak var state: ToolViewState?

    func handle(_ e: ToolEvent, in c: SliceToolContext) -> Bool {
        let kind = c.session.roiShape
        switch e.kind {
        case .mouseDown:
            guard e.isPlain else { return false }
            start = e.world
            viewport = c.viewport
            state = c.state
            c.state.preview = .roi(kind, e.world, e.world)
            return true
        case .mouseDragged:
            guard let start else { return false }
            if viewport == c.viewport { c.state.preview = .roi(kind, start, e.world) }
            return true
        case .mouseUp:
            guard let start else { return false }
            let same = viewport == c.viewport
            cancel()
            guard same, c.points(between: start, and: e.world) >= 3 else { return true }
            do {
                try c.session.addROI(kind, from: start, to: e.world, camera: c.camera, viewport: c.viewport)
            } catch {
                c.session.report(error)
            }
            return true
        default:
            return false
        }
    }

    func cancel() {
        start = nil
        viewport = nil
        state?.preview = nil
        state = nil
    }
}
