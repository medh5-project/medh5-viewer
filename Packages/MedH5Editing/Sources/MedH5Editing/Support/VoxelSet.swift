import Foundation
import simd

/// A set of voxels of one grid, in padded index space, enumerable row by row.
///
/// A *row* is the line of voxels with fixed `(k0, k1)`; `k2` is the fastest
/// (contiguous) axis, so a run of a row is one contiguous range of linear
/// indices. Every editing primitive consumes voxel sets through this
/// protocol: tools build a `VoxelRegion` (row spans, for brush dabs and
/// other analytic shapes) or a `VoxelMask` (a dense byte mask over a box, for
/// fills, thresholds and morphology), and `SegmentationModel` turns either
/// into a `VoxelEdit`.
public protocol VoxelSet: Sendable {
    /// A box holding every member (members lie inside it; it need not be tight).
    var bounds: VoxelBox { get }

    /// Calls `body(start, end)` for each run `start ..< end` of members in
    /// row `(k0, k1)`, in ascending order. Rows outside `bounds` have none.
    func forEachRun(k0: Int, k1: Int, _ body: (_ start: Int, _ end: Int) -> Void)
}

extension VoxelSet {
    /// Number of member voxels.
    public var voxelCount: Int {
        let b = bounds
        guard !b.isEmpty else { return 0 }
        var n = 0
        for k0 in b.lower.x..<b.upper.x {
            for k1 in b.lower.y..<b.upper.y {
                forEachRun(k0: k0, k1: k1) { s, e in n += e - s }
            }
        }
        return n
    }

    /// Whether a voxel is a member.
    public func contains(_ k: SIMD3<Int>) -> Bool {
        guard bounds.contains(k) else { return false }
        var found = false
        forEachRun(k0: k.x, k1: k.y) { s, e in
            if k.z >= s && k.z < e { found = true }
        }
        return found
    }

    /// Calls `body` with every member voxel, in C order.
    public func forEachVoxel(_ body: (SIMD3<Int>) -> Void) {
        let b = bounds
        guard !b.isEmpty else { return }
        for k0 in b.lower.x..<b.upper.x {
            for k1 in b.lower.y..<b.upper.y {
                forEachRun(k0: k0, k1: k1) { s, e in
                    for x in s..<e { body(SIMD3(k0, k1, x)) }
                }
            }
        }
    }

    /// The members as a dense mask over `bounds`.
    public func makeMask() -> VoxelMask {
        let b = bounds
        var mask = VoxelMask(bounds: b)
        guard !b.isEmpty else { return mask }
        let s = b.size
        mask.withUnsafeMutableBytes { bytes in
            for k0 in b.lower.x..<b.upper.x {
                for k1 in b.lower.y..<b.upper.y {
                    let row = ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                    forEachRun(k0: k0, k1: k1) { st, e in
                        for x in st..<e { bytes[row + x] = 1 }
                    }
                }
            }
        }
        return mask
    }
}

// MARK: - Dense mask

/// A dense voxel mask over a box: one byte per voxel of `bounds`, in C order;
/// a voxel is a member when its byte is nonzero.
///
/// The bytes are a Swift array (value semantics, copy on write). For parallel
/// writes, take the pointer once with `withUnsafeMutableBytes` and write
/// disjoint parts from each worker.
public struct VoxelMask: VoxelSet {
    public private(set) var bounds: VoxelBox
    public private(set) var bytes: [UInt8]

    /// An empty (all-zero) mask over `bounds`.
    public init(bounds: VoxelBox) {
        self.bounds = bounds.isEmpty ? .empty : bounds
        self.bytes = [UInt8](repeating: 0, count: bounds.isEmpty ? 0 : bounds.voxelCount)
    }

    /// A mask from bytes in C order over `bounds`.
    public init(bounds: VoxelBox, bytes: [UInt8]) {
        precondition(bytes.count == (bounds.isEmpty ? 0 : bounds.voxelCount), "mask has \(bytes.count) bytes for \(bounds)")
        self.bounds = bounds.isEmpty ? .empty : bounds
        self.bytes = bytes
    }

    /// Offset of an absolute padded voxel in `bytes` (the voxel must be in `bounds`).
    @inline(__always)
    public func offset(of k: SIMD3<Int>) -> Int {
        let s = bounds.size
        return ((k.x - bounds.lower.x) * s.y + (k.y - bounds.lower.y)) * s.z + (k.z - bounds.lower.z)
    }

