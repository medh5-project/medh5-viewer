import AppKit
import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

extension EditingSession {
    // MARK: Which annotation

    /// The annotation kinds a drawing tool adds to (the first one it creates).
    static func annotationKinds(for tool: ViewerTool) -> [String] {
        switch tool {
        case .box: return ["boxes"]
        case .point: return ["points", "keypoints"]
        case .polyline: return ["polylines"]
        case .contour: return ["contours"]
        default: return []
        }
    }

    /// The drawing tool of an annotation kind.
    static func tool(forKind kind: String) -> ViewerTool? {
        switch kind {
        case "boxes": return .box
        case "points", "keypoints": return .point
        case "polylines": return .polyline
        case "contours": return .contour
        default: return nil
        }
    }

    /// The task a new annotation of a kind records.
    static func defaultTask(_ kind: String) -> String {
        switch kind {
        case "boxes": return "detection"
        case "contours": return "segmentation"
        default: return "other"
        }
    }

    func isEditableAnnotation(_ id: String) -> Bool {
        guard let a = summary.annotation(id) else { return false }
        return AnnotationDraft.editableKinds.contains(a.kind)
    }

    /// The geometric annotations the tools edit.
    var editableAnnotations: [AnnotationInfo] {
        summary.annotations.filter { AnnotationDraft.editableKinds.contains($0.kind) }
    }

    /// The annotation a drawing tool adds to; `nil`: a new one, made with
    /// the next item. Automatically, an annotation the clinical history
    /// attests is passed over (it cannot be amended).
    func activeAnnotation(for tool: ViewerTool) -> String? {
        let kinds = Self.annotationKinds(for: tool)
        switch annotationTarget {
        case .existing(let id) where summary.annotation(id).map({ kinds.contains($0.kind) }) == true:
            return id
        case .new:
            return nil
        default:
            return workspace.activeStack.layers.reversed().first {
                $0.isVisible && kinds.contains($0.detail) && isEditableAnnotation($0.id) && attestation(of: $0.id) == nil
            }?.id
        }
    }

    /// Why an annotation cannot be amended because the clinical history
    /// attests what it holds (1.1 §7.3), or `nil`.
    func attestation(of id: String) -> String? {
        if let event = attestations.annotations[id] {
            return "\(id) is attested by the clinical event \(event): what an event attests is immutable (format 1.1 §7.3)"
        }
        guard !attestations.instances.isEmpty, pendingEdits.annotations[id] == nil || workspace.file.summary.annotation(id) != nil
        else { return nil }
        var ids = summary.annotation(id)?.instanceIDs ?? []
        if let d = draft(id) { ids += d.instanceIDs }
        guard let hit = ids.first(where: { attestations.instances[$0] != nil }), let event = attestations.instances[hit] else {
            return nil
        }
        return "\(id) holds instance \(hit), which the clinical event \(event) attests: what an event attests is immutable (format 1.1 §7.3)"
    }

    /// The annotation the Annotations tab lists.
    var listedAnnotation: String? {
        if case .existing(let id) = annotationTarget, summary.annotation(id) != nil { return id }
        let tool = workspace.viewer.tool
        if !Self.annotationKinds(for: tool).isEmpty { return activeAnnotation(for: tool) }
        if case .new = annotationTarget { return nil }
        return workspace.activeStack.layers.reversed().first { $0.isVisible && isEditableAnnotation($0.id) }?.id
    }

    /// Makes an annotation the one the tools add to (and the tab lists),
    /// shows it, and takes the matching drawing tool when one is in use.
    func choose(annotation id: String) {
        annotationTarget = .existing(id)
        show(id)
        if let kind = summary.annotation(id)?.kind, let tool = Self.tool(forKind: kind),
           !Self.annotationKinds(for: workspace.viewer.tool).isEmpty, workspace.viewer.tool != tool {
            workspace.viewer.tool = tool
        }
        if selectionAnnotationID != id {
            selectionAnnotationID = id
            selectedItems = []
        }
    }

    func annotationGrid(_ id: String) -> GridGeometry? {
        summary.annotation(id)?.grid.flatMap { summary.grid($0) }
    }

