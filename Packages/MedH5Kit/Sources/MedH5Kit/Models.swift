import Foundation
import MedH5Core

// The models of the sample summary (docs/BRIDGE.md, "Sample summary").
// Each is decoded from the bridge's JSON with `JSONValue.decode`, so a
// `JSONValue` member holds exactly what the file holds.

/// Everything the viewer shows of a sample without reading voxels.
public struct SampleSummary: Sendable {
    /// Whether this engine reads the file fully, or as the projection of a
    /// later minor version (1.1 §2: read what is known, never amend).
    public enum Support: String, Sendable, Codable {
        case full
        case projection
        case unsupported
    }

    public var path: String
    /// The format version the file declares (`"1.0"`, `"1.1"`, `"1.2"`).
    public var formatVersion: String
    public var support: Support
    public var kind: String
    public var profiles: [String]
    public var contentID: String?
    public var digestAlgorithm: String?
    public var created: String?
    public var generator: String?

    public var identity: Identity
    public var cohort: Cohort?
    public var timepoints: [TimepointInfo]
    public var labelSet: LabelSetInfo?
    public var provenance: Provenance
    /// Quality records by key.
    public var quality: [String: QualityRecord]
    public var splits: [JSONValue]
    /// Acquisition parameters by image id (§4.5).
    public var acquisition: JSONObject
    /// The de-identification record, `nil` when none: the file must then be
    /// treated as potentially identifying.
    public var deidentification: JSONValue?
    /// Namespaced extension members of the document.
    public var extra: JSONObject
    public var isLongitudinal: Bool

    public var grids: [GridGeometry]
    public var images: [ImageInfo]
    public var annotations: [AnnotationInfo]
    public var transforms: [TransformInfo]
    /// Objects the engine could not read, each with its error (a damaged
    /// file still shows what is intact).
    public var unreadable: [UnreadableObject]
    /// Sampling index entries (§14.3).
    public var index: [IndexEntry]
    public var clinical: ClinicalSummary
    /// Objects a later minor's projection leaves out, with why (W913).
    public var leftOut: [String: String]
    /// The summary as the bridge wrote it.
    public var raw: JSONValue

    init(json: JSONValue) throws {
        raw = json
        func string(_ key: String) -> String? { json[key]?.stringValue }
        path = string("path") ?? ""
        formatVersion = string("format_version") ?? ""
        support = Support(rawValue: string("support") ?? "") ?? .unsupported
        kind = string("kind") ?? "sample"
        profiles = try json["profiles"]?.decode([String].self) ?? []
        contentID = string("content_id")
        digestAlgorithm = string("digest_algo")
        created = string("created")
        generator = string("generator")
        identity = try (json["identity"]).flatMap { $0.isNull ? nil : try $0.decode(Identity.self) }
            ?? Identity(sampleID: "", subjectID: "")
        cohort = try json["cohort"].flatMap { $0.isNull ? nil : try $0.decode(Cohort.self) }
        timepoints = try json["timepoints"].flatMap { $0.isNull ? nil : try $0.decode([TimepointInfo].self) } ?? []
        labelSet = try json["label_set"].flatMap { $0.isNull ? nil : try $0.decode(LabelSetInfo.self) }
        provenance = try json["provenance"].flatMap { $0.isNull ? nil : try $0.decode(Provenance.self) } ?? Provenance()
        quality = try json["quality"].flatMap { $0.isNull ? nil : try $0.decode([String: QualityRecord].self) } ?? [:]
        splits = json["splits"]?.arrayValue ?? []
        acquisition = json["acquisition"]?.objectValue ?? JSONObject()
        deidentification = json["deidentification"].flatMap { $0.isNull ? nil : $0 }
        extra = json["extra"]?.objectValue ?? JSONObject()
        isLongitudinal = json["longitudinal"]?.boolValue ?? false
        grids = try json["grids"]?.decode([GridGeometry].self) ?? []
        var unreadable: [UnreadableObject] = []
        func split<T: Decodable>(_ key: String, _ type: T.Type) throws -> [T] {
            var out: [T] = []
            for entry in json[key]?.arrayValue ?? [] {
                if let error = entry["error"], !error.isNull {
                    unreadable.append(UnreadableObject(
                        group: key, id: entry["id"]?.stringValue ?? "",
                        kind: error["kind"]?.stringValue ?? "", code: error["code"]?.stringValue,
                        message: error["message"]?.stringValue ?? ""))
                } else {
                    out.append(try entry.decode(T.self))
                }
            }
            return out
        }
        images = try split("images", ImageInfo.self)
        annotations = try split("annotations", AnnotationInfo.self)
        transforms = try split("transforms", TransformInfo.self)
        self.unreadable = unreadable
        index = try json["index"]?.decode([IndexEntry].self) ?? []
        clinical = try json["clinical"]?.decode(ClinicalSummary.self) ?? ClinicalSummary(present: false)
        leftOut = (json["left_out"]?.objectValue?.entries ?? []).reduce(into: [:]) { $0[$1.key] = $1.value.stringValue ?? "" }
    }

