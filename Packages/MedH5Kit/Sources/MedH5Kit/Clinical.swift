import Foundation

/// Inclusive bounds `[lo, hi]` of a time on the subject clock, in
/// microseconds: a source that knows a day does not know the hour (1.1 §5).
public struct TimeBounds: Codable, Sendable, Hashable {
    public var lo: Int64
    public var hi: Int64

    public init(lo: Int64, hi: Int64) {
        self.lo = lo
        self.hi = hi
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lo = try c.decode(Int64.self)
        hi = try c.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lo)
        try c.encode(hi)
    }

    /// The bounds in hours of the subject clock.
    public var hours: ClosedRange<Double> { Double(lo) / 3.6e9...Double(hi) / 3.6e9 }
}

/// The subject clock every clinical time is measured on (1.1 §3).
public struct ClinicalClock: Codable, Sendable, Hashable {
    public var id: String
    /// Always `us`.
    public var unit: String
    /// `relative`, `utc` or `shifted_utc`.
    public var reference: String
    public var originDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, unit, reference
        case originDescription = "origin_description"
    }
}

/// One immutable version of information about the subject (1.1 §5): when
/// it happened (`effective…`) and when it became known (`available`).
public struct ClinicalEvent: Codable, Sendable, Hashable, Identifiable {
    public var eventID: String
    public var recordID: String
    /// `observation`, `imaging`, `document`, `assessment`, `procedure`, …
    public var kind: String
    public var temporalType: String
    public var effectiveStart: TimeBounds?
    public var effectiveEnd: TimeBounds?
    public var available: TimeBounds?
    public var status: String
    public var timepointID: String?
    public var encounterID: String?
    public var codeSystem: String?
    public var code: String?
    public var codeVersion: String?
    public var valueNum: Double?
    public var valueComparator: String?
    public var unit: String?
    public var valueText: String?
    public var missingReason: String?
    public var prov: String?

    public var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case kind, status, code, unit, prov
        case eventID = "event_id", recordID = "record_id", temporalType = "temporal_type"
        case effectiveStart = "effective_start_us", effectiveEnd = "effective_end_us", available = "available_us"
        case timepointID = "timepoint_id", encounterID = "encounter_id", codeSystem = "code_system"
        case codeVersion = "code_version", valueNum = "value_num", valueComparator = "value_comparator"
        case valueText = "value_text", missingReason = "missing_reason"
    }
}

/// A typed relationship between clinical records and imaging objects (1.1 §7).
public struct ClinicalLink: Codable, Sendable, Hashable {
    public var sourceType: String
    public var sourceID: String
    /// `describes`, `compares_with`, `measures`, `derived_from`,
    /// `supersedes` or `assesses`.
    public var relation: String
    public var targetType: String
    public var targetID: String
    /// A half-open UTF-8 byte span `[start, end)` of a document source.
    public var sourceSpan: [UInt64]?
    public var targetAnnotationID: String?
    public var assertedByEventID: String?

    enum CodingKeys: String, CodingKey {
        case relation
        case sourceType = "source_type", sourceID = "source_id", targetType = "target_type", targetID = "target_id"
        case sourceSpan = "source_span", targetAnnotationID = "target_annotation_id"
        case assertedByEventID = "asserted_by_event_id"
    }
}

/// A document's metadata; its text is read on demand.
public struct ClinicalDocumentInfo: Codable, Sendable, Hashable, Identifiable {
    public var documentID: String
    public var mediaType: String
    public var language: String?
    public var sourceType: String?
    /// The text's length in UTF-8 bytes (what a span is measured in).
    public var bytes: UInt64

    public var id: String { documentID }

    enum CodingKeys: String, CodingKey {
        case language, bytes
        case documentID = "document_id", mediaType = "media_type", sourceType = "source_type"
    }
}

/// The clinical history of a sample (format 1.1), without document text.
public struct ClinicalRecords: Codable, Sendable, Hashable {
    /// Read from a later minor version, as its projection.
    public var projection: Bool
    public var schema: String
    public var clock: ClinicalClock
    public var events: [ClinicalEvent]
    public var links: [ClinicalLink]
    public var documents: [ClinicalDocumentInfo]
    public var summary: JSONValue?

    public func event(_ id: String) -> ClinicalEvent? { events.first { $0.eventID == id } }

    /// Every version of one record, in stored order.
    public func versions(of recordID: String) -> [ClinicalEvent] { events.filter { $0.recordID == recordID } }

    /// The links leaving or reaching an object (`("image", "CT_tp0")`).
    public func links(involving type: String, _ id: String) -> [ClinicalLink] {
        links.filter { ($0.sourceType == type && $0.sourceID == id) || ($0.targetType == type && $0.targetID == id) }
    }
}

/// What was known at a cutoff (1.1 §9).
public struct ClinicalSelection: Codable, Sendable, Hashable {
    public struct Selected: Codable, Sendable, Hashable {
        public var eventID: String
        public var recordID: String
        public var kind: String
        public var order: TimeBounds?
        public var tieGroup: Int
        public var plan: Bool

        enum CodingKeys: String, CodingKey {
            case kind, plan
            case eventID = "event_id", recordID = "record_id", order = "order_us", tieGroup = "tie_group"
        }
    }

    public var cutoffMicroseconds: Int64
    public var policy: String
    /// `certified`, `uncertifiable` or `provable`.
    public var status: String
    public var certified: Bool
    public var events: [Selected]
    public var eventIDs: [String]
    /// The documents whose text may be read as input.
    public var documents: [String]
    public var links: [Int]
    public var uncertainRecords: [String]
    public var excluded: [String: Int]

    enum CodingKeys: String, CodingKey {
        case policy, status, certified, events, documents, links, excluded
        case cutoffMicroseconds = "cutoff_us", eventIDs = "event_ids", uncertainRecords = "uncertain_records"
    }
}
