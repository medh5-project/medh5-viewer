import Foundation
import simd
import MedH5Core

/// The coordinate system of a geometric annotation (spec §8.1).
public enum AnnotationSpace: String, Sendable, Hashable, Codable {
    /// Continuous index coordinates of the annotation's grid: integers at
    /// voxel centres, the volume spanning `[-0.5, n - 0.5]`.
    case index
    /// World coordinates of the annotation's frame.
    case world
}

/// One dataset of a geometric annotation, named and shaped as medh5 stores
/// it (`boxes (N, S, 2) float32`, `class_ids (N,) uint16`, …): what the
/// format layer writes with `m5_writer_add_geometric` and reads back.
public struct AnnotationArray: Sendable, Equatable {
    public enum Values: Sendable, Equatable {
        case float32([Float])
        case float64([Double])
        case int32([Int32])
        case int64([Int64])
        case uint8([UInt8])
        case uint16([UInt16])
        case uint32([UInt32])
        case uint64([UInt64])
    }

    public var name: String
    public var shape: [Int]
    public var values: Values

    public init(name: String, shape: [Int], values: Values) {
        self.name = name
        self.shape = shape
        self.values = values
    }

    public var scalarType: ScalarType {
        switch values {
        case .float32: return .float32
        case .float64: return .float64
        case .int32: return .int32
        case .int64: return .int64
        case .uint8: return .uint8
        case .uint16: return .uint16
        case .uint32: return .uint32
        case .uint64: return .uint64
        }
    }

    public var count: Int {
        switch values {
        case .float32(let v): return v.count
        case .float64(let v): return v.count
        case .int32(let v): return v.count
        case .int64(let v): return v.count
        case .uint8(let v): return v.count
        case .uint16(let v): return v.count
        case .uint32(let v): return v.count
        case .uint64(let v): return v.count
        }
    }

    /// The values as `Double` (any type).
    public var doubles: [Double] {
        switch values {
        case .float32(let v): return v.map(Double.init)
        case .float64(let v): return v
        case .int32(let v): return v.map(Double.init)
        case .int64(let v): return v.map(Double.init)
        case .uint8(let v): return v.map(Double.init)
        case .uint16(let v): return v.map(Double.init)
        case .uint32(let v): return v.map(Double.init)
        case .uint64(let v): return v.map(Double.init)
        }
    }

    /// The values as integers, or nil for a floating-point array.
    public var integers: [Int64]? {
        switch values {
        case .float32, .float64: return nil
        case .int32(let v): return v.map(Int64.init)
        case .int64(let v): return v
        case .uint8(let v): return v.map(Int64.init)
        case .uint16(let v): return v.map(Int64.init)
        case .uint32(let v): return v.map(Int64.init)
        case .uint64(let v): return v.map { Int64(clamping: $0) }
        }
    }

    /// The raw bytes, C order (for the bridge's `M5ArrayView`).
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        switch values {
        case .float32(let v): return try v.withUnsafeBytes(body)
        case .float64(let v): return try v.withUnsafeBytes(body)
        case .int32(let v): return try v.withUnsafeBytes(body)
        case .int64(let v): return try v.withUnsafeBytes(body)
        case .uint8(let v): return try v.withUnsafeBytes(body)
        case .uint16(let v): return try v.withUnsafeBytes(body)
        case .uint32(let v): return try v.withUnsafeBytes(body)
        case .uint64(let v): return try v.withUnsafeBytes(body)
        }
    }
}

/// A geometric annotation as stored: its datasets, its string columns and
/// the attributes that shape them.
///
/// String columns (`names` of points, `attributes` of boxes) are variable-
/// length UTF-8 datasets in the file; the bridge takes them as JSON lists in
/// the writer options, so they are kept apart from the numeric arrays.
public struct GeometricArrays: Sendable, Equatable {
    /// `boxes`, `points`, `keypoints`, `polylines` or `contours`.
    public var kind: String
    public var space: AnnotationSpace
    public var arrays: [AnnotationArray]
    public var strings: [String: [String]]
    /// Scalar string attributes (`skeleton`, `correspondence`).
    public var attributes: [String: String]

