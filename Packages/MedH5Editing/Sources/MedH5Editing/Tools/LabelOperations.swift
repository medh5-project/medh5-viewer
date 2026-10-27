import Foundation
import simd
import MedH5Core

/// Operations between classes: copy, move, merge, subtract, intersect,
/// clear, relabel, swap. Each returns a `VoxelEdit` without applying it.
///
/// Where a class is added to voxels, the paint policy of `options` and the
/// locks apply. A locked class is never changed, so an operation that would
/// change one throws `classLocked`.
public enum LabelOperations {
    /// Adds class `target` wherever `source` is (B ∪= A); `source` keeps its voxels.
    public static func copy(_ model: SegmentationModel, from source: UInt16, to target: UInt16,
                            options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        try requireClasses(model, [source, target])
        let region = model.mask(of: source)
        return try model.makeEdit(.paint(target), over: region, options: options, control: control)
    }

    /// Moves the voxels of `source` to `target`: `target` is added where
    /// `source` is, and `source` removed wherever `target` now is (within
    /// one layer this is a relabelling; across layers a voxel `target`
    /// cannot take — a locked class there — keeps `source`).
    public static func move(_ model: SegmentationModel, from source: UInt16, to target: UInt16,
                            options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        try merge(model, classes: [source], into: target, options: options, control: control)
    }

    /// Renames class `source`'s voxels to `target` (a move).
    public static func relabel(_ model: SegmentationModel, _ source: UInt16, to target: UInt16,
                               options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        try move(model, from: source, to: target, options: options, control: control)
    }

    /// Moves every class of `classes` into `target`, in one edit.
    public static func merge(_ model: SegmentationModel, classes sources: [UInt16], into target: UInt16,
                             options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        let sources = sources.filter { $0 != target }
        try requireClasses(model, sources + [target])
        for s in sources where model.isLocked(s) { throw EditingError.classLocked(s) }
        if model.isLocked(target) { throw EditingError.classLocked(target) }
        guard !sources.isEmpty else { return VoxelEdit(shape: model.shape) }
        let region = sources.map { model.mask(of: $0) }.reduce(VoxelMask(bounds: .empty)) { $0.union($1) }
        let targetLayer = model.layer(of: target)!
        let srcLayers = sources.map { model.layer(of: $0)! }
        let policy = options.policy
        return try model.makeCustomEdit(over: region, paintedClass: target, control: control) { ctx, li, b in
            var sameLayerSource = false
            var present: [Int] = []
            for (i, s) in sources.enumerated() where ctx.value(srcLayers[i], li) == s {
                present.append(i)
                if srcLayers[i] == targetLayer { sameLayerSource = true }
            }
            guard !present.isEmpty else { return false }
            let painted: Bool
            if sameLayerSource {
                // The target's layer holds a source here: relabel it.
                b.append(layer: targetLayer, li, old: ctx.value(targetLayer, li), new: target)
                painted = true
            } else {
                painted = ctx.paint(target, layer: targetLayer, at: li, policy: policy, b)
            }
            if painted {
                for i in present where srcLayers[i] != targetLayer {
                    b.append(layer: srcLayers[i], li, old: sources[i], new: 0)
                }
            }
            return painted
        }
    }

    /// Removes class `a` where class `b` is (A := A \ B).
    public static func subtract(_ model: SegmentationModel, _ a: UInt16, minus b: UInt16,
                                control: OperationControl? = nil) throws -> VoxelEdit {
        try requireClasses(model, [a, b])
        return try model.makeEdit(.erase(a), over: model.mask(of: b), control: control)
    }

    /// Removes class `a` where class `b` is not (A := A ∩ B).
    public static func intersect(_ model: SegmentationModel, _ a: UInt16, with b: UInt16,
                                 control: OperationControl? = nil) throws -> VoxelEdit {
        try requireClasses(model, [a, b])
        let outside = model.mask(of: a).subtracting(model.mask(of: b))
        return try model.makeEdit(.erase(a), over: outside, control: control)
    }

