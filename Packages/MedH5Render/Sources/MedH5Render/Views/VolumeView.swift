import AppKit
import MetalKit
import simd

/// An `MTKView` showing a ``VolumeScene`` (the 3-D view): draws on demand,
/// renders at ``interactiveQuality`` while the camera moves and refines to
/// ``finalQuality`` once input pauses for ``refinementDelay``, keeps the
/// camera's viewport in step with the drawable, and forwards input to
/// ``interactionHandler`` and then ``navigation`` (``VolumeNavigation``).
@MainActor
open class VolumeView: MTKView {
    /// The renderer (one per view).
    public let renderer: VolumeRenderer

    /// What the view shows. Setting it redraws (at final quality unless an
    /// interaction is in progress).
    public var scene: VolumeScene {
        didSet { if !isSyncing { needsDisplay = true } }
    }

    /// The app's tools; sees every event first.
    public weak var interactionHandler: (any VolumeViewInteraction)?
    /// Default navigation, used for events the handler did not take.
    public var navigation: (any VolumeViewInteraction)? = VolumeNavigation()

    /// Quality while the camera moves.
    public var interactiveQuality: VolumeRenderQuality = .interactive
    /// Quality when idle.
    public var finalQuality: VolumeRenderQuality = .full
    /// Idle time after the last interaction before refining.
    public var refinementDelay: TimeInterval = 0.2

    /// Called after built-in navigation changed the camera.
    public var sceneChangedByInteraction: ((VolumeView) -> Void)?
    public private(set) var lastError: (any Error)?

    /// The camera ``resetCamera()`` returns to; framed on the scene when nil.
    public var homeCamera: VolumeCamera?

    private var isSyncing = false
    private var isInteracting = false
    private var trackingArea: NSTrackingArea?

    /// A view drawing `scene` with `context`'s device.
    public init(frame: CGRect, context: RenderContext, scene: VolumeScene) throws {
        renderer = try VolumeRenderer(context: context, colorPixelFormat: .bgra8Unorm)
        self.scene = scene
        super.init(frame: frame, device: context.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("VolumeView is created in code")
    }

    // MARK: Drawing

    /// Brings the camera's viewport in line with the drawable.
    public func syncViewport() {
        let size = SIMD2(Int(drawableSize.width.rounded()), Int(drawableSize.height.rounded()))
        guard size.x > 0, size.y > 0, scene.camera.viewportSize != size else { return }
        isSyncing = true
        scene.camera.viewportSize = size
        isSyncing = false
    }

    open override func draw(_ dirtyRect: NSRect) {
        syncViewport()
        guard let drawable = currentDrawable else { return }
        var s = scene
        s.quality = isInteracting ? interactiveQuality : finalQuality
        do {
            let cb = try renderer.context.makeCommandBuffer(label: "volume view")
            try renderer.encode(scene: s, to: drawable.texture, commandBuffer: cb)
            cb.present(drawable)
            cb.commit()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Marks the start (or continuation) of an interaction: frames render at
    /// interactive quality until input pauses.
    public func noteInteraction() {
        isInteracting = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refine), object: nil)
        perform(#selector(refine), with: nil, afterDelay: refinementDelay)
        needsDisplay = true
    }

    @objc private func refine() {
        isInteracting = false
        needsDisplay = true
    }

    /// Called by navigation after it changed the scene.
    public func noteSceneChangedByInteraction() {
        noteInteraction()
        sceneChangedByInteraction?(self)
    }

    /// Back to ``homeCamera``, or a camera framing the scene from the front.
    public func resetCamera() {
        if let home = homeCamera {
            scene.camera = home
        } else if let b = scene.worldBounds {
            scene.camera = VolumeCamera.framing(bounds: b, from: .anterior, viewportSize: scene.camera.viewportSize,
                                                fieldOfView: scene.camera.fieldOfView,
                                                projection: scene.camera.projection)
        }
    }

    /// Renders the scene offscreen at final quality and the drawable's size
    /// times `scale`.
    public func snapshot(scale: Double = 1) throws -> CGImage {
        syncViewport()
        var s = scene
        s.quality = finalQuality
        s.camera.viewportSize = SIMD2(Int((Double(s.camera.viewportSize.x) * scale).rounded()),
                                      Int((Double(s.camera.viewportSize.y) * scale).rounded()))
        return try renderer.makeImage(scene: s)
    }

    // MARK: Coordinates

    /// View point (AppKit, bottom-left origin) → drawable pixel (top-left origin).
    public func pixel(fromViewPoint p: CGPoint) -> SIMD2<Double> {
        let s = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
        let y = isFlipped ? Double(p.y) : Double(bounds.height - p.y)
        return SIMD2(Double(p.x) * s, y * s)
    }

    /// The camera ray through a view point.
    public func ray(atViewPoint p: CGPoint) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        syncViewport()
        return scene.camera.ray(atPixel: pixel(fromViewPoint: p))
    }

    /// Where a world point projects in the view (points), or nil behind the camera.
    public func viewPoint(forWorld x: SIMD3<Double>) -> CGPoint? {
        syncViewport()
        guard let (q, _) = scene.camera.project(x) else { return nil }
        let s = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
        let y = q.y / s
        return CGPoint(x: q.x / s, y: isFlipped ? y : Double(bounds.height) - y)
    }

    // MARK: Events

    open override var acceptsFirstResponder: Bool { true }
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                          .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Builds the event and offers it to the handler, then the navigation.
    @discardableResult
    public func dispatch(_ kind: ViewEventKind, _ event: NSEvent) -> Bool {
        syncViewport()
        let location = convert(event.locationInWindow, from: nil)
        let pixel = pixel(fromViewPoint: location)
        let e = VolumeViewEvent(kind: kind, event: event, locationInView: location, pixel: pixel,
                                ray: scene.camera.ray(atPixel: pixel))
        if let handler = interactionHandler, handler.volumeView(self, handle: e) { return true }
        if let navigation, navigation.volumeView(self, handle: e) { return true }
        return false
    }

    open override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !dispatch(.mouseDown, event) { super.mouseDown(with: event) }
    }
    open override func mouseDragged(with event: NSEvent) {
        if !dispatch(.mouseDragged, event) { super.mouseDragged(with: event) }
    }
    open override func mouseUp(with event: NSEvent) {
        if !dispatch(.mouseUp, event) { super.mouseUp(with: event) }
    }
    open override func rightMouseDown(with event: NSEvent) {
        if !dispatch(.rightMouseDown, event) { super.rightMouseDown(with: event) }
    }
    open override func rightMouseDragged(with event: NSEvent) {
        if !dispatch(.rightMouseDragged, event) { super.rightMouseDragged(with: event) }
    }
    open override func rightMouseUp(with event: NSEvent) {
        if !dispatch(.rightMouseUp, event) { super.rightMouseUp(with: event) }
    }
    open override func otherMouseDown(with event: NSEvent) {
        if !dispatch(.otherMouseDown, event) { super.otherMouseDown(with: event) }
    }
    open override func otherMouseDragged(with event: NSEvent) {
        if !dispatch(.otherMouseDragged, event) { super.otherMouseDragged(with: event) }
    }
    open override func otherMouseUp(with event: NSEvent) {
        if !dispatch(.otherMouseUp, event) { super.otherMouseUp(with: event) }
    }
    open override func mouseMoved(with event: NSEvent) {
        if !dispatch(.mouseMoved, event) { super.mouseMoved(with: event) }
    }
    open override func mouseEntered(with event: NSEvent) {
        if !dispatch(.mouseEntered, event) { super.mouseEntered(with: event) }
    }
    open override func mouseExited(with event: NSEvent) {
        if !dispatch(.mouseExited, event) { super.mouseExited(with: event) }
    }
    open override func scrollWheel(with event: NSEvent) {
        if !dispatch(.scrollWheel, event) { super.scrollWheel(with: event) }
    }
    open override func magnify(with event: NSEvent) {
        if !dispatch(.magnify, event) { super.magnify(with: event) }
    }
    open override func rotate(with event: NSEvent) {
        if !dispatch(.rotate, event) { super.rotate(with: event) }
    }
    open override func keyDown(with event: NSEvent) {
        if !dispatch(.keyDown, event) { super.keyDown(with: event) }
    }
    open override func keyUp(with event: NSEvent) {
        if !dispatch(.keyUp, event) { super.keyUp(with: event) }
    }
}

