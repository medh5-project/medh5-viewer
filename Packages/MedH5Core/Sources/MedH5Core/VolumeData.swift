import Foundation

/// A C-contiguous array in memory: one image, one label layer, one mask.
///
/// Storage is page-aligned and a whole number of pages, so a Metal buffer can
/// wrap it without a copy (`makeBuffer(bytesNoCopy:)`), and it is mapped
/// anonymously, so a large volume costs no time to zero. A `VolumeData` made
/// by `frame(_:)` or `reshaped(_:)` is a view into its parent's storage and
/// keeps the parent alive.
///
/// Guarantee: the page-rounded span of any volume — its first byte rounded
/// down to a page boundary through its last byte rounded up — lies inside
/// the mapping of the owning volume it views, because that mapping starts on
/// a page boundary and is a whole number of pages. A renderer may therefore
/// wrap a view's pages in a no-copy Metal buffer.
///
/// The class is `@unchecked Sendable`: readers may share it across threads,
/// and a writer (the segmentation editor) must serialise its own writes.
public final class VolumeData: @unchecked Sendable {
    public let scalarType: ScalarType
    /// Stored shape, C order (axis 0 slowest).
    public let shape: [Int]
    /// Number of elements.
    public let count: Int
    /// First byte.
    public let baseAddress: UnsafeMutableRawPointer
    /// Bytes reserved (a whole number of pages for an owning volume).
    public let allocatedByteCount: Int

    private let parent: VolumeData?
    private let mapped: Bool

    public static let pageSize: Int = Int(getpagesize())

    /// Bytes holding elements.
    public var byteCount: Int { count * scalarType.byteSize }