    public func grid(_ id: String) -> GridGeometry? { grids.first { $0.id == id } }
    public func image(_ id: String) -> ImageInfo? { images.first { $0.id == id } }
    public func annotation(_ id: String) -> AnnotationInfo? { annotations.first { $0.id == id } }
    public func transform(_ id: String) -> TransformInfo? { transforms.first { $0.id == id } }
    public func timepoint(_ id: String) -> TimepointInfo? { timepoints.first { $0.id == id } }

    /// The grid an image lies on.
    public func grid(of image: ImageInfo) -> GridGeometry? { grid(image.grid) }

    /// The images of one visit.
    public func images(at timepoint: String) -> [ImageInfo] { images.filter { $0.timepoint == timepoint } }

    /// The annotations of one visit.
    public func annotations(at timepoint: String) -> [AnnotationInfo] {
        annotations.filter { $0.timepoints.contains(timepoint) }
    }

    /// Whether two grids share a frame of reference (so overlay without a
    /// transform).
    public func sharesFrame(_ a: String, _ b: String) -> Bool {
        guard let ga = grid(a), let gb = grid(b) else { return false }
        return ga.sharesFrame(with: gb)
    }
}

/// An object listed in the file that the engine could not read.
public struct UnreadableObject: Sendable, Hashable {
    /// `images`, `annotations` or `transforms`.
    public var group: String
    public var id: String
    public var kind: String
    public var code: String?
    public var message: String
}

/// The subject's identity (§11.1).
public struct Identity: Codable, Sendable, Hashable {
    public var sampleID: String
    public var subjectID: String
    public var sex: String?
    public var laterality: String?
    public var bodypart: String?

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id", subjectID = "subject_id", sex, laterality, bodypart
    }

    public init(sampleID: String, subjectID: String, sex: String? = nil, laterality: String? = nil, bodypart: String? = nil) {
        self.sampleID = sampleID
        self.subjectID = subjectID
        self.sex = sex
        self.laterality = laterality
        self.bodypart = bodypart
    }
}

/// Where the sample comes from (§11.2).
public struct Cohort: Codable, Sendable, Hashable {
    public var datasetID: String?
    public var siteID: String?
    public var scannerID: String?
    public var groupID: String?
    public var acquisitionProtocol: String?

    enum CodingKeys: String, CodingKey {
        case datasetID = "dataset_id", siteID = "site_id", scannerID = "scanner_id", groupID = "group_id"
        case acquisitionProtocol = "acquisition_protocol"
    }
}

/// One visit (§3.7).
public struct TimepointInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var index: Int
    public var label: String?
    public var date: String?
    public var daysFromBaseline: Double?
    public var studyUID: String?
    /// Series UID by image id.
    public var seriesUIDs: [String: String]?
    public var subjectAgeYears: Double?
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case id, index, label, date, description
        case daysFromBaseline = "days_from_baseline", studyUID = "study_uid", seriesUIDs = "series_uids"
        case subjectAgeYears = "subject_age_years"
    }
}

/// An ontology code of a class (§5.2).
public struct OntologyCode: Codable, Sendable, Hashable {
    public var system: String
    public var code: String
    public var name: String?
}

