import AppKit
import Foundation
import Observation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The integrity check run when a document opens (spec §13).
enum VerificationState: Equatable {
    case notStarted
    case running
    case passed
    case failed(String)
    case error(String)
}

/// Raw HDF5 attributes of an object, loaded for the Info panel.
enum AttributeState {
    case loading
    case loaded(JSONObject)
    case failed(String)
}

/// An error or notice shown as an alert.
struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// How the two sides of Compare are linked.
enum CompareLink {
    /// Resolving the transform.
    case pending
    /// Through the transform the engine resolves between the two frames.
    case registered(summary: String)
    /// No transform: linked by voxel index, labelled "not registered".
    case notRegistered
}

/// Everything one document window shows: the open sample, its summary, the
/// sidebar outline and selection, the viewer and its layer stacks, the
/// volume store. One per window; the document owns it.
///
/// State flows one way: the sidebar, inspector, toolbar and menus change
/// the workspace; the viewport controllers observe it (Observation) and
/// rebuild their render scenes; the workspace keeps the store loading what
/// the stacks need.
@MainActor
@Observable
final class Workspace {
    @ObservationIgnored weak var document: MedH5Document?
    private(set) var file: SampleFile
    private(set) var summary: SampleSummary
    var displayName: String
    private(set) var readOnlyReasons: [ReadOnlyReason] = []
    private(set) var verification: VerificationState = .notStarted
    /// A save is writing (the window shows progress).
    var isSaving = false
    /// Incremented when voxels change in memory (an edit applied to a
    /// segmentation model): the viewports depend on it and redraw, uploading
    /// the edit's dirty boxes.
    private(set) var editRevision = 0

    let store: VolumeStore
    let viewer: ViewerModel
    /// The stack of the main views (and the left side of Compare).
    let primary: LayerStack
    /// The stack of the compared timepoint (right side of Compare).
    private(set) var compare: LayerStack?

    private(set) var sections: [SidebarSection]
    var expanded: Set<String>
    /// The selected sidebar node id.
    var selection: String?
    var inspectorTab: InspectorTab = .layers
    var showsInspector = true
    var showsSidebar = true
    var alert: AppAlert?
    private(set) var attributes: [String: AttributeState] = [:]

    /// The live viewport controllers (made by the viewer's views).
    @ObservationIgnored let viewports = ViewportRegistry()
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private(set) var isShutDown = false
    @ObservationIgnored private var verifyTask: Task<Void, Never>?

    init(file: SampleFile, displayName: String, readOnly: [ReadOnlyReason] = [],
         context: RenderContext? = RenderContext.shared) {
        self.file = file
        self.summary = file.summary
        self.displayName = displayName
        self.store = VolumeStore(file: file, context: context)
        self.viewer = ViewerModel()
        self.primary = LayerStack(id: "primary")
        let sections = SidebarBuilder.sections(for: file.summary)
        self.sections = sections
        self.expanded = SidebarBuilder.initiallyExpanded(sections)
        var reasons = readOnly
        if file.summary.support == .projection {
            reasons.append(.projection(version: file.summary.formatVersion))
        }
        self.readOnlyReasons = reasons
        primary.replaceAll(defaultLayers(timepoint: nil))
        if let grid = referenceGrid(of: primary) {
            viewer.cursor = snapToVoxel(grid.worldCenter, grid: grid)
            if grid.is2D { showPlanarDefaults() }
        }
        updateVolumeDefaults()
        if viewer.layout == .compare { ensureCompareStack() }
    }

    /// Starts loading what the views need, and keeps doing so as they
    /// change. Call once the window is up.
    func start(verify: Bool = true) {
        if !tracking {
            tracking = true
            trackResources()
        }
        if verify { startVerification() }
    }

    /// Cancels every load (the window closes).
    func shutDown() {
        isShutDown = true
        verifyTask?.cancel()
        store.cancelAll()
        viewports.removeAll()
    }

    var isReadOnly: Bool { !readOnlyReasons.isEmpty }

    // MARK: Stacks

    /// The stack of the active viewport.
    var activeStack: LayerStack {
        if viewer.activeViewport == .compareRight, let compare { return compare }
        return primary
    }

    func stack(for viewport: ViewportID) -> LayerStack {
        if viewport == .compareRight, let compare { return compare }
        return primary
    }

    /// The stacks the current layout shows.
    var stacksInUse: [LayerStack] {
        if viewer.layout == .compare, let compare { return [primary, compare] }
        return [primary]
    }

