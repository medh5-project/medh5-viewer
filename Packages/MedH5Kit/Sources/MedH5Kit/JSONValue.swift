import Foundation

/// A JSON value that keeps what medh5's digests depend on.
///
/// medh5 hashes canonical JSON (spec §5.1) and stores `/meta` exactly as
/// Python's `json.dumps(doc, ensure_ascii=False)` writes it, so a document
/// edited in the viewer and written back must not turn `1` into `1.0`,
/// reorder an object's members, or respell a float. `JSONValue` therefore
///
/// - keeps integers (`.int`, `.uint`) and floats (`.double`) apart,
/// - keeps the members of an object in their order (``JSONObject``),
/// - parses with its own parser (``JSONValue/parse(_:)``) and serialises with
///   its own writer (``JSONValue/serialized(_:)``), whose floats are Python's
///   `repr` and whose formats are the engine's: ``JSONFormat/meta`` (the
///   `/meta` text), ``JSONFormat/canonical`` (§5.1), ``JSONFormat/compact``
///   and ``JSONFormat/pretty``.
///
/// Parsing `/meta` and serialising it with ``JSONFormat/meta`` reproduces
/// its bytes.
///
/// Two values are equal when they hold the same members (object member
/// order is not compared) and the same numbers of the same kind (`.int(1)`
/// is not `.double(1)`).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// An integer that fits `Int64`.
    case int(Int64)
    /// An integer above `Int64.max`.
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// The members of a JSON object, in order.
public struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ entries: [(String, JSONValue)]) {
        for (key, value) in entries { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    /// A member's value; setting `nil` removes it, setting a new key appends it.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// `(key, value)` pairs in order.
    public var entries: [(key: String, value: JSONValue)] { keys.map { ($0, storage[$0]!) } }

    public var values: [JSONValue] { keys.map { storage[$0]! } }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        entries.makeIterator()
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.storage == b.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

// MARK: - Literals and accessors

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

extension JSONValue {
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ values: [Int]) { self = .array(values.map { JSONValue($0) }) }
    public init(_ values: [Double]) { self = .array(values.map { JSONValue($0) }) }
    public init(_ values: [String]) { self = .array(values.map { JSONValue($0) }) }
    /// An array of integers.
    public static func ints(_ values: [Int]) -> JSONValue { .array(values.map { .int(Int64($0)) }) }
    /// An array of floats.
    public static func doubles(_ values: [Double]) -> JSONValue { .array(values.map { .double($0) }) }
    /// An array of strings.
    public static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }

    /// The value as `Int` (an integral float counts).
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .uint(let u): return Int(exactly: u)
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }

    /// The value as `Double` (any number).
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        case .double(let d): return d
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }

    /// An object member (`nil` for another value or an absent key).
    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    /// An array element (`nil` out of range or for another value).
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

// MARK: - Parsing

/// A JSON text that does not parse.
public struct JSONParseError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    /// The byte offset where parsing stopped.
    public let offset: Int
    public var errorDescription: String? { "invalid JSON at byte \(offset): \(message)" }
}