    /// The spatial rank of an annotation's coordinates.
    func annotationRank(_ info: AnnotationInfo) -> Int {
        info.grid.flatMap { summary.grid($0) }?.spatialRank ?? 3
    }

    /// The class of new items: the one chosen, else the annotation's first
    /// class, else the label set's first.
    func annotationClass(for tool: ViewerTool) -> Int? {
        if let c = annotationClassID, c > 0, c < 65535 { return c }
        if let id = activeAnnotation(for: tool), let first = summary.annotation(id)?.classIDs.first { return first }
        return summary.labelSet?.classes.first?.id
    }

    /// Whether a drawing tool can work now, and if not, why.
    func annotationAvailability(_ tool: ViewerTool) -> EditAvailability {
        if let why = readOnlyReason { return .unavailable(why) }
        guard workspace.referenceGrid(of: workspace.activeStack) != nil else { return .unavailable("There is no image to draw on") }
        if tool != .point, annotationClass(for: tool) == nil {
            return .unavailable("Choose a class for new items in the Annotations tab, or create one")
        }
        return .available
    }

    // MARK: Drafts

    /// The annotation as the tools edit it: the pending edit's, else what the
    /// engine read (`nil` while it loads, or for a kind not edited here).
    func draft(_ id: String) -> AnnotationDraft? {
        if let edit = pendingEdits.annotations[id] {
            if let c = draftCache[id], c.source == .pending(edit) { return c.draft }
            guard let d = try? AnnotationDraft(edit: edit) else { return nil }
            draftCache[id] = DraftCacheEntry(source: .pending(edit), draft: d)
            return d
        }
        guard let g = store.ready(.geometry(id), as: GeometryResource.self), let info = summary.annotation(id) else { return nil }
        let key = ObjectIdentifier(g)
        if let c = draftCache[id], c.source == .file(key) { return c.draft }
        guard let d = try? AnnotationDraft(g.annotation, rank: annotationRank(info)) else { return nil }
        draftCache[id] = DraftCacheEntry(source: .file(key), draft: d)
        return d
    }

    /// Whether an annotation has unsaved changes (it is drawn from them).
    func hasPendingDraft(_ id: String) -> Bool { pendingEdits.annotations[id] != nil }

    /// The items of an annotation, as the tab lists them.
    func items(of id: String) -> [AnnotationDraft.Item] {
        draft(id)?.items(grid: annotationGrid(id), labelSet: summary.labelSet) ?? []
    }

    // MARK: Drawing

    /// Where a drawing tool's item goes: the active annotation of its kind,
    /// or a new one on the view's base grid.
    struct DrawingTarget {
        var id: String
        var draft: AnnotationDraft
        var grid: GridGeometry?
        var isNew: Bool
        var stack: LayerStack
    }

    func drawingTarget(_ tool: ViewerTool, viewport: ViewportID) throws -> DrawingTarget {
        if case .unavailable(let why) = annotationAvailability(tool) { throw EditingFailure(why) }
        let stack = workspace.stack(for: viewport)
        guard let reference = workspace.referenceGrid(of: stack) else { throw EditingFailure("There is no image to draw on") }
        if let id = activeAnnotation(for: tool), let info = summary.annotation(id) {
            let grid = info.grid.flatMap { summary.grid($0) }
            if let grid, !Self.sameFrame(grid, reference) {
                throw EditingFailure("\(id) is in another frame than this view: draw in a view of its own timepoint")
            }
            if grid == nil, let frame = info.frameUID, frame != reference.frameUID {
                throw EditingFailure("\(id) is in another frame than this view")
            }
            if let why = attestation(of: id) { throw EditingFailure(why + ". Draw into a new annotation.") }
            guard let draft = draft(id) else { throw EditingFailure("\(id) is loading") }
            return DrawingTarget(id: id, draft: draft, grid: grid, isNew: false, stack: stack)
        }
        guard let kind = Self.annotationKinds(for: tool).first,
              let draft = AnnotationDraft.empty(kind: kind, space: kind == "points" ? .world : .index, rank: reference.spatialRank)
        else { throw EditingFailure("\(tool.title) draws no annotation") }
        let tp = reference.timepoint.map { "_\($0)" } ?? ""
        return DrawingTarget(id: uniqueID("\(kind)\(tp)"), draft: draft, grid: reference, isNew: true, stack: stack)
    }

