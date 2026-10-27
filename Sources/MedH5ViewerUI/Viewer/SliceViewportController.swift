import AppKit
import SwiftUI
import simd
import MedH5Kit
import MedH5Render

/// Drives one slice view: rebuilds its scene whenever what it reads in the
/// workspace changes (Observation), turns navigation back into model state
/// (the cursor, the view's framing, the window), and runs the viewing tools.
///
/// Built-in navigation (`SliceNavigation`): scroll and ↑/↓/Page/Home/End
/// move through slices, ⌥-drag pans, ⌃-drag zooms, ⇧-drag windows, pinch
/// zooms; a plain click (Navigate tool) moves the crosshair. The Window/Level,
/// Pan and Zoom tools take the plain drag.
@MainActor
final class SliceViewportController: NSObject, SliceViewInteraction {
    let id: ViewportID
    private unowned let workspace: Workspace
    let container: ViewportContainerView
    let presentation = ViewportPresentation()
    private(set) var sliceView: SliceView?
    private let navigation = SliceNavigation()

    private var lastCamera: SliceCamera?
    private var lastFit: SliceCamera?
    private var scheduled = false
    private var isTornDown = false
    private var toolDrag: (start: SIMD2<Double>, last: SIMD2<Double>, camera: SliceCamera)?
    /// Rebuilds since creation (tests, diagnostics).
    private(set) var buildCount = 0

