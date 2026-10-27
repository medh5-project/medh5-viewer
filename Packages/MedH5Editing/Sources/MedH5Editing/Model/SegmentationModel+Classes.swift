import Foundation
import simd
import MedH5Core

/// Class-table, coverage and layer operations. Each returns a `VoxelEdit`
/// (metadata change, plus voxel changes where the operation moves or erases
/// voxels) without applying it, so it is undone like any other edit.
extension SegmentationModel {
    /// An edit changing the metadata only. The result is validated; the layer
    /// count may grow (new empty layers) but not shrink.
    public func metadataEdit(_ transform: (inout SegmentationMetadata) throws -> Void) throws -> VoxelEdit {
        var after = metadata
        try transform(&after)
        try after.validate()
        guard after.layerCount >= layerCount else {
            throw EditingError.invalidArgument("layers cannot be removed by a metadata edit")
        }
        guard after.ignoreValue == metadata.ignoreValue || isIgnoreRegionEmpty() else {
            throw EditingError.invalidArgument("the ignore value cannot change while voxels hold it")
        }
        let change = after == metadata ? nil : VoxelEdit.MetadataChange(before: metadata, after: after)
        return VoxelEdit(shape: shape, layerChanges: [], metadataChange: change, baseRevision: revision)
    }

    private func isIgnoreRegionEmpty() -> Bool {
        let ignore = ignoreValue
        return layers.allSatisfy { l in
            let p = l.pointer(as: UInt16.self)
            return !(0..<l.count).contains { p[$0] == ignore }
        }
    }

    // MARK: Classes

    /// Adds a class to the table.
    ///
    /// - Parameters:
    ///   - layer: the layer for the class; `nil` chooses the first layer that
    ///     holds none of `overlapping`, adding a layer when every layer
    ///     holds one. Passing `layerCount` adds a layer.
    ///   - overlapping: classes the new class must be able to overlap (they
    ///     may not share its layer).
    ///   - inAnnotation: also add it to `classIDs`.
    ///   - annotated: also add it to `annotatedClassIDs` (and `classIDs`).
    public func addClassEdit(_ newClass: SegmentClass, layer: Int? = nil, overlapping: Set<UInt16> = [],
                             inAnnotation: Bool = false, annotated: Bool = false) throws -> VoxelEdit {
        guard metadata.isAssignable(newClass.id) else { throw EditingError.reservedClassID(newClass.id) }
        guard classInfo(newClass.id) == nil else { throw EditingError.duplicateClass(newClass.id) }
        for o in overlapping where classInfo(o) == nil { throw EditingError.unknownClass(o) }
        let chosen: Int
        if let layer {
            guard layer >= 0 && layer <= layerCount else { throw EditingError.invalidLayer(layer) }
            if layer < layerCount, metadata.classes(inLayer: layer).contains(where: { overlapping.contains($0.id) }) {
                throw EditingError.invalidArgument("layer \(layer) holds a class that class \(newClass.id) must overlap")
            }
            chosen = layer
        } else {
            chosen = (0..<layerCount).first { l in
                !metadata.classes(inLayer: l).contains { overlapping.contains($0.id) }
            } ?? layerCount
        }
        return try metadataEdit { m in
            var c = newClass
            c.layer = chosen
            m.classes.append(c)
            if chosen >= m.layerCount { m.layerCount = chosen + 1 }
            if inAnnotation || annotated { m.classIDs.append(c.id) }
            if annotated { m.annotatedClassIDs.append(c.id) }
        }
    }

    /// Changes a class's key, name, colour, visibility or lock. Its id and
    /// layer cannot change here (see `moveClassEdit(_:toLayer:)`).
    public func updateClassEdit(_ id: UInt16, _ transform: (inout SegmentClass) -> Void) throws -> VoxelEdit {
        guard let i = metadata.classIndex(id) else { throw EditingError.unknownClass(id) }
        return try metadataEdit { m in
            var c = m.classes[i]
            transform(&c)
            guard c.id == id, c.layer == m.classes[i].layer else {
                throw EditingError.invalidArgument("updateClassEdit cannot change a class's id or layer")
            }
            m.classes[i] = c
        }
    }

