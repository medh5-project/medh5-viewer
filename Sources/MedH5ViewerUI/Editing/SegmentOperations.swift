import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The operations of the segment editor, each through MedH5Editing.
enum SegmentOperationKind: String, CaseIterable, Identifiable {
    case threshold, regionGrowing, morphology, fillHoles, keepLargest, removeIslands, interpolate, logical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threshold: return "Threshold"
        case .regionGrowing: return "Region Growing"
        case .morphology: return "Morphology"
        case .fillHoles: return "Fill Holes"
        case .keepLargest: return "Keep Largest Component"
        case .removeIslands: return "Remove Islands"
        case .interpolate: return "Interpolate Between Slices"
        case .logical: return "Logical Operations"
        }
    }

    /// The Segmentation ▸ Operations item (an ellipsis when it has options).
    var menuTitle: String {
        switch self {
        case .fillHoles, .keepLargest, .interpolate: return title
        default: return title + "…"
        }
    }

    /// What it does, for the inspector.
    var help: String {
        switch self {
        case .threshold: return "Sets the class where the base image’s value is in the range."
        case .regionGrowing: return "Grows the class from the crosshair over connected voxels whose value is close to it (or in a range)."
        case .morphology: return "Dilates, erodes, opens or closes the class with a ball (or a disc on each slice) of the radius."
        case .fillHoles: return "Fills the cavities of the class (background not connected to its outside)."
        case .keepLargest: return "Keeps the largest connected component of the class and erases the others."
        case .removeIslands: return "Erases the connected components of the class smaller than the volume."
        case .interpolate: return "Fills the slices between the slices holding the class (across the active view’s plane), morphing its shape."
        case .logical: return "Combines the active class with another class."
        }
    }
}

enum MorphologyKind: String, CaseIterable, Identifiable {
    case dilate, erode, open, close

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LogicalKind: String, CaseIterable, Identifiable {
    case copy, move, subtract, intersect, swap, clear

    var id: String { rawValue }

    /// How it reads with A the active class and B the other.
    var title: String {
        switch self {
        case .copy: return "Copy A into B (B ∪= A)"
        case .move: return "Move A into B"
        case .subtract: return "A minus B (A := A \\ B)"
        case .intersect: return "A and B (A := A ∩ B)"
        case .swap: return "Swap A and B"
        case .clear: return "Clear A"
        }
    }

    var needsOther: Bool { self != .clear }
}

/// The options of the operations.
struct OperationSettings: Equatable {
    var kind: SegmentOperationKind = .threshold
    // Threshold (and region growing in a range)
    var low = 100.0
    var high = 400.0
    var thresholdOnSlice = false
    var thresholdInsideClass: UInt16?
    var thresholdClearOutside = false
    // Region growing
    var growTolerance = 60.0
    var growInRange = false
    var growIn3D = true
    // Morphology
    var morphology: MorphologyKind = .dilate
    var morphologyRadius = 2.0
    var morphologyIn2D = false
    // Fill holes
    var holesIn2D = false
    // Remove islands
    var islandMinimumVolume = 100.0
    // Logical
    var logical: LogicalKind = .copy
    var logicalOther: UInt16?
}

extension EditingSession {
    /// The world point the operations seed at: the crosshair, in the frame of
    /// the active view's stack.
    var seedPoint: SIMD3<Double> {
        if workspace.viewer.activeViewport == .compareRight, let p = workspace.compareCursor { return p }
        return workspace.viewer.cursor
    }

    /// The normal of the active slice view's plane (axial for the 3-D view).
    func activePlaneNormal() -> SIMD3<Double>? {
        let viewport = workspace.viewer.activeViewport.isSlice ? workspace.viewer.activeViewport : .slice(.axial)
        guard let reference = workspace.referenceGrid(of: workspace.stack(for: viewport)) else { return nil }
        return SliceSceneBuilder(workspace: workspace, viewport: viewport)
            .fitCamera(reference: reference, size: SIMD2(64, 64), scale: 1).normal
    }

