import Foundation
import simd
import MedH5Core

/// The segmentation being edited: `uint16` layers on one grid (spec §7.2),
/// the class table and the coverage contract.
///
/// ## Layers and classes
/// Each layer is a `VolumeData` of the grid's spatial shape holding class
/// ids; classes of one layer are mutually exclusive, classes of different
/// layers may overlap. Every class of the table lives in exactly one layer
/// (`SegmentClass.layer`). `0` is background and `ignoreValue` (65535 by
/// default) marks the ignore region, in any layer; neither is a class.
///
/// ## Coverage
/// `classIDs` (what the annotation can express) and `annotatedClassIDs`
/// (what was looked for, a subset) are never collapsed (spec §6.2, §11.3):
/// painting a class adds it to both; erasing every voxel of a class leaves
/// it in both, an examined absence. Change coverage explicitly with
/// `annotationEdit(...)`, `addClassEdit(...)` and friends.
///
/// ## Edits, revisions and rendering
/// The model changes only through `apply(_:)` / `revert(_:)` of a
/// `VoxelEdit` (and a `BrushStroke` in progress, which applies its dabs as
/// it goes). Each change increments `revision` and records, per layer, the
/// boxes that changed; the renderer collects them with `takeRenderUpdate()`
/// and re-uploads only those regions.
///
/// ## Threading
/// The model is not synchronised. Mutate it from one serial context (the
/// main actor in the app). Operations that compute an edit only read the
/// model; to run a long one in the background, give it a `copy()` (a memory
/// copy of the layers, milliseconds) and apply the result on the main actor,
/// checking `revision` (or `canApply(_:)`) first:
///
/// ```swift
/// let snapshot = model.copy()
/// let edit = try await Task.detached {
///     try Morphology.dilate(snapshot, classID: 3, radius: 2.0)
/// }.value
/// if model.revision == snapshot.revision { model.apply(edit); history.record(edit, name: "Dilate") }
/// ```
public final class SegmentationModel: @unchecked Sendable {
    /// The grid, spatial axes only.
    public let geometry: GridGeometry
    /// Padded shape `(n0, n1, n2)`.
    public let shape: SIMD3<Int>
    /// Voxels per layer.
    public let voxelCount: Int

    /// The layers, each `uint16` with the grid's spatial shape.
    public private(set) var layers: [VolumeData]

    /// Class table, coverage and layer count.
    public private(set) var metadata: SegmentationMetadata {
        didSet { rebuildTables() }
    }

    /// Increases with every change (voxels or metadata).
    public private(set) var revision: UInt64 = 0

    /// Called after every change, on the mutating thread.
    public var didChange: (() -> Void)?

    /// Class id → layer (−1 when the id is not a class of the table).
    var layerTable: [Int16]
    /// Class id → locked.
    var lockedTable: [Bool]

    private var dirty = DirtyTracker()

    // MARK: Creating

    /// An empty segmentation with `metadata.layerCount` zero layers.
    public init(geometry: GridGeometry, metadata: SegmentationMetadata = SegmentationMetadata()) throws {
        try metadata.validate()
        let g = geometry.spatialOnly
        self.geometry = g
        self.shape = g.paddedShape
        self.voxelCount = g.spatialVoxelCount
        self.layers = (0..<metadata.layerCount).map { _ in VolumeData(scalarType: .uint16, shape: g.spatialShape) }
        self.metadata = metadata
        self.layerTable = []
        self.lockedTable = []
        rebuildTables()
    }

