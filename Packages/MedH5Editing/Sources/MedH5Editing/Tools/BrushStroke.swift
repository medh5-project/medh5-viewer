import Foundation
import simd
import MedH5Core

/// One brush stroke, from mouse-down to mouse-up, as one undoable edit.
///
/// Each `add(_:)` paints the dabs between the previous position and the new
/// one (spaced at most `radius / 2`, so fast strokes leave no gaps) straight
/// into the model, for immediate display: the model's revision increases and
/// its dirty regions grow as the stroke goes. The stroke keeps the original
/// values of the chunks it touches, and `finish()` returns the whole stroke
/// as a single `VoxelEdit` (to record in an `EditHistory`); `cancel()` puts
/// the model back as it was.
///
/// Use from the model's serial context (the main thread), and make no other
/// edit to the model while a stroke is in progress.
///
/// ```swift
/// let stroke = try BrushStroke(model: model, operation: .paint(liver),
///                              brush: .disc(radius: 3, plane: view.axes))
/// stroke.add(mouseDownWorld)        // on mouseDragged: stroke.add(p)
/// let edit = stroke.finish()        // on mouseUp
/// history.record(edit, name: "Paint")
/// ```
public final class BrushStroke {
    public let model: SegmentationModel
    public let operation: VoxelOperation
    public let brush: Brush
    public let options: PaintOptions
    /// The last position painted.
    public private(set) var lastPoint: SIMD3<Double>?
    /// The box changed so far, all layers together.
    public private(set) var changedBounds: VoxelBox = .empty
    public private(set) var isFinished = false

    private let metadataBefore: SegmentationMetadata
    private let revisionBefore: UInt64
    /// Per layer: chunk index → the chunk's values before the stroke.
    private var originals: [Int: [Int: [UInt16]]] = [:]

    /// - Throws: `unknownClass` or `classLocked` for the class painted or erased.
    public init(model: SegmentationModel, operation: VoxelOperation, brush: Brush,
                options: PaintOptions = PaintOptions()) throws {
        if case .assign = operation {
            throw EditingError.invalidArgument("a brush stroke paints or erases; it does not assign")
        }
        _ = try EditPlan(model: model, operation: operation, options: options)
        self.model = model
        self.operation = operation
        self.brush = brush
        self.options = options
        self.metadataBefore = model.metadata
        self.revisionBefore = model.revision
    }

    /// Paints from the previous position (if any) to `point` (world
    /// coordinates). Returns the box this call changed (`.empty` when
    /// nothing changed).
    @discardableResult
    public func add(_ point: SIMD3<Double>) throws -> VoxelBox {
        precondition(!isFinished, "the stroke is finished")
        let centers = lastPoint.map { brush.dabCenters(from: $0, to: point) } ?? [point]
        lastPoint = point
        let region = brush.region(along: centers, in: model.geometry)
        guard !region.isEmpty else { return .empty }
        let edit = try model.makeEdit(operation, over: region, options: options)
        guard !edit.isEmpty else { return .empty }
        saveOriginals(for: edit)
        model.applyLive(edit)
        changedBounds = changedBounds.union(edit.bounds)
        return edit.bounds
    }

    /// Adds several positions (e.g. coalesced mouse events).
    @discardableResult
    public func add(_ points: [SIMD3<Double>]) throws -> VoxelBox {
        var box = VoxelBox.empty
        for p in points { box = box.union(try add(p)) }
        return box
    }

    private func saveOriginals(for edit: VoxelEdit) {
        for change in edit.layerChanges {
            let values = model.values(ofLayer: change.layer)
            var saved = originals[change.layer] ?? [:]
            for chunk in change.chunks where saved[chunk.index] == nil {
                let start = chunk.base
                let count = min(editChunkLength, model.voxelCount - start)
                saved[chunk.index] = Array(UnsafeBufferPointer(start: values + start, count: count))
            }
            originals[change.layer] = saved
        }
    }

    /// Ends the stroke: the edit that takes the model from its state before
    /// the stroke to its current state.
    public func finish() -> VoxelEdit {
        isFinished = true
        var changes: [LayerChange] = []
        for layer in originals.keys.sorted() {
            guard let saved = originals[layer], layer < model.layerCount else { continue }
            let current = model.values(ofLayer: layer)
            let builder = LayerChangeBuilder(layer: layer)
            for index in saved.keys.sorted() {
                let before = saved[index]!
                let base = index << editChunkShift
                for i in 0..<before.count where before[i] != current[base + i] {
                    builder.append(base + i, old: before[i], new: current[base + i])
                }
            }
            let chunks = builder.finish()
            if !chunks.isEmpty { changes.append(LayerChange(layer: layer, chunks: chunks, shape: model.shape)) }
        }
        let after = model.metadata
        let meta = after == metadataBefore ? nil : VoxelEdit.MetadataChange(before: metadataBefore, after: after)
        return VoxelEdit(shape: model.shape, layerChanges: changes, metadataChange: meta, baseRevision: revisionBefore)
    }

    /// Ends the stroke and restores the model to its state before it.
    public func cancel() {
        let edit = finish()
        if !edit.isEmpty { model.revert(edit) }
    }
}