    /// Removes a class from the table and the coverage, erasing its voxels.
    /// - Throws: `classLocked` when the class is locked and has voxels.
    public func removeClassEdit(_ id: UInt16) throws -> VoxelEdit {
        guard classInfo(id) != nil else { throw EditingError.unknownClass(id) }
        var after = metadata
        after.classes.removeAll { $0.id == id }
        after.classIDs.removeAll { $0 == id }
        after.annotatedClassIDs.removeAll { $0 == id }
        return try erasingEdit(of: id, metadataAfter: after)
    }

    // MARK: Coverage (spec §6.2, §11.3)

    /// Marks a class as examined (`annotatedClassIDs`, adding it to
    /// `classIDs` too) or not examined (removing it from
    /// `annotatedClassIDs` only).
    public func setAnnotatedEdit(_ id: UInt16, _ annotated: Bool) throws -> VoxelEdit {
        guard classInfo(id) != nil else { throw EditingError.unknownClass(id) }
        return try metadataEdit { m in
            if annotated {
                m = SegmentationModel.addingCoverage(id, to: m)
            } else {
                m.annotatedClassIDs.removeAll { $0 == id }
            }
        }
    }

    /// Adds a class to the annotation (`classIDs`) or removes it from both
    /// `classIDs` and `annotatedClassIDs`. A class the annotation cannot
    /// express cannot have voxels, so removing it erases them.
    /// - Throws: `classLocked` when removing a locked class that has voxels.
    public func setInAnnotationEdit(_ id: UInt16, _ included: Bool) throws -> VoxelEdit {
        guard classInfo(id) != nil else { throw EditingError.unknownClass(id) }
        if included {
            return try metadataEdit { m in
                if !m.classIDs.contains(id) { m.classIDs.append(id) }
            }
        }
        var after = metadata
        after.classIDs.removeAll { $0 == id }
        after.annotatedClassIDs.removeAll { $0 == id }
        return try erasingEdit(of: id, metadataAfter: after)
    }

    /// Protects (or unprotects) the ignore region from being painted over.
    public func setIgnoreLockedEdit(_ locked: Bool) throws -> VoxelEdit {
        try metadataEdit { $0.ignoreLocked = locked }
    }

    /// Erases every voxel of a class and sets the metadata to `after`.
    private func erasingEdit(of id: UInt16, metadataAfter after: SegmentationMetadata) throws -> VoxelEdit {
        try after.validate()
        let box = bounds(of: id)
        var changes: [LayerChange] = []
        if !box.isEmpty, let l = layer(of: id) {
            if isLocked(id) { throw EditingError.classLocked(id) }
            changes = classValueChanges(id, in: box, layerChanges: [(l, id, 0)])
        }
        let meta = after == metadata ? nil : VoxelEdit.MetadataChange(before: metadata, after: after)
        return VoxelEdit(shape: shape, layerChanges: changes, metadataChange: meta, baseRevision: revision)
    }

    /// For every voxel of class `id` in `box`, records `layer: from → to` for
    /// each entry of `layerChanges` (where the layer holds `from`).
    func classValueChanges(_ id: UInt16, in box: VoxelBox,
                           layerChanges: [(layer: Int, from: UInt16, to: UInt16)]) -> [LayerChange] {
        guard let l = layer(of: id) else { return [] }
        let src = UnsafePointer(layers[l].pointer(as: UInt16.self))
        let n1 = shape.y, n2 = shape.z
        let count = max(layerCount, (layerChanges.map(\.layer).max() ?? 0) + 1)
        let ptrs: [UnsafePointer<UInt16>?] = (0..<count).map { $0 < layerCount ? UnsafePointer(layers[$0].pointer(as: UInt16.self)) : nil }
        let parts: [[[ChunkChange]]] = (try? Parallel.map(box.lower.x..<box.upper.x, grain: max(1, 65536 / max(1, box.size.y * box.size.z))) { slab in
            let b = LayerBuilderSet(layerCount: count)
            for k0 in slab {
                for k1 in box.lower.y..<box.upper.y {
                    let base = (k0 * n1 + k1) * n2
                    for x in box.lower.z..<box.upper.z where src[base + x] == id {
                        for c in layerChanges {
                            let cur: UInt16 = ptrs[c.layer].map { $0[base + x] } ?? 0
                            if cur == c.from && cur != c.to { b.append(layer: c.layer, base + x, old: cur, new: c.to) }
                        }
                    }
                }
            }
            return b.finish()
        }) ?? []
        var out: [LayerChange] = []
        for layer in 0..<count {
            let chunks = LayerChange.concatenate(parts.map { $0[layer] })
            if !chunks.isEmpty { out.append(LayerChange(layer: layer, chunks: chunks, shape: shape)) }
        }
        return out
    }

