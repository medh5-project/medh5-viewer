import Foundation
import MedH5Kit
import MedH5Editing

/// The changes made to a document since it was opened or last saved. A save
/// applies them all as one copy-on-write amendment of the file (spec §14.4).
///
/// It is a value: the document changes it through `MedH5Document.apply`,
/// which registers the inverse with the undo manager and marks the document
/// edited. A save takes a `SaveSnapshot` of it on the main actor (copying
/// the edited segmentations' layers) and writes the snapshot in the
/// background, so editing can continue while the file is written.
///
/// Edit kinds (phase B adds tools that produce them; the save already
/// writes every one):
/// - **segmentations**: a voxel annotation whose layers the editor holds
///   (`SegmentationModel` in the volume store) and changed, written back as
///   layers with its coverage (`class_ids`, `annotated_class_ids`), ignore
///   value and header preserved; or a new one;
/// - **annotations**: geometric, classification or mask annotations added
///   or replaced;
/// - **removed objects**: annotations, images, transforms;
/// - **document**: the whole `/meta` document (identity, cohort,
///   timepoints, quality, provenance, extra…);
/// - **label set**: replaced or removed;
/// - **image attributes**: window presets, valid mask and other attributes
///   that do not rewrite samples.
public struct PendingEdits: Sendable, Equatable {
    /// Voxel annotations whose in-memory model holds unsaved edits.
    public var editedSegmentations: Set<String> = []
    /// Segmentations made in the viewer (written from the model in the store).
    public var newSegmentations: [String: NewSegmentation] = [:]
    /// Geometric, classification or mask annotations to write (added, or
    /// replacing the stored one).
    public var annotations: [String: AnnotationEdit] = [:]
    public var removedAnnotations: Set<String> = []
    public var removedImages: Set<String> = []
    public var removedTransforms: Set<String> = []
    /// The whole document to store, when it changed.
    public var document: JSONValue?
    public var labelSet: LabelSetChange?
    /// Attribute edits per image (a key with `.null` removes it).
    public var imageAttributes: [String: JSONObject] = [:]
    /// Grids, images and segmentations the viewer added (NIfTI imports;
    /// see PendingAdditions.swift).
    public var newGrids: [String: GridGeometry] = [:]
    public var newImages: [String: NewImage] = [:]
    public var importedSegmentations: [String: ImportedSegmentation] = [:]

    public init() {}

    public var isEmpty: Bool { self == PendingEdits() }

    /// The objects the amendment drops before writing them again (or for
    /// good): replaced and removed annotations, removed images and
    /// transforms. Only objects the source holds are named.
    func without(in summary: SampleSummary) -> [String] {
        var names: [String] = []
        let replaced = editedSegmentations.union(annotations.keys).union(newSegmentations.keys)
        for id in replaced.union(removedAnnotations).sorted() where summary.annotation(id) != nil {
            names.append("annotations/\(id)")
        }
        for id in removedImages.sorted() where summary.image(id) != nil { names.append("images/\(id)") }
        for id in removedTransforms.sorted() where summary.transform(id) != nil { names.append("transforms/\(id)") }
        return names
    }

    /// Every object whose stored bytes the save changes.
    var touchedObjects: Set<String> {
        editedSegmentations.union(newSegmentations.keys).union(annotations.keys).union(removedAnnotations)
            .union(removedImages).union(removedTransforms).union(imageAttributes.keys)
    }
}

/// A segmentation created in the viewer.
public struct NewSegmentation: Sendable, Equatable {
    public var grid: String
    public var task: String
    public var timepoints: [String]?

    public init(grid: String, task: String = "segmentation", timepoints: [String]? = nil) {
        self.grid = grid
        self.task = task
        self.timepoints = timepoints
    }
}

/// The label set change of a save.
public enum LabelSetChange: Sendable, Equatable {
    /// The label set as the document holds it.
    case set(JSONValue)
    case remove
}

/// A geometric, classification or mask annotation to write.
public enum AnnotationEdit: @unchecked Sendable, Equatable {
    /// Any geometric kind from its arrays (`SampleWriter.addGeometric`).
    case geometric(kind: String, options: GeometricWriteOptions, arrays: [NamedArray])
    case classification(assertions: [ClassificationAssertion], scope: String, multilabel: Bool, grid: String?,
                        options: AnnotationWriteOptions)
    case mask(grid: String, mask: VolumeData, task: String, prov: String?)

    public static func == (a: AnnotationEdit, b: AnnotationEdit) -> Bool {
        switch (a, b) {
        case let (.geometric(k1, o1, a1), .geometric(k2, o2, a2)):
            return k1 == k2 && o1 == o2 && a1.map(\.name) == a2.map(\.name) && zip(a1, a2).allSatisfy { $0.data === $1.data }
        case let (.classification(a1, s1, m1, g1, o1), .classification(a2, s2, m2, g2, o2)):
            return a1 == a2 && s1 == s2 && m1 == m2 && g1 == g2 && o1 == o2
        case let (.mask(g1, m1, t1, p1), .mask(g2, m2, t2, p2)):
            return g1 == g2 && m1 === m2 && t1 == t2 && p1 == p2
        default:
            return false
        }
    }
}

