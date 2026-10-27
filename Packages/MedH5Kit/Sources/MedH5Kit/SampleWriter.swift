import Foundation
import MedH5Bridge
import MedH5Core
import simd

/// Which classes an annotation's annotator looked for (§11.3).
public enum AnnotatedClasses: Sendable, Hashable {
    /// Every class the annotation can express (`class_ids`).
    case given
    /// Every class of the label set.
    case all
    /// The classes with at least one voxel (segmentations).
    case present
    /// Exactly these ids.
    case classes([Int])
    /// Exactly these label-set keys.
    case keys([String])

    var json: JSONValue {
        switch self {
        case .given: return "given"
        case .all: return "all"
        case .present: return "present"
        case .classes(let ids): return .ints(ids)
        case .keys(let keys): return .strings(keys)
        }
    }
}

/// A quality record an object names: an existing key, or a record to file
/// under the object's id.
public enum QualityReference: Sendable, Hashable {
    case key(String)
    case record(JSONObject)

    var json: JSONValue {
        switch self {
        case .key(let k): return .string(k)
        case .record(let r): return .object(r)
        }
    }
}

/// Options of `SampleWriter.create`.
public struct WriterOptions: Sendable, Hashable {
    public var sampleID: String?
    public var subjectID: String?
    /// The codec profile: `balanced`, `fast`, `training`, `archive`,
    /// `portable`.
    public var codec: String
    public var profiles: [String]

    public init(sampleID: String? = nil, subjectID: String? = nil, codec: String = "balanced", profiles: [String] = []) {
        self.sampleID = sampleID
        self.subjectID = subjectID
        self.codec = codec
        self.profiles = profiles
    }

    var json: JSONValue {
        ["sample_id": sampleID.map(JSONValue.string) ?? .null, "subject_id": subjectID.map(JSONValue.string) ?? .null,
         "codec": .string(codec), "profiles": .strings(profiles)]
    }
}

/// Options of `SampleWriter.addImage`.
public struct ImageWriteOptions: Sendable, Hashable {
    public var modality: String
    public var valueType: String?
    public var valueUnits: String?
    public var rescaleSlope: Double?
    public var rescaleIntercept: Double?
    public var windowCenter: [Double]?
    public var windowWidth: [Double]?
    public var channelNames: [String]?
    public var validMask: String?
    public var prov: String?
    public var codec: String?
    /// Acquisition parameters (§4.5), merged into the document.
    public var acquisition: JSONObject?

    public init(modality: String = "OT", valueType: String? = nil, valueUnits: String? = nil,
                rescaleSlope: Double? = nil, rescaleIntercept: Double? = nil,
                windowCenter: [Double]? = nil, windowWidth: [Double]? = nil, channelNames: [String]? = nil,
                validMask: String? = nil, prov: String? = nil, codec: String? = nil, acquisition: JSONObject? = nil) {
        self.modality = modality
        self.valueType = valueType
        self.valueUnits = valueUnits
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.channelNames = channelNames
        self.validMask = validMask
        self.prov = prov
        self.codec = codec
        self.acquisition = acquisition
    }

    var json: JSONValue {
        var o: JSONObject = ["modality": .string(modality)]
        o["value_type"] = valueType.map(JSONValue.string)
        o["value_units"] = valueUnits.map(JSONValue.string)
        o["rescale_slope"] = rescaleSlope.map(JSONValue.double)
        o["rescale_intercept"] = rescaleIntercept.map(JSONValue.double)
        o["window_center"] = windowCenter.map(JSONValue.doubles)
        o["window_width"] = windowWidth.map(JSONValue.doubles)
        o["channel_names"] = channelNames.map(JSONValue.strings)
        o["valid_mask"] = validMask.map(JSONValue.string)
        o["prov"] = prov.map(JSONValue.string)
        o["codec"] = codec.map(JSONValue.string)
        o["acquisition"] = acquisition.map(JSONValue.object)
        return .object(o)
    }
}