/// One class of the label set (§5.2).
public struct LabelClassInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var key: String
    public var name: String
    /// `is_a` parents (§5.4).
    public var parents: [Int]
    public var category: String?
    public var color: RGBA8?
    public var codes: [OntologyCode]
    public var laterality: String?
    public var properties: JSONObject

    enum CodingKeys: String, CodingKey {
        case id, key, name, parents, category, color, codes, laterality, properties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        parents = try c.decodeIfPresent([Int].self, forKey: .parents) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category)
        color = try c.decodeIfPresent([Int].self, forKey: .color).flatMap { RGBA8(array: $0) }
        codes = try c.decodeIfPresent([OntologyCode].self, forKey: .codes) ?? []
        laterality = try c.decodeIfPresent(String.self, forKey: .laterality)
        properties = try c.decodeIfPresent(JSONObject.self, forKey: .properties) ?? JSONObject()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(name, forKey: .name)
        if !parents.isEmpty { try c.encode(parents, forKey: .parents) }
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(color?.array, forKey: .color)
        if !codes.isEmpty { try c.encode(codes, forKey: .codes) }
        try c.encodeIfPresent(laterality, forKey: .laterality)
        if !properties.isEmpty { try c.encode(JSONValue.object(properties), forKey: .properties) }
    }

    /// The class's colour, or the palette's for its id.
    public var displayColor: RGBA8 { color ?? LabelPalette.color(forClassID: id) }
}

extension JSONObject: Codable {
    public init(from decoder: Decoder) throws {
        guard case .object(let object) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(JSONObject.self, .init(codingPath: decoder.codingPath, debugDescription: "expected an object"))
        }
        self = object
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(self).encode(to: encoder)
    }
}

/// A keypoint topology (§5.5).
public struct Skeleton: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Class ids of the keypoints.
    public var keypoints: [Int]
    /// Pairs of keypoint class ids.
    public var edges: [[Int]]
}

/// The vocabulary the classes come from (§5).
public struct LabelSetInfo: Codable, Sendable, Hashable {
    public var id: String
    public var version: String
    public var form: String?
    public var uri: String?
    public var sha256: String?
    public var classes: [LabelClassInfo]
    public var relations: [JSONValue]
    public var skeletons: [Skeleton]

    enum CodingKeys: String, CodingKey { case id, version, form, uri, sha256, classes, relations, skeletons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        form = try c.decodeIfPresent(String.self, forKey: .form)
        uri = try c.decodeIfPresent(String.self, forKey: .uri)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        classes = try c.decodeIfPresent([LabelClassInfo].self, forKey: .classes) ?? []
        relations = try c.decodeIfPresent([JSONValue].self, forKey: .relations) ?? []
        skeletons = try c.decodeIfPresent([Skeleton].self, forKey: .skeletons) ?? []
    }

    public func labelClass(id: Int) -> LabelClassInfo? { classes.first { $0.id == id } }
    public func labelClass(key: String) -> LabelClassInfo? { classes.first { $0.key == key } }

    /// The classes whose parents include `id`.
    public func children(of id: Int) -> [LabelClassInfo] { classes.filter { $0.parents.contains(id) } }

    /// Every `is_a` ancestor of a class, nearest first.
    public func ancestors(of id: Int) -> [Int] {
        var out: [Int] = []
        var frontier = labelClass(id: id)?.parents ?? []
        while let next = frontier.first {
            frontier.removeFirst()
            if out.contains(next) { continue }
            out.append(next)
            frontier += labelClass(id: next)?.parents ?? []
        }
        return out
    }
}

/// Who and what produced the sample's content (§11.5).
public struct Provenance: Codable, Sendable, Hashable {
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// `person`, `software` or `organization`.
        public var type: String
        public var name: String
        public var role: String?
        public var version: String?
        public var qualification: String?
        public var organization: String?
    }

    public struct Activity: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var type: String
        public var agent: String?
        public var started: String?
        public var ended: String?
        public var tool: String?
        public var inputs: [String]?
        public var outputs: [String]?
        public var params: JSONValue?
    }

    public var agents: [Agent]
    public var activities: [Activity]

    public init(agents: [Agent] = [], activities: [Activity] = []) {
        self.agents = agents
        self.activities = activities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        agents = try c.decodeIfPresent([Agent].self, forKey: AnyKey("agents")) ?? []
        activities = try c.decodeIfPresent([Activity].self, forKey: AnyKey("activities")) ?? []
    }

    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
    public func activity(_ id: String) -> Activity? { activities.first { $0.id == id } }
}