    /// The reference grid of a stack: its base image's grid.
    func referenceGrid(of stack: LayerStack) -> GridGeometry? {
        guard let base = stack.base, let image = summary.image(base.id) else { return nil }
        return summary.grid(image.grid)
    }

    /// The timepoint a stack shows (its base image's).
    func timepoint(of stack: LayerStack) -> String? {
        guard let base = stack.base else { return nil }
        return summary.image(base.id)?.timepoint ?? referenceGrid(of: stack)?.timepoint
    }

    /// The default layers for a timepoint (the first when `nil`): its CT (or
    /// first) image as the base, and the first segmentation on its grid.
    func defaultLayers(timepoint: String?, preferModality: String? = nil) -> [DisplayLayer] {
        let tps = summary.timepoints.sorted { $0.index < $1.index }.map(\.id)
        let tp = timepoint ?? tps.first
        let candidates = summary.images.filter { tp == nil || ($0.timepoint ?? summary.grid($0.grid)?.timepoint) == tp }
        let pick = candidates.first { $0.modality == preferModality }
            ?? candidates.first { $0.modality.uppercased() == "CT" }
            ?? candidates.first ?? summary.images.first
        guard let image = pick, let base = makeLayer(image.id) else { return [] }
        var layers = [base]
        let voxelKinds: Set<String> = ["labelmap", "layers", "bitmask"]
        if let seg = summary.annotations.first(where: { $0.grid == image.grid && voxelKinds.contains($0.kind) }),
           let layer = makeLayer(seg.id) {
            layers.append(layer)
        }
        return layers
    }

    /// A layer for an image or annotation, with its default display.
    func makeLayer(_ objectID: String) -> DisplayLayer? {
        if let image = summary.image(objectID) {
            let layer = DisplayLayer(id: image.id, kind: .image, detail: image.modality)
            layer.interpolation = Preferences.interpolation
            var presets = image.windowPresets
            if image.modality.uppercased() == "CT" { presets += WindowPreset.ct }
            if image.valueType == "rgb" {
                layer.apply(WindowPreset(name: "RGB", center: 127.5, width: 255))
            } else if let first = presets.first {
                layer.apply(first)
            } else {
                layer.needsAutoWindow = true
            }
            return layer
        }
        guard let a = summary.annotation(objectID) else { return nil }
        let kind: LayerKind
        switch a.kind {
        case "labelmap", "layers", "bitmask": kind = .segmentation
        case "instances": kind = .instances
        case "probmap": kind = .probability
        case "mask": kind = .mask
        case "classification": kind = .classification
        default: kind = .geometric(a.kind)
        }
        let layer = DisplayLayer(id: a.id, kind: kind, detail: a.kind)
        switch kind {
        case .segmentation, .instances: layer.opacity = 0.4
        case .mask: layer.opacity = 0.25
        case .probability:
            layer.opacity = 0.55
            layer.probabilityThreshold = a.threshold ?? 0.5
        default: layer.opacity = 1
        }
        return layer
    }

    /// Makes an image the base of the active stack (double-click in the
    /// sidebar). Overlays stay; those in another frame are placed through
    /// the transform the engine resolves, or flagged as not drawn.
    func showAsBase(_ imageID: String, in stack: LayerStack? = nil) {
        guard let layer = makeLayer(imageID) else { return }
        let target = stack ?? activeStack
        let oldGrid = referenceGrid(of: target)
        target.setBase(layer)
        target.selectedLayerID = layer.id
        if target === primary { updateVolumeDefaults() }
        if target === primary, let grid = referenceGrid(of: target), grid.id != oldGrid?.id {
            if grid.is2D { showPlanarDefaults() }
            if let old = oldGrid, old.sharesFrame(with: grid) {
                viewer.cursor = snapToVoxel(viewer.cursor, grid: grid)
            } else {
                viewer.cursor = snapToVoxel(grid.worldCenter, grid: grid)
            }
            viewer.resetFraming()
        }
    }

    /// A 2-D image has one plane: a single view along its own axes.
    func showPlanarDefaults() {
        viewer.layout = .single
        viewer.singlePlane = .axial
        viewer.orientation = .aligned
        viewer.normalizeActiveViewport()
    }