    /// A segmentation over existing layers (as read from a file).
    ///
    /// `metadata.layerCount` is set to `layers.count`. With
    /// `registerUnknownLabels`, values found in the layers that are not in
    /// `classIDs` are added to it (they must be: `class_ids` holds every
    /// class the data encodes, spec §6.2), creating placeholder classes for
    /// ids the table lacks. A class found in two layers, or in a layer other
    /// than its table entry's, is an error.
    public init(geometry: GridGeometry, layers: [VolumeData], metadata: SegmentationMetadata,
                registerUnknownLabels: Bool = true) throws {
        let g = geometry.spatialOnly
        self.geometry = g
        self.shape = g.paddedShape
        self.voxelCount = g.spatialVoxelCount
        guard !layers.isEmpty else { throw EditingError.invalidArgument("a segmentation has at least one layer") }
        for (i, l) in layers.enumerated() {
            guard l.scalarType == .uint16 else {
                throw EditingError.shapeMismatch("layer \(i) is \(l.scalarType), not uint16")
            }
            guard l.count == g.spatialVoxelCount else {
                throw EditingError.shapeMismatch("layer \(i) has \(l.count) voxels; the grid has \(g.spatialVoxelCount)")
            }
        }
        self.layers = layers.map { $0.shape == g.spatialShape ? $0 : $0.reshaped(g.spatialShape) }
        var meta = metadata
        meta.layerCount = layers.count
        if registerUnknownLabels {
            let found = SegmentationModel.labelsPresent(in: self.layers, ignore: meta.ignoreValue)
            for (layer, ids) in found.enumerated() {
                for id in ids.sorted() {
                    if let existing = meta.classInfo(id) {
                        guard existing.layer == layer else {
                            throw EditingError.invalidArgument(
                                "class \(id) is stored in layer \(layer) but assigned to layer \(existing.layer)")
                        }
                    } else {
                        meta.classes.append(.placeholder(id: id, layer: layer))
                    }
                    if !meta.classIDs.contains(id) { meta.classIDs.append(id) }
                }
            }
        }
        try meta.validate()
        self.metadata = meta
        self.layerTable = []
        self.lockedTable = []
        rebuildTables()
    }

    /// An independent copy (layers copied, same metadata and revision): a
    /// snapshot for background operations.
    public func copy() -> SegmentationModel {
        let m = try! SegmentationModel(geometry: geometry, layers: layers.map { $0.copy() }, metadata: metadata,
                                       registerUnknownLabels: false)
        m.revision = revision
        return m
    }

    private func rebuildTables() {
        var lt = [Int16](repeating: -1, count: 65536)
        var lk = [Bool](repeating: false, count: 65536)
        for c in metadata.classes {
            lt[Int(c.id)] = Int16(c.layer)
            lk[Int(c.id)] = c.isLocked
        }
        layerTable = lt
        lockedTable = lk
    }

    /// The distinct nonzero, non-ignore values of each layer.
    static func labelsPresent(in layers: [VolumeData], ignore: UInt16) -> [Set<UInt16>] {
        layers.map { layer in
            let n = layer.count
            let p = layer.pointer(as: UInt16.self)
            let pieces = max(1, min(Parallel.workerCount * 2, n / 65536))
            var partial = [[Bool]](repeating: [], count: pieces)
            partial.withUnsafeMutableBufferPointer { out in
                Parallel.perform(pieces) { c in
                    var seen = [Bool](repeating: false, count: 65536)
                    for i in (n * c / pieces)..<(n * (c + 1) / pieces) { seen[Int(p[i])] = true }
                    out[c] = seen
                }
            }
            var ids = Set<UInt16>()
            for v in 1..<65536 where partial.contains(where: { $0[v] }) {
                let id = UInt16(v)
                if id != ignore && id != ClassID.ignore { ids.insert(id) }
            }
            return ids
        }
    }

    // MARK: Accessors

    public var classes: [SegmentClass] { metadata.classes }
    public var classIDs: [UInt16] { metadata.classIDs }
    public var annotatedClassIDs: [UInt16] { metadata.annotatedClassIDs }
    public var ignoreValue: UInt16 { metadata.ignoreValue }
    public var layerCount: Int { layers.count }
    /// For each layer, the ids of `classIDs` it holds: with `layers`,
    /// `classIDs`, `annotatedClassIDs` and `ignoreValue`, what the format
    /// layer writes back as a segmentation (`m5_writer_add_segmentation`).
    public var layerClassIDs: [[UInt16]] { metadata.layerClassIDs }

    public func classInfo(_ id: UInt16) -> SegmentClass? { metadata.classInfo(id) }