    // MARK: Layers

    /// Moves a class (and its voxels) to another layer; `layerCount` adds a
    /// layer.
    /// - Throws: `editConflict` when a voxel of the class is occupied in the
    ///   target layer.
    public func moveClassEdit(_ id: UInt16, toLayer target: Int) throws -> VoxelEdit {
        guard let source = layer(of: id) else { throw EditingError.unknownClass(id) }
        guard target >= 0 && target <= layerCount else { throw EditingError.invalidLayer(target) }
        if target == source { return VoxelEdit(shape: shape) }
        let box = bounds(of: id)
        if target < layerCount && collides(id, box: box, withLayer: target) {
            throw EditingError.editConflict("class \(id) overlaps voxels already labelled in layer \(target)")
        }
        var after = metadata
        if let i = after.classIndex(id) { after.classes[i].layer = target }
        if target >= after.layerCount { after.layerCount = target + 1 }
        try after.validate()
        let changes = box.isEmpty ? [] : classValueChanges(id, in: box, layerChanges: [(source, id, 0), (target, 0, id)])
        return VoxelEdit(shape: shape, layerChanges: changes,
                         metadataChange: VoxelEdit.MetadataChange(before: metadata, after: after),
                         baseRevision: revision)
    }

    /// Puts class `id` in a layer that holds none of `others`, so that it can
    /// overlap them: an empty edit when its layer already qualifies;
    /// otherwise moves the class (with its voxels) to the first layer that
    /// holds none of `others` and none of the class's voxels, adding a layer
    /// when no layer qualifies.
    public func ensureLayer(for id: UInt16, overlapping others: Set<UInt16>) throws -> VoxelEdit {
        guard let current = layer(of: id) else { throw EditingError.unknownClass(id) }
        for o in others where layer(of: o) == nil { throw EditingError.unknownClass(o) }
        let blocking = others.subtracting([id])
        func admits(_ l: Int) -> Bool {
            !metadata.classes(inLayer: l).contains { blocking.contains($0.id) }
        }
        if admits(current) { return VoxelEdit(shape: shape) }
        let box = bounds(of: id)
        for l in 0..<layerCount where l != current && admits(l) {
            if !collides(id, box: box, withLayer: l) { return try moveClassEdit(id, toLayer: l) }
        }
        return try moveClassEdit(id, toLayer: layerCount)
    }

    /// Whether any voxel of class `id` is nonzero in layer `target`.
    func collides(_ id: UInt16, box: VoxelBox, withLayer target: Int) -> Bool {
        guard !box.isEmpty, let l = layer(of: id) else { return false }
        let src = UnsafePointer(layers[l].pointer(as: UInt16.self))
        let dst = UnsafePointer(layers[target].pointer(as: UInt16.self))
        let n1 = shape.y, n2 = shape.z
        let hits = (try? Parallel.map(box.lower.x..<box.upper.x) { slab -> Bool in
            for k0 in slab {
                for k1 in box.lower.y..<box.upper.y {
                    let base = (k0 * n1 + k1) * n2
                    for x in box.lower.z..<box.upper.z where src[base + x] == id && dst[base + x] != 0 {
                        return true
                    }
                }
            }
            return false
        }) ?? []
        return hits.contains(true)
    }
}