/// What every annotation writer takes.
public struct AnnotationWriteOptions: Sendable, Hashable {
    public var annotatedClasses: AnnotatedClasses?
    /// `explicit` (the default) or `implicit` (§5.4).
    public var closure: String?
    public var timepoints: [String]?
    public var prov: String?
    public var quality: QualityReference?
    /// Annotations it was derived from.
    public var derivedFrom: [String]?
    public var task: String?
    public var codec: String?

    public init(annotatedClasses: AnnotatedClasses? = nil, closure: String? = nil, timepoints: [String]? = nil,
                prov: String? = nil, quality: QualityReference? = nil, derivedFrom: [String]? = nil,
                task: String? = nil, codec: String? = nil) {
        self.annotatedClasses = annotatedClasses
        self.closure = closure
        self.timepoints = timepoints
        self.prov = prov
        self.quality = quality
        self.derivedFrom = derivedFrom
        self.task = task
        self.codec = codec
    }

    var object: JSONObject {
        var o = JSONObject()
        o["annotated_classes"] = annotatedClasses?.json
        o["closure"] = closure.map(JSONValue.string)
        o["timepoints"] = timepoints.map(JSONValue.strings)
        o["prov"] = prov.map(JSONValue.string)
        o["quality"] = quality?.json
        o["derived_from"] = derivedFrom.map(JSONValue.strings)
        o["task"] = task.map(JSONValue.string)
        o["codec"] = codec.map(JSONValue.string)
        return o
    }
}

/// Options of `SampleWriter.addSegmentation`.
public struct SegmentationWriteOptions: Sendable, Hashable {
    /// How it is stored; `nil` lets the engine choose by measuring overlap.
    public enum Encoding: String, Sendable, Hashable {
        case labelmap, layers, bitmask, instances
    }

    /// What it can express; default: the classes present plus the
    /// annotated ones. Pass the annotation's own on a save, so coverage is
    /// never collapsed.
    public var classIDs: [Int]?
    public var common: AnnotationWriteOptions
    public var encoding: Encoding?
    /// Layer values equal to this form the ignore region (§7.7); `nil`
    /// means none is.
    public var ignoreValue: UInt16?
    /// A `mask` annotation, already written, holding the ignore region.
    public var ignoreMask: String?

    public init(classIDs: [Int]? = nil, common: AnnotationWriteOptions = .init(), encoding: Encoding? = nil,
                ignoreValue: UInt16? = ClassID.ignore, ignoreMask: String? = nil) {
        self.classIDs = classIDs
        self.common = common
        self.encoding = encoding
        self.ignoreValue = ignoreValue
        self.ignoreMask = ignoreMask
    }

    /// The options that write back an edited segmentation with the coverage
    /// and header it had.
    public static func preserving(_ info: AnnotationInfo) -> SegmentationWriteOptions {
        SegmentationWriteOptions(
            classIDs: info.classIDs,
            common: AnnotationWriteOptions(
                annotatedClasses: .classes(info.annotatedClassIDs), closure: info.closure,
                timepoints: info.declaredTimepoints, prov: info.prov, quality: info.quality.map(QualityReference.key),
                derivedFrom: info.derivedFrom.isEmpty ? nil : info.derivedFrom, task: info.task),
            encoding: nil, ignoreValue: UInt16(clamping: info.ignoreID), ignoreMask: info.ignoreMask)
    }

    var json: JSONValue {
        var o = common.object
        o["class_ids"] = classIDs.map(JSONValue.ints)
        o["encoding"] = encoding.map { .string($0.rawValue) }
        o["ignore_value"] = ignoreValue.map { .int(Int64($0)) } ?? .null
        o["ignore_mask"] = ignoreMask.map(JSONValue.string)
        return .object(o)
    }
}

/// Where a geometric annotation's coordinates live, and its options.
public struct GeometricWriteOptions: Sendable, Hashable {
    public var grid: String?
    /// `index` (the grid's voxel coordinates) or `world`.
    public var space: String?
    /// The frame of world coordinates (defaults to the grid's).
    public var frameUID: String?
    public var common: AnnotationWriteOptions
    /// One free-form object per item.
    public var attributes: [JSONObject]?
    /// Extra options as the bridge takes them (`names`, `correspondence`,
    /// `skeleton`, a class column given as keys…).
    public var extra: JSONObject