    /// The layer a class lives in, or nil when it is not in the table.
    public func layer(of classID: UInt16) -> Int? {
        let l = layerTable[Int(classID)]
        return l < 0 ? nil : Int(l)
    }

    public func isLocked(_ classID: UInt16) -> Bool { lockedTable[Int(classID)] }

    /// Linear index of a padded voxel.
    @inline(__always)
    public func linearIndex(_ k: SIMD3<Int>) -> Int { (k.x * shape.y + k.y) * shape.z + k.z }

    /// The padded voxel of a linear index.
    @inline(__always)
    public func voxel(atLinearIndex i: Int) -> SIMD3<Int> {
        let row = i / shape.z
        return SIMD3(row / shape.y, row % shape.y, i % shape.z)
    }

    public func isInside(_ k: SIMD3<Int>) -> Bool { all(k .>= 0) && all(k .< shape) }

    /// Raw pointer to a layer's values (valid while the layer exists; do not
    /// write through it — edits go through `apply`).
    public func values(ofLayer layer: Int) -> UnsafePointer<UInt16> {
        UnsafePointer(layers[layer].pointer(as: UInt16.self))
    }

    // MARK: Applying edits

    /// Applies an edit computed on this model's current state.
    public func apply(_ edit: VoxelEdit) {
        perform(edit, forward: true)
    }

    /// Undoes an edit this model's current state is the result of.
    public func revert(_ edit: VoxelEdit) {
        perform(edit, forward: false)
    }

    /// Whether `edit` applies to the current state: same grid, current
    /// metadata equal to the edit's `before`, and every changed voxel holding
    /// the edit's old value. Cheap enough to call before applying an edit
    /// computed in the background.
    public func canApply(_ edit: VoxelEdit) -> Bool { check(edit, forward: true) }

    /// Whether `edit` can be reverted from the current state.
    public func canRevert(_ edit: VoxelEdit) -> Bool { check(edit, forward: false) }

    private func check(_ edit: VoxelEdit, forward: Bool) -> Bool {
        guard edit.shape == shape else { return false }
        if let m = edit.metadataChange, (forward ? m.before : m.after) != metadata { return false }
        let available = forward ? max(layers.count, edit.metadataChange?.after.layerCount ?? 0) : layers.count
        for c in edit.layerChanges {
            guard c.layer < available else { return false }
            if c.layer >= layers.count { continue } // a layer the edit creates starts at zero
            if !c.matches(layers[c.layer].pointer(as: UInt16.self), forward: forward) { return false }
        }
        return true
    }

    private func perform(_ edit: VoxelEdit, forward: Bool) {
        precondition(edit.shape == shape, "the edit was made for another grid")
        let target = forward ? edit.metadataChange?.after : edit.metadataChange?.before
        if let t = target, t.layerCount > layers.count {
            while layers.count < t.layerCount {
                layers.append(VolumeData(scalarType: .uint16, shape: geometry.spatialShape))
            }
            dirty.layersChanged = true
        }
        for c in edit.layerChanges {
            precondition(c.layer < layers.count, "the edit changes layer \(c.layer) of \(layers.count)")
            c.write(into: layers[c.layer].pointer(as: UInt16.self), forward: forward)
            dirty.add(c.bounds, layer: c.layer)
        }
        if let t = target {
            if t.layerCount < layers.count {
                layers.removeLast(layers.count - t.layerCount)
                dirty.layersChanged = true
            }
            metadata = t
            dirty.classTableChanged = true
        }
        revision &+= 1
        didChange?()
    }

    /// Writes changes recorded by a brush stroke straight into the layers
    /// (the stroke keeps the originals and produces the undoable edit).
    func applyLive(_ edit: VoxelEdit) {
        perform(edit, forward: true)
    }

    // MARK: Rendering

    /// What changed since the last call: dirty boxes per layer, whether the
    /// layer count or the class table changed. Call on the main thread before
    /// drawing; upload the boxes of each layer.
    public func takeRenderUpdate() -> RenderUpdate {
        let u = RenderUpdate(revision: revision, regions: dirty.boxes,
                             layersChanged: dirty.layersChanged, classTableChanged: dirty.classTableChanged)
        dirty = DirtyTracker()
        return u
    }