    /// The padded axis of a grid the active view's plane runs across.
    func activeSliceAxis(in grid: GridGeometry) -> Int {
        activePlaneNormal().map { grid.nearestAxis(to: $0) } ?? 0
    }

    /// Paint options from the brush settings (the intensity constraint on the
    /// base image of `stack`).
    func paintOptions(model: SegmentationModel, stack: LayerStack) throws -> PaintOptions {
        var options = PaintOptions()
        switch brush.policy {
        case .overwrite: options.policy = .overwrite
        case .onlyEmpty: options.policy = .onlyEmpty
        case .onlyInside:
            guard let inside = brush.insideClass, model.classInfo(inside) != nil else {
                throw EditingFailure("Choose the class to paint inside")
            }
            options.policy = .onlyInside(inside)
        }
        if brush.usesIntensity {
            guard let (image, frame) = intensityImage(for: stack, model: model) else {
                throw EditingFailure("The intensity range needs the base image loaded, in the segmentation’s frame")
            }
            let lo = min(brush.intensityLow, brush.intensityHigh), hi = max(brush.intensityLow, brush.intensityHigh)
            options.intensity = IntensityConstraint(image: image, range: lo...hi, frame: frame)
        }
        return options
    }

    /// Whether an operation can run now, and if not, why.
    func operationAvailability(_ kind: SegmentOperationKind) -> EditAvailability {
        let base = segmentationAvailability(needsClass: true)
        guard base.isAvailable else { return base }
        switch kind {
        case .threshold, .regionGrowing:
            guard let id = activeSegmentation, let model = segmentationResource(id)?.model,
                  intensityImage(for: workspace.activeStack, model: model) != nil else {
                return .unavailable("Needs the base image loaded, in the segmentation’s frame")
            }
        case .logical where operation.logical.needsOther:
            guard let other = operation.logicalOther, let id = activeSegmentation,
                  segmentationResource(id)?.model.classInfo(other) != nil, other != activeClassOfActive else {
                return .unavailable("Choose class B")
            }
        default:
            break
        }
        return .available
    }

    private var activeClassOfActive: UInt16? {
        guard let id = activeSegmentation, let model = segmentationResource(id)?.model else { return nil }
        return activeClass(of: id, model: model)
    }

    /// Runs an operation on the active class of the active segmentation, in
    /// the background, as one undo step.
    @discardableResult
    func runOperation(_ kind: SegmentOperationKind? = nil) -> Task<Void, Never>? {
        let kind = kind ?? operation.kind
        if case .unavailable(let why) = operationAvailability(kind) {
            report(.error(why))
            return nil
        }
        do {
            let target = try segmentationTarget(for: workspace.viewer.activeViewport)
            let (name, compute) = try makeOperation(kind, target: target)
            return startOperation(name, target: target, compute: compute)
        } catch {
            report(error)
            return nil
        }
    }

