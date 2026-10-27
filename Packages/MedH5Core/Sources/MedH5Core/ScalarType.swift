import Foundation

/// The element type of a volume in memory.
///
/// The raw values are the bridge's `M5DType` codes (`bridge/include/medh5_bridge.h`),
/// so a value crosses the C boundary as itself. The names are NumPy's, which is
/// how medh5 spells a dtype everywhere else (`Image.dtype`, `medh5 info`).
public enum ScalarType: Int32, Sendable, Codable, CaseIterable, CustomStringConvertible {
    case bool = 1
    case uint8 = 2
    case int8 = 3
    case uint16 = 4
    case int16 = 5
    case uint32 = 6
    case int32 = 7
    case uint64 = 8
    case int64 = 9
    case float16 = 10
    case float32 = 11
    case float64 = 12

    /// Bytes per element.
    public var byteSize: Int {
        switch self {
        case .bool, .uint8, .int8: return 1
        case .uint16, .int16, .float16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        }
    }

    public var isFloatingPoint: Bool {
        self == .float16 || self == .float32 || self == .float64
    }

    public var isSignedInteger: Bool {
        self == .int8 || self == .int16 || self == .int32 || self == .int64
    }

    public var isUnsignedInteger: Bool {
        self == .uint8 || self == .uint16 || self == .uint32 || self == .uint64
    }

    /// NumPy's name for the type: `"int16"`, `"float32"`, `"bool"`.
    public var name: String {
        switch self {
        case .bool: return "bool"
        case .uint8: return "uint8"
        case .int8: return "int8"
        case .uint16: return "uint16"
        case .int16: return "int16"
        case .uint32: return "uint32"
        case .int32: return "int32"
        case .uint64: return "uint64"
        case .int64: return "int64"
        case .float16: return "float16"
        case .float32: return "float32"
        case .float64: return "float64"
        }
    }

    public var description: String { name }

    /// Parses NumPy's name, also accepting the short spellings medh5's
    /// summaries use (`"f4"`, `"<i2"`, `"u1"`, `"?"`).
    public init?(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = ScalarType.allCases.first(where: { $0.name == name }) {
            self = match
            return
        }
        let short = name.drop(while: { $0 == "<" || $0 == ">" || $0 == "=" || $0 == "|" })
        switch short {
        case "?", "b1": self = .bool
        case "u1": self = .uint8
        case "i1": self = .int8
        case "u2": self = .uint16
        case "i2": self = .int16
        case "u4": self = .uint32
        case "i4": self = .int32
        case "u8": self = .uint64
        case "i8": self = .int64
        case "f2", "half": self = .float16
        case "f4", "float", "single": self = .float32
        case "f8", "double": self = .float64
        default: return nil
        }
    }

    /// The smallest and largest value the type can hold, as `Double`.
    public var representableRange: ClosedRange<Double> {
        switch self {
        case .bool: return 0...1
        case .uint8: return 0...Double(UInt8.max)
        case .int8: return Double(Int8.min)...Double(Int8.max)
        case .uint16: return 0...Double(UInt16.max)
        case .int16: return Double(Int16.min)...Double(Int16.max)
        case .uint32: return 0...Double(UInt32.max)
        case .int32: return Double(Int32.min)...Double(Int32.max)
        case .uint64: return 0...Double(UInt64.max)
        case .int64: return Double(Int64.min)...Double(Int64.max)
        case .float16: return -65504...65504
        case .float32: return -Double(Float.greatestFiniteMagnitude)...Double(Float.greatestFiniteMagnitude)
        case .float64: return -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        }
    }

    /// The type a GPU texture can hold this type's values in without loss of
    /// the values a viewer displays: 8- and 16-bit integers and 16/32-bit
    /// floats stay as they are; wider integers and `float64` become `float32`.
    public var gpuCompatible: ScalarType {
        switch self {
        case .bool, .uint8, .int8, .uint16, .int16, .float16, .float32: return self
        case .uint32, .int32, .uint64, .int64, .float64: return .float32
        }
    }
}
