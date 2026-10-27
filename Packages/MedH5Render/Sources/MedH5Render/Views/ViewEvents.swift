import AppKit
import simd

/// The kinds of input a view forwards to its interaction handlers.
public enum ViewEventKind: Sendable, Hashable {
    case mouseDown, mouseDragged, mouseUp
    case rightMouseDown, rightMouseDragged, rightMouseUp
    case otherMouseDown, otherMouseDragged, otherMouseUp
    case mouseMoved, mouseEntered, mouseExited
    case scrollWheel
    /// Trackpad pinch (`event.magnification`).
    case magnify
    /// Trackpad two-finger rotation (`event.rotation`, degrees).
    case rotate
    case keyDown, keyUp

    /// Whether this is a button press.
    public var isDown: Bool { self == .mouseDown || self == .rightMouseDown || self == .otherMouseDown }
    /// Whether this is a drag with a button held.
    public var isDrag: Bool { self == .mouseDragged || self == .rightMouseDragged || self == .otherMouseDragged }
    /// Whether this is a button release.
    public var isUp: Bool { self == .mouseUp || self == .rightMouseUp || self == .otherMouseUp }
}

/// An input event in a slice view, with the pointer in every coordinate
/// system a tool needs.
public struct SliceViewEvent {
    public let kind: ViewEventKind
    /// The AppKit event.
    public let event: NSEvent
    /// Pointer in view points (AppKit: bottom-left origin).
    public let locationInView: CGPoint
    /// Pointer in drawable pixels (top-left origin; the renderer's pixels).
    public let pixel: SIMD2<Double>
    /// Pointer in world coordinates, on the view's plane.
    public let world: SIMD3<Double>

    public var modifierFlags: NSEvent.ModifierFlags { event.modifierFlags }
}

/// An input event in a 3-D view.
public struct VolumeViewEvent {
    public let kind: ViewEventKind
    public let event: NSEvent
    /// Pointer in view points (AppKit: bottom-left origin).
    public let locationInView: CGPoint
    /// Pointer in drawable pixels (top-left origin).
    public let pixel: SIMD2<Double>
    /// The camera ray through the pointer.
    public let ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)

    public var modifierFlags: NSEvent.ModifierFlags { event.modifierFlags }
}

/// Something that handles input in a slice view: the app's tools, or the
/// default navigation. Return `true` when the event was handled, so later
/// handlers (the view's `navigation`) do not see it.
@MainActor
public protocol SliceViewInteraction: AnyObject {
    func sliceView(_ view: SliceView, handle event: SliceViewEvent) -> Bool
}

/// Something that handles input in a 3-D view.
@MainActor
public protocol VolumeViewInteraction: AnyObject {
    func volumeView(_ view: VolumeView, handle event: VolumeViewEvent) -> Bool
}

/// Key codes used by the default navigation.
enum KeyCode {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let home: UInt16 = 115
    static let end: UInt16 = 119
}
