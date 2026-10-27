import Foundation
import simd

/// Edits are stored per *chunk*: a block of `editChunkLength` consecutive
/// linear voxel indices of one layer.
let editChunkShift = 12
let editChunkLength = 1 << editChunkShift
let editChunkMask = editChunkLength - 1
private let bitmapWords = editChunkLength / 64
/// Above this many position runs a chunk stores a bitmap (512 bytes) instead.
private let maxPositionRuns = editChunkLength / 32

/// The changed voxels of one chunk of one layer, with their old and new
/// values, compressed:
///
/// - positions: `.all` (the whole chunk), `.runs` (packed `start << 16 |
///   length − 1`) or `.bitmap` (one bit per voxel), whichever is smallest;
/// - values, in position order: `.uniform`, `.runs` (packed `value << 16 |
///   length − 1`) or `.raw`.
///
/// A paint or fill stores a few bytes per chunk (uniform old and new values
/// over a handful of runs); a noisy threshold stores at most a 512-byte
/// bitmap plus its values.
struct ChunkChange: Sendable {
    enum Positions: Sendable {
        case all
        case runs([UInt32])
        case bitmap([UInt64])
    }

    enum Values: Sendable {
        case uniform(UInt16)
        case runs([UInt32])
        case raw([UInt16])
    }

    /// Chunk number: the chunk covers linear indices `index << editChunkShift ..< + editChunkLength`.
    var index: Int
    /// Number of changed voxels.
    var count: Int
    var positions: Positions
    var oldValues: Values
    var newValues: Values

    var base: Int { index << editChunkShift }

    /// Approximate heap and inline bytes held.
    var byteSize: Int {
        func size(_ p: Positions) -> Int {
            switch p {
            case .all: return 0
            case .runs(let r): return r.count * 4 + 32
            case .bitmap(let b): return b.count * 8 + 32
            }
        }
        func size(_ v: Values) -> Int {
            switch v {
            case .uniform: return 0
            case .runs(let r): return r.count * 4 + 32
            case .raw(let r): return r.count * 2 + 32
            }
        }
        return 64 + size(positions) + size(oldValues) + size(newValues)
    }

    var inverted: ChunkChange {
        ChunkChange(index: index, count: count, positions: positions, oldValues: newValues, newValues: oldValues)
    }

    // MARK: Encoding

    /// Encodes `count ≥ 1` changes at ascending chunk offsets.
    static func encode(index: Int, offsets: UnsafePointer<UInt16>, old: UnsafePointer<UInt16>,
                       new: UnsafePointer<UInt16>, count n: Int) -> ChunkChange {
        precondition(n > 0 && n <= editChunkLength)
        let positions: Positions
        if n == editChunkLength {
            positions = .all
        } else {
            var runCount = 1
            if n > 1 {
                for i in 1..<n where offsets[i] != offsets[i - 1] &+ 1 { runCount += 1 }
            }
            if runCount <= maxPositionRuns {
                var runs = [UInt32]()
                runs.reserveCapacity(runCount)
                var start = Int(offsets[0]), length = 1
                if n > 1 {
                    for i in 1..<n {
                        let o = Int(offsets[i])
                        if o == start + length {
                            length += 1
                        } else {
                            runs.append(UInt32(start) << 16 | UInt32(length - 1))
                            start = o
                            length = 1
                        }
                    }
                }
                runs.append(UInt32(start) << 16 | UInt32(length - 1))
                positions = .runs(runs)
            } else {
                var words = [UInt64](repeating: 0, count: bitmapWords)
                words.withUnsafeMutableBufferPointer { w in
                    for i in 0..<n {
                        let o = Int(offsets[i])
                        w[o >> 6] |= 1 << UInt64(o & 63)
                    }
                }
                positions = .bitmap(words)
            }
        }
        return ChunkChange(index: index, count: n, positions: positions,
                           oldValues: encodeValues(old, n), newValues: encodeValues(new, n))
    }

