import Foundation
import MedH5Bridge
import MedH5Core
import simd

/// The validator (§15): it opens the file itself.
public enum Validator {
    /// Validate a `.medh5` or `.medh5c` file at `level` (`structural`,
    /// `semantic`, `integrity`, `strict`). A file that cannot be read is
    /// reported (E001), not thrown.
    public static func validate(url: URL, level: String = "integrity") throws -> ValidationReport {
        try callJSON { m5_validate_file(url.path, level, $0) }.decode(ValidationReport.self)
    }

    /// `validate` off the calling task's thread (validation reads every
    /// object, and at `integrity` hashes them all).
    public static func validateInBackground(url: URL, level: String = "integrity") async throws -> ValidationReport {
        try await runBlocking { _ in try validate(url: url, level: level) }
    }
}

/// What a converter decided, guessed and warned about.
public struct ConversionReport: Codable, Sendable, Hashable {
    public struct Note: Codable, Sendable, Hashable {
        public var kind: String
        public var message: String
        /// `decision`, `guess` or `warning`.
        public var severity: String
        public var detail: JSONValue?
    }

    public var source: String?
    public var converter: String?
    public var outputs: [String]?
    public var ok: Bool
    public var notes: [Note]
    /// The file written, for an export.
    public var path: String?
}

/// A NIfTI volume read in medh5 conventions: axes `(z, y, x)`, world in LPS.
public struct NIfTIVolume: @unchecked Sendable {
    /// The voxels as stored in the file's type.
    public var data: VolumeData
    /// The grid it describes.
    public var geometry: GridGeometry
    /// The homogeneous index → world matrix of that grid.
    public var affine: [[Double]]
    /// Everything the engine read (`units`, `rescale`, `time_values`, …).
    public var header: JSONValue
}

/// NIfTI conversion, in the engine (`medh5::convert::nifti`).
public enum NIfTI {
    /// Read a `.nii`/`.nii.gz` file.
    public static func read(_ url: URL) throws -> NIfTIVolume {
        var bundle: OpaquePointer?
        try check(m5_nifti_read(url.path, &bundle))
        let contents = try BundleContents(taking: bundle)
        let geometry = try contents.header["grid"]!.decode(GridGeometry.self)
        let affine = contents.header["affine"]?.arrayValue?.map { $0.arrayValue?.compactMap(\.doubleValue) ?? [] } ?? []
        return NIfTIVolume(data: try contents.array("data").data, geometry: geometry, affine: affine, header: contents.header)
    }

    /// Create a sample at `url` from NIfTI images (by image id) and masks
    /// (by class name). `options` as the bridge takes them (`modality`,
    /// `sample_id`, `label_set`, `codec`, …).
    @discardableResult
    public static func importSample(images: [(String, URL)], masks: [(String, URL)] = [], to url: URL,
                                    options: JSONObject = [:]) throws -> ConversionReport {
        var o = options
        o["images"] = .object(JSONObject(images.map { ($0.0, .string($0.1.path)) }))
        if !masks.isEmpty { o["masks"] = .object(JSONObject(masks.map { ($0.0, .string($0.1.path)) })) }
        return try callJSON { m5_nifti_import(url.path, JSONValue.object(o).serialized(), $0) }.decode(ConversionReport.self)
    }

    /// Add NIfTI masks (by class name) to the sample at `url` as one
    /// segmentation, amending it.
    @discardableResult
    public static func importSegmentation(into url: URL, annotationID: String, masks: [(String, URL)],
                                          options: JSONObject = [:]) throws -> ConversionReport {
        var o = options
        o["annotation_id"] = .string(annotationID)
        o["masks"] = .object(JSONObject(masks.map { ($0.0, .string($0.1.path)) }))
        return try callJSON { m5_nifti_import_segmentation(url.path, JSONValue.object(o).serialized(), $0) }
            .decode(ConversionReport.self)
    }

    /// Write one image (`"images/CT"`) or voxel annotation
    /// (`"annotations/organs"`, or one of its classes with `classID`) as
    /// NIfTI. Images are written in physical values unless `physical` is
    /// false.
    @discardableResult
    public static func export(sample url: URL, object: String, to out: URL, physical: Bool = true,
                              classID: Int? = nil) throws -> ConversionReport {
        var o: JSONObject = ["object": .string(object), "out": .string(out.path), "physical": .bool(physical)]
        o["class"] = classID.map { .int(Int64($0)) }
        return try callJSON { m5_nifti_export(url.path, JSONValue.object(o).serialized(), $0) }.decode(ConversionReport.self)
    }
}

