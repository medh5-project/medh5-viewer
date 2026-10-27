import AppKit
import Foundation
import Observation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// Whether a tool or command can be used now, and if not, why.
enum EditAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

/// A notice or an error of the editing tools, shown in the inspector.
struct EditMessage: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var isError: Bool

    static func error(_ text: String) -> EditMessage { EditMessage(text: text, isError: true) }
    static func notice(_ text: String) -> EditMessage { EditMessage(text: text, isError: false) }
}

/// An operation computing on a segmentation in the background; the editing
/// tools wait for it.
struct RunningOperation: Identifiable {
    let id: UUID
    var name: String
    var progress: Double
    let control: OperationControl
}

/// The sheets of the editing tools.
enum EditingSheet: String, Identifiable {
    case newSegmentation, addClass
    /// A class for the label set only (the Annotations tab).
    case newLabelClass

    var id: String { rawValue }
}

/// The state of the editing tools of one document window (phase B): the
/// active segmentation and class, the active geometric annotation and its
/// selected items, the tools' options, the window's measurements, the tool
/// gestures in progress — and the undo machinery that makes every stroke or
/// operation one step of the document's undo manager.
///
/// ## Edits and undo
/// The pending edits (`MedH5Document.pendingEdits`) stay the single record
/// of what a save writes. A voxel edit is applied to the segmentation model
/// the volume store holds, then `commit` registers one undo step that
/// reverts the voxels *and* restores the pending edits (redo re-applies
/// both). Steps are targets of their own (`UndoStep`): when the edits they
/// hold exceed the undo memory of Preferences, the oldest are removed from
/// the undo manager.
///
/// Geometric annotations are edited as `AnnotationDraft`s (the editing
/// library's sets): a change stores the draft's arrays in the pending edits
/// (`document.apply`), and drawing reads them back from there, so undo is
/// the document's.
///
/// Objects made here and not saved yet (a new segmentation, a new
/// annotation, classes added to the label set) are merged into the
/// workspace's summary (`summary(merging:)`), so the sidebar, the layers and
/// the views treat them as part of the sample.
@MainActor
@Observable
final class EditingSession {
    @ObservationIgnored unowned let workspace: Workspace

    /// Incremented whenever the pending edits, a segmentation's voxels or
    /// classes, or an annotation change (undo and redo too): the inspector
    /// tabs and the views read it.
    private(set) var revision = 0

    // MARK: Segment editor

    /// The segmentation chosen in the segment editor (`nil`: the topmost
    /// visible one of the active view).
    var activeSegmentationID: String?
    /// The class painted, per segmentation.
    var activeClasses: [String: UInt16] = [:]
    var brush = BrushSettings()
    var fill = FillSettings()
    var operation = OperationSettings()
    /// An operation computing in the background.
    var running: RunningOperation?
    /// The last notice or error, shown in the segment editor.
    var message: EditMessage?
    var sheet: EditingSheet?

    // MARK: Annotations

    /// Which geometric annotation the drawing tools add to.
    var annotationTarget: AnnotationTarget = .automatic
    /// The class of new items (`nil`: the annotation's first class).
    var annotationClassID: Int?
    /// 0 draws a 2-D box on the slice; n > 0 a 3-D box n slices deep.
    var boxDepth = 0
    /// Selected items of `selectionAnnotationID`.
    var selectedItems: Set<Int> = []
    var selectionAnnotationID: String?

    /// What the clinical history attests (format 1.1 §7.3), loaded once:
    /// annotations holding it cannot be amended.
    var attestations = Attestations()

    // MARK: Measurements

    var measurements: [ViewerMeasurement] = []
    var selectedMeasurements: Set<Int> = []
    var roiShape: ROIShapeKind = .ellipse
    @ObservationIgnored var nextMeasurementNumber = 1

    // MARK: Machinery

    /// The tools' handlers (one per tool, shared by the views).
    @ObservationIgnored private(set) lazy var tools = SliceToolSet()
    @ObservationIgnored private var viewStates: [ViewportID: ToolViewState] = [:]
    @ObservationIgnored private var undoLedger: [LedgerEntry] = []
    @ObservationIgnored private var parkedLayers: [String: ParkedLayer] = [:]
    @ObservationIgnored private var lastTool: ViewerTool?
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var draftCache: [String: DraftCacheEntry] = [:]
    /// Voxels per class, per segmentation, kept in step with every edit.
    @ObservationIgnored var classCounts: [String: [UInt16: Int]] = [:]
    /// The task of the operation running, for tests and the snapshot mode.
    @ObservationIgnored var currentTask: Task<Void, Never>?
    /// Surface re-extractions waiting for the edits to settle.
    @ObservationIgnored var surfaceRefreshes: [String: DispatchWorkItem] = [:]

