import AppKit
import SwiftUI
import MedH5Kit

// Colours and SF Symbols the app uses for medh5 objects, kept together so the
// sidebar, inspector and viewports agree.

extension RGBA8 {
    /// The colour for SwiftUI (sRGB).
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    /// Straight RGBA in `[0, 1]`, as the renderer's overlay styles take it.
    var rgba: SIMD4<Double> {
        SIMD4(Double(r) / 255, Double(g) / 255, Double(b) / 255, Double(a) / 255)
    }

    /// The same colour with another alpha.
    func withAlpha(_ alpha: UInt8) -> RGBA8 { RGBA8(r, g, b, alpha) }
}

/// The colour of a class: the label set's, else the palette's (spec §5.2).
func classColor(_ id: Int, labelSet: LabelSetInfo?) -> RGBA8 {
    if let c = labelSet?.labelClass(id: id)?.color { return c }
    return LabelPalette.color(forClassID: id)
}

/// The display name of a class: the label set's name, else "Class n".
func className(_ id: Int, labelSet: LabelSetInfo?) -> String {
    labelSet?.labelClass(id: id)?.name ?? "Class \(id)"
}

/// The colours of the three standard planes (the 3-D view's plane outlines,
/// the viewport title dots): axial red, coronal green, sagittal yellow, as
/// most MPR viewers draw them.
enum PlaneColors {
    static func rgba(_ plane: ViewPlane) -> SIMD4<Double> {
        switch plane {
        case .axial: return SIMD4(0.93, 0.33, 0.31, 1)
        case .coronal: return SIMD4(0.36, 0.78, 0.38, 1)
        case .sagittal: return SIMD4(0.95, 0.80, 0.25, 1)
        }
    }

    static func color(_ plane: ViewPlane) -> Color {
        let c = rgba(plane)
        return Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: 1)
    }
}

/// SF Symbols for medh5 objects.
enum Symbols {
    static func annotation(kind: String) -> String {
        switch kind {
        case "labelmap": return "square.grid.3x3.fill"
        case "layers": return "square.3.layers.3d"
        case "bitmask": return "square.grid.3x3.square"
        case "instances": return "circle.grid.2x2.fill"
        case "probmap": return "circle.dotted"
        case "mask": return "square.dashed.inset.filled"
        case "boxes": return "square.dashed"
        case "obb": return "cube"
        case "keypoints": return "point.3.connected.trianglepath.dotted"
        case "points": return "smallcircle.filled.circle"
        case "contours": return "lasso"
        case "polylines": return "point.topleft.down.to.point.bottomright.curvepath"
        case "mesh": return "cube.transparent"
        case "classification": return "tag"
        default: return "questionmark.square.dashed"
        }
    }

    static func image(modality: String, valueType: String) -> String {
        if valueType == "rgb" { return "photo" }
        if valueType == "displacement" { return "arrow.up.and.down.and.arrow.left.and.right" }
        if valueType == "probability" { return "circle.dotted" }
        if valueType == "mask" { return "square.dashed.inset.filled" }
        return "square.stack.3d.up.fill"
    }

    static let grid = "grid"
    static let timepoint = "calendar"
    static let transform = "arrow.triangle.swap"
    static let labelSet = "paintpalette"
    static let provenance = "person.2"
    static let quality = "checkmark.seal"
    static let deidentification = "eye.slash"
    static let clinical = "stethoscope"
    static let index = "list.number"
    static let sample = "doc.text.magnifyingglass"
    static let acrossTimepoints = "arrow.left.and.right"
    static let warning = "exclamationmark.triangle.fill"
}

/// Human names of the annotation kinds.
enum KindNames {
    static func annotation(_ kind: String) -> String {
        switch kind {
        case "labelmap": return "Label map"
        case "layers": return "Layers"
        case "bitmask": return "Bitmask"
        case "instances": return "Instances"
        case "probmap": return "Probability map"
        case "mask": return "Mask"
        case "boxes": return "Boxes"
        case "obb": return "Oriented boxes"
        case "keypoints": return "Keypoints"
        case "points": return "Points"
        case "contours": return "Contours"
        case "polylines": return "Polylines"
        case "mesh": return "Mesh"
        case "classification": return "Classification"
        default: return kind
        }
    }
}