    /// A world point in an annotation's own space.
    static func own(_ p: SIMD3<Double>, space: AnnotationSpace, grid: GridGeometry?) -> SIMD3<Double> {
        space == .index ? (grid?.index(fromWorld: p) ?? p) : p
    }

    /// Draws a box from a drag on a slice view (2-D on the slice, or
    /// `boxDepth` slices deep).
    func addBox(from a: SIMD3<Double>, to b: SIMD3<Double>, planeNormal: SIMD3<Double>, viewport: ViewportID) throws {
        let t = try drawingTarget(.box, viewport: viewport)
        guard case .boxes(var set) = t.draft, let grid = t.grid else { throw EditingFailure("Boxes are drawn on a grid") }
        guard let cls = annotationClass(for: .box) else { throw EditingFailure("Choose a class") }
        let axis = grid.nearestAxis(to: planeNormal)
        let slice = Int((grid.index(fromWorld: a)[axis] + 0.5).rounded(.down))
        let depth: ClosedRange<Int>? = boxDepth > 0 ? (slice - (boxDepth - 1) / 2)...(slice + boxDepth / 2) : nil
        var box = BoxAnnotation.fromDrag(from: a, to: b, planeNormal: planeNormal, geometry: grid, classID: UInt16(cls),
                                         depth: depth, snapToVoxels: true)
        if set.space == .world {
            // An axis-aligned world box around the index box drawn.
            let v = box.voxelBox
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for i in 0..<8 {
                let k = SIMD3((i & 4) != 0 ? v.edgeUpper.x : v.edgeLower.x, (i & 2) != 0 ? v.edgeUpper.y : v.edgeLower.y,
                              (i & 1) != 0 ? v.edgeUpper.z : v.edgeLower.z)
                let w = grid.world(fromIndex: k)
                lo = simd_min(lo, w)
                hi = simd_max(hi, w)
            }
            box = BoxAnnotation(lower: lo, upper: hi, classID: UInt16(cls))
        } else if set.rank < 3 {
            box.sliceIndex = nil
        }
        set.boxes.append(box)
        try store(.boxes(set), target: t, name: "Add Box", select: [set.boxes.count - 1])
    }

    /// Places a point: a landmark of a point set, or the next keypoint of a
    /// keypoint set's last object (a new object when it is complete).
    func addPoint(at world: SIMD3<Double>, viewport: ViewportID) throws {
        let t = try drawingTarget(.point, viewport: viewport)
        let p = Self.own(world, space: t.draft.space, grid: t.grid)
        switch t.draft {
        case .points(var set):
            var point = LandmarkPoint(position: p)
            let classed = set.points.allSatisfy { $0.classID != nil }
            if classed, let c = annotationClass(for: .point) { point.classID = UInt16(c) }
            if set.points.contains(where: { $0.instanceID != nil }) { point.instanceID = (set.points.compactMap(\.instanceID).max() ?? 0) + 1 }
            if set.points.contains(where: { $0.weight != nil }) { point.weight = 1 }
            if set.points.contains(where: { $0.name != nil }) {
                // Named landmarks: a name of its own.
                let names = Set(set.points.compactMap(\.name))
                var n = set.points.count + 1
                while names.contains("Point \(n)") { n += 1 }
                point.name = "Point \(n)"
            }
            set.points.append(point)
            try store(.points(set), target: t, name: "Add Point", select: [set.points.count - 1])
        case .keypoints(var set):
            guard set.slotCount > 0 else { throw EditingFailure("\(t.id) has no keypoint slots") }
            let object: Int
            if let last = set.objects.indices.last, let slot = set.objects[last].visibility.firstIndex(of: .unlabelled) {
                set.objects[last].set(slot: slot, to: p)
                object = last
            } else {
                let cls = annotationClassID.map { UInt16($0) } ?? set.objects.last?.classID
                    ?? annotationClass(for: .point).map { UInt16($0) } ?? 1
                object = set.addObject(classID: cls)
                set.objects[object].set(slot: 0, to: p)
            }
            try store(.keypoints(set), target: t, name: "Add Keypoint", select: [object])
        default:
            throw EditingFailure("\(t.id) holds no points")
        }
    }