    init(workspace: Workspace) {
        self.workspace = workspace
        brush.radius = Preferences.defaultBrushRadius
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                // The document's undo manager works on the main thread; an
                // undo manager elsewhere is none of ours.
                guard Thread.isMainThread else { return }
                let manager = note.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self, let manager, manager === self.workspace.document?.undoManager else { return }
                    self.sync()
                }
            })
        }
        loadAttestations()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Reads what the clinical history attests (in the background).
    func loadAttestations() {
        guard workspace.summary.clinical.present else { return }
        let file = workspace.file
        Task { [weak self] in
            let records = try? await blocking { try file.clinicalRecords() }
            guard let self, let records else { return }
            self.attestations = Attestations(records)
        }
    }

    // MARK: Basics

    var document: MedH5Document? { workspace.document }
    var summary: SampleSummary { workspace.summary }
    var store: VolumeStore { workspace.store }

    /// The pending edits of the document (empty without one).
    var pendingEdits: PendingEdits { document?.pendingEdits ?? PendingEdits() }

    /// Why nothing can be edited, or `nil`.
    var readOnlyReason: String? {
        guard let reason = workspace.readOnlyReasons.first else { return nil }
        switch reason {
        case .projection(let version): return "The document is read-only: it is a projection of format \(version)"
        case .verificationFailed: return "The document is read-only: its integrity check failed"
        case .collectionMember: return "The document is read-only: it is a member of a collection"
        }
    }

    /// The per-view state of the tools (the pointer, a gesture in progress).
    func viewState(_ viewport: ViewportID) -> ToolViewState {
        if let s = viewStates[viewport] { return s }
        let s = ToolViewState()
        viewStates[viewport] = s
        return s
    }

    /// Clears every gesture in progress (the tool changed, Escape).
    func cancelGestures() {
        tools.cancelAll()
        for s in viewStates.values { s.preview = nil }
    }

    /// Shows a notice or error in the inspector (and beeps for an error).
    func report(_ message: EditMessage) {
        self.message = message
        if message.isError { NSSound.beep() }
    }

    func report(_ error: Error) {
        report(.error(Self.describe(error)))
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? EditingError { return e.description.prefix(1).uppercased() + e.description.dropFirst() + "." }
        if let e = error as? EditingFailure { return e.message }
        if let e = error as? GeometryArrayError { return e.description }
        return VolumeStore.describe(error)
    }

    // MARK: Tools

    /// Whether a tool can be used now in the active view, and if not, why.
    func availability(_ tool: ViewerTool) -> EditAvailability {
        switch tool {
        case .navigate, .windowLevel, .pan, .zoom:
            return .available
        case .ruler, .angle, .roi:
            guard workspace.activeStack.base != nil else { return .unavailable("There is no image to measure") }
            return .available
        case .brush, .eraser, .fill:
            return segmentationAvailability(needsClass: !(tool == .eraser && brush.eraserErasesAll))
        case .box, .point, .polyline, .contour:
            return annotationAvailability(tool)
        }
    }

    /// Selects a tool (when it is available).
    func select(_ tool: ViewerTool) {
        guard availability(tool).isAvailable else {
            NSSound.beep()
            return
        }
        if workspace.viewer.tool != tool { cancelGestures() }
        workspace.viewer.tool = tool
    }

    /// Routes an event of a slice view to the active tool's handler.
    /// Returns whether the tool used it (navigation then does not see it).
    func handle(_ event: ToolEvent, viewport: ViewportID, camera: SliceCamera) -> Bool {
        let tool = workspace.viewer.tool
        if tool != lastTool {
            // The tool changed (toolbar, menu, key): gestures of the old one end.
            if lastTool != nil { cancelGestures() }
            lastTool = tool
        }
        if let handler = tools.handler(for: tool) {
            if event.kind.isDown, workspace.viewer.activeViewport != viewport { workspace.viewer.activeViewport = viewport }
            let context = SliceToolContext(session: self, viewport: viewport, camera: camera)
            if handler.handle(event, in: context) { return true }
        }
        // ⌫ in a view deletes the selection (the tools had it first).
        if event.kind == .keyDown, event.modifiers.isEmpty,
           event.keyCode == ToolEvent.deleteKey || event.keyCode == ToolEvent.forwardDeleteKey {
            return deleteSelection()
        }
        return false
    }

    /// Deletes the selected measurements (the Measurements tab showing) or
    /// annotation items; returns whether there was a selection to delete.
    @discardableResult
    func deleteSelection() -> Bool {
        if workspace.showsInspector, workspace.inspectorTab == .measurements, !selectedMeasurements.isEmpty {
            deleteMeasurements(selectedMeasurements)
            return true
        }
        guard !currentSelection.isEmpty, canEditListedItems else { return false }
        do {
            try deleteSelectedItems()
        } catch {
            report(error)
        }
        return true
    }

    /// Changes the brush radius by a factor (`[` and `]`).
    func scaleBrush(by factor: Double) {
        brush.radius = BrushSettings.clamp(brush.radius * factor)
    }

    // MARK: Undo

    /// One undoable step of the editing tools: the target of its undo and
    /// redo actions, so it can be removed from the undo manager when the
    /// undo memory is exceeded.
    final class UndoStep {
        let name: String
        let bytes: Int

        init(name: String, bytes: Int) {
            self.name = name
            self.bytes = bytes
        }
    }

    private struct LedgerEntry {
        weak var step: UndoStep?
        let bytes: Int
    }

    /// A layer whose object an undo took away, kept for a redo.
    private struct ParkedLayer {
        weak var stack: LayerStack?
        let layer: DisplayLayer
    }

    /// Records a change already made to the editor's state (voxels, a
    /// model's classes, objects held by the store) together with a change of
    /// the pending edits, as one undoable step named `name`. `undo` takes
    /// the editor's state back; `redo` makes the change again. Without a
    /// document the change stays and nothing is recorded.
    func commit(_ name: String, bytes: Int = 0, edits change: (inout PendingEdits) -> Void = { _ in },
                undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        guard let document else {
            sync()
            return
        }
        let before = document.pendingEdits
        var after = before
        change(&after)
        if after != before { document.setPendingEdits(after) }
        let step = UndoStep(name: name, bytes: bytes)
        registerUndo(step, restoring: before, then: after, revert: undo, reapply: redo)
        document.undoManager?.setActionName(name)
        undoLedger.append(LedgerEntry(step: step, bytes: bytes))
        enforceUndoMemory()
        sync()
    }

    /// Registers the action undoing `step`; run, it registers its opposite
    /// (the undo manager keeps it as the redo action, and so on). The undo
    /// manager does not retain its targets: the action holds the step, so
    /// the step lives exactly as long as an action of it is registered.
    private func registerUndo(_ step: UndoStep, restoring edits: PendingEdits, then other: PendingEdits,
                              revert: @escaping @MainActor () -> Void, reapply: @escaping @MainActor () -> Void) {
        guard let undoManager = document?.undoManager else { return }
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                revert()
                self.document?.setPendingEdits(edits)
                self.registerUndo(step, restoring: other, then: edits, revert: reapply, reapply: revert)
                self.document?.undoManager?.setActionName(step.name)
                self.sync()
            }
        }
    }

    /// Bytes of edits the undo steps hold.
    var undoMemoryInUse: Int {
        undoLedger.filter { $0.step != nil }.reduce(0) { $0 + $1.bytes }
    }

    /// Drops the oldest steps while the steps hold more than the undo
    /// memory of Preferences (the newest step is always kept).
    func enforceUndoMemory(limit: Int = Preferences.undoMemoryBytes) {
        undoLedger.removeAll { $0.step == nil }
        var total = undoLedger.reduce(0) { $0 + $1.bytes }
        var dropped = 0
        while total > limit, undoLedger.count - dropped > 1 {
            if let step = undoLedger[dropped].step { document?.undoManager?.removeAllActions(withTarget: step) }
            total -= undoLedger[dropped].bytes
            dropped += 1
        }
        if dropped > 0 { undoLedger.removeFirst(dropped) }
    }

    // MARK: Keeping things in step

    /// Brings what is derived from the pending edits and the models up to
    /// date: the summary's unsaved objects, the layers of objects that went
    /// away, the selections, the views.
    func sync() {
        revision &+= 1
        workspace.refreshSummary()
        dropLayersOfVanishedObjects()
        if let id = selectionAnnotationID {
            let count = draft(id)?.itemCount ?? 0
            let valid = selectedItems.filter { $0 < count }
            if valid != selectedItems { selectedItems = valid }
        }
        workspace.noteVoxelsChanged()
    }

    /// Layers of unsaved objects an undo took away leave the views, and come
    /// back (with their settings) when a redo brings the object back.
    private func dropLayersOfVanishedObjects() {
        for stack in [workspace.primary] + (workspace.compare.map { [$0] } ?? []) {
            for layer in stack.overlays where summary.image(layer.id) == nil && summary.annotation(layer.id) == nil {
                parkedLayers[layer.id] = ParkedLayer(stack: stack, layer: layer)
                stack.remove(layer.id)
            }
        }
        for (id, parked) in parkedLayers where summary.annotation(id) != nil {
            if let stack = parked.stack, !stack.contains(id) { stack.add(parked.layer) }
            parkedLayers[id] = nil
        }
    }

    /// Shows an object in the active stack (when it is not shown yet).
    func show(_ objectID: String, in stack: LayerStack? = nil) {
        let target = stack ?? workspace.activeStack
        if let layer = target.layer(objectID) {
            layer.isVisible = true
            return
        }
        guard let layer = workspace.makeLayer(objectID) else { return }
        target.add(layer)
    }
}