    private static func encodeValues(_ v: UnsafePointer<UInt16>, _ n: Int) -> Values {
        var runCount = 1
        if n > 1 {
            for i in 1..<n where v[i] != v[i - 1] { runCount += 1 }
        }
        if runCount == 1 { return .uniform(v[0]) }
        if runCount * 2 < n {
            var runs = [UInt32]()
            runs.reserveCapacity(runCount)
            var current = v[0], length = 1
            for i in 1..<n {
                if v[i] == current {
                    length += 1
                } else {
                    runs.append(UInt32(current) << 16 | UInt32(length - 1))
                    current = v[i]
                    length = 1
                }
            }
            runs.append(UInt32(current) << 16 | UInt32(length - 1))
            return .runs(runs)
        }
        return .raw(Array(UnsafeBufferPointer(start: v, count: n)))
    }

    // MARK: Decoding

    /// Calls `body(offset, length)` for each run of changed voxels (offsets
    /// within the chunk), ascending.
    @inline(__always)
    func forEachPositionRun(_ body: (Int, Int) -> Void) {
        switch positions {
        case .all:
            body(0, editChunkLength)
        case .runs(let runs):
            for r in runs { body(Int(r >> 16), Int(r & 0xFFFF) + 1) }
        case .bitmap(let words):
            words.withUnsafeBufferPointer { w in
                var from = 0
                while from < editChunkLength {
                    guard let start = nextSetBit(w, from) else { return }
                    let end = nextClearBit(w, start)
                    body(start, end - start)
                    from = end
                }
            }
        }
    }

    /// Writes `values` (old or new) at the changed positions; `chunk` points
    /// to the chunk's first voxel.
    func write(_ values: Values, into chunk: UnsafeMutablePointer<UInt16>) {
        switch values {
        case .uniform(let v):
            forEachPositionRun { o, l in (chunk + o).update(repeating: v, count: l) }
        case .raw(let raw):
            raw.withUnsafeBufferPointer { src in
                var c = 0
                forEachPositionRun { o, l in
                    (chunk + o).update(from: src.baseAddress! + c, count: l)
                    c += l
                }
            }
        case .runs(let runs):
            var ri = 0
            var value = UInt16(truncatingIfNeeded: runs[0] >> 16)
            var remaining = Int(runs[0] & 0xFFFF) + 1
            forEachPositionRun { o, l in
                var o = o, l = l
                while l > 0 {
                    if remaining == 0 {
                        ri += 1
                        value = UInt16(truncatingIfNeeded: runs[ri] >> 16)
                        remaining = Int(runs[ri] & 0xFFFF) + 1
                    }
                    let take = min(l, remaining)
                    (chunk + o).update(repeating: value, count: take)
                    o += take
                    l -= take
                    remaining -= take
                }
            }
        }
    }

    /// Whether the chunk currently holds `values` at the changed positions.
    func matches(_ values: Values, in chunk: UnsafePointer<UInt16>) -> Bool {
        var ok = true
        var cursor = ValueCursor(values)
        forEachPositionRun { o, l in
            guard ok else { return }
            for i in 0..<l where chunk[o + i] != cursor.next() {
                ok = false
                return
            }
        }
        return ok
    }

    /// Calls `body(offset, old, new)` for every changed voxel, ascending.
    func forEachChange(_ body: (Int, UInt16, UInt16) -> Void) {
        var olds = ValueCursor(oldValues)
        var news = ValueCursor(newValues)
        forEachPositionRun { o, l in
            for i in 0..<l { body(o + i, olds.next(), news.next()) }
        }
    }

    /// Adds the bounding box of the changed voxels (inclusive `lo`/`hi`) for
    /// a volume of padded `shape`.
    func accumulateBounds(lo: inout SIMD3<Int>, hi: inout SIMD3<Int>, shape: SIMD3<Int>) {
        let n1 = shape.y, n2 = shape.z
        let b = base
        forEachPositionRun { o, l in
            let s = b + o, e = b + o + l - 1
            let rowS = s / n2, rowE = e / n2
            let zS = rowS / n1, zE = rowE / n1
            lo.x = min(lo.x, zS)
            hi.x = max(hi.x, zE)
            if zS == zE {
                lo.y = min(lo.y, rowS - zS * n1)
                hi.y = max(hi.y, rowE - zE * n1)
            } else {
                lo.y = 0
                hi.y = n1 - 1
            }
            if rowS == rowE {
                lo.z = min(lo.z, s - rowS * n2)
                hi.z = max(hi.z, e - rowE * n2)
            } else {
                lo.z = 0
                hi.z = n2 - 1
            }
        }
    }

