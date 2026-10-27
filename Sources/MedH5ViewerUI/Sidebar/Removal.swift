import Foundation
import MedH5Kit

/// What removing an image, annotation or transform does, and whether the
/// format allows it (the sidebar's Remove… items).
///
/// A removal is a pending edit like any other (undoable; the save drops the
/// object from the amendment). It is refused when something the save
/// cannot change still names the object — above all the clinical history:
/// an event version is immutable, and so is what it attests (format 1.1
/// §7.3), so the engine refuses a commit that removes an attested image
/// (E809). A removal that reaches beyond the object is confirmed first.
struct RemovalPlan: Equatable {
    enum Group: String { case image, annotation, transform }

    var group: Group
    var objectID: String
    /// Why it is refused; `nil` when it may go ahead.
    var refusal: String?
    /// What else it changes or affects, for the confirmation.
    var consequences: [String] = []
    /// Images whose `valid_mask` names the annotation (cleared with it).
    var clearsValidMaskOf: [String] = []
    /// The object exists only as a pending addition (an import).
    var isPendingAddition = false

    /// Whether to ask first: the removal reaches beyond the object, or drops
    /// image data.
    var needsConfirmation: Bool { !consequences.isEmpty && !isPendingAddition }

    var title: String {
        switch group {
        case .image: return "Remove Image"
        case .annotation: return "Remove Annotation"
        case .transform: return "Remove Transform"
        }
    }
}

enum RemovalPlanner {
    /// The clinical links that name an object, with the event attesting
    /// each (its source event, or the event asserting it).
    static func clinicalLinks(to type: String, _ id: String, in records: ClinicalRecords?) -> [ClinicalLink] {
        (records?.links ?? []).filter { l in
            (l.targetType == type && l.targetID == id) || (l.sourceType == type && l.sourceID == id)
                || (type == "annotation" && l.targetAnnotationID == id)
        }
    }

    private static func describe(_ links: [ClinicalLink], records: ClinicalRecords?) -> String {
        let events = links.compactMap { l -> String? in
            if l.sourceType == "event" { return l.sourceID }
            return l.assertedByEventID
        }
        var unique: [String] = []
        for e in events where !unique.contains(e) { unique.append(e) }
        let kinds = unique.map { id in records?.event(id).map { "\(id) (\($0.kind))" } ?? id }
        return kinds.isEmpty ? "its links" : (kinds.count == 1 ? "event " : "events ") + Format.list(kinds)
    }

    static func image(_ id: String, summary: SampleSummary, clinical: ClinicalRecords?, edits: PendingEdits,
                      isBase: Bool = false) -> RemovalPlan {
        var plan = RemovalPlan(group: .image, objectID: id)
        if edits.newImages[id] != nil {
            plan.isPendingAddition = true
            return plan
        }
        guard let info = summary.image(id) else {
            plan.refusal = "The sample holds no image \(id)."
            return plan
        }
        let links = clinicalLinks(to: "image", id, in: clinical)
        if !links.isEmpty {
            plan.refusal = "\(id) cannot be removed: the clinical history's \(describe(links, records: clinical)) attest\(links.count == 1 ? "s" : "") it. "
                + "An event version is immutable, and so is what it attests (format 1.1 §7.3): the engine refuses to commit the removal (E809)."
            return plan
        }
        plan.consequences.append("Its samples\(info.storedBytes.map { " (\(Format.bytes($0)) stored)" } ?? "") are dropped from the file at the next save.")
        if !summary.acquisition.isEmpty, summary.acquisition[id] != nil {
            plan.consequences.append("Its acquisition parameters leave the document.")
        }
        let onGrid = summary.annotations.filter { $0.grid == info.grid && !edits.removedAnnotations.contains($0.id) }.map(\.id)
        let otherImages = summary.images.filter { $0.grid == info.grid && $0.id != id && !edits.removedImages.contains($0.id) }
        if !onGrid.isEmpty && otherImages.isEmpty {
            plan.consequences.append("Grid \(info.grid) keeps its annotations (\(Format.list(Array(onGrid.prefix(4))))\(onGrid.count > 4 ? "…" : "")) without an image.")
        }
        if isBase { plan.consequences.append("It is the base image of the main views.") }
        return plan
    }