extension JSONValue {
    /// Parse JSON text. `NaN`, `Infinity` and `-Infinity`, which 1.x files
    /// may hold, are read as doubles (and written back the same way).
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(Array(text.utf8))
        return try parser.document()
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser([UInt8](data))
        return try parser.document()
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var at = 0
    var depth = 0
    static let maxDepth = 512

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: at) }

    mutating func document() throws -> JSONValue {
        skipSpace()
        let value = try parseValue()
        skipSpace()
        if at != bytes.count { throw fail("trailing characters") }
        return value
    }

    mutating func skipSpace() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 {
            at += 1
        }
    }

    mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard at < bytes.count, bytes[at] == b else { throw fail("expected \(literal)") }
            at += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard at < bytes.count else { throw fail("unexpected end of input") }
        switch bytes[at] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "N"): try expect("NaN"); return .double(.nan)
        case UInt8(ascii: "I"): try expect("Infinity"); return .double(.infinity)
        case UInt8(ascii: "-") where at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "I"):
            at += 1
            try expect("Infinity")
            return .double(-.infinity)
        default: return try parseNumber()
        }
    }

    mutating func parseObject() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        if depth > JSONParser.maxDepth { throw fail("nested too deep") }
        at += 1
        var object = JSONObject()
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
            at += 1
            return .object(object)
        }
        while true {
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("expected a member name") }
            let key = try parseString()
            skipSpace()
            try expect(":")
            skipSpace()
            object[key] = try parseValue()
            skipSpace()
            guard at < bytes.count else { throw fail("unterminated object") }
            if bytes[at] == UInt8(ascii: ",") {
                at += 1
                continue
            }
            if bytes[at] == UInt8(ascii: "}") {
                at += 1
                return .object(object)
            }
            throw fail("expected , or }")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        if depth > JSONParser.maxDepth { throw fail("nested too deep") }
        at += 1
        var items: [JSONValue] = []
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
            at += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try parseValue())
            skipSpace()
            guard at < bytes.count else { throw fail("unterminated array") }
            if bytes[at] == UInt8(ascii: ",") {
                at += 1
                continue
            }
            if bytes[at] == UInt8(ascii: "]") {
                at += 1
                return .array(items)
            }
            throw fail("expected , or ]")
        }
    }

    mutating func hex4() throws -> UInt16 {
        guard at + 4 <= bytes.count else { throw fail("short \\u escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let b = bytes[at]
            let digit: UInt16
            switch b {
            case 0x30...0x39: digit = UInt16(b - 0x30)
            case 0x41...0x46: digit = UInt16(b - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(b - 0x61 + 10)
            default: throw fail("bad \\u escape")
            }
            value = value << 4 | digit
            at += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        at += 1
        var out: [UInt8] = []
        var start = at
        while true {
            guard at < bytes.count else { throw fail("unterminated string") }
            let b = bytes[at]
            if b == UInt8(ascii: "\"") {
                out.append(contentsOf: bytes[start..<at])
                at += 1
                break
            }
            if b == UInt8(ascii: "\\") {
                out.append(contentsOf: bytes[start..<at])
                at += 1
                guard at < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[at]
                at += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let unit = try hex4()
                    var scalar: UInt32 = UInt32(unit)
                    if (0xD800...0xDBFF).contains(unit),
                       at + 6 <= bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u")
                    {
                        let save = at
                        at += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                        } else {
                            at = save
                            scalar = 0xFFFD
                        }
                    } else if (0xD800...0xDFFF).contains(unit) {
                        scalar = 0xFFFD
                    }
                    let character = Unicode.Scalar(scalar) ?? Unicode.Scalar(0xFFFD)!
                    out.append(contentsOf: Array(String(Character(character)).utf8))
                default: throw fail("bad escape")
                }
                start = at
                continue
            }
            if b < 0x20 { throw fail("a control character in a string") }
            at += 1
        }
        guard let text = String(bytes: out, encoding: .utf8) else { throw fail("invalid UTF-8") }
        return text
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = at
        if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
        var digits = 0
        while at < bytes.count, (0x30...0x39).contains(bytes[at]) {
            at += 1
            digits += 1
        }
        if digits == 0 { throw fail("expected a value") }
        var integral = true
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
            integral = false
            at += 1
            var fraction = 0
            while at < bytes.count, (0x30...0x39).contains(bytes[at]) {
                at += 1
                fraction += 1
            }
            if fraction == 0 { throw fail("a fraction needs digits") }
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
            integral = false
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            var exponent = 0
            while at < bytes.count, (0x30...0x39).contains(bytes[at]) {
                at += 1
                exponent += 1
            }
            if exponent == 0 { throw fail("an exponent needs digits") }
        }
        let text = String(decoding: bytes[start..<at], as: UTF8.self)
        if integral {
            if let i = Int64(text) { return .int(i) }
            if let u = UInt64(text) { return .uint(u) }
        }
        guard let d = Double(text) else { throw fail("a number out of range") }
        return .double(d)
    }
}

// MARK: - Serialising

/// How ``JSONValue/serialized(_:)`` writes JSON: the subset of Python's
/// `json.dumps` options medh5's serialisations use.
public struct JSONFormat: Sendable, Hashable {
    public var itemSeparator: String
    public var keySeparator: String
    public var sortKeys: Bool
    /// Escape every non-ASCII character as `\uXXXX`.
    public var escapeNonASCII: Bool
    /// Pretty-print with this many spaces per level.
    public var indent: Int?

    public init(itemSeparator: String, keySeparator: String, sortKeys: Bool, escapeNonASCII: Bool, indent: Int?) {
        self.itemSeparator = itemSeparator
        self.keySeparator = keySeparator
        self.sortKeys = sortKeys
        self.escapeNonASCII = escapeNonASCII
        self.indent = indent
    }

    /// `/meta`: `json.dumps(doc, ensure_ascii=False)`.
    public static let meta = JSONFormat(itemSeparator: ", ", keySeparator: ": ", sortKeys: false,
                                        escapeNonASCII: false, indent: nil)
    /// Canonical JSON (§5.1): sorted keys, no whitespace, UTF-8.
    public static let canonical = JSONFormat(itemSeparator: ",", keySeparator: ":", sortKeys: true,
                                             escapeNonASCII: false, indent: nil)
    /// Members in order, no whitespace.
    public static let compact = JSONFormat(itemSeparator: ",", keySeparator: ":", sortKeys: false,
                                           escapeNonASCII: false, indent: nil)
    /// `json.dumps(v, indent=2)`.
    public static let pretty = JSONFormat(itemSeparator: ",", keySeparator: ": ", sortKeys: false,
                                          escapeNonASCII: true, indent: 2)
}

