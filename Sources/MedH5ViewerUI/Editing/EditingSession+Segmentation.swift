import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The segmentation a voxel tool edits, resolved for a view.
@MainActor
struct SegmentationTarget {
    let id: String
    let resource: SegmentationResource
    /// The class painted (`nil` for the eraser removing every class).
    let classID: UInt16?

    var model: SegmentationModel { resource.model }
}

/// What a new segmentation is made of (the New Segmentation sheet).
struct NewSegmentationRequest: Equatable {
    var id: String
    var grid: String
    var task = "segmentation"
    /// The visits it pertains to (`nil`: its grid's).
    var timepoints: [String]?
    /// Label-set classes it can express from the start (none examined yet).
    var classIDs: [Int] = []
}

extension EditingSession {
    // MARK: Which segmentation

    /// The voxel encodings the segment editor edits (as layers). Instances,
    /// probability maps and masks are shown, not edited.
    static let editableSegmentationKinds: Set<String> = ["labelmap", "layers", "bitmask"]

    func isEditableSegmentation(_ id: String) -> Bool {
        guard let a = summary.annotation(id) else { return false }
        return Self.editableSegmentationKinds.contains(a.kind)
    }

    /// Every segmentation of the sample the editor can edit.
    var editableSegmentations: [AnnotationInfo] {
        summary.annotations.filter { Self.editableSegmentationKinds.contains($0.kind) }
    }

    /// The active segmentation: the one chosen in the segment editor, else
    /// the topmost visible segmentation of the active view.
    var activeSegmentation: String? {
        if let id = activeSegmentationID, isEditableSegmentation(id) { return id }
        return workspace.activeStack.layers.reversed()
            .first { $0.isVisible && $0.kind == .segmentation && isEditableSegmentation($0.id) }?.id
    }

    func segmentationResource(_ id: String) -> SegmentationResource? {
        store.ready(.segmentation(id), as: SegmentationResource.self)
    }

    /// The class painted in a segmentation: the one chosen, else its first
    /// unlocked class.
    func activeClass(of id: String, model: SegmentationModel) -> UInt16? {
        if let c = activeClasses[id], model.classInfo(c) != nil { return c }
        return model.classes.first { !$0.isLocked }?.id ?? model.classes.first?.id
    }

    /// Makes a segmentation the active one and shows it in the active view.
    func activate(segmentation id: String) {
        activeSegmentationID = id
        show(id)
    }

    /// Whether the voxel tools can work now, and if not, why.
    func segmentationAvailability(needsClass: Bool = true) -> EditAvailability {
        if let why = readOnlyReason { return .unavailable(why) }
        if let r = running { return .unavailable("\(r.name) is running") }
        guard let id = activeSegmentation else {
            return .unavailable(editableSegmentations.isEmpty
                ? "There is no segmentation to edit: create one with Segmentation ▸ New Segmentation…"
                : "Choose a segmentation in the Segment Editor, or show one in the view")
        }
        if let why = attestation(of: id) { return .unavailable(why) }
        guard let res = segmentationResource(id) else {
            if let failure = store.failure(.segmentation(id)) { return .unavailable("\(id) could not be read: \(failure)") }
            return .unavailable("\(id) is loading")
        }
        if needsClass {
            guard let c = activeClass(of: id, model: res.model) else {
                return .unavailable("\(id) has no class: add one with Segmentation ▸ Add Class…")
            }
            if res.model.isLocked(c) { return .unavailable("\(res.model.classInfo(c)?.name ?? "The class") is locked") }
        }
        return .available
    }

    /// The segmentation and class the voxel tools edit from a view; refused
    /// (with why) when nothing suitable is active or the segmentation is in
    /// another frame than the view.
    func segmentationTarget(for viewport: ViewportID?, needsClass: Bool = true) throws -> SegmentationTarget {
        if case .unavailable(let why) = segmentationAvailability(needsClass: needsClass) { throw EditingFailure(why) }
        guard let id = activeSegmentation, let res = segmentationResource(id) else { throw EditingFailure("No segmentation") }
        let stack = viewport.map { workspace.stack(for: $0) } ?? workspace.activeStack
        if let reference = workspace.referenceGrid(of: stack), !Self.sameFrame(res.model.geometry, reference) {
            throw EditingFailure("\(id) is in another frame than this view: edit it in a view of its own timepoint")
        }
        return SegmentationTarget(id: id, resource: res, classID: activeClass(of: id, model: res.model))
    }