    /// Adds a polyline or a contour drawn on a slice view. On a view aligned
    /// with the grid it lies in the slice's grid plane (exactly).
    func addCurve(_ tool: ViewerTool, points world: [SIMD3<Double>], planeNormal: SIMD3<Double>, viewport: ViewportID) throws {
        let t = try drawingTarget(tool, viewport: viewport)
        guard let cls = annotationClass(for: tool) else { throw EditingFailure("Choose a class") }
        let minimum = tool == .contour ? 3 : 2
        guard world.count >= minimum else {
            throw EditingFailure("A \(tool == .contour ? "contour" : "polyline") needs at least \(minimum) points")
        }
        var plane: GridPlane?
        var own = world.map { Self.own($0, space: t.draft.space, grid: t.grid) }
        if let g = t.grid {
            let axis = g.nearestAxis(to: planeNormal)
            if abs(simd_dot(g.axisDirections[axis], simd_normalize(planeNormal))) > 0.9999 {
                let n = g.paddedShape[axis]
                let index = max(0, min(n - 1, Int((g.index(fromWorld: world[0])[axis] + 0.5).rounded(.down))))
                plane = GridPlane(axis: axis, index: index)
                own = world.map { p in
                    var k = g.index(fromWorld: p)
                    k[axis] = Double(index)
                    return t.draft.space == .index ? k : g.world(fromIndex: k)
                }
            }
        }
        switch t.draft {
        case .polylines(var set):
            var line = Polyline(vertices: own, classID: UInt16(cls), plane: plane)
            if !set.polylines.isEmpty, set.polylines.allSatisfy({ $0.instanceID != nil }) {
                line.instanceID = (set.polylines.compactMap(\.instanceID).max() ?? 0) + 1
            }
            set.polylines.append(line)
            try store(.polylines(set), target: t, name: "Add Polyline", select: [set.polylines.count - 1])
        case .contours(var set):
            set.contours.append(Contour(vertices: own, classID: UInt16(cls), plane: plane))
            try store(.contours(set), target: t, name: "Add Contour", select: [set.contours.count - 1])
        default:
            throw EditingFailure("\(t.id) holds no \(tool == .contour ? "contours" : "polylines")")
        }
    }

    // MARK: Storing

    /// Stores a changed draft as the annotation's pending edit (one undo
    /// step), validated first: a save would refuse what the validator
    /// calls an error.
    func store(_ draft: AnnotationDraft, target t: DrawingTarget, name: String, select items: Set<Int>? = nil) throws {
        try store(draft, id: t.id, grid: t.grid, isNew: t.isNew, stack: t.stack, name: name, select: items)
    }

    func store(_ draft: AnnotationDraft, id: String, grid: GridGeometry?, isNew: Bool, stack: LayerStack? = nil,
               name: String, select items: Set<Int>? = nil) throws {
        if let why = readOnlyReason { throw EditingFailure(why) }
        guard let document else { throw EditingFailure("There is no document to edit") }
        if !isNew, let why = attestation(of: id) { throw EditingFailure(why) }
        var d = draft
        d.normalizeRoles(grid: grid)
        if let e = d.validate(grid: grid).first(where: \.isError) {
            throw EditingFailure("Not stored — \(e.code): \(e.message)")
        }
        let edit = d.edit(options: writeOptions(for: d, id: id, grid: grid, isNew: isNew))
        document.apply(name) { $0.annotations[id] = edit }
        draftCache[id] = DraftCacheEntry(source: .pending(edit), draft: d)
        if isNew {
            annotationTarget = .existing(id)
            // Not in the file: nothing for the store to read.
            if !store.isReady(.geometry(id)) { store.put(.geometry(id), UnsavedObjectResource()) }
        }
        sync()
        if isNew { show(id, in: stack) }
        if let items {
            selectionAnnotationID = id
            selectedItems = items
        }
    }