    private func makeOperation(_ kind: SegmentOperationKind, target: SegmentationTarget) throws
        -> (String, @Sendable (SegmentationModel, OperationControl) throws -> VoxelEdit) {
        guard let cls = target.classID else { throw EditingFailure("Choose a class") }
        let model = target.model
        let stack = workspace.activeStack
        let o = operation
        let options = try paintOptions(model: model, stack: stack)
        let axis = activeSliceAxis(in: model.geometry)
        switch kind {
        case .threshold:
            guard let (image, frame) = intensityImage(for: stack, model: model) else { throw EditingFailure("No image") }
            let range = min(o.low, o.high)...max(o.low, o.high)
            let k = model.geometry.index(fromWorld: seedPoint)
            let index = max(0, min(model.shape[axis] - 1, Int((k[axis] + 0.5).rounded(.down))))
            let extent: Threshold.Extent = o.thresholdOnSlice ? .slice(GridPlane(axis: axis, index: index)) : .volume
            let inside = o.thresholdInsideClass
            let clear = o.thresholdClearOutside
            let paint = PaintOptions(policy: options.policy)
            return ("Threshold", { m, c in
                try Threshold.edit(m, classID: cls, image: image, range: range, frame: frame, extent: extent,
                                   insideClass: inside, clearOutside: clear, options: paint, control: c)
            })
        case .regionGrowing:
            guard let (image, _) = intensityImage(for: stack, model: model) else { throw EditingFailure("No image") }
            guard let seed = model.geometry.voxel(containingWorld: seedPoint) else {
                throw EditingFailure("The crosshair is outside the segmentation’s grid")
            }
            let criterion: FloodFill.Criterion = o.growInRange
                ? .intensityRange(image, range: min(o.low, o.high)...max(o.low, o.high))
                : .intensityTolerance(image, tolerance: o.growTolerance)
            let extent: FloodFill.Extent = o.growIn3D ? .volume : .slice(axis: axis)
            let limit = fill.maxVoxels
            let paint = PaintOptions(policy: options.policy)
            return ("Region Growing", { m, c in
                try Self.fillEdit(m, cls: cls, seed: seed, criterion: criterion, extent: extent, limit: limit, options: paint, control: c)
            })
        case .morphology:
            let radius = o.morphologyRadius
            let sliceAxis: Int? = o.morphologyIn2D ? axis : nil
            let which = o.morphology
            return (which.title, { m, c in
                switch which {
                case .dilate: return try LabelMorphology.dilate(m, classID: cls, radius: radius, sliceAxis: sliceAxis, options: options, control: c)
                case .erode: return try LabelMorphology.erode(m, classID: cls, radius: radius, sliceAxis: sliceAxis, control: c)
                case .open: return try LabelMorphology.open(m, classID: cls, radius: radius, sliceAxis: sliceAxis, control: c)
                case .close: return try LabelMorphology.close(m, classID: cls, radius: radius, sliceAxis: sliceAxis, options: options, control: c)
                }
            })
        case .fillHoles:
            let scope: LabelMorphology.HoleScope = o.holesIn2D ? .slices(axis: axis) : .volume
            return ("Fill Holes", { m, c in
                try LabelMorphology.fillHoles(m, classID: cls, scope: scope, options: options, control: c)
            })
        case .keepLargest:
            return ("Keep Largest Component", { m, c in
                try LabelMorphology.keepLargestComponent(m, classID: cls, control: c)
            })
        case .removeIslands:
            let volume = o.islandMinimumVolume
            return ("Remove Islands", { m, c in
                try LabelMorphology.removeSmallComponents(m, classID: cls, minimumVolume: volume, control: c)
            })
        case .interpolate:
            return ("Interpolate Between Slices", { m, c in
                try SliceInterpolation.interpolate(m, classID: cls, axis: axis, options: options, control: c)
            })
        case .logical:
            let which = o.logical
            let other = o.logicalOther ?? 0
            return (which == .clear ? "Clear Class" : "Logical Operation", { m, c in
                switch which {
                case .copy: return try LabelOperations.copy(m, from: cls, to: other, options: options, control: c)
                case .move: return try LabelOperations.move(m, from: cls, to: other, options: options, control: c)
                case .subtract: return try LabelOperations.subtract(m, cls, minus: other, control: c)
                case .intersect: return try LabelOperations.intersect(m, cls, with: other, control: c)
                case .swap: return try LabelOperations.swap(m, cls, other, options: options, control: c)
                case .clear: return try LabelOperations.clear(m, cls, control: c)
                }
            })
        }
    }

    /// A fill's edit; refused when the fill reached its voxel limit (a leak
    /// through a gap, most often).
    nonisolated static func fillEdit(_ m: SegmentationModel, cls: UInt16, operation: VoxelOperation? = nil, seed: SIMD3<Int>,
                                     criterion: FloodFill.Criterion, extent: FloodFill.Extent, limit: Int,
                                     options: PaintOptions, control: OperationControl) throws -> VoxelEdit {
        let (edit, fill) = try FloodFill.edit(m, operation: operation ?? .paint(cls), seed: seed, criterion: criterion,
                                              extent: extent, connectivity: .face, maxVoxels: limit, paintTruncated: false,
                                              options: options, control: control)
        if fill.reachedLimit {
            throw EditingFailure("The fill reached \(limit) voxels and stopped — it probably leaks through a gap. Nothing was painted.")
        }
        return edit
    }