    /// Membership of an absolute padded voxel; outside `bounds` reads `false`
    /// and writes are ignored.
    public subscript(_ k: SIMD3<Int>) -> Bool {
        get { bounds.contains(k) && bytes[offset(of: k)] != 0 }
        set {
            guard bounds.contains(k) else { return }
            bytes[offset(of: k)] = newValue ? 1 : 0
        }
    }

    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutablePointer<UInt8>) throws -> R) rethrows -> R {
        if bytes.isEmpty {
            var dummy: UInt8 = 0
            return try body(&dummy)
        }
        return try bytes.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    public func withUnsafeBytes<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        if bytes.isEmpty {
            var dummy: UInt8 = 0
            return try body(&dummy)
        }
        return try bytes.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// Number of members.
    public var memberCount: Int {
        bytes.withUnsafeBufferPointer { buf -> Int in
            var n = 0
            for b in buf where b != 0 { n += 1 }
            return n
        }
    }

    public var isEmpty: Bool { !bytes.contains(where: { $0 != 0 }) }

    public func forEachRun(k0: Int, k1: Int, _ body: (Int, Int) -> Void) {
        let b = bounds
        guard k0 >= b.lower.x, k0 < b.upper.x, k1 >= b.lower.y, k1 < b.upper.y else { return }
        let s = b.size
        let rowStart = ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z
        bytes.withUnsafeBufferPointer { buf in
            let row = buf.baseAddress! + rowStart
            scanRuns(row, count: s.z) { a, e in body(a + b.lower.z, e + b.lower.z) }
        }
    }

    /// The tight box of the members (empty when there are none).
    public func memberBounds() -> VoxelBox {
        let b = bounds
        guard !b.isEmpty else { return .empty }
        let s = b.size
        var lo = SIMD3<Int>(Int.max, Int.max, Int.max)
        var hi = SIMD3<Int>(Int.min, Int.min, Int.min)
        bytes.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for z in 0..<s.x {
                for y in 0..<s.y {
                    let row = p + (z * s.y + y) * s.z
                    var first = -1, last = -1
                    scanRuns(row, count: s.z) { a, e in
                        if first < 0 { first = a }
                        last = e - 1
                    }
                    if first >= 0 {
                        lo = pointwiseMin(lo, SIMD3(z, y, first))
                        hi = pointwiseMax(hi, SIMD3(z, y, last))
                    }
                }
            }
        }
        if lo.x == Int.max { return .empty }
        return VoxelBox(lower: lo &+ b.lower, upper: hi &+ b.lower &+ 1)
    }

    /// The same members over their tight box.
    public func trimmed() -> VoxelMask {
        let tight = memberBounds()
        if tight == bounds { return self }
        return cropped(to: tight)
    }

    /// The members inside `box`, as a mask over `box` (voxels of `box`
    /// outside `bounds` are not members).
    public func cropped(to box: VoxelBox) -> VoxelMask {
        var out = VoxelMask(bounds: box)
        let common = box.intersection(bounds)
        guard !common.isEmpty else { return out }
        let src = bounds, s = src.size, d = box.size
        let n = common.size.z
        bytes.withUnsafeBufferPointer { sb in
            out.withUnsafeMutableBytes { db in
                for z in common.lower.x..<common.upper.x {
                    for y in common.lower.y..<common.upper.y {
                        let so = ((z - src.lower.x) * s.y + (y - src.lower.y)) * s.z + (common.lower.z - src.lower.z)
                        let dO = ((z - box.lower.x) * d.y + (y - box.lower.y)) * d.z + (common.lower.z - box.lower.z)
                        (db + dO).update(from: sb.baseAddress! + so, count: n)
                    }
                }
            }
        }
        return out
    }

    /// Members of either mask, over the union of their bounds.
    public func union(_ other: VoxelMask) -> VoxelMask {
        if other.bounds.isEmpty { return self }
        if bounds.isEmpty { return other }
        var out = cropped(to: bounds.union(other.bounds))
        let b = out.bounds, s = b.size
        out.withUnsafeMutableBytes { p in
            for k0 in other.bounds.lower.x..<other.bounds.upper.x {
                for k1 in other.bounds.lower.y..<other.bounds.upper.y {
                    let row = ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                    other.forEachRun(k0: k0, k1: k1) { st, e in
                        (p + row + st).update(repeating: 1, count: e - st)
                    }
                }
            }
        }
        return out
    }

    /// Members of `self` that are not members of `other`.
    public func subtracting(_ other: some VoxelSet) -> VoxelMask {
        var out = self
        let b = bounds
        guard !b.isEmpty else { return out }
        let s = b.size
        out.withUnsafeMutableBytes { p in
            for k0 in b.lower.x..<b.upper.x {
                for k1 in b.lower.y..<b.upper.y {
                    let row = ((k0 - b.lower.x) * s.y + (k1 - b.lower.y)) * s.z - b.lower.z
                    other.forEachRun(k0: k0, k1: k1) { st, e in
                        let a = Swift.max(st, b.lower.z), z = Swift.min(e, b.upper.z)
                        if a < z { (p + row + a).update(repeating: 0, count: z - a) }
                    }
                }
            }
        }
        return out
    }
}