    /// The header a draft is written with: the pending edit's, else the
    /// file's annotation's (coverage kept, the classes drawn added to what
    /// was looked for), else a new annotation's on `grid`.
    func writeOptions(for draft: AnnotationDraft, id: String, grid: GridGeometry?, isNew: Bool) -> GeometricWriteOptions {
        let used = Set(draft.classIDs)
        func ids(_ a: AnnotatedClasses?) -> Set<Int> {
            if case .classes(let ids)? = a { return Set(ids) }
            return []
        }
        if case .geometric(_, var options, _)? = pendingEdits.annotations[id] {
            options.common.annotatedClasses = .classes(ids(options.common.annotatedClasses).union(used).sorted())
            return options
        }
        if !isNew, let info = workspace.file.summary.annotation(id) {
            return GeometricWriteOptions(
                grid: info.grid, space: draft.space.rawValue, frameUID: info.grid == nil ? info.frameUID : nil,
                common: AnnotationWriteOptions(
                    annotatedClasses: .classes(Set(info.annotatedClassIDs).union(used).sorted()), closure: info.closure,
                    timepoints: info.declaredTimepoints, prov: info.prov, quality: info.quality.map(QualityReference.key),
                    derivedFrom: info.derivedFrom.isEmpty ? nil : info.derivedFrom, task: info.task))
        }
        return GeometricWriteOptions(grid: grid?.id, space: draft.space.rawValue,
                                     common: AnnotationWriteOptions(annotatedClasses: .classes(used.sorted()),
                                                                    task: Self.defaultTask(draft.kind)))
    }

    // MARK: Items

    /// The selected items of the listed annotation.
    var currentSelection: Set<Int> {
        guard let id = listedAnnotation, id == selectionAnnotationID else { return [] }
        return selectedItems
    }

    func select(items: Set<Int>, of id: String) {
        selectionAnnotationID = id
        selectedItems = items
    }

    /// Moves the crosshair to an item.
    func jump(toItem index: Int, of id: String) {
        guard let center = items(of: id)[safe: index]?.center else { return }
        let viewport = workspace.viewer.activeViewport.isSlice ? workspace.viewer.activeViewport : .slice(.axial)
        let stack = workspace.stack(for: viewport)
        var p = center
        if let reference = workspace.referenceGrid(of: stack), let info = summary.annotation(id) {
            let key = PlacementResolver.pointKey(reference: reference, annotationGrid: annotationGrid(id), annotationFrame: info.frameUID)
            if let mapper = PlacementResolver.pointMapper(key, store: store).0 { p = mapper.map(center) }
        }
        workspace.setCursor(p, from: viewport)
    }

    /// Whether the listed annotation's items can be changed.
    var canEditListedItems: Bool {
        guard readOnlyReason == nil, let id = listedAnnotation, attestation(of: id) == nil else { return false }
        return draft(id) != nil
    }

    func deleteSelectedItems() throws {
        guard let id = listedAnnotation, var d = draft(id) else { return }
        let sel = currentSelection
        guard !sel.isEmpty else { return }
        d.remove(sel)
        try store(d, id: id, grid: annotationGrid(id), isNew: false,
                  name: sel.count == 1 ? "Delete Item" : "Delete Items", select: [])
    }

    func setClassOfSelectedItems(_ classID: Int) throws {
        guard let id = listedAnnotation, var d = draft(id), classID > 0, classID < 65535 else { return }
        let sel = currentSelection
        guard !sel.isEmpty else { return }
        d.setClass(UInt16(classID), items: sel)
        try store(d, id: id, grid: annotationGrid(id), isNew: false, name: "Change Class", select: sel)
    }

    func selectAllItems() {
        guard let id = listedAnnotation, let d = draft(id) else { return }
        select(items: Set(0..<d.itemCount), of: id)
    }