    /// Whether world coordinates of two grids agree (the same grid, or one frame).
    static func sameFrame(_ a: GridGeometry, _ b: GridGeometry) -> Bool {
        a.id == b.id || a.sharesFrame(with: b)
    }

    // MARK: Voxels per class

    /// Voxels per class of a segmentation (kept in step with every edit).
    func voxelCounts(_ id: String) -> [UInt16: Int] {
        if let c = classCounts[id] { return c }
        guard let res = segmentationResource(id) else { return [:] }
        var counts: [UInt16: Int] = [:]
        if pendingEdits.newSegmentations[id] != nil {
            counts = Self.count(res.model)
        } else if !res.classStats.isEmpty, res.model.revision == 0 {
            // As the engine counted them when it read the segmentation.
            for (classID, s) in res.classStats where classID > 0 && classID < 65535 {
                counts[UInt16(classID)] = Int(s.voxels)
            }
        } else {
            counts = Self.count(res.model)
        }
        classCounts[id] = counts
        return counts
    }

    static func count(_ model: SegmentationModel) -> [UInt16: Int] {
        var counts: [UInt16: Int] = [:]
        for s in (try? model.classStatistics()) ?? [] { counts[s.classID] = s.voxelCount }
        return counts
    }

    /// Applies an edit's changes to the counts (or takes them back).
    func updateCounts(_ id: String, with edit: VoxelEdit, forward: Bool) {
        guard var counts = classCounts[id] else { return }
        var delta = [Int](repeating: 0, count: 65536)
        delta.withUnsafeMutableBufferPointer { d in
            edit.forEachChange { _, _, old, new in
                let (o, n) = forward ? (old, new) : (new, old)
                d[Int(o)] -= 1
                d[Int(n)] += 1
            }
        }
        for v in 1..<65535 where delta[v] != 0 { counts[UInt16(v), default: 0] += delta[v] }
        classCounts[id] = counts
    }

    // MARK: Recording voxel edits

    /// Records an edit already applied to a segmentation's model as one undo
    /// step: undo reverts the voxels (and the class table and coverage) and
    /// restores the pending edits; redo applies both again.
    func recordVoxelEdit(_ edit: VoxelEdit, segmentation id: String, model: SegmentationModel, name: String,
                         edits extra: (inout PendingEdits) -> Void = { _ in }) {
        guard !edit.isEmpty else { return }
        updateCounts(id, with: edit, forward: true)
        refreshSurfaces(id)
        commit(name, bytes: edit.byteSize, edits: { e in
            if e.newSegmentations[id] == nil { e.editedSegmentations.insert(id) }
            extra(&e)
        }, undo: { [weak self] in
            self?.applyVoxelEdit(edit, model: model, segmentation: id, forward: false)
        }, redo: { [weak self] in
            self?.applyVoxelEdit(edit, model: model, segmentation: id, forward: true)
        })
    }

    /// Applies or reverts a recorded edit (undo, redo). Locks are a setting
    /// of the window, not of the file: they stay as they are.
    func applyVoxelEdit(_ edit: VoxelEdit, model: SegmentationModel, segmentation id: String, forward: Bool) {
        let locked = Set(model.classes.filter(\.isLocked).map(\.id))
        if forward { model.apply(edit) } else { model.revert(edit) }
        if Set(model.classes.filter(\.isLocked).map(\.id)) != locked,
           let fix = try? model.metadataEdit({ m in
               for i in m.classes.indices { m.classes[i].isLocked = locked.contains(m.classes[i].id) }
           }) {
            model.apply(fix)
        }
        updateCounts(id, with: edit, forward: forward)
        refreshSurfaces(id)
        workspace.noteVoxelsChanged()
    }

    /// The 3-D view's smoothed surfaces of a segmentation are made again
    /// from the edited voxels (when the view uses them).
    func refreshSurfaces(_ id: String) {
        let key = ResourceKey.surfaces(id)
        guard store.isReady(key) || store.isLoading(key) else { return }
        store.evict(key)
        if store.inUse.contains(key) { store.request(key) }
    }

    // MARK: New segmentation

    /// An id no object of the sample (or of the pending edits) has.
    func uniqueID(_ base: String) -> String {
        let taken = Set(summary.annotations.map(\.id)).union(summary.images.map(\.id))
            .union(pendingEdits.newSegmentations.keys).union(pendingEdits.annotations.keys)
        var id = base, n = 2
        while taken.contains(id) {
            id = "\(base)_\(n)"
            n += 1
        }
        return id
    }

