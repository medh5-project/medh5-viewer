import AppKit
import SwiftUI

/// The AppKit view of a viewport: the Metal view (or a placeholder) with a
/// SwiftUI text overlay on top that lets every event through. Keeping the
/// overlay a separate hosting view lets the snapshot runner composite it
/// over the Metal image in the right order.
final class ViewportContainerView: NSView {
    let content: NSView
    let overlay: NSView
    /// Called when the size changes (the camera's fit depends on it).
    var onResize: (() -> Void)?
    /// Called when the view enters a window.
    var onWindow: (() -> Void)?

    init(content: NSView, overlay: NSView) {
        self.content = content
        self.overlay = overlay
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for v in [content, overlay] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
}

/// A hosting view that never takes the mouse: the overlay above a Metal
/// view is text only.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        if #available(macOS 13.0, *) { sizingOptions = [] }
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

/// A plain view shown where Metal is not available.
final class PlaceholderView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }
}

/// Puts a viewport's AppKit view into SwiftUI.
struct ViewportRepresentable: NSViewRepresentable {
    let view: ViewportContainerView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        attach(to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}