/// How good an annotation is, and who said so (§11.6).
public struct QualityRecord: Codable, Sendable, Hashable {
    /// `draft`, `submitted`, `reviewed`, `approved`, `rejected`, `deprecated`.
    public var status: String
    public var confidence: Double?
    public var reviewedBy: [String]?
    public var agreement: JSONValue?
    public var issues: JSONValue?
    public var editEffortSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case status, confidence, agreement, issues
        case reviewedBy = "reviewed_by", editEffortSeconds = "edit_effort_s"
    }
}

/// An image (§4).
public struct ImageInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var grid: String
    public var timepoint: String?
    public var modality: String
    /// `intensity`, `quantitative`, `rgb`, `probability`, `displacement`, `mask`.
    public var valueType: String
    public var valueUnits: String?
    public var channelNames: [String]?
    public var shape: [Int]
    /// NumPy's name of the stored type.
    public var dtype: String
    public var chunks: [Int]?
    public var levels: Int
    public var multiscale: Bool
    public var gridLevels: [String]?
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    public var rescaled: Bool
    public var windowCenter: [Double]?
    public var windowWidth: [Double]?
    public var validMask: String?
    public var prov: String?
    public var digest: String?
    public var nbytes: Int?
    public var codec: String?
    public var storedBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, grid, timepoint, modality, shape, dtype, chunks, levels, multiscale, rescaled, prov, digest, nbytes, codec
        case valueType = "value_type", valueUnits = "value_units", channelNames = "channel_names"
        case gridLevels = "grid_levels", rescaleSlope = "rescale_slope", rescaleIntercept = "rescale_intercept"
        case windowCenter = "window_center", windowWidth = "window_width", validMask = "valid_mask"
        case storedBytes = "stored_bytes"
    }

    /// The stored element type.
    public var scalarType: ScalarType? { ScalarType(name: dtype) }

    /// The display windows the file stores (`window_center`/`window_width`).
    public var windowPresets: [WindowPreset] {
        guard let centers = windowCenter, let widths = windowWidth else { return [] }
        return zip(centers, widths).enumerated().map { i, pair in
            WindowPreset(name: centers.count == 1 ? "Stored" : "Stored \(i + 1)", center: pair.0, width: pair.1)
        }
    }
}

/// An annotation's header and coverage (§6), and what its kind adds.
public struct AnnotationInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `labelmap`, `layers`, `bitmask`, `instances`, `probmap`, `mask`,
    /// `boxes`, `obb`, `keypoints`, `points`, `contours`, `polylines`,
    /// `mesh` or `classification`.
    public var kind: String
    public var task: String
    public var grid: String?
    /// The visits it pertains to (declared, or its grid's).
    public var timepoints: [String]
    public var declaredTimepoints: [String]?
    public var space: String?
    public var frameUID: String?
    /// What it can express.
    public var classIDs: [Int]
    /// What was looked for: a class here with no voxel was examined and
    /// found absent; a class not here was not examined.
    public var annotatedClassIDs: [Int]
    public var fullyCovered: Bool
    public var closure: String
    public var ignoreID: Int
    public var ignoreMask: String?
    public var prov: String?
    public var quality: String?
    public var derivedFrom: [String]
    public var voxel: Bool
    public var geometric: Bool
    /// The annotation's identity: a digest over its datasets' digests.
    public var digest: String?
    /// Objects of a geometric, classification or instances annotation.
    public var items: Int?
    public var layers: Int?
    public var layerClasses: [[Int]]?
    public var planes: Int?
    public var threshold: Double?
    public var normalized: Bool?
    public var hasMasks: Bool?
    public var instanceIDs: [UInt64]?
    public var skeleton: String?
    public var correspondence: String?
    public var names: [String]?
    public var submeshes: Int?
    public var scope: String?
    public var multilabel: Bool?
    public var scopeIDs: [Int]?
    public var changeLabel: Bool?
    public var shape: [Int]?
    public var dtype: String?
    public var codec: String?
    /// Attributes outside the header.
    public var attributes: JSONObject

    enum CodingKeys: String, CodingKey {
        case id, kind, task, grid, timepoints, space, closure, prov, quality, voxel, geometric, digest, items, layers
        case planes, threshold, normalized, skeleton, correspondence, names, submeshes, scope, multilabel, shape
        case dtype, codec, attributes
        case declaredTimepoints = "declared_timepoints", frameUID = "frame_uid", classIDs = "class_ids"
        case annotatedClassIDs = "annotated_class_ids", fullyCovered = "fully_covered", ignoreID = "ignore_id"
        case ignoreMask = "ignore_mask", derivedFrom = "derived_from", layerClasses = "layer_classes"
        case hasMasks = "has_masks", instanceIDs = "instance_ids", scopeIDs = "scope_ids", changeLabel = "change_label"
    }

    /// Classes it can express and was not examined for.
    public var unexaminedClassIDs: [Int] { classIDs.filter { !annotatedClassIDs.contains($0) } }

    public func isAnnotated(_ classID: Int) -> Bool { annotatedClassIDs.contains(classID) }
}

