import Foundation
import MedH5Bridge
import MedH5Core
import simd

/// An open medh5 sample, read through the engine.
///
/// The class is thread-safe: calls may come from several threads at once
/// (the engine's sample is read-only; HDF5 is serialised by the engine), and
/// `close()` waits for calls in flight. Calls block; the `async` variants
/// run them off the cooperative thread pool and cancel through the bridge's
/// progress callbacks. After `close()` every call throws.
public final class SampleFile: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = HandleLock()

    /// Where the sample was opened from.
    public let url: URL
    /// The member name, for a sample of a `.medh5c` collection.
    public let member: String?
    /// Everything the sample holds but voxels, read once at open.
    public let summary: SampleSummary

    private init(handle: OpaquePointer, url: URL, member: String?) throws {
        self.handle = handle
        self.url = url
        self.member = member
        do {
            summary = try SampleSummary(json: callJSON { m5_sample_summary(handle, $0) })
        } catch {
            m5_sample_close(handle)
            throw error
        }
    }

    deinit {
        if let handle { m5_sample_close(handle) }
    }

    /// Open a `.medh5` file, read-only. A file of a later minor version
    /// opens as a projection (`summary.support`).
    public static func open(_ url: URL) throws -> SampleFile {
        var handle: OpaquePointer?
        try check(m5_sample_open(url.path, &handle))
        return try SampleFile(handle: handle!, url: url, member: nil)
    }

    /// Open one member of a `.medh5c` collection.
    public static func open(collection url: URL, member: String) throws -> SampleFile {
        var handle: OpaquePointer?
        try check(m5_sample_open_member(url.path, member, &handle))
        return try SampleFile(handle: handle!, url: url, member: member)
    }

    /// Close the file and everything read from it. Idempotent; waits for
    /// calls in flight.
    public func close() {
        lock.exclusive {
            if let handle { m5_sample_close(handle) }
            handle = nil
        }
    }

    public var isOpen: Bool { lock.shared { handle != nil } }

    /// Run `body` with the open handle.
    private func withHandle<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        try lock.shared {
            guard let handle else { throw MedH5Error.closed }
            return try body(handle)
        }
    }

    // MARK: Document and integrity

    /// `/meta` exactly as stored.
    public func documentText() throws -> String {
        try withHandle { h in try callString { m5_sample_document(h, $0) } }
    }

    /// `/meta`, parsed: serialising it with `JSONFormat.meta` gives back
    /// the stored bytes.
    public func document() throws -> JSONValue {
        try JSONValue.parse(documentText())
    }

    /// Verify every object digest and the `content_id` (§13).
    public func verify() throws -> VerifyReport {
        try withHandle { h in try callJSON { m5_sample_verify(h, $0) }.decode(VerifyReport.self) }
    }

    /// The raw HDF5 attributes of a group or dataset (`"images/CT"`,
    /// `"annotations/organs/data"`, `"/"`), for an inspector.
    public func attributes(of objectPath: String) throws -> JSONObject {
        try withHandle { h in
            try callJSON { m5_sample_attributes(h, objectPath, $0) }.objectValue ?? JSONObject()
        }
    }

    // MARK: Images

    /// Read an image (or a region of it) into a new volume, in slabs along
    /// axis 0, straight into its memory.
    ///
    /// - Parameters:
    ///   - level: the pyramid level (0 = full resolution).
    ///   - region: `[start, stop)` per axis of the image, or of its spatial
    ///     axes only (the leading channel/time axes are then whole).
    ///   - physical: apply `rescale_slope`/`rescale_intercept` (§4.2).
    ///   - type: the element type wanted; `nil` keeps the stored type, or
    ///     `float32` when `physical`.
    public func readImage(
        _ id: String,
        level: Int = 0,
        region: ArrayRegion? = nil,
        physical: Bool = false,
        as type: ScalarType? = nil,
        progress: ProgressHandler? = nil
    ) throws -> VolumeData {
        guard let info = summary.image(id) else {
            throw MedH5Error(status: .failed, kind: "key", message: "no image \(id) in the sample")
        }
        let stored = info.scalarType ?? .float32
        let out = type ?? (physical ? .float32 : stored)
        var shape = info.shape
        if level > 0, let grids = info.gridLevels, grids.indices.contains(level), let g = summary.grid(grids[level]) {
            shape = g.shape
        }
        if let region { shape = region.outputShape(for: shape) }
        let volume = VolumeData(scalarType: out, shape: shape)
        try withHandle { h in
            try withRegion(region) { start, stop, ndim in
                try withProgress(progress) { callback, context in
                    try volume.withUnsafeMutableRawBufferPointer { buffer in
                        try check(m5_image_read(h, id, UInt32(level), start, stop, ndim, physical, out.rawValue,
                                                buffer.baseAddress, buffer.count, callback, context))
                    }
                }
            }
        }
        return volume
    }

    /// An image ready to display: raw values (rescale applied by the
    /// renderer) in a type a texture holds (`ScalarType.gpuCompatible`), its
    /// grid and its stored window presets.
    public func loadImage(_ id: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ImageVolume {
        guard let info = summary.image(id), let geometry = summary.grid(info.grid) else {
            throw MedH5Error(status: .failed, kind: "key", message: "no image \(id) in the sample")
        }
        let type = (info.scalarType ?? .float32).gpuCompatible
        let data = try await runBlocking { flag in
            try self.readImage(id, as: type, progress: cancellable(flag, progress))
        }
        return ImageVolume(
            id: id, data: data, geometry: geometry, rescaleSlope: info.rescaleSlope,
            rescaleIntercept: info.rescaleIntercept, modality: info.modality, valueType: info.valueType,
            valueUnits: info.valueUnits, channelNames: info.channelNames, windowPresets: info.windowPresets)
    }

    /// `readImage` off the calling task's thread, cancelled with the task;
    /// `progress` receives the fraction read.
    public func loadImageData(
        _ id: String,
        level: Int = 0,
        region: ArrayRegion? = nil,
        physical: Bool = false,
        as type: ScalarType? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VolumeData {
        try await runBlocking { flag in
            try self.readImage(id, level: level, region: region, physical: physical, as: type,
                               progress: cancellable(flag, progress))
        }
    }

    /// `readLayer` off the calling task's thread, cancelled with the task.
    public func loadLayer(_ id: String, layer: Int, region: ArrayRegion? = nil,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> VolumeData {
        try await runBlocking { flag in
            try self.readLayer(id, layer: layer, region: region, progress: cancellable(flag, progress))
        }
    }

    // MARK: Voxel annotations

    /// How a voxel annotation's classes split into mutually exclusive
    /// `uint16` layers, for any encoding (computed once per annotation).
    public func layerPlan(_ id: String) throws -> LayerPlan {
        try withHandle { h in try callJSON { m5_annotation_layer_plan(h, id, $0) }.decode(LayerPlan.self) }
    }

    /// One layer of the plan: `uint16` class ids over the grid's spatial
    /// shape (or `region`), `0` background, the ignore id where held in band.
    public func readLayer(_ id: String, layer: Int, region: ArrayRegion? = nil, progress: ProgressHandler? = nil) throws -> VolumeData {
        let plan = try layerPlan(id)
        let shape = region?.shape ?? plan.spatialShape
        let volume = VolumeData(scalarType: .uint16, shape: shape)
        try withHandle { h in
            try withRegion(region) { start, stop, ndim in
                try withProgress(progress) { callback, context in
                    try volume.withUnsafeMutableBufferPointer(as: UInt16.self) { buffer in
                        try check(m5_annotation_read_layer(h, id, UInt32(layer), start, stop, ndim,
                                                           buffer.baseAddress, buffer.count, callback, context))
                    }
                }
            }
        }
        return volume
    }

    /// A segmentation as the editor holds it: every layer, the plan, the
    /// grid, the classes and the ignore region.
    public func loadSegmentation(_ id: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> SegmentationData {
        guard let info = summary.annotation(id), let gridID = info.grid, let geometry = summary.grid(gridID) else {
            throw MedH5Error(status: .failed, kind: "key", message: "no voxel annotation \(id) on a grid of the sample")
        }
        let labelSet = summary.labelSet
        return try await runBlocking { flag in
            let plan = try self.layerPlan(id)
            let n = max(1, plan.layers.count)
            var layers: [VolumeData] = []
            for layer in plan.layers.indices {
                let base = Double(layer) / Double(n)
                layers.append(try self.readLayer(id, layer: layer, progress: cancellable(flag, progress.map { report in
                    { @Sendable fraction in report(base + fraction / Double(n)) }
                })))
            }
            // In band, the layers hold the ignore region; a sibling mask is read.
            let ignore: VolumeData? = plan.ignoreMask != nil ? try self.readMask(id, ignoreRegion: true) : nil
            return SegmentationData(
                info: info, plan: plan, layers: layers, geometry: geometry.spatialOnly,
                classes: plan.classIDs.map { labelSet?.labelClass(id: $0) ?? LabelClassInfo.unnamed($0) },
                ignoreRegion: ignore)
        }
    }

    /// A `mask` annotation, or (with `ignoreRegion`) the ignore region of any
    /// voxel annotation, as 0/1 bytes over the grid's spatial shape.
    public func readMask(_ id: String, ignoreRegion: Bool = false, region: ArrayRegion? = nil) throws -> VolumeData {
        let shape = try region?.shape ?? spatialShape(of: id)
        let volume = VolumeData(scalarType: .uint8, shape: shape)
        try withHandle { h in
            try withRegion(region) { start, stop, ndim in
                try volume.withUnsafeMutableBufferPointer(as: UInt8.self) { buffer in
                    try check(m5_annotation_read_mask(h, id, ignoreRegion, start, stop, ndim, buffer.baseAddress, buffer.count))
                }
            }
        }
        return volume
    }

    /// One class of a probmap as `float32` probabilities.
    public func readProbability(_ id: String, classID: Int, region: ArrayRegion? = nil) throws -> VolumeData {
        let shape = try region?.shape ?? spatialShape(of: id)
        let volume = VolumeData(scalarType: .float32, shape: shape)
        try withHandle { h in
            try withRegion(region) { start, stop, ndim in
                try volume.withUnsafeMutableBufferPointer(as: Float.self) { buffer in
                    try check(m5_annotation_read_probability(h, id, UInt32(classID), start, stop, ndim,
                                                             buffer.baseAddress, buffer.count))
                }
            }
        }
        return volume
    }

    /// The objects of an `instances` (or `boxes`) annotation.
    public func instances(_ id: String) throws -> [InstanceInfo] {
        let list = try withHandle { h in try callJSON { m5_annotation_instances(h, id, $0) } }
        return (list.arrayValue ?? []).map { o in
            InstanceInfo(
                index: o["index"]?.intValue ?? 0,
                instanceID: o["instance_id"].flatMap { v -> UInt64? in
                    if case .uint(let u) = v { return u }
                    return v.intValue.map { UInt64($0) }
                } ?? 0,
                classID: o["class_id"]?.intValue ?? 0,
                bbox: [AxisInterval](json: o["bbox"]) ?? [],
                voxelCount: UInt64(o["voxel_count"]?.doubleValue ?? 0),
                score: o["score"]?.doubleValue,
                hasMask: o["has_mask"]?.boolValue ?? false)
        }
    }

    /// An `instances` annotation as one `uint32` map: `1 +` the index (in
    /// `instances` order) of the last object covering a voxel, `0` for none.
    public func readInstanceMap(_ id: String, region: ArrayRegion? = nil) throws -> VolumeData {
        let shape = try region?.shape ?? spatialShape(of: id)
        let volume = VolumeData(scalarType: .uint32, shape: shape)
        try withHandle { h in
            try withRegion(region) { start, stop, ndim in
                try volume.withUnsafeMutableBufferPointer(as: UInt32.self) { buffer in
                    try check(m5_annotation_read_instance_map(h, id, start, stop, ndim, buffer.baseAddress, buffer.count))
                }
            }
        }
        return volume
    }

    /// Voxels and box of every class of a voxel annotation.
    public func classStats(_ id: String) throws -> [Int: AnnotationClassStats] {
        let stats = try withHandle { h in try callJSON { m5_annotation_class_stats(h, id, $0) } }
        var out: [Int: AnnotationClassStats] = [:]
        for (key, value) in stats.objectValue ?? JSONObject() {
            guard let classID = Int(key) else { continue }
            out[classID] = AnnotationClassStats(classID: classID, voxels: UInt64(value["voxels"]?.doubleValue ?? 0),
                                           bbox: [AxisInterval](json: value["bbox"]))
        }
        return out
    }

    private func spatialShape(of id: String) throws -> [Int] {
        guard let grid = summary.annotation(id)?.grid.flatMap({ summary.grid($0) }) else {
            throw MedH5Error(status: .failed, kind: "key", message: "no voxel annotation \(id) on a grid of the sample")
        }
        return grid.spatialShape
    }

    // MARK: Geometric annotations

    /// A geometric or classification annotation, its arrays as stored and
    /// in world.
    public func geometry(_ id: String) throws -> GeometricAnnotation {
        try withHandle { h in
            var bundle: OpaquePointer?
            try check(m5_annotation_geometry(h, id, &bundle))
            return try GeometricAnnotation(bundle: BundleContents(taking: bundle))
        }
    }

    // MARK: Transforms

    /// A stored transform and its parameters.
    public func transform(_ id: String) throws -> StoredTransform {
        try withHandle { h in
            var bundle: OpaquePointer?
            try check(m5_transform_read(h, id, &bundle))
            let contents = try BundleContents(taking: bundle)
            let info = try contents.header.decode(TransformInfo.self)
            var stored = StoredTransform(info: info)
            if let m = contents.arrays["matrix"] {
                let n = m.shape.first ?? 0
                let flat = m.doubles
                let rows = (0..<n).map { r in Array(flat[r * n..<(r + 1) * n]) }
                stored.storedMatrix = rows
                stored.matrix = simd_double4x4(rowMajorHomogeneous: rows)
            }
            stored.field = contents.arrays["field"]?.data
            stored.controlPoints = contents.arrays["control_points"]?.data
            return stored
        }
    }

    /// The transform taking points of `from` to points of `to` (`x_to =
    /// T(x_from)`, §10.2); a key is a timepoint, a grid or a frame uid.
    ///
    /// Returns `nil` when no transform relates the two (alignment is never
    /// assumed, §3.4: do not overlay). When they share a frame the mapping
    /// is the identity (`isIdentity`). A linear transform is a matrix; any
    /// other is sampled as a displacement field on `fieldGrid` (a grid in
    /// the `from` frame, typically the view's reference grid) every `step`
    /// voxels, or left `.unsampled` without one.
    public func resolveTransform(from: String, to: String, fieldGrid: String? = nil, step: Int = 1) throws -> ResolvedTransform? {
        try withHandle { h in
            var bundle: OpaquePointer?
            try withOptionalCString(fieldGrid) { grid in
                try check(m5_transform_resolve(h, from, to, grid, UInt32(clamping: max(1, step)), &bundle))
            }
            let contents = try BundleContents(taking: bundle)
            let header = contents.header
            if header["found"]?.boolValue != true {
                guard header["same_frame"]?.boolValue == true else { return nil }
                return ResolvedTransform(isIdentity: true, kind: "identity", fromFrame: nil, toFrame: nil, units: nil,
                                         path: [], inverted: [], mapping: .matrix(matrix_identity_double4x4))
            }
            let mapping: ResolvedTransform.Mapping
            if let m = contents.arrays["matrix"] {
                let flat = m.doubles
                mapping = .matrix(simd_double4x4(rowMajorHomogeneous: (0..<4).map { Array(flat[$0 * 4..<$0 * 4 + 4]) })!)
            } else if let field = contents.arrays["displacement"], let grid = header["field_grid"] {
                mapping = .field(displacement: field.data, grid: try grid.decode(GridGeometry.self))
            } else {
                mapping = .unsampled
            }
            return ResolvedTransform(
                isIdentity: false, kind: header["kind"]?.stringValue, fromFrame: header["from_frame"]?.stringValue,
                toFrame: header["to_frame"]?.stringValue, units: header["units"]?.stringValue,
                path: header["path"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                inverted: header["inverted"]?.arrayValue?.compactMap(\.boolValue) ?? [], mapping: mapping)
        }
    }

    // MARK: Clinical history

    /// The clinical history (format 1.1), `nil` when the sample has none.
    public func clinicalRecords() throws -> ClinicalRecords? {
        let json = try withHandle { h in try callJSON { m5_clinical_records(h, $0) } }
        guard json["present"]?.boolValue == true else { return nil }
        return try json.decode(ClinicalRecords.self)
    }

    /// One document's text, read now.
    public func clinicalDocumentText(_ documentID: String) throws -> String {
        try withHandle { h in try callString { m5_clinical_document_text(h, documentID, $0) } }
    }

    /// What was known `cutoffHours` after the clock's origin (strict
    /// prospective selection, 1.1 §9, unless `policy` says otherwise).
    public func clinicalSelect(cutoffHours: Double, policy: JSONValue? = nil) throws -> ClinicalSelection {
        var query: JSONObject = ["cutoff_hours": .double(cutoffHours)]
        if let policy { query["policy"] = policy }
        return try clinicalSelect(query: .object(query))
    }

    /// The same, at a cutoff in microseconds of the subject clock.
    public func clinicalSelect(cutoffMicroseconds: Int64, policy: JSONValue? = nil) throws -> ClinicalSelection {
        var query: JSONObject = ["cutoff_us": .int(cutoffMicroseconds)]
        if let policy { query["policy"] = policy }
        return try clinicalSelect(query: .object(query))
    }

    private func clinicalSelect(query: JSONValue) throws -> ClinicalSelection {
        try withHandle { h in
            try callJSON { m5_clinical_select(h, query.serialized(), $0) }.decode(ClinicalSelection.self)
        }
    }
}

/// A segmentation as the editor holds it (spec §7.2): mutually exclusive
/// `uint16` layers over the grid's spatial shape.
public struct SegmentationData: @unchecked Sendable {
    public var info: AnnotationInfo
    public var plan: LayerPlan
    /// One volume per layer of the plan.
    public var layers: [VolumeData]
    /// The grid's spatial geometry.
    public var geometry: GridGeometry
    /// The classes the annotation can express, in `class_ids` order.
    public var classes: [LabelClassInfo]
    /// The ignore region (0/1), when a `mask` holds it rather than the
    /// layers (`plan.ignoreInBand`).
    public var ignoreRegion: VolumeData?

    /// What it can express, and what was looked for: kept apart through
    /// every edit (§6.2, §11.3).
    public var classIDs: [Int] { plan.classIDs }
    public var annotatedClassIDs: [Int] { plan.annotatedClassIDs }
    public var ignoreID: Int { plan.ignoreID }
}

extension LabelClassInfo {
    /// A class the label set does not name.
    static func unnamed(_ id: Int) -> LabelClassInfo {
        // Decoding is the one initializer; a class needs an id, key and name.
        try! JSONValue.object(["id": .int(Int64(id)), "key": .string(String(id)), "name": .string("Class \(id)")])
            .decode(LabelClassInfo.self)
    }
}