    /// Whether anything changed since the last `takeRenderUpdate()`.
    public var hasPendingRenderUpdate: Bool {
        !dirty.boxes.isEmpty || dirty.layersChanged || dirty.classTableChanged
    }

    /// Marks every layer wholly dirty (after the renderer lost its textures).
    public func markAllDirty() {
        for l in 0..<layers.count { dirty.add(VoxelBox(shape: shape), layer: l) }
        dirty.layersChanged = true
        dirty.classTableChanged = true
    }

    /// Records dirty boxes for changes written outside `perform`.
    func markDirty(_ box: VoxelBox, layer: Int) { dirty.add(box, layer: layer) }

    /// A colour table for the renderer: 65536 entries indexed by class id,
    /// premultiplied by nothing, with alpha 0 for background, ignore, hidden
    /// classes and ids outside the table (the ignore region gets
    /// `ignoreColor` when given).
    public func colorTable(ignoreColor: RGBA8? = nil) -> [RGBA8] {
        var t = [RGBA8](repeating: RGBA8(0, 0, 0, 0), count: 65536)
        for c in metadata.classes where c.isVisible { t[Int(c.id)] = c.color }
        if let ignoreColor { t[Int(metadata.ignoreValue)] = ignoreColor }
        return t
    }
}

/// What a renderer must re-upload after edits.
///
/// A layer is C-contiguous `uint16` of padded shape `(n0, n1, n2)` — a 3-D
/// texture of width `n2`, height `n1`, depth `n0`. A dirty box uploads
/// straight from the layer, without a copy:
///
/// ```swift
/// let base = model.values(ofLayer: l) + model.linearIndex(box.lower)
/// texture.replace(region: MTLRegionMake3D(box.lower.z, box.lower.y, box.lower.x,
///                                         box.size.z, box.size.y, box.size.x),
///                 mipmapLevel: 0, slice: 0, withBytes: base,
///                 bytesPerRow: n2 * 2, bytesPerImage: n1 * n2 * 2)
/// ```
public struct RenderUpdate: Sendable {
    /// The model revision this update brings the renderer to.
    public var revision: UInt64
    /// Changed boxes per layer index (a few boxes per layer, merged).
    public var regions: [Int: [VoxelBox]]
    /// The number of layers changed: recreate the layer textures.
    public var layersChanged: Bool
    /// Classes, colours, visibility or coverage changed: rebuild lookup tables.
    public var classTableChanged: Bool

    public var isEmpty: Bool { regions.isEmpty && !layersChanged && !classTableChanged }
}

/// Dirty boxes per layer, merged so that each layer keeps a few boxes.
struct DirtyTracker {
    static let maxBoxesPerLayer = 8

    var boxes: [Int: [VoxelBox]] = [:]
    var layersChanged = false
    var classTableChanged = false

    mutating func add(_ box: VoxelBox, layer: Int) {
        guard !box.isEmpty else { return }
        var list = boxes[layer] ?? []
        var b = box
        // Absorb boxes that overlap, touch, or whose union wastes little.
        var merged = true
        while merged {
            merged = false
            for (i, e) in list.enumerated() {
                let u = e.union(b)
                if e.expanded(by: 1).intersects(b) || u.voxelCount <= (e.voxelCount + b.voxelCount) * 5 / 4 {
                    b = u
                    list.remove(at: i)
                    merged = true
                    break
                }
            }
        }
        list.append(b)
        if list.count > DirtyTracker.maxBoxesPerLayer {
            // Merge the pair whose union grows least.
            var best = (0, 1, Int.max)
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let growth = list[i].union(list[j]).voxelCount - list[i].voxelCount - list[j].voxelCount
                    if growth < best.2 { best = (i, j, growth) }
                }
            }
            let u = list[best.0].union(list[best.1])
            list.remove(at: best.1)
            list[best.0] = u
        }
        boxes[layer] = list
    }
}