    public init(kind: String, space: AnnotationSpace, arrays: [AnnotationArray] = [],
                strings: [String: [String]] = [:], attributes: [String: String] = [:]) {
        self.kind = kind
        self.space = space
        self.arrays = arrays
        self.strings = strings
        self.attributes = attributes
    }

    public subscript(name: String) -> AnnotationArray? {
        arrays.first { $0.name == name }
    }

    /// The spatial rank `S` of the coordinate arrays (the last extent of
    /// `boxes`'s second axis, `points`'s or `vertices`'s last axis).
    public var rank: Int? {
        if let b = self["boxes"], b.shape.count == 3 { return b.shape[1] }
        if let v = self["vertices"], v.shape.count == 2 { return v.shape[1] }
        if let p = self["points"], let last = p.shape.last { return last }
        return nil
    }
}

/// A problem a validator found, with the spec's diagnostic code.
public struct GeometryIssue: Sendable, Hashable, CustomStringConvertible {
    /// `E402` (a reserved class id), `E404` (an encoding invariant: too few
    /// vertices, a contour role other than 0 or 1), `E405` (shapes that do
    /// not agree), `E406` (non-finite or inverted coordinates), `E408`
    /// (offsets that do not delimit the vertices), `E410` (a required
    /// dataset is absent), `E411` (a keypoint visibility other than 0, 1 or
    /// 2), `W919` (a contour role that disagrees with its depth).
    public var code: String
    public var message: String
    /// The item (box, point, polyline…) concerned, when one is.
    public var item: Int?

    public init(code: String, message: String, item: Int? = nil) {
        self.code = code
        self.message = message
        self.item = item
    }

    public var isError: Bool { code.hasPrefix("E") }

    public var description: String {
        "\(code)\(item.map { " (item \($0))" } ?? ""): \(message)"
    }
}

/// Errors reading geometric arrays.
public struct GeometryArrayError: Error, Sendable, CustomStringConvertible {
    public var issue: GeometryIssue
    public var description: String { issue.description }

    init(_ code: String, _ message: String, item: Int? = nil) {
        issue = GeometryIssue(code: code, message: message, item: item)
    }
}

// MARK: - Coordinates

/// Converts between padded 3-D coordinates (how this package holds every
/// point) and the `S` stored components of a coordinate.
///
/// Index space: a 2-D grid's stored `(i0, i1)` is padded `(0, i0, i1)`.
/// World space: a 2-D frame's stored `(x, y)` is padded `(x, y, 0)`.
enum StoredCoordinates {
    static func stored(_ p: SIMD3<Double>, rank: Int, space: AnnotationSpace) -> [Double] {
        if rank >= 3 { return [p.x, p.y, p.z] }
        return space == .index ? [p.y, p.z] : [p.x, p.y]
    }

    static func padded(_ v: ArraySlice<Double>, rank: Int, space: AnnotationSpace) -> SIMD3<Double> {
        let a = Array(v)
        if rank >= 3 { return SIMD3(a[0], a[1], a[2]) }
        return space == .index ? SIMD3(0, a[0], a[1]) : SIMD3(a[0], a[1], 0)
    }

    /// Padded axis ↔ stored axis of a grid plane (`(axis, index)` columns).
    static func storedAxis(_ padded: Int, rank: Int) -> Int { padded - (3 - min(3, rank)) }
    static func paddedAxis(_ stored: Int, rank: Int) -> Int { stored + (3 - min(3, rank)) }

