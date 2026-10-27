import Foundation
import MedH5Core

/// One class of the segmentation's class table.
///
/// A class lives in exactly one layer (`layer`); classes of one layer are
/// mutually exclusive, classes of different layers may overlap (spec §7.2).
public struct SegmentClass: Hashable, Sendable, Codable, Identifiable {
    /// Class id, 1…65534 (spec §5.2), never the annotation's ignore value.
    public var id: UInt16
    /// Machine name (`snake_case`), unique in a label set.
    public var key: String
    /// Display name.
    public var name: String
    public var color: RGBA8
    /// The layer holding this class's voxels.
    public var layer: Int
    /// Whether the renderer draws the class.
    public var isVisible: Bool
    /// A locked class is frozen: no tool adds or removes its voxels, and no
    /// other class overwrites it.
    public var isLocked: Bool

    public init(id: UInt16, key: String, name: String, color: RGBA8? = nil, layer: Int = 0,
                isVisible: Bool = true, isLocked: Bool = false) {
        self.id = id
        self.key = key
        self.name = name
        self.color = color ?? LabelPalette.color(forClassID: Int(id))
        self.layer = layer
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    /// A class for an id with no label-set entry: key `class_<id>`, name
    /// `Class <id>`, the palette colour.
    public static func placeholder(id: UInt16, layer: Int = 0) -> SegmentClass {
        SegmentClass(id: id, key: "class_\(id)", name: "Class \(id)", layer: layer)
    }
}

/// Everything about a segmentation except its voxels: the class table, the
/// coverage contract and the layer count. Edits that change it carry a
/// before/after pair, so class-table and coverage changes undo like voxel
/// changes.
///
/// Invariants (`validate()`): class ids unique and not reserved; every class
/// in a layer `< layerCount`; `classIDs` unique and in the table;
/// `annotatedClassIDs ⊆ classIDs` (spec §6.2).
public struct SegmentationMetadata: Hashable, Sendable {
    /// The class table, in display order.
    public var classes: [SegmentClass]
    /// What the annotation can express (`class_ids`), in encoding order.
    public var classIDs: [UInt16]
    /// What was looked for (`annotated_class_ids`), a subset of `classIDs`.
    public var annotatedClassIDs: [UInt16]
    /// Number of `uint16` layers.
    public var layerCount: Int
    /// The in-band ignore value (`ignore_id`, 65535 by default).
    public var ignoreValue: UInt16
    /// Whether painting a class may replace the ignore region (false: the
    /// ignore region is protected like a locked class).
    public var ignoreLocked: Bool

    public init(classes: [SegmentClass] = [], classIDs: [UInt16] = [], annotatedClassIDs: [UInt16] = [],
                layerCount: Int = 1, ignoreValue: UInt16 = ClassID.ignore, ignoreLocked: Bool = false) {
        self.classes = classes
        self.classIDs = classIDs
        self.annotatedClassIDs = annotatedClassIDs
        self.layerCount = layerCount
        self.ignoreValue = ignoreValue
        self.ignoreLocked = ignoreLocked
    }

    public func classInfo(_ id: UInt16) -> SegmentClass? {
        classes.first { $0.id == id }
    }

    public func classIndex(_ id: UInt16) -> Int? {
        classes.firstIndex { $0.id == id }
    }

    /// Classes assigned to a layer, in table order.
    public func classes(inLayer layer: Int) -> [SegmentClass] {
        classes.filter { $0.layer == layer }
    }

    /// For each layer, the ids of `classIDs` it holds (in `classIDs` order):
    /// the `layer_class_ids` a `layers` annotation stores (spec §7.2).
    public var layerClassIDs: [[UInt16]] {
        var out = Array(repeating: [UInt16](), count: layerCount)
        for id in classIDs {
            if let c = classInfo(id), c.layer < layerCount { out[c.layer].append(id) }
        }
        return out
    }

    public func isAnnotated(_ id: UInt16) -> Bool { annotatedClassIDs.contains(id) }

    public func isInAnnotation(_ id: UInt16) -> Bool { classIDs.contains(id) }

    /// Whether `id` may be a class id here: not 0, not 65535, not the ignore value.
    public func isAssignable(_ id: UInt16) -> Bool {
        id != ClassID.background && id != ClassID.ignore && id != ignoreValue
    }

    /// Checks the invariants.
    public func validate() throws {
        guard layerCount >= 1 else { throw EditingError.invalidArgument("a segmentation has at least one layer") }
        var seen = Set<UInt16>()
        for c in classes {
            guard isAssignable(c.id) else { throw EditingError.reservedClassID(c.id) }
            guard seen.insert(c.id).inserted else { throw EditingError.duplicateClass(c.id) }
            guard c.layer >= 0 && c.layer < layerCount else { throw EditingError.invalidLayer(c.layer) }
        }
        var expressed = Set<UInt16>()
        for id in classIDs {
            guard seen.contains(id) else { throw EditingError.unknownClass(id) }
            guard expressed.insert(id).inserted else {
                throw EditingError.invalidArgument("class \(id) is listed twice in class_ids")
            }
        }
        var annotated = Set<UInt16>()
        for id in annotatedClassIDs {
            guard expressed.contains(id) else {
                throw EditingError.invalidArgument("annotated class \(id) is not in class_ids (spec §6.2: annotated ⊆ class_ids)")
            }
            guard annotated.insert(id).inserted else {
                throw EditingError.invalidArgument("class \(id) is listed twice in annotated_class_ids")
            }
        }
    }
}
