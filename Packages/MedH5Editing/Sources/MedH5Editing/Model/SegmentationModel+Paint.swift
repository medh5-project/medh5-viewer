import Foundation
import simd
import MedH5Core

/// What happens when class A is painted where another class B already is.
///
/// Locked classes are never overwritten, whatever the policy.
public enum PaintPolicy: Sendable, Hashable {
    /// A replaces B when B lives in A's layer; when B lives in another layer
    /// both keep the voxel (they overlap). Painting over the ignore region
    /// replaces it, unless the ignore region is locked.
    case overwrite
    /// Paint only where A's layer holds 0 (and the voxel is not ignored).
    case onlyEmpty
    /// Paint only where class B is present (masking); within A's layer the
    /// voxel is overwritten as with `.overwrite`.
    case onlyInside(UInt16)
}

/// Options shared by painting tools.
public struct PaintOptions: Sendable {
    public var policy: PaintPolicy
    /// Paint only where the image value is in a range.
    public var intensity: IntensityConstraint?

    public init(policy: PaintPolicy = .overwrite, intensity: IntensityConstraint? = nil) {
        self.policy = policy
        self.intensity = intensity
    }
}

/// What an edit does to the voxels of a `VoxelSet`.
public enum VoxelOperation: Sendable, Hashable {
    /// Add the class (subject to the paint policy and locks).
    case paint(UInt16)
    /// Remove the class.
    case erase(UInt16)
    /// Remove every unlocked class (the ignore region stays).
    case eraseAll
    /// Mark the voxels ignored (spec §7.7). An in-band ignore value cannot
    /// share a voxel with a class, so classes there are removed under
    /// `.overwrite`; voxels holding a locked class are skipped.
    case paintIgnore
    /// Clear the ignore region.
    case eraseIgnore
    /// Make the class exactly the set within the set's `bounds`: members are
    /// painted (policy applies), other voxels of the bounds lose the class.
    /// An intensity constraint only limits painting (a member it rejects is
    /// left as it is).
    case assign(UInt16)
}

extension SegmentationModel {
    /// Computes the edit an operation makes on a voxel set, without changing
    /// the model. Members outside the grid are ignored. The edit adds a
    /// painted class to `classIDs` and `annotatedClassIDs` when it paints at
    /// least one voxel of it.
    ///
    /// - Throws: `unknownClass`, `classLocked` (the target class is locked),
    ///   `cancelled`.
    public func makeEdit(_ operation: VoxelOperation, over region: some VoxelSet,
                         options: PaintOptions = PaintOptions(), control: OperationControl? = nil) throws -> VoxelEdit {
        let plan = try EditPlan(model: self, operation: operation, options: options)
        let box = region.bounds.clamped(to: shape)
        guard !box.isEmpty else { return VoxelEdit(shape: shape) }
        let sampler = options.intensity?.sampler(for: geometry)
        let range = options.intensity?.range

        let perSlice = box.size.y * box.size.z
        let grain = max(1, 65536 / max(1, perSlice))
        let results: [([[ChunkChange]], Bool)] = try withEditContext { ctx in
            try Parallel.map(box.lower.x..<box.upper.x, grain: grain, control: control) { slab in
                let builders = LayerBuilderSet(layerCount: ctx.layerCount)
                var painted = false
                let n1 = shape.y, n2 = shape.z
                for k0 in slab {
                    if control.isCancelled { throw EditingError.cancelled }
                    for k1 in box.lower.y..<box.upper.y {
                        let rowBase = (k0 * n1 + k1) * n2
                        @inline(__always) func accepts(_ x: Int) -> Bool {
                            guard let sampler, let range else { return true }
                            let v = sampler.value(at: SIMD3(k0, k1, x), linear: rowBase + x)
                            return range.contains(v)
                        }
                        if case .assign = plan.operation {
                            var x = box.lower.z
                            region.forEachRun(k0: k0, k1: k1) { s0, e0 in
                                let s = max(s0, box.lower.z), e = min(e0, box.upper.z)
                                guard s < e else { return }
                                if x < s { for g in x..<s { ctx.erase(plan.target, layer: plan.targetLayer, at: rowBase + g, builders) } }
                                // A member the intensity constraint rejects keeps its value.
                                for v in s..<e where accepts(v) {
                                    if ctx.paint(plan.target, layer: plan.targetLayer, at: rowBase + v, policy: plan.policy, builders) {
                                        painted = true
                                    }
                                }
                                x = e
                            }
                            if x < box.upper.z {
                                for g in x..<box.upper.z { ctx.erase(plan.target, layer: plan.targetLayer, at: rowBase + g, builders) }
                            }
                        } else {
                            region.forEachRun(k0: k0, k1: k1) { s0, e0 in
                                let s = max(s0, box.lower.z), e = min(e0, box.upper.z)
                                guard s < e else { return }
                                for x in s..<e where accepts(x) {
                                    if plan.apply(ctx, at: rowBase + x, builders) { painted = true }
                                }
                            }
                        }
                    }
                }
                return (builders.finish(), painted)
            }
        }
        return finishEdit(parts: results.map(\.0), paintedTarget: results.contains { $0.1 } ? plan.paintedClass : nil)
    }

