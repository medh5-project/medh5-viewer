import Foundation
import MedH5Bridge

/// A failure reported by the medh5 engine or the bridge.
///
/// `kind` is the engine's error category (`file`, `version`, `schema`,
/// `validation`, `integrity`, `key`, `value`, `type`, `index`, `io`,
/// `unsupported`, `runtime`) or the bridge's own (`argument`, `cancelled`,
/// `panic`, `not_found`, `closed`); `code` is the §15.2 diagnostic code the
/// engine attached (`"E701"`), when it did.
public struct MedH5Error: Error, LocalizedError, Sendable, Hashable, CustomStringConvertible {
    /// The bridge's status codes (`M5Status`).
    public enum Status: Int32, Sendable, Hashable {
        /// The engine refused or failed.
        case failed = 1
        /// A bad argument: NULL, bad UTF-8 or JSON, a buffer of the wrong size.
        case argument = 2
        /// The engine panicked (a bug), caught at the boundary.
        case panic = 3
        /// A progress callback (or a cancelled task) stopped the call.
        case cancelled = 4
        /// A named array or key is absent.
        case notFound = 5
    }

    public let status: Status
    public let kind: String
    public let code: String?
    public let message: String

    public init(status: Status, kind: String, code: String? = nil, message: String) {
        self.status = status
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        if let code { return "[\(code)] \(message)" }
        return message
    }

    public var description: String { "MedH5Error(\(kind)\(code.map { ", \($0)" } ?? ""): \(message))" }

    /// Whether a progress callback or a cancelled task stopped the call.
    public var isCancellation: Bool { status == .cancelled }

    /// The calling thread's last bridge error, for a call that returned
    /// `status`.
    static func last(_ status: M5Status) -> MedH5Error {
        let fallbackStatus = Status(rawValue: status) ?? .failed
        guard let pointer = m5_last_error() else {
            return MedH5Error(status: fallbackStatus, kind: "unknown", message: "the bridge returned status \(status)")
        }
        let text = String(cString: pointer)
        m5_string_free(pointer)
        guard let json = try? JSONValue.parse(text) else {
            return MedH5Error(status: fallbackStatus, kind: "unknown", message: text)
        }
        return MedH5Error(
            status: json["status"]?.intValue.flatMap { Status(rawValue: Int32($0)) } ?? fallbackStatus,
            kind: json["kind"]?.stringValue ?? "unknown",
            code: json["code"]?.stringValue,
            message: json["message"]?.stringValue ?? text
        )
    }

    /// A sample or writer used after it was closed.
    static let closed = MedH5Error(status: .argument, kind: "closed", message: "the handle has been closed")
}
