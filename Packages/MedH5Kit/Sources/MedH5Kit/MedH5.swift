@_exported import MedH5Core
import Foundation
import MedH5Bridge

/// The medh5 engine the bridge links: versions, threads, the diagnostic code
/// table and the validation levels.
public enum MedH5 {
    /// The engine's package version (`"2.2.3"`).
    public static var engineVersion: String { String(cString: m5_engine_version()) }

    /// The newest format version the engine implements (`"1.2"`).
    public static var formatVersion: String { String(cString: m5_format_version()) }

    /// The bridge's own version.
    public static var bridgeVersion: String { String(cString: m5_bridge_version()) }

    /// How many threads one engine call may use for its work outside HDF5
    /// (decompression, hashing). The setting is process-wide.
    public static var threads: Int { Int(m5_threads()) }

    /// Let one engine call use up to `count` threads; `0` restores the
    /// engine's default (`MEDH5_THREADS`, else 1). A viewer typically sets
    /// the number of performance cores at launch.
    public static func setThreads(_ count: Int) {
        m5_set_threads(UInt32(clamping: max(0, count)))
    }

    /// The §15.2 diagnostic code table, in table order.
    public static func codeTable() throws -> [DiagnosticCode] {
        try callJSON { m5_code_table($0) }.decode([DiagnosticCode].self)
    }

    /// The validation levels, lowest first (`structural`, `semantic`,
    /// `integrity`, `strict`).
    public static func validationLevels() throws -> [String] {
        try callJSON { m5_validation_levels($0) }.decode([String].self)
    }
}

/// One diagnostic code (spec §15.2).
public struct DiagnosticCode: Codable, Sendable, Hashable, Identifiable {
    public var code: String
    /// `error` or `warning`.
    public var severity: String
    public var domain: String
    public var summary: String
    /// The format version whose rules it reports.
    public var since: String?
    /// The table revision that allocated it.
    public var revision: Int?

    public var id: String { code }
}