    /// The 3-D transfer function suited to the base image: a CT preset in
    /// HU for a CT, the generic one (scaled to the image's values) otherwise.
    func updateVolumeDefaults() {
        let isCT = primary.base.flatMap { summary.image($0.id) }.map { $0.modality.uppercased() == "CT" } ?? false
        let ctPresets: Set<TransferFunctionPreset> = [.ctBone, .ctSoftTissue, .ctLung, .ctAngiography, .ctSkin]
        if isCT && !ctPresets.contains(viewer.volume.preset) { viewer.volume.preset = .ctBone }
        if !isCT && ctPresets.contains(viewer.volume.preset) { viewer.volume.preset = .mrDefault }
    }

    /// Whether an object is in a stack (and visible).
    func isShown(_ objectID: String, in stack: LayerStack? = nil) -> Bool {
        guard let l = (stack ?? activeStack).layer(objectID) else { return false }
        return l.isVisible
    }

    /// The eye button: adds an object as an overlay, or removes it.
    func toggleOverlay(_ objectID: String, in stack: LayerStack? = nil) {
        let target = stack ?? activeStack
        if let layer = target.layer(objectID) {
            if layer === target.base { layer.isVisible.toggle() } else { target.remove(objectID) }
            return
        }
        guard let layer = makeLayer(objectID) else { return }
        if target.base == nil, layer.kind == .image {
            target.setBase(layer)
        } else {
            if layer.kind == .image {
                // A fusion: a colour ramp over the base's grey.
                layer.colormap = .hotIron
                layer.opacity = 0.5
            }
            target.add(layer)
        }
        target.selectedLayerID = layer.id
    }

    /// Shows every annotation of the base image's timepoint (and the
    /// annotations spanning timepoints) as overlays; used by `--overlays all`.
    func showAllAnnotations(in stack: LayerStack? = nil) {
        let target = stack ?? primary
        guard let tp = timepoint(of: target) else { return }
        for a in summary.annotations where a.timepoints.contains(tp) && !target.contains(a.id) {
            if let layer = makeLayer(a.id) { target.add(layer) }
        }
    }

    // MARK: Timepoints and layout

    var timepointIDs: [String] { summary.timepoints.sorted { $0.index < $1.index }.map(\.id) }

    func timepointTitle(_ id: String) -> String {
        guard let tp = summary.timepoint(id) else { return id }
        var t = tp.label?.capitalizedFirst ?? tp.id
        if let d = tp.daysFromBaseline, d != 0 { t += " (day \(Format.number(d, digits: 1)))" }
        return t
    }

    /// Shows another timepoint in the primary stack: its matching image as
    /// the base and its first segmentation.
    func showTimepoint(_ id: String) {
        guard id != timepoint(of: primary) else { return }
        let modality = primary.base.flatMap { summary.image($0.id)?.modality }
        let layers = defaultLayers(timepoint: id, preferModality: modality)
        guard !layers.isEmpty else { return }
        let oldGrid = referenceGrid(of: primary)
        let mapper = oldGrid.flatMap { old in
            layers.first.flatMap { summary.image($0.id) }.flatMap { summary.grid($0.grid) }.map { (old, $0) }
        }
        primary.replaceAll(layers)
        if let (old, new) = mapper {
            viewer.cursor = mapCursor(viewer.cursor, from: old, to: new)
        }
        viewer.views = [:]
        if viewer.layout == .compare { rebuildCompareStack() }
    }

    func stepTimepoint(_ delta: Int) {
        let ids = timepointIDs
        guard let current = timepoint(of: primary), let i = ids.firstIndex(of: current) else { return }
        let j = i + delta
        guard ids.indices.contains(j) else { return }
        showTimepoint(ids[j])
    }

    func setLayout(_ layout: ViewerLayout) {
        if layout == .compare { ensureCompareStack() }
        // Keep the view that was active (as the old layout showed it) when
        // the new layout shows it too.
        viewer.normalizeActiveViewport()
        viewer.layout = layout
        viewer.normalizeActiveViewport()
    }

    /// The timepoint Compare shows beside the primary one: the next visit,
    /// or the previous one for the last.
    var compareTimepoint: String? {
        let ids = timepointIDs
        guard ids.count > 1 else { return nil }
        guard let current = timepoint(of: primary), let i = ids.firstIndex(of: current) else { return ids.dropFirst().first }
        return i + 1 < ids.count ? ids[i + 1] : ids[i - 1]
    }

    func ensureCompareStack() {
        if compare == nil { rebuildCompareStack() }
    }

    func rebuildCompareStack() {
        let stack = compare ?? LayerStack(id: "compare")
        let modality = primary.base.flatMap { summary.image($0.id)?.modality }
        if let tp = compareTimepoint {
            stack.replaceAll(defaultLayers(timepoint: tp, preferModality: modality))
        } else {
            stack.replaceAll(primary.layers.compactMap { makeLayer($0.id) })
        }
        compare = stack
    }

