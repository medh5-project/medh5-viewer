import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class VoxelEditTests: XCTestCase {
    /// Builds a layer change from (index, old, new) triples.
    private func change(_ entries: [(Int, UInt16, UInt16)], layer: Int = 0, shape: SIMD3<Int>) -> LayerChange {
        let b = LayerChangeBuilder(layer: layer)
        for (i, o, n) in entries.sorted(by: { $0.0 < $1.0 }) { b.append(i, old: o, new: n) }
        return LayerChange(layer: layer, chunks: b.finish(), shape: shape)
    }

    /// Changes of every density round-trip exactly through the chunk codec.
    func testCodecRoundTripsAllDensities() throws {
        let shape = SIMD3(7, 33, 61) // 14091 voxels: three full chunks and a partial one
        let n = shape.x * shape.y * shape.z
        var rng = SeededRandom(42)
        for density in [0.0005, 0.01, 0.2, 0.5, 0.97, 1.0] {
            for valueMode in 0..<3 {
                var original = [UInt16](repeating: 0, count: n)
                for i in 0..<n { original[i] = UInt16.random(in: 0...3, using: &rng) }
                var entries: [(Int, UInt16, UInt16)] = []
                var expected = original
                for i in 0..<n where Double.random(in: 0..<1, using: &rng) < density {
                    let new: UInt16
                    switch valueMode {
                    case 0: new = 7 // uniform
                    case 1: new = UInt16((i / 300) % 4 + 10) // long runs
                    default: new = UInt16.random(in: 10...5000, using: &rng) // noise
                    }
                    entries.append((i, original[i], new))
                    expected[i] = new
                }
                guard !entries.isEmpty else { continue }
                let c = change(entries, shape: shape)
                XCTAssertEqual(c.voxelCount, entries.count)
                var data = original
                data.withUnsafeMutableBufferPointer { c.write(into: $0.baseAddress!, forward: true) }
                XCTAssertEqual(data, expected, "density \(density) mode \(valueMode)")
                XCTAssertTrue(data.withUnsafeBufferPointer { c.matches($0.baseAddress!, forward: false) })
                data.withUnsafeMutableBufferPointer { c.write(into: $0.baseAddress!, forward: false) }
                XCTAssertEqual(data, original)
                // Decoding lists the changes in order.
                var decoded: [(Int, UInt16, UInt16)] = []
                c.forEachChange { decoded.append(($0, $1, $2)) }
                XCTAssertEqual(decoded.map(\.0), entries.map(\.0))
                XCTAssertEqual(decoded.map(\.2), entries.map(\.2))
            }
        }
    }

    func testBoundsAreTight() {
        let shape = SIMD3(10, 20, 30)
        let lin = { (k: SIMD3<Int>) in (k.x * 20 + k.y) * 30 + k.z }
        let c = change([(lin(SIMD3(2, 3, 4)), 0, 1), (lin(SIMD3(5, 17, 9)), 0, 1), (lin(SIMD3(3, 1, 25)), 0, 1)], shape: shape)
        XCTAssertEqual(c.bounds, VoxelBox(lower: SIMD3(2, 1, 4), upper: SIMD3(6, 18, 26)))
    }

    /// A contiguous fill of a million voxels costs a few bytes per chunk.
    func testUniformFillIsCompact() {
        let shape = SIMD3(100, 100, 100)
        let b = LayerChangeBuilder(layer: 0)
        for i in 0..<1_000_000 { b.append(i, old: 0, new: 5) }
        let c = LayerChange(layer: 0, chunks: b.finish(), shape: shape)
        XCTAssertEqual(c.voxelCount, 1_000_000)
        XCTAssertLessThan(c.byteSize, 30_000, "\(c.byteSize) bytes")
        // A noisy change of every other voxel stays near a bitmap per chunk.
        let b2 = LayerChangeBuilder(layer: 0)
        var rng = SeededRandom(1)
        var count = 0
        for i in 0..<1_000_000 where Bool.random(using: &rng) { b2.append(i, old: 0, new: 5); count += 1 }
        let c2 = LayerChange(layer: 0, chunks: b2.finish(), shape: shape)
        XCTAssertEqual(c2.voxelCount, count)
        XCTAssertLessThan(c2.byteSize, 200_000, "\(c2.byteSize) bytes")
    }

    /// Composition equals applying the edits in sequence, and drops voxels
    /// that return to their original value.
    func testCompositionMatchesSequence() throws {
        let m = try makeModel(shape: [6, 40, 50])
        let original = snapshot(m)
        let e1 = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.y < 20 })
        m.apply(e1)
        let e2 = try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.y >= 10 && $0.y < 30 })
        m.apply(e2)
        let e3 = try m.makeEdit(.erase(1), over: makeMask(m.shape) { $0.y < 5 })
        m.apply(e3)
        let e4 = try m.makeEdit(.paint(3), over: makeMask(m.shape) { $0.z < 4 })
        m.apply(e4)
        let final = snapshot(m)
        let composite = e1.followed(by: e2).followed(by: e3).followed(by: e4)
        // Rows y < 5 went 0 → 1 → 0 in layer 0: not part of the composite.
        XCTAssertEqual(composite.change(forLayer: 0)?.voxelCount, 6 * 25 * 50)
        m.revert(composite)
        XCTAssertEqual(snapshot(m), original)
        m.apply(composite)
        XCTAssertEqual(snapshot(m), final)
        m.revert(composite.inverse.inverse)
        XCTAssertEqual(snapshot(m), original)
    }

    /// Edits built in parallel slabs equal edits built sequentially, including
    /// chunks split across slab boundaries.
    func testParallelBuildMatchesSequential() throws {
        let m = try makeModel(shape: [64, 37, 41]) // slices of 1517 voxels: chunks straddle slices
        var rng = SeededRandom(9)
        var mask = VoxelMask(bounds: VoxelBox(shape: m.shape))
        mask.withUnsafeMutableBytes { p in
            for i in 0..<(64 * 37 * 41) { p[i] = UInt8.random(in: 0...3, using: &rng) == 0 ? 1 : 0 }
        }
        let edit = try m.makeEdit(.paint(2), over: mask)
        var expected: [Int] = []
        for i in 0..<(64 * 37 * 41) where mask.bytes[i] != 0 { expected.append(i) }
        var got: [Int] = []
        edit.forEachChange { _, li, o, n in
            XCTAssertEqual(o, 0)
            XCTAssertEqual(n, 2)
            got.append(li)
        }
        XCTAssertEqual(got, expected)
    }

    func testInverseSwapsValuesAndMetadata() throws {
        let m = try makeModel(shape: [3, 8, 8])
        let before = m.metadata
        let e = try m.makeEdit(.paint(3), over: makeMask(m.shape) { $0.x == 1 })
        XCTAssertNotNil(e.metadataChange)
        m.apply(e)
        XCTAssertTrue(m.classIDs.contains(3))
        m.apply(e.inverse)
        XCTAssertEqual(m.metadata, before)
        XCTAssertTrue(voxels(of: 3, in: m).isEmpty)
    }
}