    /// Allocates a zero-filled array.
    public init(scalarType: ScalarType, shape: [Int]) {
        precondition(shape.allSatisfy { $0 >= 0 }, "negative extent in \(shape)")
        self.scalarType = scalarType
        self.shape = shape
        self.count = shape.reduce(1, *)
        let bytes = max(1, count * scalarType.byteSize)
        let page = VolumeData.pageSize
        let rounded = (bytes + page - 1) / page * page
        let p = mmap(nil, rounded, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let p, p != MAP_FAILED else {
            fatalError("VolumeData: could not map \(rounded) bytes for \(scalarType) \(shape)")
        }
        self.baseAddress = p
        self.allocatedByteCount = rounded
        self.parent = nil
        self.mapped = true
    }

    /// Copies `bytes` into a new array; `bytes.count` must equal
    /// `shape.product * scalarType.byteSize`.
    public convenience init(scalarType: ScalarType, shape: [Int], bytes: UnsafeRawBufferPointer) {
        self.init(scalarType: scalarType, shape: shape)
        precondition(bytes.count == byteCount, "expected \(byteCount) bytes, got \(bytes.count)")
        if let src = bytes.baseAddress, byteCount > 0 {
            baseAddress.copyMemory(from: src, byteCount: byteCount)
        }
    }

    /// Makes an array from typed values.
    public convenience init<T: VoxelScalar>(shape: [Int], values: [T]) {
        self.init(scalarType: T.scalarType, shape: shape)
        precondition(values.count == count, "expected \(count) values, got \(values.count)")
        values.withUnsafeBytes { raw in
            if let src = raw.baseAddress, byteCount > 0 {
                baseAddress.copyMemory(from: src, byteCount: byteCount)
            }
        }
    }

    private init(view parent: VolumeData, offsetBytes: Int, shape: [Int]) {
        self.scalarType = parent.scalarType
        self.shape = shape
        self.count = shape.reduce(1, *)
        self.baseAddress = parent.baseAddress + offsetBytes
        self.allocatedByteCount = count * parent.scalarType.byteSize
        self.parent = parent
        self.mapped = false
    }

    deinit {
        if mapped { munmap(baseAddress, allocatedByteCount) }
    }

    /// Whether this volume is a view into another's storage.
    public var isView: Bool { parent != nil }

    /// Raw bytes.
    public var rawBuffer: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: baseAddress, count: byteCount)
    }

    /// The elements as `T`, which must be the stored type's Swift type
    /// (`UInt8` for `bool`).
    @inline(__always)
    public func pointer<T: VoxelScalar>(as type: T.Type) -> UnsafeMutablePointer<T> {
        precondition(T.scalarType.byteSize == scalarType.byteSize
                     && (T.scalarType == scalarType || (T.self == UInt8.self && scalarType == .bool)),
                     "\(T.self) does not match \(scalarType)")
        return baseAddress.assumingMemoryBound(to: T.self)
    }

    @inline(__always)
    public func buffer<T: VoxelScalar>(as type: T.Type) -> UnsafeMutableBufferPointer<T> {
        UnsafeMutableBufferPointer(start: pointer(as: type), count: count)
    }

    /// Calls `body` with the elements as `T`, keeping the volume alive for
    /// the duration of the call. Prefer this to `pointer(as:)` when the
    /// volume could otherwise be released while the pointer is in use (a
    /// temporary, or the last reference held by a value about to go away).
    @inlinable
    public func withUnsafeMutableBufferPointer<T: VoxelScalar, R>(
        as type: T.Type,
        _ body: (UnsafeMutableBufferPointer<T>) throws -> R
    ) rethrows -> R {
        try withExtendedLifetime(self) { try body(buffer(as: type)) }
    }

    /// Calls `body` with the raw bytes, keeping the volume alive for the call.
    @inlinable
    public func withUnsafeMutableRawBufferPointer<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) { try body(rawBuffer) }
    }

    /// C-order linear index of a full index (one entry per axis).
    @inline(__always)
    public func linearIndex(_ index: [Int]) -> Int {
        precondition(index.count == shape.count)
        var linear = 0
        for (i, n) in zip(index, shape) { linear = linear * n + i }
        return linear
    }

    /// One element, as `Double`.
    public func value(at linear: Int) -> Double {
        switch scalarType {
        case .bool, .uint8: return Double(baseAddress.load(fromByteOffset: linear, as: UInt8.self))
        case .int8: return Double(baseAddress.load(fromByteOffset: linear, as: Int8.self))
        case .uint16: return Double(baseAddress.load(fromByteOffset: linear * 2, as: UInt16.self))
        case .int16: return Double(baseAddress.load(fromByteOffset: linear * 2, as: Int16.self))
        case .uint32: return Double(baseAddress.load(fromByteOffset: linear * 4, as: UInt32.self))
        case .int32: return Double(baseAddress.load(fromByteOffset: linear * 4, as: Int32.self))
        case .uint64: return Double(baseAddress.load(fromByteOffset: linear * 8, as: UInt64.self))
        case .int64: return Double(baseAddress.load(fromByteOffset: linear * 8, as: Int64.self))
        case .float16: return Double(baseAddress.load(fromByteOffset: linear * 2, as: Float16.self))
        case .float32: return Double(baseAddress.load(fromByteOffset: linear * 4, as: Float.self))
        case .float64: return baseAddress.load(fromByteOffset: linear * 8, as: Double.self)
        }
    }

    /// Stores one element, converting (and clamping, for integers) from `Double`.
    public func setValue(_ value: Double, at linear: Int) {
        switch scalarType {
        case .bool: baseAddress.storeBytes(of: value != 0 ? 1 : 0, toByteOffset: linear, as: UInt8.self)
        case .uint8: baseAddress.storeBytes(of: UInt8(clampingDouble: value), toByteOffset: linear, as: UInt8.self)
        case .int8: baseAddress.storeBytes(of: Int8(clampingDouble: value), toByteOffset: linear, as: Int8.self)
        case .uint16: baseAddress.storeBytes(of: UInt16(clampingDouble: value), toByteOffset: linear * 2, as: UInt16.self)
        case .int16: baseAddress.storeBytes(of: Int16(clampingDouble: value), toByteOffset: linear * 2, as: Int16.self)
        case .uint32: baseAddress.storeBytes(of: UInt32(clampingDouble: value), toByteOffset: linear * 4, as: UInt32.self)
        case .int32: baseAddress.storeBytes(of: Int32(clampingDouble: value), toByteOffset: linear * 4, as: Int32.self)
        case .uint64: baseAddress.storeBytes(of: UInt64(clampingDouble: value), toByteOffset: linear * 8, as: UInt64.self)
        case .int64: baseAddress.storeBytes(of: Int64(clampingDouble: value), toByteOffset: linear * 8, as: Int64.self)
        case .float16: baseAddress.storeBytes(of: Float16(value), toByteOffset: linear * 2, as: Float16.self)
        case .float32: baseAddress.storeBytes(of: Float(value), toByteOffset: linear * 4, as: Float.self)
        case .float64: baseAddress.storeBytes(of: value, toByteOffset: linear * 8, as: Double.self)
        }
    }

    /// A view of the contiguous block a leading index selects: with
    /// `shape = [T, Z, Y, X]`, `frame([t])` is the `[Z, Y, X]` volume at `t`.
    /// The trailing axes are contiguous in C order, so this never copies.
    public func frame(_ leading: [Int]) -> VolumeData {
        precondition(leading.count <= shape.count)
        if leading.isEmpty { return self }
        let lead = Array(shape.prefix(leading.count))
        for (i, n) in zip(leading, lead) { precondition(i >= 0 && i < n, "frame index \(leading) outside \(lead)") }
        let rest = Array(shape.dropFirst(leading.count))
        let frameElements = rest.reduce(1, *)
        var linear = 0
        for (i, n) in zip(leading, lead) { linear = linear * n + i }
        return VolumeData(view: self, offsetBytes: linear * frameElements * scalarType.byteSize, shape: rest)
    }

    /// The same values with another shape of equal element count, sharing storage.
    public func reshaped(_ newShape: [Int]) -> VolumeData {
        precondition(newShape.reduce(1, *) == count, "cannot reshape \(shape) to \(newShape)")
        return VolumeData(view: self, offsetBytes: 0, shape: newShape)
    }

    /// An owning copy.
    public func copy() -> VolumeData {
        let out = VolumeData(scalarType: scalarType, shape: shape)
        if byteCount > 0 { out.baseAddress.copyMemory(from: baseAddress, byteCount: byteCount) }
        return out
    }

    /// The values converted to another type (integers round and clamp;
    /// `bool` is "nonzero").
    public func converted(to target: ScalarType) -> VolumeData {
        if target == scalarType { return copy() }
        let out = VolumeData(scalarType: target, shape: shape)
        let n = count
        if target == .float32 {
            struct ToFloat: VoxelVisitor {
                let dst: UnsafeMutablePointer<Float>
                let n: Int
                func visit<T: VoxelScalar>(_ src: UnsafeBufferPointer<T>) {
                    DispatchQueue.concurrentPerform(iterations: VolumeData.chunks(n)) { c in
                        for i in VolumeData.chunkRange(c, n) { dst[i] = Float(src[i].doubleValue) }
                    }
                }
            }
            visit(ToFloat(dst: out.pointer(as: Float.self), n: n))
            return out
        }
        DispatchQueue.concurrentPerform(iterations: VolumeData.chunks(n)) { c in
            for i in VolumeData.chunkRange(c, n) { out.setValue(value(at: i), at: i) }
        }
        return out
    }

    /// Calls the visitor with the elements as their Swift type (`UInt8` for
    /// `bool`), so that generic code runs specialised per type. Inlinable,
    /// so a visitor in another module is specialised too; the volume is
    /// kept alive while the visitor runs.
    @inlinable
    public func visit<V: VoxelVisitor>(_ visitor: V) -> V.Result {
        withExtendedLifetime(self) { visitUnretained(visitor) }
    }

    @inlinable
    internal func visitUnretained<V: VoxelVisitor>(_ visitor: V) -> V.Result {
        func call<T: VoxelScalar>(_ t: T.Type) -> V.Result {
            visitor.visit(UnsafeBufferPointer(start: baseAddress.assumingMemoryBound(to: T.self), count: count))
        }
        switch scalarType {
        case .bool, .uint8: return call(UInt8.self)
        case .int8: return call(Int8.self)
        case .uint16: return call(UInt16.self)
        case .int16: return call(Int16.self)
        case .uint32: return call(UInt32.self)
        case .int32: return call(Int32.self)
        case .uint64: return call(UInt64.self)
        case .int64: return call(Int64.self)
        case .float16: return call(Float16.self)
        case .float32: return call(Float.self)
        case .float64: return call(Double.self)
        }
    }

    // MARK: Statistics

    /// Minimum, maximum, mean and standard deviation of the finite values.
    public func statistics() -> VolumeStatistics {
        struct Moments: VoxelVisitor {
            func visit<T: VoxelScalar>(_ src: UnsafeBufferPointer<T>) -> VolumeStatistics {
                let n = src.count
                let nChunks = VolumeData.chunks(n)
                var partials = [VolumeStatistics.Partial](repeating: .init(), count: nChunks)
                partials.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                        var p = VolumeStatistics.Partial()
                        for i in VolumeData.chunkRange(c, n) { p.add(src[i].doubleValue) }
                        out[c] = p
                    }
                }
                var total = VolumeStatistics.Partial()
                for p in partials { total.merge(p) }
                return total.result
            }
        }
        if count == 0 { return VolumeStatistics(minimum: 0, maximum: 0, mean: 0, standardDeviation: 0, finiteCount: 0) }
        return visit(Moments())
    }

    /// Counts of values in `bins` equal bins over `range` (values outside are
    /// clamped into the first or last bin; non-finite values are skipped).
    public func histogram(bins: Int, range: ClosedRange<Double>) -> [Int] {
        precondition(bins > 0)
        struct Histogram: VoxelVisitor {
            let bins: Int
            let lo: Double
            let scale: Double
            func visit<T: VoxelScalar>(_ src: UnsafeBufferPointer<T>) -> [Int] {
                let n = src.count
                let nChunks = VolumeData.chunks(n)
                var partial = [[Int]](repeating: [], count: nChunks)
                partial.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                        var h = [Int](repeating: 0, count: bins)
                        for i in VolumeData.chunkRange(c, n) {
                            let v = src[i].doubleValue
                            guard v.isFinite else { continue }
                            let b = Int((v - lo) * scale)
                            h[min(bins - 1, max(0, b))] += 1
                        }
                        out[c] = h
                    }
                }
                var total = [Int](repeating: 0, count: bins)
                for h in partial where !h.isEmpty {
                    for b in 0..<bins { total[b] += h[b] }
                }
                return total
            }
        }
        let width = range.upperBound - range.lowerBound
        return visit(Histogram(bins: bins, lo: range.lowerBound, scale: width > 0 ? Double(bins) / width : 0))
    }

    /// Approximate percentiles (0–100) of the finite values, from a fine
    /// histogram between the minimum and maximum.
    public func percentiles(_ ps: [Double], stats: VolumeStatistics? = nil, bins: Int = 8192) -> [Double] {
        let s = stats ?? statistics()
        guard s.finiteCount > 0 else { return ps.map { _ in 0 } }
        if s.maximum <= s.minimum { return ps.map { _ in s.minimum } }
        let h = histogram(bins: bins, range: s.minimum...s.maximum)
        let width = (s.maximum - s.minimum) / Double(bins)
        let total = Double(h.reduce(0, +))
        return ps.map { p in
            let target = max(0, min(100, p)) / 100 * total
            var acc = 0.0
            for (b, c) in h.enumerated() {
                acc += Double(c)
                if acc >= target { return s.minimum + (Double(b) + 0.5) * width }
            }
            return s.maximum
        }
    }

    // MARK: Chunking

    static let chunkSize = 1 << 18

    static func chunks(_ n: Int) -> Int { max(1, (n + chunkSize - 1) / chunkSize) }

    static func chunkRange(_ c: Int, _ n: Int) -> Range<Int> {
        let start = c * chunkSize
        return start..<min(n, start + chunkSize)
    }
}

