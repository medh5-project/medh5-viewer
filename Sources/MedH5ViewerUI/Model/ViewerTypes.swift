import Foundation
import MedH5Kit
import MedH5Render

/// The arrangements of the viewer (View menu, keys 1–5).
public enum ViewerLayout: String, CaseIterable, Identifiable, Sendable {
    /// One slice view.
    case single
    /// Axial, coronal and sagittal side by side.
    case oneByThree = "1x3"
    /// The three planes and the 3-D view.
    case twoByTwo = "2x2"
    /// The 3-D view alone.
    case volume = "3d"
    /// Two timepoints side by side, crosshairs linked through their transform.
    case compare

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single View"
        case .oneByThree: return "1 × 3"
        case .twoByTwo: return "2 × 2"
        case .volume: return "3-D Only"
        case .compare: return "Compare Timepoints"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "square"
        case .oneByThree: return "rectangle.split.3x1"
        case .twoByTwo: return "square.grid.2x2"
        case .volume: return "cube"
        case .compare: return "rectangle.split.2x1"
        }
    }

    /// The key (1–5) that selects the layout.
    var key: String {
        switch self {
        case .single: return "1"
        case .oneByThree: return "2"
        case .twoByTwo: return "3"
        case .volume: return "4"
        case .compare: return "5"
        }
    }

    /// Parses the snapshot option spelling (`single`, `1x3`, `2x2`, `3d`, `compare`).
    init?(argument: String) {
        switch argument.lowercased() {
        case "single", "1": self = .single
        case "1x3", "1×3", "2": self = .oneByThree
        case "2x2", "2×2", "4up", "3": self = .twoByTwo
        case "3d", "3-d", "volume", "4": self = .volume
        case "compare", "5": self = .compare
        default: return nil
        }
    }
}

/// One viewport of the viewer.
public enum ViewportID: Hashable, Sendable, CustomStringConvertible {
    /// A slice view of the primary stack.
    case slice(ViewPlane)
    /// The 3-D view.
    case volume
    /// The two sides of the compare layout (the primary stack and the
    /// compared timepoint's), both in the compare plane.
    case compareLeft
    case compareRight

    public var description: String {
        switch self {
        case .slice(let p): return p.rawValue
        case .volume: return "3d"
        case .compareLeft: return "compare-left"
        case .compareRight: return "compare-right"
        }
    }

    var isSlice: Bool { self != .volume }
}

/// The interaction tools (toolbar, Tools menu). Phase A has the viewing
/// tools; the editing and measuring tools are listed for the menus and
/// enabled by later phases.
public enum ViewerTool: String, CaseIterable, Identifiable, Sendable {
    case navigate, windowLevel, pan, zoom
    case ruler, angle, roi, brush, eraser, fill, box, point, polyline, contour

    public var id: String { rawValue }

    /// Whether the tool works in this version.
    var isAvailable: Bool {
        switch self {
        case .navigate, .windowLevel, .pan, .zoom: return true
        default: return false
        }
    }

    static var viewingTools: [ViewerTool] { [.navigate, .windowLevel, .pan, .zoom] }
    static var editingTools: [ViewerTool] { [.ruler, .angle, .roi, .brush, .eraser, .fill, .box, .point, .polyline, .contour] }

    var title: String {
        switch self {
        case .navigate: return "Navigate"
        case .windowLevel: return "Window/Level"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .ruler: return "Ruler"
        case .angle: return "Angle"
        case .roi: return "ROI"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .box: return "Box"
        case .point: return "Point"
        case .polyline: return "Polyline"
        case .contour: return "Contour"
        }
    }

    var symbol: String {
        switch self {
        case .navigate: return "cursorarrow"
        case .windowLevel: return "circle.lefthalf.filled"
        case .pan: return "hand.raised"
        case .zoom: return "plus.magnifyingglass"
        case .ruler: return "ruler"
        case .angle: return "angle"
        case .roi: return "circle.dashed"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop"
        case .box: return "square.dashed"
        case .point: return "smallcircle.filled.circle"
        case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .contour: return "lasso"
        }
    }

    /// The key equivalent (and whether it needs ⇧).
    var key: (String, shift: Bool) {
        switch self {
        case .navigate: return ("v", false)
        case .windowLevel: return ("w", false)
        case .pan: return ("h", false)
        case .zoom: return ("z", false)
        case .ruler: return ("m", false)
        case .angle: return ("a", false)
        case .roi: return ("o", false)
        case .brush: return ("b", false)
        case .eraser: return ("e", false)
        case .fill: return ("f", false)
        case .box: return ("b", true)
        case .point: return ("p", true)
        case .polyline: return ("l", true)
        case .contour: return ("c", true)
        }
    }
}

/// The inspector's tabs. Segment editor, Annotations and Measurements are
/// filled by the editing phase.
public enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case layers, segmentEditor, annotations, measurements, info

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: return "Layers"
        case .segmentEditor: return "Segment Editor"
        case .annotations: return "Annotations"
        case .measurements: return "Measurements"
        case .info: return "Info"
        }
    }

    var symbol: String {
        switch self {
        case .layers: return "square.3.layers.3d"
        case .segmentEditor: return "paintbrush.pointed"
        case .annotations: return "square.dashed"
        case .measurements: return "ruler"
        case .info: return "info.circle"
        }
    }

    init?(argument: String) {
        switch argument.lowercased() {
        case "layers": self = .layers
        case "info": self = .info
        case "segment", "segmenteditor", "segment-editor": self = .segmentEditor
        case "annotations": self = .annotations
        case "measurements": self = .measurements
        default: return nil
        }
    }
}

/// Why a document cannot be edited.
public enum ReadOnlyReason: Hashable, Sendable {
    /// The file declares a later format minor; the engine reads what it
    /// knows (a projection) and never amends it.
    case projection(version: String)
    /// Stored digests do not match the bytes: amending would restamp bytes
    /// nobody verified (E701).
    case verificationFailed(summary: String)
    /// A member of a `.medh5c` collection, opened for viewing.
    case collectionMember(String)

    var message: String {
        switch self {
        case .projection(let version):
            return "This file declares format \(version), newer than this engine’s 1.2. It is shown as a projection of what the engine knows and opens read-only."
        case .verificationFailed(let summary):
            return "Integrity check failed: \(summary). The file opens read-only; repair it with `medh5 fix` before editing."
        case .collectionMember(let name):
            return "“\(name)” is a member of a collection and opens read-only."
        }
    }

    var symbol: String {
        switch self {
        case .projection: return "arrow.up.forward.square"
        case .verificationFailed: return "exclamationmark.shield.fill"
        case .collectionMember: return "lock.fill"
        }
    }
}