/// The default navigation of a 3-D view:
///
/// | input | does |
/// |---|---|
/// | drag | orbits about the target |
/// | ⌥-drag, ⇧-drag, middle drag | pans |
/// | ⌃-drag, right drag | zooms |
/// | scroll, pinch | zooms |
/// | two-finger rotate | rolls |
/// | double-click | resets the camera |
@MainActor
open class VolumeNavigation: VolumeViewInteraction {
    private enum Drag {
        case orbit, pan, zoom
    }

    /// Radians of orbit per point dragged.
    public var orbitSensitivity = 0.008
    public var zoomSensitivity = 0.01

    private var drag: Drag?
    private var last = SIMD2<Double>(0, 0)

    public init() {}

    open func volumeView(_ view: VolumeView, handle e: VolumeViewEvent) -> Bool {
        let ppp = max(1, Double(view.window?.backingScaleFactor ?? 1))
        switch e.kind {
        case .mouseDown, .rightMouseDown, .otherMouseDown:
            if e.kind == .mouseDown && e.event.clickCount == 2 {
                view.resetCamera()
                view.noteSceneChangedByInteraction()
                return true
            }
            last = e.pixel
            let flags = e.modifierFlags.intersection([.option, .control, .shift, .command])
            if e.kind == .otherMouseDown || flags == .option || flags == .shift {
                drag = .pan
            } else if e.kind == .rightMouseDown || flags == .control {
                drag = .zoom
            } else if flags.isEmpty {
                drag = .orbit
            } else {
                drag = nil
            }
            if drag != nil { view.noteInteraction() }
            return drag != nil
        case .mouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let drag else { return false }
            let delta = e.pixel - last
            last = e.pixel
            switch drag {
            case .orbit: view.scene.camera.orbit(byPixels: delta / ppp, radiansPerPixel: orbitSensitivity)
            case .pan: view.scene.camera.pan(byPixels: delta)
            case .zoom: view.scene.camera.zoom(by: exp(-delta.y / ppp * zoomSensitivity))
            }
            view.noteSceneChangedByInteraction()
            return true
        case .mouseUp, .rightMouseUp, .otherMouseUp:
            let handled = drag != nil
            drag = nil
            return handled
        case .scrollWheel:
            let ev = e.event
            let amount = ev.hasPreciseScrollingDeltas ? ev.scrollingDeltaY / 200 : ev.scrollingDeltaY / 20
            view.scene.camera.zoom(by: exp(amount))
            view.noteSceneChangedByInteraction()
            return true
        case .magnify:
            view.scene.camera.zoom(by: 1 + e.event.magnification)
            view.noteSceneChangedByInteraction()
            return true
        case .rotate:
            view.scene.camera.roll(by: Double(e.event.rotation) * .pi / 180)
            view.noteSceneChangedByInteraction()
            return true
        default:
            return false
        }
    }
}