/// One segmentation as the save writes it: its layers copied at the moment
/// the save began, and its coverage and header.
struct SegmentationSnapshot: @unchecked Sendable {
    var id: String
    var grid: String
    var layers: [VolumeData]
    var options: SegmentationWriteOptions
    /// The model revision the copy was taken at.
    var revision: UInt64
}

/// What a save writes: the edits, with segmentation layers copied.
struct SaveSnapshot: @unchecked Sendable {
    var edits: PendingEdits
    var segmentations: [SegmentationSnapshot]
    /// The summary of the file being amended.
    var summary: SampleSummary

    /// Builds the snapshot on the main actor: each edited segmentation's
    /// layers are copied from the editor's model (milliseconds), so the
    /// background write never sees a half-made edit.
    @MainActor
    static func make(edits: PendingEdits, summary: SampleSummary, store: VolumeStore?) throws -> SaveSnapshot {
        var segmentations: [SegmentationSnapshot] = []
        let ids = edits.editedSegmentations.union(edits.newSegmentations.keys).sorted()
        for id in ids where !edits.removedAnnotations.contains(id) {
            guard let res = store?.ready(.segmentation(id), as: SegmentationResource.self) else {
                throw SaveError.missingSegmentation(id)
            }
            let model = res.model
            let grid = summary.annotation(id)?.grid ?? edits.newSegmentations[id]?.grid ?? res.info.grid ?? ""
            segmentations.append(SegmentationSnapshot(
                id: id, grid: grid, layers: model.layers.map { $0.copy() },
                options: writeOptions(model: model, stored: summary.annotation(id), new: edits.newSegmentations[id]),
                revision: model.revision))
        }
        return SaveSnapshot(edits: edits, segmentations: segmentations, summary: summary)
    }

    /// The options that write a segmentation back with the coverage the
    /// model holds (never collapsed: `class_ids` and `annotated_class_ids`
    /// as they are) and the header it had.
    static func writeOptions(model: SegmentationModel, stored: AnnotationInfo?, new: NewSegmentation?) -> SegmentationWriteOptions {
        var options = stored.map(SegmentationWriteOptions.preserving) ?? SegmentationWriteOptions()
        options.classIDs = model.classIDs.map(Int.init)
        options.common.annotatedClasses = .classes(model.annotatedClassIDs.map(Int.init))
        options.ignoreValue = model.ignoreValue
        if let new {
            options.common.task = new.task
            options.common.timepoints = new.timepoints
        }
        return options
    }
}

enum SaveError: LocalizedError {
    case readOnly(String)
    case noSource
    case missingSegmentation(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let why): return "This document is read-only. \(why)"
        case .noSource: return "The document has no file to amend."
        case .missingSegmentation(let id): return "The edited segmentation \(id) is no longer in memory."
        }
    }
}

/// Writes a save snapshot by amending the source into the destination
/// (`SampleWriter.amend(url:outURL:without:)`), copy-on-write, validated
/// and digested by the engine at the commit.
struct SaveOperation {
    let snapshot: SaveSnapshot

    /// Amends `source` into `destination` (or in place when `nil`).
    /// Returns the new `content_id`.
    @discardableResult
    func perform(source: URL, destination: URL?, codec: String? = nil) throws -> String? {
        let edits = snapshot.edits
        let writer = try SampleWriter.amend(url: source, outURL: destination, without: edits.without(in: snapshot.summary),
                                            codec: codec)
        do {
            if let document = edits.document { try writer.setDocument(document) }
            switch edits.labelSet {
            case .set(let labels)?: try writer.setLabelSet(labels)
            case .remove?: try writer.setLabelSet(nil)
            case nil: break
            }
            for (id, attrs) in edits.imageAttributes.sorted(by: { $0.key < $1.key })
            where !edits.removedImages.contains(id) && snapshot.summary.image(id) != nil {
                try writer.setImageAttributes(id, attrs)
            }
            try edits.writeAdditions(to: writer)
            for s in snapshot.segmentations {
                try writer.addSegmentation(id: s.id, grid: s.grid, layers: s.layers, options: s.options)
            }
            for (id, edit) in edits.annotations.sorted(by: { $0.key < $1.key }) where !edits.removedAnnotations.contains(id) {
                switch edit {
                case .geometric(let kind, let options, let arrays):
                    try writer.addGeometric(kind: kind, id: id, options: options, arrays: arrays)
                case .classification(let assertions, let scope, let multilabel, let grid, let options):
                    try writer.addClassification(id: id, assertions: assertions, scope: scope, multilabel: multilabel,
                                                 grid: grid, options: options)
                case .mask(let grid, let mask, let task, let prov):
                    try writer.addMask(id: id, grid: grid, mask: mask, task: task, prov: prov)
                }
            }
            return try writer.commit(digests: false)
        } catch {
            writer.abort()
            throw error
        }
    }
}