    /// Erases every voxel of a class. The class stays in the table and in
    /// the coverage: an examined absence.
    public static func clear(_ model: SegmentationModel, _ a: UInt16, control: OperationControl? = nil) throws -> VoxelEdit {
        try requireClasses(model, [a])
        return try model.makeEdit(.erase(a), over: model.mask(of: a), control: control)
    }

    /// Exchanges the voxels of two classes. A voxel holding both keeps both.
    /// Across layers, a voxel whose new class cannot be painted there (paint
    /// policy, a locked class) keeps its old class.
    public static func swap(_ model: SegmentationModel, _ a: UInt16, _ b: UInt16,
                            options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        try requireClasses(model, [a, b])
        if model.isLocked(a) { throw EditingError.classLocked(a) }
        if model.isLocked(b) { throw EditingError.classLocked(b) }
        guard a != b else { return VoxelEdit(shape: model.shape) }
        let la = model.layer(of: a)!, lb = model.layer(of: b)!
        let region = model.mask(of: a).union(model.mask(of: b))
        let policy = options.policy
        var edit = try model.makeCustomEdit(over: region, paintedClass: nil, control: control) { ctx, li, bs in
            let hasA = ctx.value(la, li) == a
            let hasB = ctx.value(lb, li) == b
            if hasA == hasB { return false }
            if la == lb {
                bs.append(layer: la, li, old: hasA ? a : b, new: hasA ? b : a)
                return false
            }
            if hasA {
                if ctx.paint(b, layer: lb, at: li, policy: policy, bs) { bs.append(layer: la, li, old: a, new: 0) }
            } else {
                if ctx.paint(a, layer: la, at: li, policy: policy, bs) { bs.append(layer: lb, li, old: b, new: 0) }
            }
            return false
        }
        // Each class that gains voxels joins the coverage.
        var after = model.metadata
        if !edit.layerChanges.isEmpty {
            after = SegmentationModel.addingCoverage(a, to: after)
            after = SegmentationModel.addingCoverage(b, to: after)
        }
        if after != model.metadata {
            edit = VoxelEdit(shape: model.shape, layerChanges: edit.layerChanges,
                             metadataChange: .init(before: model.metadata, after: after), baseRevision: model.revision)
        }
        return edit
    }

    static func requireClasses(_ model: SegmentationModel, _ ids: [UInt16]) throws {
        for id in ids where model.layer(of: id) == nil { throw EditingError.unknownClass(id) }
    }
}

extension SegmentationModel {
    /// An edit from a per-voxel rule over the members of `region`. `body`
    /// records at most one change per layer for the voxel it is given and
    /// returns whether it painted `paintedClass` (which then joins the
    /// coverage).
    func makeCustomEdit(over region: some VoxelSet, paintedClass: UInt16?, control: OperationControl?,
                        _ body: (EditContext, Int, LayerBuilderSet) -> Bool) throws -> VoxelEdit {
        let box = region.bounds.clamped(to: shape)
        guard !box.isEmpty else { return VoxelEdit(shape: shape) }
        let grain = max(1, 65536 / max(1, box.size.y * box.size.z))
        let n1 = shape.y, n2 = shape.z
        let results: [([[ChunkChange]], Bool)] = try withEditContext { ctx in
            try Parallel.map(box.lower.x..<box.upper.x, grain: grain, control: control) { slab in
                let builders = LayerBuilderSet(layerCount: ctx.layerCount)
                var painted = false
                for k0 in slab {
                    for k1 in box.lower.y..<box.upper.y {
                        let rowBase = (k0 * n1 + k1) * n2
                        region.forEachRun(k0: k0, k1: k1) { s0, e0 in
                            let s = max(s0, box.lower.z), e = min(e0, box.upper.z)
                            guard s < e else { return }
                            for x in s..<e where body(ctx, rowBase + x, builders) { painted = true }
                        }
                    }
                }
                return (builders.finish(), painted)
            }
        }
        return finishEdit(parts: results.map(\.0), paintedTarget: results.contains { $0.1 } ? paintedClass : nil)
    }
}
