import Foundation
import simd
import MedH5Core

/// The voxel changes of one segmentation layer: changed linear indices with
/// their old and new values, block-compressed in chunks of 4096 voxels.
public struct LayerChange: Sendable {
    /// The layer the changes apply to.
    public let layer: Int
    /// Chunks in ascending order.
    let chunks: [ChunkChange]
    /// Number of changed voxels.
    public let voxelCount: Int
    /// The tight box of the changed voxels.
    public let bounds: VoxelBox

    init(layer: Int, chunks: [ChunkChange], shape: SIMD3<Int>) {
        self.layer = layer
        self.chunks = chunks
        voxelCount = chunks.reduce(0) { $0 + $1.count }
        var lo = SIMD3<Int>(Int.max, Int.max, Int.max)
        var hi = SIMD3<Int>(Int.min, Int.min, Int.min)
        for c in chunks { c.accumulateBounds(lo: &lo, hi: &hi, shape: shape) }
        bounds = chunks.isEmpty ? .empty : VoxelBox(lower: lo, upper: hi &+ 1)
    }

    private init(layer: Int, chunks: [ChunkChange], voxelCount: Int, bounds: VoxelBox) {
        self.layer = layer
        self.chunks = chunks
        self.voxelCount = voxelCount
        self.bounds = bounds
    }

    /// Approximate memory held, in bytes.
    public var byteSize: Int { chunks.reduce(64) { $0 + $1.byteSize } }

    var inverted: LayerChange {
        LayerChange(layer: layer, chunks: chunks.map(\.inverted), voxelCount: voxelCount, bounds: bounds)
    }

    /// Calls `body(linearIndex, old, new)` for every changed voxel, ascending.
    public func forEachChange(_ body: (Int, UInt16, UInt16) -> Void) {
        for c in chunks {
            let b = c.base
            c.forEachChange { o, ov, nv in body(b + o, ov, nv) }
        }
    }

    /// Writes the new (`forward`) or old values into a layer's storage.
    func write(into layer: UnsafeMutablePointer<UInt16>, forward: Bool) {
        let n = chunks.count
        if n < 64 {
            for c in chunks { c.write(forward ? c.newValues : c.oldValues, into: layer + c.base) }
            return
        }
        chunks.withUnsafeBufferPointer { cs in
            let pieces = min(n, Parallel.workerCount * 4)
            Parallel.perform(pieces) { p in
                for i in (n * p / pieces)..<(n * (p + 1) / pieces) {
                    let c = cs[i]
                    c.write(forward ? c.newValues : c.oldValues, into: layer + c.base)
                }
            }
        }
    }

    /// Whether the layer currently holds the old (`forward`) or new values at
    /// every changed voxel, i.e. whether the change can be applied (or
    /// reverted) without clobbering other edits.
    func matches(_ layer: UnsafePointer<UInt16>, forward: Bool) -> Bool {
        chunks.allSatisfy { c in c.matches(forward ? c.oldValues : c.newValues, in: layer + c.base) }
    }

    /// `a` then `b` on the same layer.
    static func compose(_ a: LayerChange, _ b: LayerChange, shape: SIMD3<Int>) -> LayerChange? {
        precondition(a.layer == b.layer)
        var out: [ChunkChange] = []
        out.reserveCapacity(a.chunks.count + b.chunks.count)
        var i = 0, j = 0
        while i < a.chunks.count || j < b.chunks.count {
            if j == b.chunks.count || (i < a.chunks.count && a.chunks[i].index < b.chunks[j].index) {
                out.append(a.chunks[i])
                i += 1
            } else if i == a.chunks.count || b.chunks[j].index < a.chunks[i].index {
                out.append(b.chunks[j])
                j += 1
            } else {
                if let c = ChunkChange.compose(a.chunks[i], b.chunks[j]) { out.append(c) }
                i += 1
                j += 1
            }
        }
        return out.isEmpty ? nil : LayerChange(layer: a.layer, chunks: out, shape: shape)
    }

    /// Joins chunk lists recorded over consecutive ascending linear ranges;
    /// a chunk split between two parts is merged.
    static func concatenate(_ parts: [[ChunkChange]]) -> [ChunkChange] {
        var out: [ChunkChange] = []
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts where !part.isEmpty {
            if let last = out.last, last.index == part[0].index {
                out[out.count - 1] = ChunkChange.concatenate(last, part[0])
                out.append(contentsOf: part.dropFirst())
            } else {
                out.append(contentsOf: part)
            }
        }
        return out
    }
}

/// Records changes of one layer at strictly ascending linear indices and
/// encodes them chunk by chunk.
final class LayerChangeBuilder {
    let layer: Int
    private(set) var chunks: [ChunkChange] = []
    private var current = -1
    private var n = 0
    private var lastLinear = -1
    private let offsets: UnsafeMutablePointer<UInt16>
    private let olds: UnsafeMutablePointer<UInt16>
    private let news: UnsafeMutablePointer<UInt16>

    init(layer: Int) {
        self.layer = layer
        offsets = .allocate(capacity: editChunkLength)
        olds = .allocate(capacity: editChunkLength)
        news = .allocate(capacity: editChunkLength)
    }

    deinit {
        offsets.deallocate()
        olds.deallocate()
        news.deallocate()
    }

    var isEmpty: Bool { chunks.isEmpty && n == 0 }

    /// Records a change; `linear` must be greater than every index recorded before.
    @inline(__always)
    func append(_ linear: Int, old: UInt16, new: UInt16) {
        assert(linear > lastLinear, "changes must be recorded in ascending order")
        lastLinear = linear
        let c = linear >> editChunkShift
        if c != current {
            flush()
            current = c
        }
        offsets[n] = UInt16(truncatingIfNeeded: linear & editChunkMask)
        olds[n] = old
        news[n] = new
        n += 1
    }

    private func flush() {
        if n > 0 {
            chunks.append(.encode(index: current, offsets: offsets, old: olds, new: news, count: n))
            n = 0
        }
    }

    /// The chunks recorded (the builder is finished afterwards).
    func finish() -> [ChunkChange] {
        flush()
        return chunks
    }
}

/// One builder per layer, created on first use.
final class LayerBuilderSet {
    private(set) var builders: [LayerChangeBuilder?]

    init(layerCount: Int) {
        builders = Array(repeating: nil, count: layerCount)
    }

    @inline(__always)
    func append(layer: Int, _ linear: Int, old: UInt16, new: UInt16) {
        if let b = builders[layer] {
            b.append(linear, old: old, new: new)
        } else {
            let b = LayerChangeBuilder(layer: layer)
            builders[layer] = b
            b.append(linear, old: old, new: new)
        }
    }

    /// Per layer, the chunks recorded (empty for untouched layers).
    func finish() -> [[ChunkChange]] {
        builders.map { $0?.finish() ?? [] }
    }
}