    static func encodePlanes(_ planes: [GridPlane?], rank: Int) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(planes.count * 2)
        for p in planes {
            if let p, storedAxis(p.axis, rank: rank) >= 0 {
                out.append(Int32(storedAxis(p.axis, rank: rank)))
                out.append(Int32(p.index))
            } else {
                out.append(-1)
                out.append(0)
            }
        }
        return out
    }

    static func decodePlanes(_ flat: [Int64], count: Int, rank: Int) -> [GridPlane?] {
        (0..<count).map { i in
            let a = Int(flat[2 * i]), idx = Int(flat[2 * i + 1])
            return a < 0 ? nil : GridPlane(axis: paddedAxis(a, rank: rank), index: idx)
        }
    }

    /// A point converted between index and world space of `geometry`.
    static func convert(_ p: SIMD3<Double>, from: AnnotationSpace, to: AnnotationSpace,
                        geometry: GridGeometry) -> SIMD3<Double> {
        if from == to { return p }
        return to == .world ? geometry.world(fromIndex: p) : geometry.index(fromWorld: p)
    }
}

/// Flat-array helpers for decoding.
extension GeometricArrays {
    func require(_ name: String) throws -> AnnotationArray {
        guard let a = self[name] else { throw GeometryArrayError("E410", "\(kind): the `\(name)` dataset is missing") }
        return a
    }

    func requireIntegers(_ name: String) throws -> [Int64] {
        let a = try require(name)
        guard let v = a.integers else { throw GeometryArrayError("E405", "\(kind): `\(name)` must hold integers") }
        return v
    }

    func optionalIntegers(_ name: String, count: Int) throws -> [Int64]? {
        guard let a = self[name] else { return nil }
        guard let v = a.integers else { throw GeometryArrayError("E405", "\(kind): `\(name)` must hold integers") }
        guard v.count == count else {
            throw GeometryArrayError("E405", "\(kind): `\(name)` has \(v.count) entries for \(count) items")
        }
        return v
    }

    /// An optional id column (`instance_ids`: uint32 or uint64), exactly.
    func optionalIDs(_ name: String, count: Int) throws -> [UInt64]? {
        guard let a = self[name] else { return nil }
        guard a.count == count else {
            throw GeometryArrayError("E405", "\(kind): `\(name)` has \(a.count) entries for \(count) items")
        }
        switch a.values {
        case .uint64(let v): return v
        case .uint32(let v): return v.map(UInt64.init)
        case .uint16(let v): return v.map(UInt64.init)
        case .uint8(let v): return v.map(UInt64.init)
        case .int64(let v): return v.map { UInt64(bitPattern: $0) }
        case .int32(let v): return v.map { UInt64(bitPattern: Int64($0)) }
        case .float32, .float64:
            throw GeometryArrayError("E411", "\(kind): `\(name)` must hold unsigned integers")
        }
    }

    func optionalDoubles(_ name: String, count: Int) throws -> [Double]? {
        guard let a = self[name] else { return nil }
        guard a.count == count else {
            throw GeometryArrayError("E405", "\(kind): `\(name)` has \(a.count) entries for \(count) items")
        }
        return a.doubles
    }

    func optionalStrings(_ name: String, count: Int) throws -> [String]? {
        guard let s = strings[name] else { return nil }
        guard s.count == count else {
            throw GeometryArrayError("E405", "\(kind): `\(name)` has \(s.count) entries for \(count) items")
        }
        return s
    }
}

/// Validation helpers shared by the annotation sets.
enum GeometryChecks {
    static func finite(_ p: SIMD3<Double>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }

    /// E408: offsets non-decreasing, starting at 0 and ending at `vertexCount`.
    static func offsets(_ o: [Int64], vertexCount: Int, kind: String) -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        guard let first = o.first else {
            return [GeometryIssue(code: "E408", message: "\(kind) offsets are empty; they hold M + 1 entries")]
        }
        if first != 0 { issues.append(GeometryIssue(code: "E408", message: "\(kind) offsets start at \(first), not 0")) }
        if o.last! != Int64(vertexCount) {
            issues.append(GeometryIssue(code: "E408", message: "\(kind) offsets end at \(o.last!), not at the \(vertexCount) vertices"))
        }
        for i in 1..<o.count where o[i] < o[i - 1] {
            issues.append(GeometryIssue(code: "E408", message: "\(kind) offsets decrease at entry \(i)", item: i - 1))
        }
        return issues
    }
}