    /// Why an id cannot name a new object, or `nil`.
    func idProblem(_ id: String) -> String? {
        if id.isEmpty { return "Give it an id" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        if id.unicodeScalars.contains(where: { !allowed.contains($0) }) || id.hasPrefix(".") {
            return "Use letters, digits, “_”, “-” and “.” only"
        }
        if summary.annotation(id) != nil || summary.image(id) != nil || pendingEdits.annotations[id] != nil
            || pendingEdits.newSegmentations[id] != nil {
            return "“\(id)” is taken"
        }
        return nil
    }

    /// The request the New Segmentation sheet starts from: the base image's
    /// grid of the active view.
    func defaultNewSegmentation() -> NewSegmentationRequest {
        let grid = workspace.referenceGrid(of: workspace.activeStack) ?? summary.grids.first
        let tp = grid?.timepoint.map { "_\($0)" } ?? ""
        return NewSegmentationRequest(id: uniqueID("segmentation\(tp)"), grid: grid?.id ?? "")
    }

    /// Creates an empty segmentation on a grid (in memory until saved) as
    /// one undo step, shows it in the active view and makes it active.
    @discardableResult
    func createSegmentation(_ request: NewSegmentationRequest) throws -> String {
        if let why = readOnlyReason { throw EditingFailure(why) }
        if let problem = idProblem(request.id) { throw EditingFailure(problem) }
        guard let grid = summary.grid(request.grid) else { throw EditingFailure("There is no grid \(request.grid)") }
        let labels = summary.labelSet
        var classes: [SegmentClass] = []
        for c in request.classIDs where c > 0 && c < 65535 {
            let info = labels?.labelClass(id: c)
            classes.append(SegmentClass(id: UInt16(c), key: info?.key ?? "class_\(c)", name: info?.name ?? "Class \(c)",
                                        color: info?.displayColor ?? LabelPalette.color(forClassID: c), layer: 0))
        }
        let metadata = SegmentationMetadata(classes: classes, classIDs: classes.map(\.id), annotatedClassIDs: [], layerCount: 1)
        let model = try SegmentationModel(geometry: grid.spatialOnly, metadata: metadata)
        let id = request.id
        let timepoints = request.timepoints ?? grid.timepoint.map { [$0] } ?? []
        let info = try ProvisionalInfo.segmentation(id: id, grid: grid, task: request.task, timepoints: timepoints, model: model)
        let plan = try ProvisionalInfo.plan(id: id, grid: grid, model: model)
        var textures: [VolumeTexture] = []
        if let context = store.context {
            textures = try model.layers.map { try VolumeTexture(context: context, labels: $0, geometry: model.geometry) }
        }
        let resource = SegmentationResource(info: info, plan: plan, model: model, textures: textures, ignoreRegion: nil,
                                            ignoreTexture: nil, classStats: [:], context: store.context)
        let stack = workspace.activeStack
        let insert: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.store.put(.segmentation(id), resource)
            self.store.pin(.segmentation(id))
            self.classCounts[id] = nil
        }
        insert()
        let new = NewSegmentation(grid: grid.id, task: request.task, timepoints: request.timepoints)
        commit("New Segmentation", edits: { $0.newSegmentations[id] = new }, undo: { [weak self] in
            guard let self else { return }
            self.store.unpin(.segmentation(id))
            self.store.evict(.segmentation(id))
            if self.activeSegmentationID == id { self.activeSegmentationID = nil }
        }, redo: { [weak self] in
            // Its layer comes back with the summary entry (`sync`).
            insert()
            self?.activeSegmentationID = id
        })
        show(id, in: stack)
        activeSegmentationID = id
        return id
    }

    // MARK: Classes

    /// The label set as the document will store it: the pending one, else
    /// the file's, else a new one.
    func labelSetJSON() throws -> JSONValue {
        switch pendingEdits.labelSet {
        case .set(let json)?:
            return json
        case .remove?:
            break
        case nil:
            if let labels = summary.labelSet { return try JSONValue.encoding(labels) }
        }
        return ["id": "medh5-viewer-labels", "version": "1.0.0", "classes": []]
    }