/// Storage (§14).
public enum Storage {
    /// Rewrite a sample's storage with a codec profile; every digest and the
    /// `content_id` are unchanged. `out` nil rewrites in place.
    public static func recompress(_ url: URL, profile: String, out: URL? = nil, rechunk: Bool = false) throws -> JSONValue {
        let o: JSONValue = ["profile": .string(profile), "out": out.map { .string($0.path) } ?? .null, "rechunk": .bool(rechunk)]
        return try callJSON { m5_recompress(url.path, o.serialized(), $0) }
    }
}

/// One member of a `.medh5c` collection.
public struct CollectionMember: Codable, Sendable, Hashable {
    public var name: String
    public var sampleID: String?
    public var subjectID: String?
    public var profiles: [String]?
    public var contentID: String?
    public var timepoints: [String]?
    public var images: [String]?
    public var annotations: [String]?

    enum CodingKeys: String, CodingKey {
        case name, profiles, timepoints, images, annotations
        case sampleID = "sample_id", subjectID = "subject_id", contentID = "content_id"
    }
}

/// `.medh5c` collections (§2.2).
public enum Collections {
    public static func list(_ url: URL) throws -> [CollectionMember] {
        try callJSON { m5_collection_list(url.path, $0) }["members"]?.decode([CollectionMember].self) ?? []
    }

    /// Pack samples into a collection; `keys` names the members.
    @discardableResult
    public static func pack(_ sources: [URL], keys: [String]? = nil, to url: URL) throws -> [String] {
        let o: JSONValue = ["sources": .strings(sources.map(\.path)), "keys": keys.map(JSONValue.strings) ?? .null]
        return try callJSON { m5_collection_pack(url.path, o.serialized(), $0) }["members"]?.decode([String].self) ?? []
    }
}

/// Options of the demonstration sample.
public struct DemoOptions: Sendable, Hashable {
    /// Voxels per axis (16–512).
    public var size: Int
    /// A clinical history (format 1.1).
    public var clinical: Bool
    /// Polylines (format 1.2).
    public var polylines: Bool
    /// A sampling index.
    public var index: Bool
    public var codec: String

    public init(size: Int = 64, clinical: Bool = true, polylines: Bool = true, index: Bool = true, codec: String = "balanced") {
        self.size = size
        self.clinical = clinical
        self.polylines = polylines
        self.index = index
        self.codec = codec
    }
}

/// A synthetic, deterministic, rich sample: two visits of a CT phantom on
/// their own frames with the affine between them, an oblique MR, every
/// annotation encoding and kind, provenance, quality and a clinical history.
public enum Demo {
    /// Where the lesion is at baseline (world, mm), and its radius at each
    /// visit; the follow-up motion (`x_tp1 = R x_tp0 + t`).
    public static let lesionCentre = SIMD3<Double>(-70, -10, 55)
    public static let lesionRadius: (baseline: Double, followUp: Double) = (18, 27)
    public static let motionDegrees = 6.0
    public static let motionShift = SIMD3<Double>(12, -8, 15)

    /// The baseline-to-follow-up motion the demo stores as `tp0_to_tp1`.
    public static var motion: simd_double4x4 {
        let a = motionDegrees * .pi / 180
        return simd_double4x4(rowMajorHomogeneous: [
            [cos(a), -sin(a), 0, motionShift.x],
            [sin(a), cos(a), 0, motionShift.y],
            [0, 0, 1, motionShift.z],
            [0, 0, 0, 1],
        ])!
    }

    public static func write(to url: URL, options: DemoOptions = .init()) throws {
        let o: JSONValue = ["size": .int(Int64(options.size)), "clinical": .bool(options.clinical),
                            "polylines": .bool(options.polylines), "index": .bool(options.index), "codec": .string(options.codec)]
        try check(m5_demo_write(url.path, o.serialized()))
    }
}

/// One case of the conformance corpus.
public struct ConformanceCase: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var clause: String
    public var level: String
    public var file: String
    public var valid: Bool
    public var mutated: Bool
    public var expectErrors: [String]
    public var expectWarnings: [String]
    public var formatVersion: String?

    enum CodingKeys: String, CodingKey {
        case name, description, clause, level, file, valid, mutated
        case expectErrors = "expect_errors", expectWarnings = "expect_warnings", formatVersion = "format_version"
    }
}

/// The engine's conformance corpus.
public enum Conformance {
    public struct Manifest: Sendable {
        public var cases: [ConformanceCase]
        /// Hostile files that are not cases (paths relative to the directory).
        public var robustness: [String]
        public var raw: JSONValue
    }

    /// Write every case and its manifest into `directory` (and the
    /// robustness fixtures into `directory/robustness`).
    @discardableResult
    public static func write(to directory: URL) throws -> Manifest {
        let json = try callJSON { m5_conformance_write(directory.path, $0) }
        return Manifest(cases: try json["cases"]?.decode([ConformanceCase].self) ?? [],
                        robustness: json["robustness"]?.arrayValue?.compactMap(\.stringValue) ?? [], raw: json)
    }
}