/// Summary statistics of a volume's finite values.
public struct VolumeStatistics: Sendable, Hashable, Codable {
    public var minimum: Double
    public var maximum: Double
    public var mean: Double
    public var standardDeviation: Double
    public var finiteCount: Int

    public init(minimum: Double, maximum: Double, mean: Double, standardDeviation: Double, finiteCount: Int) {
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.finiteCount = finiteCount
    }

    /// Welford's running moments, mergeable across threads.
    struct Partial {
        var n = 0
        var mean = 0.0
        var m2 = 0.0
        var lo = Double.infinity
        var hi = -Double.infinity

        @inline(__always)
        mutating func add(_ v: Double) {
            guard v.isFinite else { return }
            n += 1
            let d = v - mean
            mean += d / Double(n)
            m2 += d * (v - mean)
            if v < lo { lo = v }
            if v > hi { hi = v }
        }

        mutating func merge(_ o: Partial) {
            guard o.n > 0 else { return }
            guard n > 0 else { self = o; return }
            let total = n + o.n
            let d = o.mean - mean
            mean += d * Double(o.n) / Double(total)
            m2 += o.m2 + d * d * Double(n) * Double(o.n) / Double(total)
            n = total
            lo = min(lo, o.lo)
            hi = max(hi, o.hi)
        }