    // MARK: Combining

    /// `a` then `b` on the same chunk: voxels changed by both keep `a`'s old
    /// and `b`'s new value; voxels whose final value equals their original
    /// one are dropped. `nil` when nothing remains.
    static func compose(_ a: ChunkChange, _ b: ChunkChange) -> ChunkChange? {
        precondition(a.index == b.index)
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: editChunkLength * 3) { buf in
            withUnsafeTemporaryAllocation(of: Bool.self, capacity: editChunkLength) { flags in
                let olds = buf.baseAddress!
                let news = olds + editChunkLength
                let offs = news + editChunkLength
                flags.initialize(repeating: false)
                a.forEachChange { o, ov, nv in
                    flags[o] = true
                    olds[o] = ov
                    news[o] = nv
                }
                b.forEachChange { o, ov, nv in
                    if flags[o] {
                        news[o] = nv
                    } else {
                        flags[o] = true
                        olds[o] = ov
                        news[o] = nv
                    }
                }
                var n = 0
                for o in 0..<editChunkLength where flags[o] && olds[o] != news[o] {
                    offs[n] = UInt16(o)
                    olds[n] = olds[o]
                    news[n] = news[o]
                    n += 1
                }
                return n == 0 ? nil : encode(index: a.index, offsets: offs, old: olds, new: news, count: n)
            }
        }
    }

    /// Joins the changes of one chunk recorded in two parts, every offset of
    /// `a` lying before every offset of `b`.
    static func concatenate(_ a: ChunkChange, _ b: ChunkChange) -> ChunkChange {
        precondition(a.index == b.index)
        let n = a.count + b.count
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: n * 3) { buf in
            let offs = buf.baseAddress!, olds = offs + n, news = olds + n
            var i = 0
            let add: (Int, UInt16, UInt16) -> Void = { o, ov, nv in
                offs[i] = UInt16(o)
                olds[i] = ov
                news[i] = nv
                i += 1
            }
            a.forEachChange(add)
            b.forEachChange(add)
            return encode(index: a.index, offsets: offs, old: olds, new: news, count: n)
        }
    }
}

/// Iterates a `Values` stream one value at a time.
struct ValueCursor {
    private let values: ChunkChange.Values
    private var position = 0
    private var runIndex = 0
    private var remaining = 0
    private var current: UInt16 = 0

    init(_ values: ChunkChange.Values) {
        self.values = values
        if case .uniform(let v) = values { current = v }
    }

    @inline(__always)
    mutating func next() -> UInt16 {
        switch values {
        case .uniform(let v):
            return v
        case .raw(let raw):
            let v = raw[position]
            position += 1
            return v
        case .runs(let runs):
            if remaining == 0 {
                let r = runs[runIndex]
                runIndex += 1
                current = UInt16(truncatingIfNeeded: r >> 16)
                remaining = Int(r & 0xFFFF) + 1
            }
            remaining -= 1
            return current
        }
    }
}

@inline(__always)
private func nextSetBit(_ w: UnsafeBufferPointer<UInt64>, _ from: Int) -> Int? {
    var i = from >> 6
    guard i < w.count else { return nil }
    var word = w[i] & (UInt64.max << UInt64(from & 63))
    while word == 0 {
        i += 1
        if i == w.count { return nil }
        word = w[i]
    }
    return i << 6 + word.trailingZeroBitCount
}

@inline(__always)
private func nextClearBit(_ w: UnsafeBufferPointer<UInt64>, _ from: Int) -> Int {
    var i = from >> 6
    guard i < w.count else { return w.count << 6 }
    var word = ~w[i] & (UInt64.max << UInt64(from & 63))
    while word == 0 {
        i += 1
        if i == w.count { return w.count << 6 }
        word = ~w[i]
    }
    return i << 6 + word.trailingZeroBitCount
}