    /// Sets the compared timepoint.
    func setCompareTimepoint(_ id: String) {
        let stack = compare ?? LayerStack(id: "compare")
        let modality = primary.base.flatMap { summary.image($0.id)?.modality }
        stack.replaceAll(defaultLayers(timepoint: id, preferModality: modality))
        compare = stack
    }

    // MARK: Cursor

    /// The nearest voxel centre of `grid` (inside it), so slices sample
    /// voxel centres rather than blending two.
    func snapToVoxel(_ p: SIMD3<Double>, grid: GridGeometry) -> SIMD3<Double> {
        var k = grid.index(fromWorld: p)
        guard k.x.isFinite && k.y.isFinite && k.z.isFinite else { return p }
        let n = grid.paddedShape
        for a in 0..<3 { k[a] = min(Double(n[a] - 1), max(0, k[a].rounded())) }
        return grid.world(fromIndex: k)
    }

    /// Moves the crosshair to a world point of a viewport's frame.
    func setCursor(_ world: SIMD3<Double>, from viewport: ViewportID) {
        if viewport == .compareRight, let compare, let ref = referenceGrid(of: compare) {
            let p = snapToVoxel(world, grid: ref)
            if let back = compareMapping()?.inverse(p) { viewer.cursor = back }
        } else if let ref = referenceGrid(of: primary) {
            viewer.cursor = snapToVoxel(world, grid: ref)
        } else {
            viewer.cursor = world
        }
    }

    /// Maps a point between two reference grids: through their transform
    /// when one is loaded, else by voxel index.
    func mapCursor(_ p: SIMD3<Double>, from a: GridGeometry, to b: GridGeometry) -> SIMD3<Double> {
        if a.id == b.id || a.sharesFrame(with: b) { return snapToVoxel(p, grid: b) }
        let key = PlacementKey(from: a.id, to: b.id, fieldGrid: a.id)
        if let m = store.ready(.placement(key), as: PlacementResource.self)?.transform?.matrix {
            return snapToVoxel(m.transformPoint(p), grid: b)
        }
        return snapToVoxel(b.world(fromIndex: a.index(fromWorld: p)), grid: b)
    }

    /// The link between the two sides of Compare: forward maps the primary
    /// cursor into the compared frame, inverse maps back.
    struct CompareMapping {
        var forward: (SIMD3<Double>) -> SIMD3<Double>
        var inverse: (SIMD3<Double>) -> SIMD3<Double>
        var link: CompareLink
    }

    func compareMapping() -> CompareMapping? {
        guard let compare, let a = referenceGrid(of: primary), let b = referenceGrid(of: compare) else { return nil }
        if a.id == b.id || a.sharesFrame(with: b) {
            return CompareMapping(forward: { $0 }, inverse: { $0 }, link: .registered(summary: "same frame"))
        }
        let key = PlacementKey(from: a.id, to: b.id, fieldGrid: a.id)
        let byIndex = CompareMapping(
            forward: { b.world(fromIndex: a.index(fromWorld: $0)) },
            inverse: { a.world(fromIndex: b.index(fromWorld: $0)) },
            link: .notRegistered)
        if store.failure(.placement(key)) != nil { return byIndex }
        guard let r = store.ready(.placement(key), as: PlacementResource.self) else {
            var pending = byIndex
            pending.link = .pending
            return pending
        }
        guard let t = r.transform else { return byIndex }
        switch t.mapping {
        case .matrix(let m):
            let inv = m.inverse
            return CompareMapping(forward: { m.transformPoint($0) }, inverse: { inv.transformPoint($0) },
                                  link: .registered(summary: r.summary))
        case .field(let d, let g):
            let forward: (SIMD3<Double>) -> SIMD3<Double> = { $0 + PlacementResolver.displacement(d, grid: g, at: $0) }
            return CompareMapping(
                forward: forward,
                inverse: { y in
                    var x = y
                    for _ in 0..<12 { x = y - PlacementResolver.displacement(d, grid: g, at: x) }
                    return x
                },
                link: .registered(summary: r.summary))
        case .unsampled:
            return byIndex
        }
    }

    /// The crosshair in the compared timepoint's frame.
    var compareCursor: SIMD3<Double>? {
        guard let mapping = compareMapping() else { return nil }
        return mapping.forward(viewer.cursor)
    }

    // MARK: Resources