    static func annotation(_ id: String, summary: SampleSummary, clinical: ClinicalRecords?, edits: PendingEdits) -> RemovalPlan {
        var plan = RemovalPlan(group: .annotation, objectID: id)
        // Made in the viewer and not saved yet (an import, a new segmentation,
        // a new geometric annotation): `summary` is the saved file's.
        if edits.importedSegmentations[id] != nil
            || ((edits.newSegmentations[id] != nil || edits.annotations[id] != nil) && summary.annotation(id) == nil) {
            plan.isPendingAddition = true
            return plan
        }
        guard summary.annotation(id) != nil else {
            plan.refusal = "The sample holds no annotation \(id)."
            return plan
        }
        let links = clinicalLinks(to: "annotation", id, in: clinical)
        if !links.isEmpty {
            plan.refusal = "\(id) cannot be removed: the clinical history's \(describe(links, records: clinical)) refer\(links.count == 1 ? "s" : "") to it. "
                + "An event version is immutable, and so is what it attests (format 1.1 §7.3): the engine refuses to commit the removal (E809)."
            return plan
        }
        let removed = edits.removedAnnotations
        if let holder = summary.annotations.first(where: { $0.ignoreMask == id && !removed.contains($0.id) }) {
            plan.refusal = "\(id) holds the ignore region of \(holder.id) (its ignore_mask): remove \(holder.id) first, or keep both."
            return plan
        }
        let derived = summary.annotations.filter { $0.derivedFrom.contains(id) && !removed.contains($0.id) }.map(\.id)
        if !derived.isEmpty {
            plan.refusal = "\(id) cannot be removed: \(Format.list(derived)) \(derived.count == 1 ? "is" : "are") derived from it (derived_from)."
            return plan
        }
        let masked = summary.images.filter { $0.validMask == id && !edits.removedImages.contains($0.id) }.map(\.id)
        if !masked.isEmpty {
            plan.clearsValidMaskOf = masked
            plan.consequences.append("\(Format.list(masked)) lose\(masked.count == 1 ? "s" : "") \(masked.count == 1 ? "its" : "their") valid region (valid_mask).")
        }
        if summary.index.contains(where: { $0.annotation == id }) {
            plan.consequences.append("Its sampling index entry is dropped.")
        }
        return plan
    }

    static func transform(_ id: String, summary: SampleSummary, edits: PendingEdits) -> RemovalPlan {
        var plan = RemovalPlan(group: .transform, objectID: id)
        guard let t = summary.transform(id) else {
            plan.refusal = "The sample holds no transform \(id)."
            return plan
        }
        let removed = edits.removedTransforms
        let users = summary.transforms.filter {
            !removed.contains($0.id) && $0.id != id && ($0.inverseID == id || ($0.components ?? []).contains(id))
        }.map(\.id)
        if !users.isEmpty {
            plan.refusal = "\(id) cannot be removed: \(Format.list(users)) \(users.count == 1 ? "names" : "name") it (as an inverse or a component)."
            return plan
        }
        let others = summary.transforms.filter { !removed.contains($0.id) && $0.id != id }
        let stillLinked = others.contains { Set([$0.fromFrame, $0.toFrame]) == Set([t.fromFrame, t.toFrame]) }
        if !stillLinked {
            plan.consequences.append("\(t.fromFrame) and \(t.toFrame) are no longer registered: overlays across them are not drawn, and Compare links them by voxel index.")
        }
        return plan
    }

    /// The pending edit a plan makes.
    static func apply(_ plan: RemovalPlan, to edits: inout PendingEdits) {
        guard plan.refusal == nil else { return }
        let id = plan.objectID
        switch plan.group {
        case .image:
            if let image = edits.newImages.removeValue(forKey: id) {
                // A grid made for the import goes with its last image.
                if edits.newGrids[image.grid] != nil && !edits.newImages.values.contains(where: { $0.grid == image.grid })
                    && !edits.importedSegmentations.values.contains(where: { $0.grid == image.grid }) {
                    edits.newGrids[image.grid] = nil
                }
                return
            }
            edits.removedImages.insert(id)
            edits.imageAttributes[id] = nil
            if var doc = edits.document {
                doc.set(nil, at: [.key("acquisition"), .key(id)])
                if doc["acquisition"]?.objectValue?.isEmpty == true { doc["acquisition"] = nil }
                if case .array(var tps)? = doc["timepoints"] {
                    for i in tps.indices { tps[i].set(nil, at: [.key("series_uids"), .key(id)]) }
                    doc["timepoints"] = .array(tps)
                }
                edits.document = doc
            }
        case .annotation:
            if edits.importedSegmentations.removeValue(forKey: id) != nil { return }
            if plan.isPendingAddition {
                // Made in the viewer: taken back. `removedAnnotations` names
                // only objects the file holds — a save skips what it names,
                // and forgets the removal, while a new segmentation left in
                // the edits would come back after it.
                edits.newSegmentations[id] = nil
                edits.editedSegmentations.remove(id)
                edits.annotations[id] = nil
                return
            }
            edits.removedAnnotations.insert(id)
            edits.annotations[id] = nil
            for image in plan.clearsValidMaskOf {
                edits.imageAttributes[image, default: JSONObject()]["valid_mask"] = .null
            }
        case .transform:
            edits.removedTransforms.insert(id)
        }
    }
}