    // MARK: Fill tool

    /// The Fill tool's click: a 2-D or 3-D flood fill or region growing from
    /// the clicked voxel, painting the active class.
    @discardableResult
    func fill(at world: SIMD3<Double>, viewport: ViewportID, planeNormal: SIMD3<Double>) -> Task<Void, Never>? {
        do {
            let target = try segmentationTarget(for: viewport)
            guard let cls = target.classID else { throw EditingFailure("Choose a class") }
            let model = target.model
            guard let seed = model.geometry.voxel(containingWorld: world) else {
                throw EditingFailure("The click is outside the segmentation’s grid")
            }
            let stack = workspace.stack(for: viewport)
            var options = try paintOptions(model: model, stack: stack)
            let criterion: FloodFill.Criterion
            switch fill.criterion {
            case .sameLabels:
                criterion = .sameLabels(.layerOfClass(cls))
            case .tolerance, .range:
                guard let (image, _) = intensityImage(for: stack, model: model) else {
                    throw EditingFailure("Region growing needs the base image loaded, in the segmentation’s frame")
                }
                criterion = fill.criterion == .tolerance
                    ? .intensityTolerance(image, tolerance: fill.tolerance)
                    : .intensityRange(image, range: min(fill.rangeLow, fill.rangeHigh)...max(fill.rangeLow, fill.rangeHigh))
                options.intensity = nil
            }
            let extent: FloodFill.Extent = fill.is3D ? .volume
                : .slice(axis: FloodFill.sliceAxis(forPlaneNormal: planeNormal, in: model.geometry))
            let limit = fill.maxVoxels
            let paint = options
            return startOperation("Fill", target: target) { m, c in
                try Self.fillEdit(m, cls: cls, seed: seed, criterion: criterion, extent: extent, limit: limit, options: paint, control: c)
            }
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Running

    /// Computes an edit in the background (the tools wait), then applies it
    /// as one undo step — unless the segmentation changed meanwhile.
    @discardableResult
    func startOperation(_ name: String, target: SegmentationTarget,
                        compute: @escaping @Sendable (SegmentationModel, OperationControl) throws -> VoxelEdit) -> Task<Void, Never>? {
        guard running == nil else {
            report(.error("\(running?.name ?? "An operation") is running"))
            return nil
        }
        let runID = UUID()
        let control = OperationControl(progress: { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.running?.id == runID else { return }
                self.running?.progress = fraction
            }
        })
        running = RunningOperation(id: runID, name: name, progress: 0, control: control)
        message = nil
        let model = target.model
        let id = target.id
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<VoxelEdit, Error> in
                Result { try compute(model, control) }
            }.value
            guard let self else { return }
            self.running = nil
            switch result {
            case .success(let edit):
                guard !edit.isEmpty else {
                    self.report(.notice("\(name) changed nothing."))
                    return
                }
                guard model.canApply(edit), self.segmentationResource(id)?.model === model else {
                    self.report(.error("The segmentation changed while \(name) ran; nothing was applied."))
                    return
                }
                model.apply(edit)
                self.recordVoxelEdit(edit, segmentation: id, model: model, name: name)
                self.report(.notice("\(name): \(Format.integer(edit.voxelCount)) voxel\(edit.voxelCount == 1 ? "" : "s") changed."))
            case .failure(let error):
                if let e = error as? EditingError, e == .cancelled {
                    self.report(.notice("\(name) was cancelled."))
                } else {
                    self.report(error)
                }
            }
        }
        currentTask = task
        return task
    }

    /// Cancels the operation running.
    func cancelOperation() {
        running?.control.cancel()
    }
}