    // MARK: Copy and paste

    static let itemsPasteboardType = NSPasteboard.PasteboardType("org.medh5.viewer.annotation-items")

    /// Copies the selected items (and a text description).
    func copySelectedItems(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let id = listedAnnotation, let d = draft(id), !currentSelection.isEmpty else { return false }
        let subset = d.subset(currentSelection)
        let grid = annotationGrid(id)
        let payload = ClipboardItems(draft: subset, grid: grid?.id, frame: summary.annotation(id)?.frameUID ?? grid?.frameUID)
        let text = subset.items(grid: grid, labelSet: summary.labelSet).map { item in
            "\(item.title)\t\(item.classID.map { className($0, labelSet: summary.labelSet) } ?? "—")\t\(item.detail)"
        }.joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.declareTypes([Self.itemsPasteboardType, .string], owner: nil)
        pasteboard.setString(payload.json.serialized(), forType: Self.itemsPasteboardType)
        pasteboard.setString(text, forType: .string)
        return true
    }

    func cutSelectedItems() throws {
        guard copySelectedItems() else { return }
        guard let id = listedAnnotation, var d = draft(id) else { return }
        let sel = currentSelection
        d.remove(sel)
        try store(d, id: id, grid: annotationGrid(id), isNew: false, name: sel.count == 1 ? "Cut Item" : "Cut Items", select: [])
    }

    var canPasteItems: Bool {
        guard canEditListedItems, NSPasteboard.general.availableType(from: [Self.itemsPasteboardType]) != nil else { return false }
        return true
    }

    /// Pastes copied items into the listed annotation (of the same kind),
    /// carried through world coordinates when the grids differ.
    func pasteItems(from pasteboard: NSPasteboard = .general) throws {
        guard let text = pasteboard.string(forType: Self.itemsPasteboardType), let json = try? JSONValue.parse(text),
              let payload = ClipboardItems(json: json) else { throw EditingFailure("Nothing to paste") }
        guard let id = listedAnnotation, var d = draft(id) else { throw EditingFailure("Choose an annotation to paste into") }
        let grid = annotationGrid(id)
        let source = payload.grid.flatMap { summary.grid($0) }
        if let s = source, let g = grid, !Self.sameFrame(s, g) {
            throw EditingFailure("The items were copied from another frame")
        }
        let incoming = try payload.draft.reprojected(from: source, to: grid, space: d.space, rank: d.rank)
        let before = d.itemCount
        try d.append(incoming)
        try store(d, id: id, grid: grid, isNew: false, name: incoming.itemCount == 1 ? "Paste Item" : "Paste Items",
                  select: Set(before..<d.itemCount))
    }

    // MARK: The summary's unsaved objects

