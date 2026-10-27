import Foundation
import simd
import MedH5Core

/// A reversible change to a `SegmentationModel`: voxel changes per layer
/// (old and new values, block-compressed) and, optionally, a change of the
/// class table, coverage or layer count.
///
/// Every editing operation produces one. Tools compute an edit from the
/// model without changing it — so a long operation can run on a background
/// task against a `copy()` of the model — and the caller applies it on the
/// model's serial context (`SegmentationModel.apply(_:)`) and records it in
/// an `EditHistory`. `revert` restores the bytes exactly.
///
/// A 3-D fill of 10⁷ voxels is a few thousand chunks of a few bytes each
/// (uniform old and new values over a handful of runs); the worst case, a
/// noisy change of every voxel, stays near 0.2 bytes per voxel plus the
/// changed values.
public struct VoxelEdit: Sendable {
    /// A class-table, coverage or layer-count change.
    public struct MetadataChange: Sendable, Hashable {
        public var before: SegmentationMetadata
        public var after: SegmentationMetadata
    }

    /// Padded shape of the grid the edit was computed for.
    public let shape: SIMD3<Int>
    /// Voxel changes, one per touched layer, ascending by layer.
    public private(set) var layerChanges: [LayerChange]
    public private(set) var metadataChange: MetadataChange?
    /// The model revision the edit was computed against (`nil` when composed
    /// from edits of different revisions).
    public var baseRevision: UInt64?

    /// An edit that changes nothing.
    public init(shape: SIMD3<Int>) {
        self.shape = shape
        self.layerChanges = []
        self.metadataChange = nil
        self.baseRevision = nil
    }

    init(shape: SIMD3<Int>, layerChanges: [LayerChange], metadataChange: MetadataChange?, baseRevision: UInt64?) {
        self.shape = shape
        self.layerChanges = layerChanges.filter { $0.voxelCount > 0 }.sorted { $0.layer < $1.layer }
        if let m = metadataChange, m.before != m.after {
            self.metadataChange = m
        } else {
            self.metadataChange = nil
        }
        self.baseRevision = baseRevision
    }

    /// Whether the edit changes nothing.
    public var isEmpty: Bool { layerChanges.isEmpty && metadataChange == nil }

    /// Number of voxel values changed (a voxel changed in two layers counts twice).
    public var voxelCount: Int { layerChanges.reduce(0) { $0 + $1.voxelCount } }

    /// Approximate memory held, in bytes.
    public var byteSize: Int {
        layerChanges.reduce(128) { $0 + $1.byteSize } + (metadataChange == nil ? 0 : 512)
    }

    /// The box of every changed voxel, all layers together.
    public var bounds: VoxelBox {
        layerChanges.reduce(VoxelBox.empty) { $0.union($1.bounds) }
    }

    /// The changed box of each touched layer: what a renderer re-uploads.
    public var dirtyBoxes: [Int: VoxelBox] {
        Dictionary(uniqueKeysWithValues: layerChanges.map { ($0.layer, $0.bounds) })
    }

    public func change(forLayer layer: Int) -> LayerChange? {
        layerChanges.first { $0.layer == layer }
    }

    /// Whether the class table, coverage or layer count changes.
    public var changesMetadata: Bool { metadataChange != nil }

    /// The edit that undoes this one.
    public var inverse: VoxelEdit {
        var out = VoxelEdit(shape: shape)
        out.layerChanges = layerChanges.map(\.inverted)
        out.metadataChange = metadataChange.map { MetadataChange(before: $0.after, after: $0.before) }
        out.baseRevision = nil
        return out
    }

    /// This edit followed by `next`, as one edit: a voxel changed by both
    /// keeps this edit's old value and `next`'s new value, and is dropped if
    /// they are equal. `next` must have been computed on the state this edit
    /// produces.
    public func followed(by next: VoxelEdit) -> VoxelEdit {
        precondition(next.shape == shape, "edits of different grids")
        if isEmpty { return next }
        if next.isEmpty { return self }
        var merged: [LayerChange] = []
        var i = 0, j = 0
        let a = layerChanges, b = next.layerChanges
        while i < a.count || j < b.count {
            if j == b.count || (i < a.count && a[i].layer < b[j].layer) {
                merged.append(a[i])
                i += 1
            } else if i == a.count || b[j].layer < a[i].layer {
                merged.append(b[j])
                j += 1
            } else {
                if let c = LayerChange.compose(a[i], b[j], shape: shape) { merged.append(c) }
                i += 1
                j += 1
            }
        }
        var meta: MetadataChange?
        switch (metadataChange, next.metadataChange) {
        case let (m1?, m2?): meta = MetadataChange(before: m1.before, after: m2.after)
        case let (m1?, nil): meta = m1
        case let (nil, m2?): meta = m2
        case (nil, nil): meta = nil
        }
        return VoxelEdit(shape: shape, layerChanges: merged, metadataChange: meta, baseRevision: baseRevision)
    }

    /// Calls `body(layer, linearIndex, old, new)` for every changed voxel value.
    public func forEachChange(_ body: (Int, Int, UInt16, UInt16) -> Void) {
        for c in layerChanges {
            c.forEachChange { li, o, n in body(c.layer, li, o, n) }
        }
    }
}

extension VoxelEdit: CustomStringConvertible {
    public var description: String {
        var parts = layerChanges.map { "layer \($0.layer): \($0.voxelCount) voxels in \($0.bounds)" }
        if metadataChange != nil { parts.append("metadata") }
        return "VoxelEdit(\(parts.isEmpty ? "empty" : parts.joined(separator: "; ")), \(byteSize) bytes)"
    }
}