    /// Computes and applies an edit; returns it for the undo history.
    @discardableResult
    public func perform(_ operation: VoxelOperation, over region: some VoxelSet,
                        options: PaintOptions = PaintOptions()) throws -> VoxelEdit {
        let edit = try makeEdit(operation, over: region, options: options)
        if !edit.isEmpty { apply(edit) }
        return edit
    }

    /// Builds an edit from per-slab, per-layer chunk lists (slabs in
    /// ascending order), adding `paintedTarget` to the coverage if needed.
    func finishEdit(parts: [[[ChunkChange]]], paintedTarget: UInt16?, extraMetadata: SegmentationMetadata? = nil) -> VoxelEdit {
        var changes: [LayerChange] = []
        let layerCount = parts.first?.count ?? 0
        for l in 0..<layerCount {
            let chunks = LayerChange.concatenate(parts.map { $0[l] })
            if !chunks.isEmpty { changes.append(LayerChange(layer: l, chunks: chunks, shape: shape)) }
        }
        var after = extraMetadata ?? metadata
        if let a = paintedTarget, !changes.isEmpty {
            after = SegmentationModel.addingCoverage(a, to: after)
        }
        let meta = after == metadata ? nil : VoxelEdit.MetadataChange(before: metadata, after: after)
        return VoxelEdit(shape: shape, layerChanges: changes, metadataChange: meta, baseRevision: revision)
    }

    /// `meta` with `id` in `classIDs` and `annotatedClassIDs`.
    static func addingCoverage(_ id: UInt16, to meta: SegmentationMetadata) -> SegmentationMetadata {
        var m = meta
        if !m.classIDs.contains(id) { m.classIDs.append(id) }
        if !m.annotatedClassIDs.contains(id) { m.annotatedClassIDs.append(id) }
        return m
    }

    /// Runs `body` with raw access to the layers and class tables.
    func withEditContext<R>(_ body: (EditContext) throws -> R) rethrows -> R {
        let pointers = layers.map { $0.pointer(as: UInt16.self) }
        return try pointers.withUnsafeBufferPointer { lp in
            try layerTable.withUnsafeBufferPointer { lt in
                try lockedTable.withUnsafeBufferPointer { lk in
                    let ctx = EditContext(layers: lp, layerCount: lp.count, layerTable: lt.baseAddress!,
                                          locked: lk.baseAddress!, ignore: metadata.ignoreValue,
                                          ignoreLocked: metadata.ignoreLocked)
                    return try body(ctx)
                }
            }
        }
    }
}

/// The validated parameters of one operation.
struct EditPlan {
    let operation: VoxelOperation
    let policy: PaintPolicy
    let target: UInt16
    let targetLayer: Int
    /// The class this operation may add to the coverage.
    let paintedClass: UInt16?

    init(model: SegmentationModel, operation: VoxelOperation, options: PaintOptions) throws {
        self.operation = operation
        self.policy = options.policy
        if case .onlyInside(let b) = options.policy, model.layer(of: b) == nil {
            throw EditingError.unknownClass(b)
        }
        switch operation {
        case .paint(let a), .erase(let a), .assign(let a):
            guard let l = model.layer(of: a) else { throw EditingError.unknownClass(a) }
            if model.isLocked(a) { throw EditingError.classLocked(a) }
            target = a
            targetLayer = l
            if case .erase = operation { paintedClass = nil } else { paintedClass = a }
        case .eraseAll, .paintIgnore, .eraseIgnore:
            target = 0
            targetLayer = 0
            paintedClass = nil
        }
    }