/// What the events of a clinical history attest: instances (by instance id)
/// and whole annotations, each with the event that attests it. An event
/// version is immutable, and so is what it attests (1.1 §7.3): the engine
/// refuses to amend an annotation holding it (E809).
struct Attestations: Equatable {
    var instances: [UInt64: String] = [:]
    var annotations: [String: String] = [:]

    init() {}

    init(_ records: ClinicalRecords?) {
        for link in records?.links ?? [] {
            guard let event = link.assertedByEventID else { continue }
            if link.targetType == "instance", let id = UInt64(link.targetID) { instances[id] = event }
            if link.targetType == "annotation" { annotations[link.targetID] = event }
        }
    }
}

/// An error of the editing tools, with its message.
struct EditingFailure: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// The per-view state of the tools: where the pointer is (the brush
/// cursor) and the gesture in progress (rubber bands, curves being drawn).
@MainActor
@Observable
final class ToolViewState {
    var pointer: SIMD3<Double>?
    var preview: ToolPreview?
}

/// A gesture in progress, drawn by the view.
enum ToolPreview: Equatable {
    /// A box being dragged: two opposite corners on the plane.
    case box(SIMD3<Double>, SIMD3<Double>)
    /// An ROI being dragged.
    case roi(ROIShapeKind, SIMD3<Double>, SIMD3<Double>)
    /// A ruler being dragged.
    case ruler(SIMD3<Double>, SIMD3<Double>)
    /// An angle's points so far (the pointer adds the next).
    case angle([SIMD3<Double>])
    /// A polyline or contour's vertices so far.
    case path([SIMD3<Double>], closed: Bool)