/// Calls `body(start, end)` for each run of nonzero bytes in `row[0..<count]`.
@inline(__always)
func scanRuns(_ row: UnsafePointer<UInt8>, count n: Int, _ body: (Int, Int) -> Void) {
    var x = 0
    while x < n {
        // Skip zeros, eight at a time where aligned runs of zeros allow.
        while x + 8 <= n && UnsafeRawPointer(row + x).loadUnaligned(as: UInt64.self) == 0 { x += 8 }
        while x < n && row[x] == 0 { x += 1 }
        if x >= n { break }
        let start = x
        while x < n && row[x] != 0 { x += 1 }
        body(start, x)
    }
}

// MARK: - Row spans

/// A voxel set stored as row spans `(k0, k1, start ..< end)` in C order:
/// compact for analytic shapes (brush discs and spheres, ROIs) and for sets
/// derived from runs (connected components).
public struct VoxelRegion: VoxelSet {
    public struct Span: Hashable, Sendable {
        public var k0: Int32
        public var k1: Int32
        public var start: Int32
        public var end: Int32

        public init(k0: Int, k1: Int, start: Int, end: Int) {
            self.k0 = Int32(k0)
            self.k1 = Int32(k1)
            self.start = Int32(start)
            self.end = Int32(end)
        }
    }

    /// Spans sorted by `(k0, k1, start)`, non-overlapping within a row.
    public let spans: [Span]
    public let bounds: VoxelBox
    /// `rowStarts[r] ..< rowStarts[r + 1]` are the spans of row `r` of `bounds`.
    private let rowStarts: [Int32]

    public static let empty = VoxelRegion(sortedSpans: [])

    /// A region from spans already sorted by `(k0, k1, start)` and not
    /// overlapping (empty spans are dropped).
    public init(sortedSpans: [Span]) {
        let spans = sortedSpans.filter { $0.end > $0.start }
        self.spans = spans
        guard let first = spans.first, let last = spans.last else {
            bounds = .empty
            rowStarts = [0]
            return
        }
        var lo1 = Int32.max, hi1 = Int32.min, lo2 = Int32.max, hi2 = Int32.min
        for s in spans {
            lo1 = min(lo1, s.k1); hi1 = max(hi1, s.k1)
            lo2 = min(lo2, s.start); hi2 = max(hi2, s.end)
        }
        let b = VoxelBox(lower: SIMD3(Int(first.k0), Int(lo1), Int(lo2)),
                         upper: SIMD3(Int(last.k0) + 1, Int(hi1) + 1, Int(hi2)))
        bounds = b
        let rows = b.size.x * b.size.y
        var starts = [Int32](repeating: 0, count: rows + 1)
        // Count spans per row, then prefix-sum.
        for s in spans {
            let r = (Int(s.k0) - b.lower.x) * b.size.y + (Int(s.k1) - b.lower.y)
            starts[r + 1] += 1
        }
        for r in 0..<rows { starts[r + 1] += starts[r] }
        rowStarts = starts
    }

    /// A region from arbitrary spans: sorts and merges overlapping or
    /// touching spans of a row.
    public init(spans unsorted: [Span]) {
        let sorted = unsorted.filter { $0.end > $0.start }.sorted {
            ($0.k0, $0.k1, $0.start) < ($1.k0, $1.k1, $1.start)
        }
        var merged: [Span] = []
        merged.reserveCapacity(sorted.count)
        for s in sorted {
            if var last = merged.last, last.k0 == s.k0, last.k1 == s.k1, s.start <= last.end {
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        self.init(sortedSpans: merged)
    }

    public var isEmpty: Bool { spans.isEmpty }

    public func forEachRun(k0: Int, k1: Int, _ body: (Int, Int) -> Void) {
        let b = bounds
        guard k0 >= b.lower.x, k0 < b.upper.x, k1 >= b.lower.y, k1 < b.upper.y else { return }
        let r = (k0 - b.lower.x) * b.size.y + (k1 - b.lower.y)
        let a = Int(rowStarts[r]), e = Int(rowStarts[r + 1])
        if a == e { return }
        for i in a..<e { body(Int(spans[i].start), Int(spans[i].end)) }
    }

    /// Number of member voxels.
    public var memberCount: Int { spans.reduce(0) { $0 + Int($1.end - $1.start) } }
}