    /// The next class id no label-set class, segmentation class or
    /// annotation uses.
    func nextFreeClassID() -> Int {
        var used = Set(summary.labelSet?.classes.map(\.id) ?? [])
        for a in summary.annotations { used.formUnion(a.classIDs) }
        for a in editableSegmentations {
            if let res = segmentationResource(a.id) { used.formUnion(res.model.classes.map { Int($0.id) }) }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return min(n, 65534)
    }

    /// `"Left kidney"` → `left_kidney`.
    static func classKey(from name: String) -> String {
        let lowered = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        var key = String(lowered)
        while key.contains("__") { key = key.replacingOccurrences(of: "__", with: "_") }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if key.isEmpty || key.first!.isNumber { key = "class_" + key }
        return key
    }

    /// Adds a label-set class to a segmentation: it can express it from now
    /// on; it is examined once painted. With `overlapping`, the class gets a
    /// layer of its own so it can overlap the others.
    func addClass(_ classID: Int, to id: String, overlapping: Bool = false) throws {
        if let why = readOnlyReason { throw EditingFailure(why) }
        guard let res = segmentationResource(id) else { throw EditingFailure("\(id) is not loaded") }
        let model = res.model
        let info = summary.labelSet?.labelClass(id: classID)
        let c = SegmentClass(id: UInt16(clamping: classID), key: info?.key ?? "class_\(classID)",
                             name: info?.name ?? "Class \(classID)",
                             color: info?.displayColor ?? LabelPalette.color(forClassID: classID))
        let edit = try model.addClassEdit(c, layer: nil, overlapping: overlapping ? Set(model.classes.map(\.id)) : [],
                                          inAnnotation: true, annotated: false)
        model.apply(edit)
        recordVoxelEdit(edit, segmentation: id, model: model, name: "Add Class")
        activeClasses[id] = c.id
    }

    /// Creates a class (adding it to the label set, with an ontology code
    /// when given — strict validation asks every class used for one) and,
    /// with a segmentation, adds it there too, as one undo step. Returns its id.
    @discardableResult
    func createClass(name: String, color: RGBA8, code: (system: String, code: String)? = nil, segmentation id: String?,
                     overlapping: Bool = false) throws -> Int {
        if let why = readOnlyReason { throw EditingFailure(why) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw EditingFailure("Give the class a name") }
        let classID = nextFreeClassID()
        let key = Self.classKey(from: trimmed)
        var labels = try labelSetJSON()
        guard case .object(var object) = labels else { throw EditingFailure("The label set is not an object") }
        var classes = object["classes"]?.arrayValue ?? []
        if classes.contains(where: { $0["key"]?.stringValue == key }) {
            throw EditingFailure("The label set already has a class “\(key)”")
        }
        var entry: JSONObject = ["id": .int(Int64(classID)), "key": .string(key), "name": .string(trimmed), "color": .ints(color.array)]
        if let code {
            let system = code.system.trimmingCharacters(in: .whitespaces), value = code.code.trimmingCharacters(in: .whitespaces)
            if !system.isEmpty && !value.isEmpty { entry["codes"] = [["system": .string(system), "code": .string(value)]] }
        }
        classes.append(.object(entry))
        object["classes"] = .array(classes)
        object["sha256"] = nil
        labels = .object(object)
        let newLabels = labels
        guard let id, let res = segmentationResource(id) else {
            document?.apply("New Class") { $0.labelSet = .set(newLabels) }
            sync()
            annotationClassID = classID
            return classID
        }
        let model = res.model
        let c = SegmentClass(id: UInt16(classID), key: key, name: trimmed, color: color)
        let edit = try model.addClassEdit(c, layer: nil, overlapping: overlapping ? Set(model.classes.map(\.id)) : [],
                                          inAnnotation: true, annotated: false)
        model.apply(edit)
        recordVoxelEdit(edit, segmentation: id, model: model, name: "New Class") { $0.labelSet = .set(newLabels) }
        activeClasses[id] = c.id
        return classID
    }

    /// Marks a class examined (it was looked for) or not examined. Marking
    /// not examined needs the class to have no voxels: a voxel of it says it
    /// was looked for.
    func setExamined(_ classID: UInt16, _ examined: Bool, in id: String) throws {
        if let why = readOnlyReason { throw EditingFailure(why) }
        guard let res = segmentationResource(id) else { throw EditingFailure("\(id) is not loaded") }
        if !examined, voxelCounts(id)[classID, default: 0] > 0 {
            throw EditingFailure("“Mark Not Examined” needs the class to have no voxels")
        }
        let edit = try res.model.setAnnotatedEdit(classID, examined)
        guard !edit.isEmpty else { return }
        res.model.apply(edit)
        recordVoxelEdit(edit, segmentation: id, model: res.model, name: examined ? "Mark Examined" : "Mark Not Examined")
    }

    /// Locks or unlocks a class (no tool changes a locked class's voxels).
    /// A setting of the window: not an edit of the file, not undone.
    func setLocked(_ classID: UInt16, _ locked: Bool, in id: String) {
        guard let model = segmentationResource(id)?.model,
              let edit = try? model.updateClassEdit(classID, { $0.isLocked = locked }), !edit.isEmpty else { return }
        model.apply(edit)
        sync()
    }

    /// Shows or hides a class in the views (the layer's display setting).
    func setVisible(_ classID: UInt16, _ visible: Bool, in id: String) {
        if workspace.activeStack.layer(id) == nil { show(id) }
        workspace.activeStack.layer(id)?.setClass(Int(classID), visible: visible)
    }

    // MARK: Images for intensity

    /// The image whose values constrain painting, fills and thresholds: the
    /// base image of the stack, when it is loaded and shares the
    /// segmentation's frame; with the frame of it the view shows.
    func intensityImage(for stack: LayerStack, model: SegmentationModel) -> (image: ImageVolume, frame: [Int])? {
        guard let base = stack.base, let info = summary.image(base.id), info.valueType != "rgb",
              let grid = summary.grid(info.grid), Self.sameFrame(grid, model.geometry),
              let image = store.ready(.image(base.id), as: ImageResource.self)?.volume else { return nil }
        return (image, base.frameIndex(for: grid))
    }

    /// The window of the base image as a value range (the "from window"
    /// buttons of the intensity fields).
    func windowRange() -> ClosedRange<Double>? {
        guard let base = workspace.activeStack.base else { return nil }
        let lo = base.windowCenter - base.windowWidth / 2
        return lo...(lo + max(1e-6, base.windowWidth))
    }

    /// The units of the base image's values (`HU`), or "".
    var valueUnits: String {
        guard let base = workspace.activeStack.base, let info = summary.image(base.id) else { return "" }
        return WindowLevel.units(of: info) ?? ""
    }
}

/// Summary entries for objects made in the window and not saved yet, in the
/// form the engine's summary gives them.
enum ProvisionalInfo {
    static func segmentation(id: String, grid: GridGeometry, task: String, timepoints: [String],
                             model: SegmentationModel) throws -> AnnotationInfo {
        var o = common(id: id, kind: "labelmap", task: task, grid: grid, timepoints: timepoints,
                       classIDs: model.classIDs.map(Int.init), annotated: model.annotatedClassIDs.map(Int.init))
        o["voxel"] = .bool(true)
        o["geometric"] = .bool(false)
        o["layers"] = .int(Int64(model.layerCount))
        o["shape"] = .ints(grid.spatialShape)
        o["dtype"] = "uint16"
        return try JSONValue.object(o).decode(AnnotationInfo.self)
    }