    public init(grid: String? = nil, space: String? = nil, frameUID: String? = nil,
                common: AnnotationWriteOptions = .init(), attributes: [JSONObject]? = nil, extra: JSONObject = [:]) {
        self.grid = grid
        self.space = space
        self.frameUID = frameUID
        self.common = common
        self.attributes = attributes
        self.extra = extra
    }

    var object: JSONObject {
        var o = common.object
        o["grid"] = grid.map(JSONValue.string)
        o["space"] = space.map(JSONValue.string)
        o["frame_uid"] = frameUID.map(JSONValue.string)
        o["attributes"] = attributes.map { .array($0.map(JSONValue.object)) }
        for (k, v) in extra { o[k] = v }
        return o
    }
}

/// One curve handed to `SampleWriter.addPolylines`.
public struct PolylineInput: Sendable {
    public var vertices: [[Double]]
    public var classID: Int
    public var plane: (axis: Int, index: Int)?
    public var instanceID: UInt64?

    public init(vertices: [[Double]], classID: Int, plane: (axis: Int, index: Int)? = nil, instanceID: UInt64? = nil) {
        self.vertices = vertices
        self.classID = classID
        self.plane = plane
        self.instanceID = instanceID
    }
}

/// One polygon handed to `SampleWriter.addContours`.
public struct PolygonInput: Sendable {
    public var vertices: [[Double]]
    public var classID: Int
    public var plane: (axis: Int, index: Int)
    public var isHole: Bool

    public init(vertices: [[Double]], classID: Int, plane: (axis: Int, index: Int) = (-1, 0), isHole: Bool = false) {
        self.vertices = vertices
        self.classID = classID
        self.plane = plane
        self.isHole = isHole
    }
}

/// One classification assertion (§9).
public struct ClassificationAssertion: Sendable, Hashable {
    public var classID: Int
    public var value: Double
    public var scopeID: Int?
    public var scheme: String?
    public var schemeValue: String?

    public init(classID: Int, value: Double, scopeID: Int? = nil, scheme: String? = nil, schemeValue: String? = nil) {
        self.classID = classID
        self.value = value
        self.scopeID = scopeID
        self.scheme = scheme
        self.schemeValue = schemeValue
    }
}