    /// The resources a layer needs in a stack with reference grid `reference`.
    func resourceKeys(for layer: DisplayLayer, reference: GridGeometry) -> [ResourceKey] {
        var keys: [ResourceKey] = []
        switch layer.kind {
        case .image:
            guard let info = summary.image(layer.id), let grid = summary.grid(info.grid) else { return [] }
            let frame = layer.frameIndex(for: grid)
            keys += [.image(layer.id), .imageFrame(layer.id, frame: frame)]
            if info.valueType != "rgb" { keys.append(.histogram(layer.id, frame: frame)) }
            if let k = PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: grid.frameUID) {
                keys.append(.placement(k))
            }
        case .segmentation, .instances, .probability, .mask:
            guard let a = summary.annotation(layer.id) else { return [] }
            let grid = a.grid.flatMap { summary.grid($0) }
            switch layer.kind {
            case .instances where layer.colorByInstance: keys.append(.instanceMap(layer.id))
            case .probability:
                for c in a.classIDs where layer.isClassVisible(c) { keys.append(.probability(layer.id, classID: c)) }
            case .mask: keys.append(.mask(layer.id))
            default: keys.append(.segmentation(layer.id))
            }
            if let k = PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: a.frameUID) {
                keys.append(.placement(k))
            }
        case .geometric:
            guard let a = summary.annotation(layer.id) else { return [] }
            keys.append(.geometry(layer.id))
            let grid = a.grid.flatMap { summary.grid($0) }
            if let k = PlacementResolver.pointKey(reference: reference, annotationGrid: grid, annotationFrame: a.frameUID) {
                keys.append(.placement(k))
            }
        case .classification:
            keys.append(.geometry(layer.id))
        }
        return keys
    }

    /// Everything the visible views need now.
    func neededResources() -> Set<ResourceKey> {
        var keys = Set<ResourceKey>()
        let shows3D = viewer.visibleViewports.contains(.volume)
        for stack in stacksInUse {
            guard let ref = referenceGrid(of: stack) else { continue }
            for layer in stack.layers where layer.isVisible || layer === stack.base {
                keys.formUnion(resourceKeys(for: layer, reference: ref))
                if shows3D, stack === primary, viewer.volume.surfaceStyle == .meshes, viewer.volume.showsLabels,
                   layer.isVisible, layer.kind == .segmentation {
                    keys.insert(.surfaces(layer.id))
                }
            }
        }
        if viewer.layout == .compare, let compare, let a = referenceGrid(of: primary), let b = referenceGrid(of: compare),
           a.id != b.id, !a.sharesFrame(with: b) {
            keys.insert(.placement(PlacementKey(from: a.id, to: b.id, fieldGrid: a.id)))
        }
        return keys
    }

    /// Keeps the store loading what the views need (re-run whenever the
    /// stacks, layout or frames change), and fills in automatic windows.
    private func trackResources() {
        guard !isShutDown else { return }
        let needed = withObservationTracking {
            neededResources()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackResources() }
        }
        store.inUse = needed
        store.request(needed)
        store.enforceBudget()
        applyAutomaticWindows()
    }

    /// Images without stored presets take a window from their percentiles
    /// once the store has them.
    private func applyAutomaticWindows() {
        guard !isShutDown else { return }
        let pending = stacksInUse.flatMap(\.layers).filter { $0.isImage && $0.needsAutoWindow }
        guard !pending.isEmpty else { return }
        for layer in pending {
            guard let info = summary.image(layer.id), let grid = summary.grid(info.grid) else { continue }
            let key = ResourceKey.histogram(layer.id, frame: layer.frameIndex(for: grid))
            if let h = store.ready(key, as: HistogramResource.self) {
                layer.apply(WindowLevel.automatic(h))
            } else if store.failure(key) != nil {
                layer.needsAutoWindow = false
            } else {
                Task { @MainActor [weak self] in
                    _ = try? await self?.store.resource(key)
                    self?.applyAutomaticWindows()
                }
            }
        }
    }

    // MARK: Verification

    func startVerification() {
        guard verification == .notStarted else { return }
        verification = .running
        let file = self.file
        verifyTask = Task { [weak self] in
            do {
                let report = try await blocking { try file.verify() }
                guard let self, !Task.isCancelled else { return }
                if report.ok {
                    self.verification = .passed
                } else {
                    var problems: [String] = []
                    if !report.mismatched.isEmpty { problems.append("\(report.mismatched.count) object(s) do not match their digest") }
                    if !report.malformed.isEmpty { problems.append("\(report.malformed.count) malformed digest(s)") }
                    if report.contentID.ok == false { problems.append("the content_id does not match") }
                    if !report.unverifiable.isEmpty { problems.append("\(report.unverifiable.count) unverifiable object(s)") }
                    let summary = problems.isEmpty ? "digests do not verify" : problems.joined(separator: "; ")
                    self.verification = .failed(summary)
                    self.readOnlyReasons.append(.verificationFailed(summary: summary))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.verification = .error(VolumeStore.describe(error))
            }
        }
    }

    // MARK: Info

    /// The HDF5 path of a sidebar node's object, for its raw attributes.
    func objectPath(forNode id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return id == "sample" ? "/" : nil }
        switch parts[0] {
        case "image": return "images/\(parts[1])"
        case "ann": return "annotations/\(parts[1])"
        case "grid": return "grids/\(parts[1])"
        case "tf": return "transforms/\(parts[1])"
        default: return nil
        }
    }

    func attributeState(_ path: String) -> AttributeState? { attributes[path] }

    func requestAttributes(_ path: String) {
        guard attributes[path] == nil else { return }
        attributes[path] = .loading
        let file = self.file
        Task { [weak self] in
            do {
                let attrs = try await blocking { try file.attributes(of: path) }
                self?.attributes[path] = .loaded(attrs)
            } catch {
                self?.attributes[path] = .failed(VolumeStore.describe(error))
            }
        }
    }

    /// Selects a sidebar node, expanding its ancestors.
    func select(_ nodeID: String?) {
        selection = nodeID
        guard let nodeID else { return }
        func path(to id: String, in nodes: [SidebarNode], trail: [String]) -> [String]? {
            for n in nodes {
                if n.id == id { return trail }
                if let c = n.children, let p = path(to: id, in: c, trail: trail + [n.id]) { return p }
            }
            return nil
        }
        for s in sections {
            if let p = path(to: nodeID, in: s.nodes, trail: []) { expanded.formUnion(p) }
        }
    }

    /// Finds a sidebar node by id, object id or title (the snapshot's
    /// `--select`).
    func findNode(_ query: String) -> SidebarNode? {
        let nodes = SidebarBuilder.flatten(sections)
        return nodes.first { $0.id == query } ?? nodes.first { $0.objectID == query }
            ?? nodes.first { $0.title.caseInsensitiveCompare(query) == .orderedSame }
            ?? nodes.first { $0.id.hasSuffix(":" + query) }
    }

    /// Selects an object and shows its attributes (context menu "Reveal
    /// Attributes").
    func revealAttributes(_ nodeID: String) {
        select(nodeID)
        inspectorTab = .info
        showsInspector = true
    }

    // MARK: Editing

    /// Call after applying a `VoxelEdit` to a segmentation model the store
    /// holds: every view redraws, uploading only the edit's dirty boxes
    /// (`SegmentationResource.syncTextures`).
    func noteVoxelsChanged() {
        editRevision &+= 1
    }

    // MARK: Saving

    /// After a save: the file was replaced; read from the new one.
    func didSave(newFile: SampleFile, displayName: String, replacedObjects: Set<String>) {
        let old = file
        file = newFile
        summary = newFile.summary
        self.displayName = displayName
        sections = SidebarBuilder.sections(for: newFile.summary)
        attributes = [:]
        store.replaceFile(newFile)
        for id in replacedObjects { store.invalidate(objectID: id) }
        // Layers of objects the save removed leave the views.
        for stack in [primary] + (compare.map { [$0] } ?? []) {
            for layer in stack.overlays where newFile.summary.image(layer.id) == nil && newFile.summary.annotation(layer.id) == nil {
                stack.remove(layer.id)
            }
        }
        Task.detached { old.close() }
    }
}

/// The viewport controllers of a window, by viewport (the snapshot runner
/// and the menus reach the views through it).
@MainActor
final class ViewportRegistry {
    private(set) var slices: [ViewportID: SliceViewportController] = [:]
    private(set) var volume: VolumeViewportController?

    func slice(_ id: ViewportID, make: () -> SliceViewportController) -> SliceViewportController {
        if let c = slices[id] { return c }
        let c = make()
        slices[id] = c
        return c
    }

    func volume(make: () -> VolumeViewportController) -> VolumeViewportController {
        if let v = volume { return v }
        let v = make()
        volume = v
        return v
    }

    func removeAll() {
        slices.values.forEach { $0.tearDown() }
        volume?.tearDown()
        slices.removeAll()
        volume = nil
    }
}
