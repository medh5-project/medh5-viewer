import AppKit
import simd

/// The default navigation of a slice view, reusable by the app's tools:
///
/// | input | does |
/// |---|---|
/// | scroll | moves the plane along its normal one voxel of the base image per notch (⌘-scroll zooms) |
/// | ↑ / ↓, Page Up / Down, Home / End | one slice, ten slices, first / last slice |
/// | ⌥-drag, middle drag | pans |
/// | ⌃-drag, right drag | zooms about the point where the drag began |
/// | ⇧-drag | window/level of the base image layer (horizontal: width, vertical: centre) |
/// | pinch | zooms about the pointer |
/// | click (no modifier) | ``onClick`` (e.g. set the crosshair), when set |
@MainActor
open class SliceNavigation: SliceViewInteraction {
    private enum Drag {
        case pan
        case zoom(anchor: SIMD2<Double>)
        case window
        case click
    }

    /// Zoom factor per pixel of vertical drag (e^(−dy·k)).
    public var zoomSensitivity = 0.006
    /// Fraction of the window width per pixel of window/level drag.
    public var windowSensitivity = 1.0 / 400.0
    /// Precise (trackpad) scroll distance, in points, per slice.
    public var pointsPerSlice = 12.0
    /// Snap the plane to voxel centres of the base grid after moving.
    public var snapsToVoxelCenters = true
    /// Called for a plain click and drag (world point under the pointer).
    public var onClick: ((SliceView, SIMD3<Double>) -> Void)?

    private var drag: Drag?
    private var last = SIMD2<Double>(0, 0)
    private var scrollAccumulator = 0.0

    /// The default navigation.
    public init() {}

    /// Handles navigation input; returns `false` for input it leaves alone.
    open func sliceView(_ view: SliceView, handle e: SliceViewEvent) -> Bool {
        switch e.kind {
        case .mouseDown, .rightMouseDown, .otherMouseDown:
            last = e.pixel
            let flags = e.modifierFlags.intersection([.option, .control, .shift, .command])
            if e.kind == .otherMouseDown || flags == .option {
                drag = .pan
            } else if e.kind == .rightMouseDown || flags == .control {
                drag = .zoom(anchor: e.pixel)
            } else if flags == .shift {
                drag = .window
            } else if e.kind == .mouseDown && flags.isEmpty, let onClick {
                drag = .click
                onClick(view, e.world)
                return true
            } else {
                drag = nil
            }
            return drag != nil

        case .mouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let drag else { return false }
            let delta = e.pixel - last
            last = e.pixel
            let ppp = max(1, view.scene.camera.pixelsPerPoint)
            switch drag {
            case .pan:
                view.scene.camera.pan(byPixels: delta)
            case .zoom(let anchor):
                view.scene.camera.zoom(by: exp(-delta.y / ppp * zoomSensitivity * 2), aboutPixel: anchor)
            case .window:
                guard var layer = view.scene.baseImageLayer else { return true }
                let width = max(1e-6, layer.windowWidth)
                layer.windowWidth = max(1e-6, width + delta.x / ppp * width * windowSensitivity * 4)
                layer.windowCenter += delta.y / ppp * width * windowSensitivity * 4
                view.scene.baseImageLayer = layer
            case .click:
                onClick?(view, e.world)
                return true
            }
            view.noteSceneChangedByInteraction()
            return true

        case .mouseUp, .rightMouseUp, .otherMouseUp:
            let handled = drag != nil
            drag = nil
            return handled

        case .scrollWheel:
            let ev = e.event
            if e.modifierFlags.contains(.command) {
                let amount = ev.hasPreciseScrollingDeltas ? ev.scrollingDeltaY / 100 : ev.scrollingDeltaY / 10
                view.scene.camera.zoom(by: exp(amount), aboutPixel: e.pixel)
                view.noteSceneChangedByInteraction()
                return true
            }
            let delta = ev.hasPreciseScrollingDeltas ? ev.scrollingDeltaY / pointsPerSlice : ev.scrollingDeltaY
            scrollAccumulator += delta
            let steps = scrollAccumulator.rounded(.towardZero)
            guard steps != 0 else { return true }
            scrollAccumulator -= steps
            moveSlices(view, by: steps)
            return true

        case .magnify:
            view.scene.camera.zoom(by: 1 + e.event.magnification, aboutPixel: e.pixel)
            view.noteSceneChangedByInteraction()
            return true

        case .keyDown:
            switch e.event.keyCode {
            case KeyCode.upArrow: moveSlices(view, by: 1)
            case KeyCode.downArrow: moveSlices(view, by: -1)
            case KeyCode.pageUp: moveSlices(view, by: 10)
            case KeyCode.pageDown: moveSlices(view, by: -10)
            case KeyCode.home, KeyCode.end:
                guard let grid = view.scene.baseGrid else { return false }
                let s = view.scene.camera.sliceIndex(in: grid)
                view.scene.camera.moveToSlice(e.event.keyCode == KeyCode.home ? 0 : Double(s.count - 1), of: grid)
                view.noteSceneChangedByInteraction()
            default:
                return false
            }
            return true

        default:
            return false
        }
    }

    /// Moves the plane by `count` voxel steps of the base grid along its
    /// normal (positive away from the viewer).
    public func moveSlices(_ view: SliceView, by count: Double) {
        view.scene.camera.moveAlongNormal(by: count * view.scene.sliceStep)
        if snapsToVoxelCenters, let grid = view.scene.baseGrid {
            view.scene.camera.snapToVoxelCenters(of: grid)
        }
        view.noteSceneChangedByInteraction()
    }
}
