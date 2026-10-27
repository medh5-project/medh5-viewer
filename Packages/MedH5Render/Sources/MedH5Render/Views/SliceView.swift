import AppKit
import MetalKit
import simd

/// An `MTKView` showing a ``SliceScene``: draws on demand (`isPaused`,
/// `enableSetNeedsDisplay`) whenever ``scene`` changes, keeps the camera's
/// viewport in step with the drawable (Retina-aware: a change of backing
/// scale keeps the zoom in millimetres per point), converts between view
/// points, drawable pixels and world coordinates, and forwards input to
/// ``interactionHandler`` (the app's tools) and then ``navigation`` (the
/// default ``SliceNavigation``).
@MainActor
open class SliceView: MTKView {
    /// The renderer (one per view).
    public let renderer: SliceRenderer

    /// What the view shows. Setting it redraws.
    public var scene: SliceScene {
        didSet { if !isSyncing { needsDisplay = true } }
    }

    /// The app's tools; sees every event first.
    public weak var interactionHandler: (any SliceViewInteraction)?
    /// Default navigation, used for events the handler did not take.
    public var navigation: (any SliceViewInteraction)? = SliceNavigation()

    /// Called after built-in navigation changed ``scene`` (pan, zoom, slice,
    /// window), so the app can sync other views and its model.
    public var sceneChangedByInteraction: ((SliceView) -> Void)?

    /// The last rendering error, if drawing failed.
    public private(set) var lastError: (any Error)?

    private var isSyncing = false
    private var trackingArea: NSTrackingArea?

    /// A view drawing `scene` with `context`'s device.
    public init(frame: CGRect, context: RenderContext, scene: SliceScene) throws {
        renderer = try SliceRenderer(context: context, colorPixelFormat: .bgra8Unorm)
        self.scene = scene
        super.init(frame: frame, device: context.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("SliceView is created in code")
    }

    // MARK: Drawing

    /// Pixels per point of the window's screen.
    public var backingScale: Double { Double(window?.backingScaleFactor ?? layer?.contentsScale ?? 1) }

    /// Brings the camera's viewport and scale in line with the drawable.
    public func syncViewport() {
        let size = SIMD2(Int(drawableSize.width.rounded()), Int(drawableSize.height.rounded()))
        let scale = backingScale
        guard size.x > 0, size.y > 0 else { return }
        if scene.camera.viewportSize != size || scene.camera.pixelsPerPoint != scale {
            isSyncing = true
            if scene.camera.pixelsPerPoint != scale && scene.camera.pixelsPerPoint > 0 {
                // Keep millimetres per point when moving between displays.
                scene.camera.millimetersPerPixel *= scene.camera.pixelsPerPoint / scale
            }
            scene.camera.viewportSize = size
            scene.camera.pixelsPerPoint = scale
            isSyncing = false
        }
    }

    open override func draw(_ dirtyRect: NSRect) {
        syncViewport()
        guard let drawable = currentDrawable else { return }
        do {
            let cb = try renderer.context.makeCommandBuffer(label: "slice view")
            try renderer.encode(scene: scene, to: drawable.texture, commandBuffer: cb)
            cb.present(drawable)
            cb.commit()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Renders the scene offscreen at the view's drawable size times
    /// `scale` (2 for a double-resolution export).
    public func snapshot(scale: Double = 1) throws -> CGImage {
        syncViewport()
        var s = scene
        if scale != 1 {
            s.camera.viewportSize = SIMD2(Int((Double(s.camera.viewportSize.x) * scale).rounded()),
                                          Int((Double(s.camera.viewportSize.y) * scale).rounded()))
            s.camera.millimetersPerPixel /= scale
            s.camera.pixelsPerPoint *= scale
        }
        return try renderer.makeImage(scene: s)
    }

    // MARK: Coordinates

    /// View point (AppKit, bottom-left origin) → drawable pixel (top-left origin).
    public func pixel(fromViewPoint p: CGPoint) -> SIMD2<Double> {
        let sx = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : backingScale
        let sy = bounds.height > 0 ? Double(drawableSize.height / bounds.height) : backingScale
        let y = isFlipped ? Double(p.y) : Double(bounds.height - p.y)
        return SIMD2(Double(p.x) * sx, y * sy)
    }

    /// Drawable pixel → view point.
    public func viewPoint(fromPixel q: SIMD2<Double>) -> CGPoint {
        let sx = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : backingScale
        let sy = bounds.height > 0 ? Double(drawableSize.height / bounds.height) : backingScale
        let y = q.y / sy
        return CGPoint(x: q.x / sx, y: isFlipped ? y : Double(bounds.height) - y)
    }

    /// The world point (on the plane) under a view point.
    public func worldPoint(atViewPoint p: CGPoint) -> SIMD3<Double> {
        syncViewport()
        return scene.camera.world(atPixel: pixel(fromViewPoint: p))
    }

    /// Where a world point projects in the view (points), for hit testing.
    public func viewPoint(forWorld x: SIMD3<Double>) -> CGPoint {
        syncViewport()
        return viewPoint(fromPixel: scene.camera.pixel(forWorld: x))
    }

    /// Distance (points) between a view point and where a world point projects.
    public func distance(fromViewPoint p: CGPoint, toWorld x: SIMD3<Double>) -> Double {
        let q = viewPoint(forWorld: x)
        return hypot(Double(p.x - q.x), Double(p.y - q.y))
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
        let e = SliceViewEvent(kind: kind, event: event, locationInView: location, pixel: pixel,
                               world: scene.camera.world(atPixel: pixel))
        if let handler = interactionHandler, handler.sliceView(self, handle: e) { return true }
        if let navigation, navigation.sliceView(self, handle: e) { return true }
        return false
    }

    /// Called by navigation handlers after they change ``scene``.
    public func noteSceneChangedByInteraction() {
        needsDisplay = true
        sceneChangedByInteraction?(self)
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