    init(id: ViewportID, workspace: Workspace) {
        self.id = id
        self.workspace = workspace
        let presentation = self.presentation
        var view: SliceView?
        if let context = workspace.store.context {
            let camera = SliceCamera(center: .zero, axes: PlaneAxes.standard(.axial), millimetersPerPixel: 1,
                                     viewportSize: SIMD2(1, 1))
            view = try? SliceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), context: context,
                                  scene: SliceScene(camera: camera))
        }
        let overlay = PassthroughHostingView(rootView: SliceViewportOverlay(presentation: presentation))
        container = ViewportContainerView(content: view ?? PlaceholderView(), overlay: overlay)
        sliceView = view
        super.init()
        container.onResize = { [weak self] in self?.scheduleUpdate() }
        container.onWindow = { [weak self] in self?.claimKeyboardIfIdle() }
        if let view {
            view.interactionHandler = self
            view.navigation = navigation
            navigation.onClick = { [weak self] _, world in
                guard let self, self.workspace.viewer.tool == .navigate else { return }
                self.workspace.setCursor(world, from: self.id)
            }
            view.sceneChangedByInteraction = { [weak self] v in self?.readBack(v) }
        }
        update()
    }

    /// The active view takes the keyboard (slice keys) when nothing else has it.
    private func claimKeyboardIfIdle() {
        guard let window = container.window, let view = sliceView, workspace.viewer.activeViewport == id else { return }
        if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(view) }
    }

    func tearDown() {
        isTornDown = true
        sliceView?.interactionHandler = nil
        sliceView?.sceneChangedByInteraction = nil
    }

    // MARK: Building

    /// The view's size in drawable pixels and its backing scale.
    private var viewport: (size: SIMD2<Int>, scale: Double) {
        let scale = Double(container.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let b = container.bounds.size
        return (SIMD2(Int((Double(b.width) * scale).rounded()), Int((Double(b.height) * scale).rounded())), scale)
    }

    func scheduleUpdate() {
        guard !scheduled, !isTornDown else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.update()
        }
    }

    /// Rebuilds the scene, tracking what it read.
    func update() {
        guard !isTornDown else { return }
        withObservationTracking {
            rebuild()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.scheduleUpdate() }
        }
    }

    private func rebuild() {
        buildCount += 1
        let (size, scale) = viewport
        let result = SliceSceneBuilder(workspace: workspace, viewport: id).build(size: size, scale: scale)
        lastCamera = result.camera
        lastFit = result.fitCamera
        if let scene = result.scene, let view = sliceView {
            view.scene = scene
        } else if let view = sliceView {
            var empty = view.scene
            empty.layers = []
            empty.overlays = []
            view.scene = empty
        }
        presentation.update(result.presentation)
    }

    /// Renders the view offscreen at `scale` pixels per point (the snapshot
    /// mode and screenshots).
    func renderImage(scale: Double) throws -> CGImage? {
        guard let view = sliceView else { return nil }
        let b = container.bounds.size
        let size = SIMD2(Int((Double(b.width) * scale).rounded()), Int((Double(b.height) * scale).rounded()))
        guard size.x > 0, size.y > 0 else { return nil }
        let result = SliceSceneBuilder(workspace: workspace, viewport: id).build(size: size, scale: scale)
        var scene = result.scene ?? SliceScene(camera: SliceCamera(center: .zero, axes: PlaneAxes.standard(.axial),
                                                                   millimetersPerPixel: 1, viewportSize: size))
        scene.camera.viewportSize = size
        return try view.renderer.makeImage(scene: scene)
    }

    // MARK: Interaction

    func sliceView(_ view: SliceView, handle e: SliceViewEvent) -> Bool {
        let viewer = workspace.viewer
        switch e.kind {
        case .mouseDown, .rightMouseDown, .otherMouseDown:
            if viewer.activeViewport != id { viewer.activeViewport = id }
            let flags = e.modifierFlags.intersection([.option, .control, .shift, .command])
            if e.kind == .mouseDown, flags.isEmpty, [.windowLevel, .pan, .zoom].contains(viewer.tool) {
                toolDrag = (e.pixel, e.pixel, view.scene.camera)
                return true
            }
            return false
        case .mouseDragged:
            guard var drag = toolDrag else {
                workspace.updateHover(world: e.world, viewport: id)
                return false
            }
            let delta = e.pixel - drag.last
            drag.last = e.pixel
            toolDrag = drag
            let ppp = max(1, view.scene.camera.pixelsPerPoint)
            switch viewer.tool {
            case .windowLevel:
                guard let base = workspace.stack(for: id).base else { return true }
                let width = max(1e-6, base.windowWidth)
                base.windowWidth = max(1e-6, width + delta.x / ppp * width / 100)
                base.windowCenter += delta.y / ppp * width / 100
                base.windowPreset = nil
            case .pan:
                var camera = view.scene.camera
                camera.pan(byPixels: delta)
                setFraming(from: camera)
            case .zoom:
                var camera = view.scene.camera
                camera.zoom(by: exp(-delta.y / ppp * 0.012), aboutPixel: drag.start)
                setFraming(from: camera)
            default:
                break
            }
            return true
        case .mouseUp:
            if toolDrag != nil {
                toolDrag = nil
                return true
            }
            return false
        case .mouseMoved:
            workspace.updateHover(world: e.world, viewport: id)
            return false
        case .mouseExited:
            workspace.updateHover(world: nil, viewport: id)
            return false
        case .keyDown:
            if viewer.activeViewport != id { viewer.activeViewport = id }
            return false
        default:
            return false
        }
    }

    /// Takes navigation's changes into the model: slice moves move the
    /// cursor along the normal; pan and zoom become the view's framing; a
    /// ⇧-drag window becomes the base layer's window.
    private func readBack(_ view: SliceView) {
        guard let old = lastCamera else { return }
        let camera = view.scene.camera
        let dn = simd_dot(camera.center - old.center, old.normal)
        if abs(dn) > 1e-9 {
            let current: SIMD3<Double>
            if id == .compareRight {
                current = workspace.compareCursor ?? camera.center
            } else {
                current = workspace.viewer.cursor
            }
            workspace.setCursor(current + old.normal * dn, from: id)
        }
        setFraming(from: camera)
        if let l = view.scene.baseImageLayer, let base = workspace.stack(for: id).base,
           l.windowCenter != base.windowCenter || l.windowWidth != base.windowWidth {
            base.windowCenter = l.windowCenter
            base.windowWidth = l.windowWidth
            base.windowPreset = nil
        }
        workspace.updateHover(world: nil, viewport: id)
    }

    /// Stores a camera's zoom and pan relative to the fitted camera.
    private func setFraming(from camera: SliceCamera) {
        guard let fit = lastFit else { return }
        var fitted = fit
        if fitted.viewportSize != camera.viewportSize || fitted.pixelsPerPoint != camera.pixelsPerPoint,
           let ref = workspace.referenceGrid(of: workspace.stack(for: id)) {
            fitted = SliceSceneBuilder(workspace: workspace, viewport: id)
                .fitCamera(reference: ref, size: camera.viewportSize, scale: camera.pixelsPerPoint)
        }
        var state = workspace.viewer.viewState(id)
        state.zoom = fitted.millimetersPerPixel / max(1e-9, camera.millimetersPerPixel)
        let d = camera.center - fitted.center
        state.pan = SIMD2(simd_dot(d, fitted.axes.right), simd_dot(d, fitted.axes.down))
        if workspace.viewer.views[id] != state { workspace.viewer.views[id] = state }
    }
}