    /// Whether it is a gesture of `tool`.
    func belongs(to tool: ViewerTool) -> Bool {
        switch self {
        case .box: return tool == .box
        case .roi: return tool == .roi
        case .ruler: return tool == .ruler
        case .angle: return tool == .angle
        case .path(_, let closed): return tool == (closed ? .contour : .polyline)
        }
    }
}

/// Which annotation the drawing tools add to.
enum AnnotationTarget: Hashable {
    /// The topmost annotation of the tool's kind shown in the active view
    /// (a new one when none is).
    case automatic
    /// This annotation (when it is of the tool's kind).
    case existing(String)
    /// A new annotation, created with the next item.
    case new
}

/// Brush and eraser options.
struct BrushSettings: Equatable {
    enum Policy: String, CaseIterable, Identifiable {
        case overwrite, onlyEmpty, onlyInside

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overwrite: return "Overwrite"
            case .onlyEmpty: return "Only empty"
            case .onlyInside: return "Only inside"
            }
        }
    }

    /// Radius in millimetres (world units).
    var radius = 5.0
    var isSphere = false
    var policy: Policy = .overwrite
    var insideClass: UInt16?
    /// Paint only where the base image's value is in a range.
    var usesIntensity = false
    var intensityLow = -100.0
    var intensityHigh = 300.0
    /// The eraser removes every unlocked class (else the active one).
    var eraserErasesAll = false

    static let radiusRange = 0.25...100.0

    static func clamp(_ r: Double) -> Double { min(radiusRange.upperBound, max(radiusRange.lowerBound, r)) }
}

/// Fill tool options.
struct FillSettings: Equatable {
    enum Criterion: String, CaseIterable, Identifiable {
        /// The voxels holding what the clicked one holds ("bucket").
        case sameLabels
        /// Image values within a tolerance of the clicked one (region growing).
        case tolerance
        /// Image values in a range.
        case range

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sameLabels: return "Same labels"
            case .tolerance: return "Value ± tolerance"
            case .range: return "Value in range"
            }
        }
    }

    var criterion: Criterion = .sameLabels
    var tolerance = 60.0
    var rangeLow = -100.0
    var rangeHigh = 300.0
    var is3D = false
    /// A fill reaching this many voxels stops (a leak through a gap) and
    /// paints nothing.
    var maxVoxels = 50_000_000
}

/// The shape of a region of interest.
enum ROIShapeKind: String, CaseIterable, Identifiable {
    case ellipse, rectangle

    var id: String { rawValue }
    var title: String { self == .ellipse ? "Ellipse" : "Rectangle" }
}