/// A transform (§10).
public struct TransformInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `identity`, `affine`, `displacement`, `bspline` or `composite`.
    public var kind: String
    public var fromFrame: String
    public var toFrame: String
    public var units: String
    public var timepoints: [String]
    public var invertible: Bool
    public var inverseID: String?
    public var metrics: String?
    public var prov: String?
    public var fromGrid: String?
    public var toGrid: String?
    public var jacobianDeterminant: Double?
    public var fieldGrid: String?
    public var vectorSpace: String?
    public var interpolation: String?
    public var extrapolation: String?
    public var fieldShape: [Int]?
    public var fieldDtype: String?
    public var cpGrid: String?
    public var order: Int?
    public var components: [String]?
    public var chainOK: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, units, timepoints, invertible, metrics, prov, interpolation, extrapolation, order, components
        case fromFrame = "from_frame", toFrame = "to_frame", inverseID = "inverse_id", fromGrid = "from_grid"
        case toGrid = "to_grid", jacobianDeterminant = "jacobian_determinant", fieldGrid = "field_grid"
        case vectorSpace = "vector_space", fieldShape = "field_shape", fieldDtype = "field_dtype", cpGrid = "cp_grid"
        case chainOK = "chain_ok"
    }
}

/// A sampling index entry (§14.3).
public struct IndexEntry: Codable, Sendable, Hashable {
    public var annotation: String
    /// Whether it still matches its annotation (`nil`: unknown).
    public var fresh: Bool?
}

/// What the summary says of the clinical history (format 1.1).
public struct ClinicalSummary: Codable, Sendable, Hashable {
    public var present: Bool
    public var projection: Bool?
    public var events: Int?
    public var records: Int?
    public var kinds: [String: Int]?
    public var documents: Int?
    public var links: Int?
    public var unknownAvailability: Int?
    public var clock: JSONValue?
    public var error: JSONValue?

    enum CodingKeys: String, CodingKey {
        case present, projection, events, records, kinds, documents, links, clock, error
        case unknownAvailability = "unknown_availability"
    }

    public init(present: Bool) { self.present = present }
}

// MARK: - Reports

/// What `verify` found (§13).
public struct VerifyReport: Codable, Sendable, Hashable {
    public struct ContentID: Codable, Sendable, Hashable {
        public var stored: String?
        public var computed: String?
        public var ok: Bool?
    }

    public struct Object: Codable, Sendable, Hashable {
        public var path: String
        public var ok: Bool
        public var state: String
    }

    public var ok: Bool
    public var contentID: ContentID
    public var objects: [Object]
    public var mismatched: [String]
    public var malformed: [String]
    public var undigested: [String]
    public var unattested: [String]
    public var unverifiable: [String]
    public var staleIndex: [String]

