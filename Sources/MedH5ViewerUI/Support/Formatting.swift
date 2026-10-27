import Foundation
import simd

/// How the app writes numbers, coordinates, shapes and sizes: one place, so
/// every panel reads the same (typographic minus, thin multiplication signs,
/// trailing zeros trimmed).
enum Format {
    /// A number with at most `digits` decimals, trailing zeros trimmed, and a
    /// typographic minus sign.
    static func number(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "∞" : "−∞") }
        let formatter = numberFormatter(digits)
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    /// A number with exactly `digits` decimals (aligned columns).
    static func fixed(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return number(value) }
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: "-", with: "−")
    }

    /// An integer with grouping (12 345).
    static func integer<T: BinaryInteger>(_ value: T) -> String {
        groupedFormatter.string(from: NSNumber(value: Int64(value))) ?? String(value)
    }

    /// A world point, `x, y, z` with one decimal.
    static func point(_ p: SIMD3<Double>, digits: Int = 1) -> String {
        "\(fixed(p.x, digits: digits)), \(fixed(p.y, digits: digits)), \(fixed(p.z, digits: digits))"
    }

    /// An array shape: `64 × 64 × 64`.
    static func shape(_ shape: [Int]) -> String {
        shape.map(String.init).joined(separator: " × ")
    }

    /// Spacings with units: `6.25 × 5 × 5 mm`.
    static func spacing(_ spacing: [Double], units: String) -> String {
        spacing.map { number($0, digits: 3) }.joined(separator: " × ") + " " + units
    }

    /// A byte count: `1.2 MB`.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    /// A digest shortened for display: `sha256:48ac819a…42f6`.
    static func shortDigest(_ digest: String?) -> String {
        guard let digest else { return "—" }
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return digest.count > 16 ? String(digest.prefix(12)) + "…" : digest }
        let hex = parts[1]
        guard hex.count > 14 else { return digest }
        return "\(parts[0]):\(hex.prefix(8))…\(hex.suffix(4))"
    }

    /// A list with a fallback for an empty one.
    static func list(_ items: [String], empty: String = "—") -> String {
        items.isEmpty ? empty : items.joined(separator: ", ")
    }

    /// Integers as a compact list: `2, 3, 5–9`.
    static func ids(_ ids: [Int]) -> String {
        guard !ids.isEmpty else { return "none" }
        let sorted = ids.sorted()
        var runs: [String] = []
        var start = sorted[0], previous = sorted[0]
        func close() { runs.append(start == previous ? "\(start)" : (previous == start + 1 ? "\(start), \(previous)" : "\(start)–\(previous)")) }
        for id in sorted.dropFirst() {
            if id == previous + 1 { previous = id; continue }
            close()
            start = id
            previous = id
        }
        close()
        return runs.joined(separator: ", ")
    }

    /// Days from baseline as "day 92".
    static func day(_ days: Double?) -> String? {
        guard let days else { return nil }
        return "day \(number(days, digits: 1))"
    }

    private static var formatters: [Int: NumberFormatter] = [:]
    private static let lock = NSLock()

    private static func numberFormatter(_ digits: Int) -> NumberFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let f = formatters[digits] { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = max(0, digits)
        f.locale = Locale(identifier: "en_US_POSIX")
        formatters[digits] = f
        return f
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()
}

extension Double {
    /// The value rounded to an `Int`, or `nil` when it is not finite or out
    /// of range (geometry from a damaged file can be either).
    var roundedInt: Int? {
        guard isFinite, abs(self) < Double(Int32.max) else { return nil }
        return Int(rounded())
    }
}

extension String {
    /// The string, or `nil` when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