    /// The summary of `base` (the file's) with what the pending edits add:
    /// new segmentations and annotations, the label set as it will be
    /// stored, the coverage and items of edited annotations.
    func summary(merging base: SampleSummary) -> SampleSummary {
        guard let edits = document?.pendingEdits, !edits.isEmpty else { return base }
        var s = base
        switch edits.labelSet {
        case .set(let json)?: if let labels = try? json.decode(LabelSetInfo.self) { s.labelSet = labels }
        case .remove?: s.labelSet = nil
        case nil: break
        }
        for (id, new) in edits.newSegmentations.sorted(by: { $0.key < $1.key })
        where base.annotation(id) == nil && !edits.removedAnnotations.contains(id) {
            if let model = segmentationResource(id)?.model, let grid = base.grid(new.grid),
               let info = try? ProvisionalInfo.segmentation(id: id, grid: grid, task: new.task,
                                                            timepoints: new.timepoints ?? grid.timepoint.map { [$0] } ?? [], model: model) {
                s.annotations.append(info)
            }
        }
        for id in edits.editedSegmentations {
            guard let i = s.annotations.firstIndex(where: { $0.id == id }), let model = segmentationResource(id)?.model else { continue }
            s.annotations[i].classIDs = model.classIDs.map(Int.init)
            s.annotations[i].annotatedClassIDs = model.annotatedClassIDs.map(Int.init)
        }
        for (id, edit) in edits.annotations.sorted(by: { $0.key < $1.key }) where !edits.removedAnnotations.contains(id) {
            guard case .geometric(let kind, let options, _) = edit, let draft = draft(id) else { continue }
            var annotated: [Int] = []
            if case .classes(let ids)? = options.common.annotatedClasses { annotated = ids }
            if let i = s.annotations.firstIndex(where: { $0.id == id }) {
                s.annotations[i].items = draft.itemCount
                s.annotations[i].classIDs = Set(s.annotations[i].classIDs).union(draft.classIDs).sorted()
                s.annotations[i].annotatedClassIDs = Set(s.annotations[i].annotatedClassIDs).union(draft.classIDs).sorted()
            } else {
                let grid = options.grid.flatMap { base.grid($0) }
                if let info = try? ProvisionalInfo.geometric(
                    id: id, kind: kind, task: options.common.task ?? Self.defaultTask(kind), grid: grid,
                    frameUID: options.frameUID, space: options.space ?? "index",
                    timepoints: options.common.timepoints ?? grid?.timepoint.map { [$0] } ?? [],
                    classIDs: Set(annotated).union(draft.classIDs).sorted(), items: draft.itemCount) {
                    s.annotations.append(info)
                }
            }
        }
        return s
    }
}

/// What the store holds for an annotation made in the window: it is drawn
/// from the pending edits, there is nothing to read from the file.
final class UnsavedObjectResource: StoredResource, @unchecked Sendable {
    var byteCount: Int { 64 }
}

/// Annotation items on the pasteboard: their datasets, the grid and frame
/// they came from.
struct ClipboardItems {
    var draft: AnnotationDraft
    var grid: String?
    var frame: String?

    init(draft: AnnotationDraft, grid: String?, frame: String?) {
        self.draft = draft
        self.grid = grid
        self.frame = frame
    }

    var json: JSONValue {
        let g = draft.arrays()
        var o: JSONObject = ["kind": .string(g.kind), "space": .string(g.space.rawValue)]
        o["grid"] = grid.map(JSONValue.string)
        o["frame"] = frame.map(JSONValue.string)
        o["arrays"] = .array(g.arrays.map { a in
            let integers = a.integers
            return ["name": .string(a.name), "shape": .ints(a.shape), "integer": .bool(integers != nil),
                    "values": integers.map { JSONValue.array($0.map { .int($0) }) } ?? .doubles(a.doubles)]
        })
        o["strings"] = .object(JSONObject(g.strings.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.strings($0.value)) }))
        o["attributes"] = .object(JSONObject(g.attributes.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }))
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue, let space = json["space"]?.stringValue.flatMap(AnnotationSpace.init(rawValue:)),
              let arrays = json["arrays"]?.arrayValue else { return nil }
        var out: [AnnotationArray] = []
        for a in arrays {
            guard let name = a["name"]?.stringValue, let shape = a["shape"]?.arrayValue?.compactMap(\.intValue),
                  let values = a["values"]?.arrayValue else { return nil }
            if a["integer"]?.boolValue == true {
                out.append(AnnotationArray(name: name, shape: shape, values: .int64(values.compactMap(\.intValue).map(Int64.init))))
            } else {
                out.append(AnnotationArray(name: name, shape: shape, values: .float64(values.compactMap(\.doubleValue))))
            }
        }
        var strings: [String: [String]] = [:]
        for (k, v) in json["strings"]?.objectValue ?? JSONObject() { strings[k] = v.arrayValue?.compactMap(\.stringValue) ?? [] }
        var attributes: [String: String] = [:]
        for (k, v) in json["attributes"]?.objectValue ?? JSONObject() { attributes[k] = v.stringValue }
        guard let draft = try? AnnotationDraft(arrays: GeometricArrays(kind: kind, space: space, arrays: out, strings: strings,
                                                                        attributes: attributes)) else { return nil }
        self.draft = draft
        grid = json["grid"]?.stringValue
        frame = json["frame"]?.stringValue
    }
}