        var result: VolumeStatistics {
            n == 0
                ? VolumeStatistics(minimum: 0, maximum: 0, mean: 0, standardDeviation: 0, finiteCount: 0)
                : VolumeStatistics(minimum: lo, maximum: hi, mean: mean,
                                   standardDeviation: (m2 / Double(n)).squareRoot(), finiteCount: n)
        }
    }
}

/// Generic code over a volume's element type: `VolumeData.visit(_:)` calls
/// `visit` with the elements as their Swift type.
public protocol VoxelVisitor {
    associatedtype Result
    func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) -> Result
}

/// A Swift type a `VolumeData` can hold.
public protocol VoxelScalar: Sendable {
    static var scalarType: ScalarType { get }
    var doubleValue: Double { get }
}

extension UInt8: VoxelScalar {
    public static var scalarType: ScalarType { .uint8 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Int8: VoxelScalar {
    public static var scalarType: ScalarType { .int8 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension UInt16: VoxelScalar {
    public static var scalarType: ScalarType { .uint16 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Int16: VoxelScalar {
    public static var scalarType: ScalarType { .int16 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension UInt32: VoxelScalar {
    public static var scalarType: ScalarType { .uint32 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Int32: VoxelScalar {
    public static var scalarType: ScalarType { .int32 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension UInt64: VoxelScalar {
    public static var scalarType: ScalarType { .uint64 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Int64: VoxelScalar {
    public static var scalarType: ScalarType { .int64 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Float16: VoxelScalar {
    public static var scalarType: ScalarType { .float16 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Float: VoxelScalar {
    public static var scalarType: ScalarType { .float32 }
    @inline(__always) public var doubleValue: Double { Double(self) }
}
extension Double: VoxelScalar {
    public static var scalarType: ScalarType { .float64 }
    @inline(__always) public var doubleValue: Double { self }
}

extension FixedWidthInteger {
    /// Rounds to nearest and clamps into the type's range; NaN becomes 0.
    @inline(__always)
    public init(clampingDouble value: Double) {
        if value.isNaN { self = 0; return }
        let r = value.rounded()
        if r <= Double(Self.min) { self = Self.min; return }
        if r >= Double(Self.max) { self = Self.max; return }
        self = Self(r)
    }
}