    /// Applies the operation to one member voxel; returns whether the target
    /// class was painted there.
    @inline(__always)
    func apply(_ ctx: EditContext, at li: Int, _ b: LayerBuilderSet) -> Bool {
        switch operation {
        case .paint(let a), .assign(let a):
            return ctx.paint(a, layer: targetLayer, at: li, policy: policy, b)
        case .erase(let a):
            ctx.erase(a, layer: targetLayer, at: li, b)
        case .eraseAll:
            ctx.eraseAll(at: li, b)
        case .paintIgnore:
            ctx.paintIgnore(at: li, policy: policy, b)
        case .eraseIgnore:
            ctx.eraseIgnore(at: li, b)
        }
        return false
    }
}

/// Raw access to the layers for computing edits: every method reads the
/// current values and records changes (old → new) in builders, leaving the
/// layers untouched. Each method records at most one change per layer for
/// the voxel it is given.
struct EditContext {
    let layers: UnsafeBufferPointer<UnsafeMutablePointer<UInt16>>
    let layerCount: Int
    let layerTable: UnsafePointer<Int16>
    let locked: UnsafePointer<Bool>
    let ignore: UInt16
    let ignoreLocked: Bool

    @inline(__always)
    func value(_ layer: Int, _ li: Int) -> UInt16 { layers[layer][li] }

    @inline(__always)
    func contains(_ cls: UInt16, _ li: Int) -> Bool {
        let l = Int(layerTable[Int(cls)])
        return l >= 0 && l < layerCount && layers[l][li] == cls
    }

    @inline(__always)
    func isIgnored(_ li: Int) -> Bool {
        for l in 0..<layerCount where layers[l][li] == ignore { return true }
        return false
    }

    /// Whether a value is a class that may not be overwritten.
    @inline(__always)
    func isProtectedClass(_ v: UInt16) -> Bool {
        v != 0 && v != ignore && locked[Int(v)]
    }

    /// Paints class `a` (living in layer `la`); returns whether `a` is
    /// present at the voxel afterwards.
    @inline(__always)
    @discardableResult
    func paint(_ a: UInt16, layer la: Int, at li: Int, policy: PaintPolicy, _ b: LayerBuilderSet) -> Bool {
        let cur = layers[la][li]
        if cur == a { return true }
        if isProtectedClass(cur) { return false }
        if cur == ignore || (layerCount > 1 && isIgnored(li)) {
            guard case .overwrite = policy, !ignoreLocked else { return false }
            for l in 0..<layerCount {
                let v = layers[l][li]
                if l == la {
                    b.append(layer: l, li, old: v, new: a)
                } else if v == ignore {
                    b.append(layer: l, li, old: v, new: 0)
                }
            }
            return true
        }
        switch policy {
        case .overwrite:
            break
        case .onlyEmpty:
            if cur != 0 { return false }
        case .onlyInside(let mask):
            if cur != mask && !contains(mask, li) { return false }
        }
        b.append(layer: la, li, old: cur, new: a)
        return true
    }

    @inline(__always)
    func erase(_ a: UInt16, layer la: Int, at li: Int, _ b: LayerBuilderSet) {
        if layers[la][li] == a { b.append(layer: la, li, old: a, new: 0) }
    }

    /// Sets class `a`'s layer to `value` (0 or `a`) without policy checks.
    @inline(__always)
    func set(_ layer: Int, at li: Int, to value: UInt16, _ b: LayerBuilderSet) {
        let cur = layers[layer][li]
        if cur != value { b.append(layer: layer, li, old: cur, new: value) }
    }

    @inline(__always)
    func eraseAll(at li: Int, _ b: LayerBuilderSet) {
        for l in 0..<layerCount {
            let v = layers[l][li]
            if v != 0 && v != ignore && !locked[Int(v)] { b.append(layer: l, li, old: v, new: 0) }
        }
    }

    @inline(__always)
    func paintIgnore(at li: Int, policy: PaintPolicy, _ b: LayerBuilderSet) {
        var hasClass = false
        for l in 0..<layerCount {
            let v = layers[l][li]
            if v != 0 && v != ignore {
                if locked[Int(v)] { return }
                hasClass = true
            }
        }
        switch policy {
        case .overwrite: break
        case .onlyEmpty: if hasClass { return }
        case .onlyInside(let mask): if !contains(mask, li) { return }
        }
        for l in 0..<layerCount {
            let v = layers[l][li]
            let target: UInt16 = l == 0 ? ignore : 0
            if v != target { b.append(layer: l, li, old: v, new: target) }
        }
    }

    @inline(__always)
    func eraseIgnore(at li: Int, _ b: LayerBuilderSet) {
        for l in 0..<layerCount where layers[l][li] == ignore {
            b.append(layer: l, li, old: ignore, new: 0)
        }
    }
}