extension JSONValue {
    /// The value as JSON text in `format` (compact by default).
    public func serialized(_ format: JSONFormat = .compact) -> String {
        var out = ""
        write(&out, format, level: 0)
        return out
    }

    /// Python's `repr(float)`: the shortest digits that round-trip,
    /// positional unless the decimal exponent is below -4 or above 15, with
    /// `.0` when integral; `NaN`, `Infinity`, `-Infinity` as 1.x wrote them.
    public static func pythonRepr(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0.0" }
        // Swift's description is the shortest round-trip digit string.
        var text = abs(value).description
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(whole + fraction)
        // value = 0.<digits> × 10^point
        var point = whole.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return sign + "0.0" }
        let n = digits.count
        if point <= -4 || point > 16 {
            var out = sign + String(digits[0])
            if n > 1 { out += "." + String(digits[1...]) }
            let e = point - 1
            out += "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
            return out
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
        if point < n { return sign + String(digits[..<point]) + "." + String(digits[point...]) }
        return sign + String(digits) + String(repeating: "0", count: point - n) + ".0"
    }

    private func write(_ out: inout String, _ format: JSONFormat, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .uint(let u): out += String(u)
        case .double(let d): out += JSONValue.pythonRepr(d)
        case .string(let s): JSONValue.writeString(&out, s, escapeNonASCII: format.escapeNonASCII)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += format.itemSeparator }
                JSONValue.newline(&out, format, level + 1)
                item.write(&out, format, level: level + 1)
            }
            JSONValue.newline(&out, format, level)
            out += "]"
        case .object(let object):
            if object.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            let keys = format.sortKeys ? object.keys.sorted(by: JSONValue.codePointOrder) : object.keys
            for (i, key) in keys.enumerated() {
                if i > 0 { out += format.itemSeparator }
                JSONValue.newline(&out, format, level + 1)
                JSONValue.writeString(&out, key, escapeNonASCII: format.escapeNonASCII)
                out += format.keySeparator
                object[key]!.write(&out, format, level: level + 1)
            }
            JSONValue.newline(&out, format, level)
            out += "}"
        }
    }

    /// Python sorts keys by code point; Swift's `<` on strings compares by
    /// Unicode canonical ordering, which can differ.
    private static func codePointOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    private static func newline(_ out: inout String, _ format: JSONFormat, _ level: Int) {
        guard let indent = format.indent else { return }
        out += "\n" + String(repeating: " ", count: indent * level)
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func hex(_ unit: UInt16) -> String {
        var s = "\\u"
        for shift in stride(from: 12, through: 0, by: -4) {
            s.append(hexDigits[Int((unit >> UInt16(shift)) & 0xF)])
        }
        return s
    }

    private static func writeString(_ out: inout String, _ s: String, escapeNonASCII: Bool) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += hex(UInt16(scalar.value))
                } else if escapeNonASCII && scalar.value > 0x7E {
                    for unit in String(scalar).utf16 { out += hex(unit) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { serialized(.compact) }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        if let ours = decoder as? JSONValueDecoder {
            self = ours.value
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let u = try? container.decode(UInt64.self) {
            self = .uint(u)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            let d = try container.decode([String: JSONValue].self)
            self = .object(JSONObject(d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .uint(let u): try container.encode(u)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o):
            var keyed = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in o { try keyed.encode(v, forKey: AnyKey(k)) }
        }
    }

    /// Decode a `Decodable` type from this value, keeping every nested
    /// `JSONValue` exactly as it is.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: JSONValueDecoder(value: self, codingPath: []))
    }

    /// The value of an `Encodable` (through Foundation's encoder).
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(value))
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - A Decoder over JSONValue

/// Decodes `Decodable` types from a ``JSONValue``: numbers convert between
/// integer and float where exact, a `JSONValue` property receives its value
/// untouched, an absent or `null` member decodes as `nil`.
struct JSONValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw DecodingError.typeMismatch(JSONObject.self, .init(codingPath: codingPath, debugDescription: "expected an object, found \(value)"))
        }
        return KeyedDecodingContainer(Keyed<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw DecodingError.typeMismatch([JSONValue].self, .init(codingPath: codingPath, debugDescription: "expected an array, found \(value)"))
        }
        return Unkeyed(items: items, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        Single(value: value, codingPath: codingPath)
    }

    static func scalar<T: Decodable>(_ type: T.Type, _ value: JSONValue, _ path: [CodingKey]) throws -> T {
        func mismatch() -> DecodingError {
            .typeMismatch(T.self, .init(codingPath: path, debugDescription: "cannot read \(value) as \(T.self)"))
        }
        if T.self == JSONValue.self { return value as! T }
        if T.self == JSONObject.self {
            guard case .object(let o) = value else { throw mismatch() }
            return o as! T
        }
        switch T.self {
        case is Bool.Type:
            guard case .bool(let b) = value else { throw mismatch() }
            return b as! T
        case is String.Type:
            guard case .string(let s) = value else { throw mismatch() }
            return s as! T
        case is Double.Type:
            guard let d = value.doubleValue else { throw mismatch() }
            return d as! T
        case is Float.Type:
            guard let d = value.doubleValue else { throw mismatch() }
            return Float(d) as! T
        case is Int.Type: return try integer(Int.self, value, mismatch) as! T
        case is Int8.Type: return try integer(Int8.self, value, mismatch) as! T
        case is Int16.Type: return try integer(Int16.self, value, mismatch) as! T
        case is Int32.Type: return try integer(Int32.self, value, mismatch) as! T
        case is Int64.Type: return try integer(Int64.self, value, mismatch) as! T
        case is UInt.Type: return try integer(UInt.self, value, mismatch) as! T
        case is UInt8.Type: return try integer(UInt8.self, value, mismatch) as! T
        case is UInt16.Type: return try integer(UInt16.self, value, mismatch) as! T
        case is UInt32.Type: return try integer(UInt32.self, value, mismatch) as! T
        case is UInt64.Type: return try integer(UInt64.self, value, mismatch) as! T
        default:
            return try T(from: JSONValueDecoder(value: value, codingPath: path))
        }
    }

    static func integer<I: FixedWidthInteger>(_ type: I.Type, _ value: JSONValue, _ mismatch: () -> DecodingError) throws -> I {
        switch value {
        case .int(let i): if let v = I(exactly: i) { return v }
        case .uint(let u): if let v = I(exactly: u) { return v }
        case .double(let d): if let v = I(exactly: d) { return v }
        default: break
        }
        throw mismatch()
    }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let object: JSONObject
        let codingPath: [CodingKey]
        var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

        func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

        func value(_ key: Key) throws -> JSONValue {
            guard let v = object[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "no member \(key.stringValue)"))
            }
            return v
        }

        func decodeNil(forKey key: Key) throws -> Bool { object[key.stringValue]?.isNull ?? true }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try JSONValueDecoder.scalar(type, value(key), codingPath + [key])
        }

        func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
            guard let v = object[key.stringValue], !v.isNull || T.self == JSONValue.self else { return nil }
            return try JSONValueDecoder.scalar(type, v, codingPath + [key])
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            try JSONValueDecoder(value: value(key), codingPath: codingPath + [key]).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            try JSONValueDecoder(value: value(key), codingPath: codingPath + [key]).unkeyedContainer()
        }

        func superDecoder() throws -> Decoder { JSONValueDecoder(value: .object(object), codingPath: codingPath) }

        func superDecoder(forKey key: Key) throws -> Decoder {
            JSONValueDecoder(value: object[key.stringValue] ?? .null, codingPath: codingPath + [key])
        }
    }

    struct Unkeyed: UnkeyedDecodingContainer {
        let items: [JSONValue]
        let codingPath: [CodingKey]
        var currentIndex = 0
        var count: Int? { items.count }
        var isAtEnd: Bool { currentIndex >= items.count }

        init(items: [JSONValue], codingPath: [CodingKey]) {
            self.items = items
            self.codingPath = codingPath
        }

        mutating func next() throws -> JSONValue {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: codingPath, debugDescription: "past the end"))
            }
            defer { currentIndex += 1 }
            return items[currentIndex]
        }

        mutating func decodeNil() throws -> Bool {
            if !isAtEnd, items[currentIndex].isNull {
                currentIndex += 1
                return true
            }
            return false
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let path = codingPath + [AnyKey(String(currentIndex))]
            return try JSONValueDecoder.scalar(type, next(), path)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            try JSONValueDecoder(value: next(), codingPath: codingPath).container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            try JSONValueDecoder(value: next(), codingPath: codingPath).unkeyedContainer()
        }

        mutating func superDecoder() throws -> Decoder { JSONValueDecoder(value: try next(), codingPath: codingPath) }
    }

    struct Single: SingleValueDecodingContainer {
        let value: JSONValue
        let codingPath: [CodingKey]
        func decodeNil() -> Bool { value.isNull }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONValueDecoder.scalar(type, value, codingPath) }
    }
}