    static func geometric(id: String, kind: String, task: String, grid: GridGeometry?, frameUID: String?,
                          space: String, timepoints: [String], classIDs: [Int], items: Int) throws -> AnnotationInfo {
        var o = common(id: id, kind: kind, task: task, grid: grid, timepoints: timepoints, classIDs: classIDs, annotated: classIDs)
        o["voxel"] = .bool(false)
        o["geometric"] = .bool(true)
        o["space"] = .string(space)
        o["items"] = .int(Int64(items))
        if grid == nil { o["frame_uid"] = frameUID.map(JSONValue.string) }
        return try JSONValue.object(o).decode(AnnotationInfo.self)
    }

    private static func common(id: String, kind: String, task: String, grid: GridGeometry?, timepoints: [String],
                               classIDs: [Int], annotated: [Int]) -> JSONObject {
        var o: JSONObject = [
            "id": .string(id), "kind": .string(kind), "task": .string(task), "timepoints": .strings(timepoints),
            "class_ids": .ints(classIDs), "annotated_class_ids": .ints(annotated), "fully_covered": false,
            "closure": "explicit", "ignore_id": 65535, "derived_from": [], "attributes": .object(JSONObject()),
        ]
        o["grid"] = grid.map { .string($0.id) }
        o["frame_uid"] = grid?.frameUID.map(JSONValue.string)
        return o
    }

    /// The layer plan of a segmentation held in memory.
    static func plan(id: String, grid: GridGeometry, model: SegmentationModel) throws -> LayerPlan {
        let o: JSONObject = [
            "annotation": .string(id), "kind": "labelmap", "spatial_shape": .ints(grid.spatialShape),
            "layers": .array(model.layerClassIDs.map { .ints($0.map(Int.init)) }),
            "class_ids": .ints(model.classIDs.map(Int.init)), "annotated_class_ids": .ints(model.annotatedClassIDs.map(Int.init)),
            "closure": "explicit", "ignore_id": 65535, "ignore_in_band": true, "instances": false, "overlaps": [],
        ]
        return try JSONValue.object(o).decode(LayerPlan.self)
    }
}