extension AnnotationDraft {
    /// The items in another space or on another grid of the same frame
    /// (positions carried through world coordinates).
    func reprojected(from source: GridGeometry?, to target: GridGeometry?, space: AnnotationSpace, rank: Int) throws -> AnnotationDraft {
        if self.space == space, source?.id == target?.id, self.rank == rank { return self }
        func convert(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let w = self.space == .index ? (source?.world(fromIndex: p) ?? p) : p
            return space == .index ? (target?.index(fromWorld: w) ?? w) : w
        }
        switch self {
        case .boxes(var s):
            s.boxes = s.boxes.map { b in
                var c = b
                c.lower = convert(b.lower)
                c.upper = convert(b.upper)
                c = c.normalized()
                if c.sliceIndex != nil, let a = c.degenerateAxis { c.sliceIndex = Int((c.lower[a] + 0.5).rounded(.down)) }
                return c
            }
            s.space = space
            s.rank = rank
            return .boxes(s)
        case .points(var s):
            s.points = s.points.map { var q = $0; q.position = convert($0.position); return q }
            s.space = space
            s.rank = rank
            return .points(s)
        case .keypoints(var s):
            s.objects = s.objects.map { var o = $0; o.points = o.points.map(convert); return o }
            s.space = space
            s.rank = rank
            return .keypoints(s)
        case .polylines(var s):
            s.polylines = s.polylines.map { var l = $0; l.vertices = l.vertices.map(convert); if source?.id != target?.id { l.plane = nil }; return l }
            s.space = space
            s.rank = rank
            return .polylines(s)
        case .contours(var s):
            s.contours = s.contours.map { var c = $0; c.vertices = c.vertices.map(convert); if source?.id != target?.id { c.plane = nil }; return c }
            s.space = space
            s.rank = rank
            return .contours(s)
        }
    }

    /// Appends another draft's items (of the same kind) as new objects: an
    /// instance id they carry is replaced by a new one (an id names one
    /// object; what an id names may be attested elsewhere, and is immutable).
    mutating func append(_ other: AnnotationDraft) throws {
        func fresh(_ existing: [UInt64?], _ count: Int) -> [UInt64] {
            let next = (existing.compactMap { $0 }.max() ?? 0) + 1
            return (0..<UInt64(count)).map { next + $0 }
        }
        switch (self, other) {
        case (.boxes(var a), .boxes(let b)):
            let ids = fresh(a.boxes.map(\.instanceID), b.boxes.count)
            a.boxes += b.boxes.enumerated().map { i, box in
                var c = box
                if c.instanceID != nil { c.instanceID = ids[i] }
                return c
            }
            self = .boxes(a)
        case (.points(var a), .points(let b)):
            let classed = !a.points.isEmpty && a.points.allSatisfy { $0.classID != nil }
            let ids = fresh(a.points.map(\.instanceID), b.points.count)
            let names = Set(a.points.compactMap(\.name))
            a.points += b.points.enumerated().map { i, point in
                var p = point
                if !a.points.isEmpty && !classed { p.classID = nil }
                if p.instanceID != nil { p.instanceID = ids[i] }
                if let n = p.name, names.contains(n) { p.name = "\(n) copy" }
                return p
            }
            self = .points(a)
        case (.keypoints(var a), .keypoints(let b)):
            guard a.slotClassIDs == b.slotClassIDs else { throw EditingFailure("The keypoints have other slots") }
            a.objects += b.objects
            self = .keypoints(a)
        case (.polylines(var a), .polylines(let b)):
            let ids = fresh(a.polylines.map(\.instanceID), b.polylines.count)
            a.polylines += b.polylines.enumerated().map { i, line in
                var l = line
                if l.instanceID != nil { l.instanceID = ids[i] }
                return l
            }
            self = .polylines(a)
        case (.contours(var a), .contours(let b)):
            a.contours += b.contours
            self = .contours(a)
        default:
            throw EditingFailure("\(KindNames.annotation(other.kind)) cannot be pasted into \(KindNames.annotation(kind).lowercased())")
        }
    }
}