    enum CodingKeys: String, CodingKey {
        case ok, objects, mismatched, malformed, undigested, unattested, unverifiable
        case contentID = "content_id", staleIndex = "stale_index"
    }
}

/// One validator finding (§15).
public struct Diagnostic: Codable, Sendable, Hashable {
    public var code: String
    /// The code table's severity.
    public var severity: String
    /// The severity at the level validated at (`strict` promotes warnings).
    public var effectiveSeverity: String
    /// An HDF5 path, or a JSON pointer into `/meta` after `/meta#`.
    public var location: String
    public var message: String
    public var level: String
    /// The code table's one-line summary.
    public var summary: String

    enum CodingKeys: String, CodingKey {
        case code, severity, location, message, level, summary
        case effectiveSeverity = "effective_severity"
    }

    public var isError: Bool { effectiveSeverity == "error" }
}

/// A validation pass (§15).
public struct ValidationReport: Codable, Sendable, Hashable {
    public var path: String
    public var level: String
    public var profiles: [String]
    public var ok: Bool
    public var errors: Int
    public var warnings: Int
    public var promoted: Int
    public var codes: [String]
    public var diagnostics: [Diagnostic]
    public var checked: JSONValue?
}

/// How an annotation's classes split into mutually exclusive `uint16`
/// layers (spec §7.2).
public struct LayerPlan: Codable, Sendable, Hashable {
    public var annotation: String
    public var kind: String
    public var spatialShape: [Int]
    /// The class ids of each layer.
    public var layers: [[Int]]
    public var classIDs: [Int]
    public var annotatedClassIDs: [Int]
    public var closure: String
    public var ignoreID: Int
    /// Whether the layers hold the ignore id where voxels are ignored.
    public var ignoreInBand: Bool
    /// The `mask` annotation holding the ignore region, when one does.
    public var ignoreMask: String?
    public var threshold: Double?
    public var instances: Bool
    /// The overlapping class pairs measured (packed encodings).
    public var overlaps: [[Int]]

    enum CodingKeys: String, CodingKey {
        case annotation, kind, layers, closure, threshold, instances, overlaps
        case spatialShape = "spatial_shape", classIDs = "class_ids", annotatedClassIDs = "annotated_class_ids"
        case ignoreID = "ignore_id", ignoreInBand = "ignore_in_band", ignoreMask = "ignore_mask"
    }

    /// The layer holding a class.
    public func layer(of classID: Int) -> Int? { layers.firstIndex { $0.contains(classID) } }
}

/// `[lo, hi]` on one axis; for a box, at voxel edges (§8.1): it covers the
/// voxels `floor(lo + 0.5) ..< floor(hi + 0.5)`.
public struct AxisInterval: Sendable, Hashable {
    public var lo: Double
    public var hi: Double

    public init(_ lo: Double, _ hi: Double) {
        self.lo = lo
        self.hi = hi
    }

    /// The voxel indices a box edge pair covers (rounding half up).
    public var voxels: Range<Int> {
        let a = Int((lo + 0.5).rounded(.down))
        let b = Int((hi + 0.5).rounded(.down))
        return a..<max(a, b)
    }
}

/// One object of an `instances` (or `boxes`) annotation.
public struct InstanceInfo: Sendable, Hashable {
    public var index: Int
    public var instanceID: UInt64
    public var classID: Int
    /// The box per spatial axis, index space, at voxel edges.
    public var bbox: [AxisInterval]
    public var voxelCount: UInt64
    public var score: Double?
    public var hasMask: Bool
}

/// One class's voxels and tight box in a voxel annotation, as
/// `SampleFile.classStats(_:)` gives them.
public struct AnnotationClassStats: Sendable, Hashable {
    public var classID: Int
    public var voxels: UInt64
    /// The tight box at voxel edges, `nil` when the class holds no voxel.
    public var bbox: [AxisInterval]?
}

extension Array where Element == AxisInterval {
    init?(json: JSONValue?) {
        guard let rows = json?.arrayValue else { return nil }
        self = rows.compactMap { row in
            guard let lo = row[0]?.doubleValue, let hi = row[1]?.doubleValue else { return nil }
            return AxisInterval(lo, hi)
        }
    }
}