/// Writes a new sample, or amends an existing one copy-on-write (§14.4).
///
/// Every call is checked as the engine checks it; nothing is visible at the
/// destination until `commit`, which validates, digests and replaces it
/// atomically. A writer neither committed nor aborted is aborted when it is
/// released. The class is thread-safe (calls are serialised).
public final class SampleWriter: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    /// Where the commit writes.
    public let url: URL

    private init(handle: OpaquePointer, url: URL) {
        self.handle = handle
        self.url = url
    }

    deinit {
        if let handle { m5_writer_free(handle) }
    }

    /// A new sample at `url`.
    public static func create(url: URL, options: WriterOptions = .init()) throws -> SampleWriter {
        var handle: OpaquePointer?
        try check(m5_writer_create(url.path, options.json.serialized(), &handle))
        return SampleWriter(handle: handle!, url: url)
    }

    /// Amend the sample at `url`, copy-on-write: the result replaces it at
    /// `commit`, or is written to `outURL` (leaving `url` alone).
    ///
    /// `without` names objects about to be removed and written again
    /// (`"annotations/organs"`), or top-level groups (`"clinical"`), so
    /// their old bytes do not reach the result. `codec` defaults to the
    /// file's own family. Close any `SampleFile` reading `url` before the
    /// commit, and reopen it after.
    public static func amend(url: URL, outURL: URL? = nil, without: [String] = [], codec: String? = nil) throws -> SampleWriter {
        var handle: OpaquePointer?
        let options: JSONValue = ["codec": codec.map(JSONValue.string) ?? .null, "without": .strings(without)]
        try withOptionalCString(outURL?.path) { out in
            try check(m5_writer_amend(url.path, out, options.serialized(), &handle))
        }
        return SampleWriter(handle: handle!, url: outURL ?? url)
    }

    private func call<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw MedH5Error.closed }
        return try body(handle)
    }

    // MARK: Commit

    /// Validate, digest and commit atomically; returns the new
    /// `content_id` (`nil` when already committed). With `digests` false
    /// only objects without a digest (those written here) are digested,
    /// which is fast; otherwise every digest is recomputed, and one that no
    /// longer matches its stored bytes is refused (E701).
    @discardableResult
    public func commit(digests: Bool = true) throws -> String? {
        try call { h in
            var id: UnsafeMutablePointer<CChar>?
            try check(m5_writer_commit(h, digests, &id))
            return takeString(id)
        }
    }

    /// Discard everything written; the destination is left as it was.
    public func abort() {
        lock.lock()
        defer { lock.unlock() }
        if let handle { m5_writer_abort(handle) }
    }

    // MARK: Document

    /// The document as the commit will store it.
    public func document() throws -> JSONValue {
        try call { h in try JSONValue.parse(callString { m5_writer_document(h, $0) }) }
    }

    /// Replace the whole document, checked as the engine checks each field.
    public func setDocument(_ document: JSONValue) throws {
        try call { h in try check(m5_writer_set_document(h, document.serialized(.meta))) }
    }

    public func setIdentity(_ fields: JSONObject) throws {
        try call { h in try check(m5_writer_set_identity(h, JSONValue.object(fields).serialized())) }
    }

    public func setCohort(_ fields: JSONObject) throws {
        try call { h in try check(m5_writer_set_cohort(h, JSONValue.object(fields).serialized())) }
    }

    /// Declare a visit; the first one replaces the implicit `tp0`.
    public func addTimepoint(_ id: String, fields: JSONObject = [:]) throws {
        try call { h in try check(m5_writer_add_timepoint(h, id, JSONValue.object(fields).serialized())) }
    }

    /// Set the label set (as the document holds it), or remove it.
    public func setLabelSet(_ labelSet: JSONValue?) throws {
        try call { h in try check(m5_writer_set_label_set(h, (labelSet ?? .null).serialized())) }
    }

    public func setQuality(_ key: String, fields: JSONObject) throws {
        try call { h in try check(m5_writer_set_quality(h, key, JSONValue.object(fields).serialized())) }
    }

    /// Declare an agent (`type`, `name`, optional `id`, …); returns it with
    /// its id.
    @discardableResult
    public func addAgent(_ agent: JSONObject) throws -> JSONValue {
        try call { h in try callJSON { m5_writer_add_agent(h, JSONValue.object(agent).serialized(), $0) } }
    }

    /// Record an activity (`type`, `agent`, `tool`, `inputs`, …); returns it
    /// with its id.
    @discardableResult
    public func addActivity(_ activity: JSONObject) throws -> JSONValue {
        try call { h in try callJSON { m5_writer_add_activity(h, JSONValue.object(activity).serialized(), $0) } }
    }

    /// Set (or, with `.null`, remove) a namespaced extension member.
    public func setExtra(_ namespace: String, _ value: JSONValue) throws {
        try call { h in try check(m5_writer_set_extra(h, namespace, value.serialized())) }
    }

    public func setAcquisition(image: String, _ parameters: JSONObject) throws {
        try call { h in try check(m5_writer_set_acquisition(h, image, JSONValue.object(parameters).serialized())) }
    }

    /// Set (or, with `nil`, remove) the de-identification record.
    public func setDeidentification(_ record: JSONObject?) throws {
        try call { h in try check(m5_writer_set_deidentification(h, record.map(JSONValue.object).map { $0.serialized() } ?? "null")) }
    }

    // MARK: Grids and images

    /// Declare a grid; geometry lives here and nowhere else.
    public func addGrid(_ grid: GridGeometry) throws {
        let json = try JSONValue.encoding(grid).serialized()
        try call { h in try check(m5_writer_add_grid(h, grid.id, json)) }
    }

    public func removeGrid(_ id: String) throws {
        try call { h in try check(m5_writer_remove_grid(h, id)) }
    }

    /// Write an image: `data`'s shape is the grid's (every axis).
    public func addImage(id: String, grid: String, data: VolumeData, options: ImageWriteOptions = .init()) throws {
        let shape = data.shape.map(Int64.init)
        try call { h in
            try shape.withUnsafeBufferPointer { s in
                try data.withUnsafeMutableRawBufferPointer { bytes in
                    try check(m5_writer_add_image(h, id, grid, options.json.serialized(), data.scalarType.rawValue,
                                                  s.baseAddress, UInt32(shape.count), bytes.baseAddress, bytes.count))
                }
            }
        }
    }

    public func removeImage(_ id: String) throws {
        try call { h in try check(m5_writer_remove_image(h, id)) }
    }

    /// Change an image's attributes without rewriting its samples: a key
    /// present sets the attribute (`.null` removes it).
    public func setImageAttributes(_ id: String, _ edit: JSONObject) throws {
        try call { h in try check(m5_writer_set_image_attrs(h, id, JSONValue.object(edit).serialized())) }
    }

    // MARK: Voxel annotations

    /// A segmentation from mutually exclusive `uint16` layers over the grid's
    /// spatial shape: a voxel is in class `c` where some layer holds `c`.
    /// The engine chooses the stored encoding by measuring overlap unless
    /// `options.encoding` names one. Returns what it chose and why.
    @discardableResult
    public func addSegmentation(id: String, grid: String, layers: [VolumeData],
                                options: SegmentationWriteOptions = .init()) throws -> (kind: String, stats: JSONValue?) {
        guard let first = layers.first else {
            throw MedH5Error(status: .argument, kind: "argument", message: "a segmentation needs at least one layer")
        }
        for layer in layers where layer.scalarType != .uint16 || layer.count != first.count {
            throw MedH5Error(status: .argument, kind: "argument", message: "layers are uint16 volumes of one shape")
        }
        let pointers: [UnsafePointer<UInt16>?] = layers.map { UnsafePointer($0.baseAddress.assumingMemoryBound(to: UInt16.self)) }
        let result = try call { h in
            try withExtendedLifetime(layers) {
                try pointers.withUnsafeBufferPointer { p in
                    try callJSON { m5_writer_add_segmentation_ex(h, id, grid, options.json.serialized(), UInt32(layers.count),
                                                                 p.baseAddress, first.count, $0) }
                }
            }
        }
        return (result["kind"]?.stringValue ?? "", result["stats"].flatMap { $0.isNull ? nil : $0 })
    }

    /// A `mask` annotation: nonzero voxels are in it.
    public func addMask(id: String, grid: String, mask: VolumeData, task: String = "other", prov: String? = nil) throws {
        let bytes = mask.scalarType == .uint8 || mask.scalarType == .bool ? mask : mask.converted(to: .uint8)
        let options: JSONValue = ["task": .string(task), "prov": prov.map(JSONValue.string) ?? .null]
        try call { h in
            try bytes.withUnsafeMutableRawBufferPointer { raw in
                try check(m5_writer_add_mask(h, id, grid, options.serialized(),
                                             raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count))
            }
        }
    }

    public func removeAnnotation(_ id: String) throws {
        try call { h in try check(m5_writer_remove_annotation(h, id)) }
    }

    /// Re-encode a voxel annotation (§7.6); refused where the target cannot
    /// express it. `dropIdentity` lets `instances` become dense (recorded).
    public func transcodeAnnotation(_ id: String, to kind: String, dropIdentity: Bool = false) throws {
        try call { h in try check(m5_writer_transcode_annotation(h, id, kind, dropIdentity)) }
    }

    // MARK: Geometric and classification annotations

    /// Any geometric kind (`boxes`, `obb`, `keypoints`, `points`,
    /// `contours`, `polylines`, `mesh`) from arrays named as its stored
    /// datasets (docs/BRIDGE.md).
    public func addGeometric(kind: String, id: String, options: GeometricWriteOptions, arrays: [NamedArray]) throws {
        let json = JSONValue.object(options.object).serialized()
        try call { h in
            try withArrayViews(arrays) { views, count in
                try check(m5_writer_add_geometric(h, kind, id, json, views, count))
            }
        }
    }

    /// Axis-aligned boxes, `[lo, hi]` per spatial axis at voxel edges.
    public func addBoxes(id: String, boxes: [[AxisInterval]], classIDs: [Int], instanceIDs: [UInt64]? = nil,
                         scores: [Double]? = nil, sliceIndex: [Int]? = nil, options: GeometricWriteOptions) throws {
        let s = boxes.first?.count ?? 3
        var arrays = [
            NamedArray("boxes", shape: [boxes.count, s, 2], doubles: boxes.flatMap { $0.flatMap { [$0.lo, $0.hi] } }),
            NamedArray("class_ids", shape: [classIDs.count], ints: classIDs.map(Int64.init)),
        ]
        if let instanceIDs { arrays.append(NamedArray("instance_ids", shape: [instanceIDs.count], unsigned: instanceIDs)) }
        if let scores { arrays.append(NamedArray("scores", shape: [scores.count], doubles: scores)) }
        if let sliceIndex { arrays.append(NamedArray("slice_index", shape: [sliceIndex.count], ints: sliceIndex.map(Int64.init))) }
        try addGeometric(kind: "boxes", id: id, options: options, arrays: arrays)
    }

    /// A point set (`names` and `correspondence` go in `options.extra`).
    public func addPoints(id: String, points: [[Double]], classIDs: [Int]? = nil, weights: [Double]? = nil,
                          options: GeometricWriteOptions) throws {
        let s = points.first?.count ?? 3
        var arrays = [NamedArray("points", shape: [points.count, s], doubles: points.flatMap { $0 })]
        if let classIDs { arrays.append(NamedArray("class_ids", shape: [classIDs.count], ints: classIDs.map(Int64.init))) }
        if let weights { arrays.append(NamedArray("weights", shape: [weights.count], doubles: weights)) }
        try addGeometric(kind: "points", id: id, options: options, arrays: arrays)
    }

    /// Open curves (format 1.2).
    public func addPolylines(id: String, polylines: [PolylineInput], options: GeometricWriteOptions) throws {
        let s = polylines.first?.vertices.first?.count ?? 3
        var offsets: [Int64] = [0]
        for line in polylines { offsets.append(offsets.last! + Int64(line.vertices.count)) }
        var arrays = [
            NamedArray("vertices", shape: [Int(offsets.last!), s], doubles: polylines.flatMap { $0.vertices.flatMap { $0 } }),
            NamedArray("polyline_offsets", shape: [offsets.count], ints: offsets),
            NamedArray("polyline_class_ids", shape: [polylines.count], ints: polylines.map { Int64($0.classID) }),
        ]
        if polylines.contains(where: { $0.plane != nil }) {
            arrays.append(NamedArray("polyline_plane", shape: [polylines.count, 2],
                                     ints: polylines.flatMap { [Int64($0.plane?.axis ?? -1), Int64($0.plane?.index ?? 0)] }))
        }
        if polylines.allSatisfy({ $0.instanceID != nil }) && !polylines.isEmpty {
            arrays.append(NamedArray("instance_ids", shape: [polylines.count], unsigned: polylines.map { $0.instanceID! }))
        }
        try addGeometric(kind: "polylines", id: id, options: options, arrays: arrays)
    }

    /// Planar polygons; a class's polygons combine by depth (§8.6).
    public func addContours(id: String, polygons: [PolygonInput], options: GeometricWriteOptions) throws {
        let s = polygons.first?.vertices.first?.count ?? 3
        var offsets: [Int64] = [0]
        for p in polygons { offsets.append(offsets.last! + Int64(p.vertices.count)) }
        let arrays = [
            NamedArray("vertices", shape: [Int(offsets.last!), s], doubles: polygons.flatMap { $0.vertices.flatMap { $0 } }),
            NamedArray("contour_offsets", shape: [offsets.count], ints: offsets),
            NamedArray("contour_class_ids", shape: [polygons.count], ints: polygons.map { Int64($0.classID) }),
            NamedArray("contour_plane", shape: [polygons.count, 2], ints: polygons.flatMap { [Int64($0.plane.axis), Int64($0.plane.index)] }),
            NamedArray("contour_role", shape: [polygons.count], ints: polygons.map { $0.isHole ? 1 : 0 }),
        ]
        try addGeometric(kind: "contours", id: id, options: options, arrays: arrays)
    }

    /// A triangle surface; `submeshes` split the faces, each of a class.
    public func addMesh(id: String, vertices: [SIMD3<Double>], faces: [SIMD3<Int32>], normals: [SIMD3<Double>]? = nil,
                        submeshes: [(faces: Range<Int>, classID: Int)]? = nil, options: GeometricWriteOptions) throws {
        var arrays = [
            NamedArray("vertices", shape: [vertices.count, 3], doubles: vertices.flatMap { [$0.x, $0.y, $0.z] }),
            NamedArray("faces", shape: [faces.count, 3], ints: faces.flatMap { [Int64($0.x), Int64($0.y), Int64($0.z)] }),
        ]
        if let normals { arrays.append(NamedArray("normals", shape: [normals.count, 3], doubles: normals.flatMap { [$0.x, $0.y, $0.z] })) }
        if let submeshes {
            arrays.append(NamedArray("mesh_offsets", shape: [submeshes.count + 1],
                                     ints: [0] + submeshes.map { Int64($0.faces.upperBound) }))
            arrays.append(NamedArray("mesh_class_ids", shape: [submeshes.count], ints: submeshes.map { Int64($0.classID) }))
        }
        try addGeometric(kind: "mesh", id: id, options: options, arrays: arrays)
    }

    /// A classification annotation (§9).
    public func addClassification(id: String, assertions: [ClassificationAssertion], scope: String = "sample",
                                  multilabel: Bool = false, grid: String? = nil,
                                  options: AnnotationWriteOptions = .init()) throws {
        var o = options.object
        o["scope"] = .string(scope)
        o["multilabel"] = .bool(multilabel)
        o["grid"] = grid.map(JSONValue.string)
        o["assertions"] = .array(assertions.map { a in
            var x: JSONObject = ["class_id": .int(Int64(a.classID)), "value": .double(a.value)]
            x["scope_id"] = a.scopeID.map { .int(Int64($0)) }
            x["scheme"] = a.scheme.map(JSONValue.string)
            x["scheme_value"] = a.schemeValue.map(JSONValue.string)
            return .object(x)
        })
        let json = JSONValue.object(o).serialized()
        try call { h in try check(m5_writer_add_classification(h, id, json)) }
    }

    // MARK: Transforms and index

    /// An affine from `fromFrame` to `toFrame` (`x_to = M x_from`, §10.3).
    public func addAffineTransform(id: String, matrix: simd_double4x4, fromFrame: String, toFrame: String,
                                   options: JSONObject = [:]) throws {
        var o = options
        o["from_frame"] = .string(fromFrame)
        o["to_frame"] = .string(toFrame)
        let rows = matrix.rowMajor.flatMap { $0 }
        let json = JSONValue.object(o).serialized()
        try call { h in
            try rows.withUnsafeBufferPointer { m in try check(m5_writer_add_affine_transform(h, id, json, m.baseAddress, 4)) }
        }
    }

    /// Any transform kind, its parameters as named arrays (`matrix`,
    /// `field`, `control_points`) and options as the bridge takes them.
    public func addTransform(id: String, kind: String, options: JSONObject, arrays: [NamedArray] = []) throws {
        let json = JSONValue.object(options).serialized()
        try call { h in
            try withArrayViews(arrays) { views, count in try check(m5_writer_add_transform(h, id, kind, json, views, count)) }
        }
    }

    public func removeTransform(_ id: String) throws {
        try call { h in try check(m5_writer_remove_transform(h, id)) }
    }

    /// Build the sampling index (§14.3) for `annotations` (all voxel
    /// annotations with classes when `nil`).
    public func buildIndex(annotations: [String]? = nil, maxCoords: Int? = nil, seed: Int = 0) throws {
        var o: JSONObject = ["seed": .int(Int64(seed))]
        o["annotations"] = annotations.map(JSONValue.strings)
        o["max_coords"] = maxCoords.map { .int(Int64($0)) }
        let json = JSONValue.object(o).serialized()
        try call { h in try check(m5_writer_build_index(h, json)) }
    }
}
