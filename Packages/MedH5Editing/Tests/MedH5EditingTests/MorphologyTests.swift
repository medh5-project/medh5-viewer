import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class MorphologyTests: XCTestCase {
    let shape = [8, 14, 16]
    let spacing = [2.0, 0.7, 1.1]

    /// Random blobs (unions of small balls and boxes).
    private func blobs(_ seed: UInt64, n: SIMD3<Int>) -> Set<SIMD3<Int>> {
        var rng = SeededRandom(seed)
        var out = Set<SIMD3<Int>>()
        for _ in 0..<4 {
            let c = SIMD3(Int.random(in: 0..<n.x, using: &rng), Int.random(in: 0..<n.y, using: &rng), Int.random(in: 0..<n.z, using: &rng))
            let r = Int.random(in: 1...4, using: &rng)
            let ball = Bool.random(using: &rng)
            out.formUnion(allVoxels(n) { k in
                let d = k &- c
                return ball ? d.x * d.x + d.y * d.y + d.z * d.z <= r * r : abs(d.x) <= r / 2 && abs(d.y) <= r && abs(d.z) <= r
            })
        }
        return out
    }

    /// Every voxel of the grid with its world position.
    private func lattice(_ g: GridGeometry) -> [(SIMD3<Int>, SIMD3<Double>)] {
        let n = g.paddedShape
        var out: [(SIMD3<Int>, SIMD3<Double>)] = []
        for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z {
            out.append((SIMD3(z, y, x), g.worldPosition(ofVoxel: SIMD3(z, y, x))))
        } } }
        return out
    }

    /// Voxels within `r` of a member of `a` (brute force over all pairs).
    private func bruteDilate(_ a: Set<SIMD3<Int>>, _ r: Double, _ g: GridGeometry) -> Set<SIMD3<Int>> {
        let limit = r * r * (1 + LabelMorphology.tolerance)
        let all = lattice(g)
        let members = all.filter { a.contains($0.0) }.map(\.1)
        var out = Set<SIMD3<Int>>()
        for (k, p) in all where members.contains(where: { simd_length_squared($0 - p) <= limit }) { out.insert(k) }
        return out
    }

    /// Members of `a` with no grid voxel outside `a` within `r` (brute force).
    private func bruteErode(_ a: Set<SIMD3<Int>>, _ r: Double, _ g: GridGeometry) -> Set<SIMD3<Int>> {
        let limit = r * r * (1 + LabelMorphology.tolerance)
        let all = lattice(g)
        let background = all.filter { !a.contains($0.0) }.map(\.1)
        var out = Set<SIMD3<Int>>()
        for (k, p) in all where a.contains(k) && !background.contains(where: { simd_length_squared($0 - p) <= limit }) {
            out.insert(k)
        }
        return out
    }

    func testDilateErodeOpenCloseMatchBruteForce() throws {
        let g = makeGeometry(shape: shape, spacing: spacing)
        let n = g.paddedShape
        for (seed, r) in [(UInt64(1), 1.0), (2, 1.9), (3, 3.3), (4, 0.65)] {
            let a = blobs(seed, n: n)
            let mask = makeMask(n) { a.contains($0) }
            let sp = g.paddedSpacing
            let d = voxels(of: try LabelMorphology.dilate(mask, radius: r, spacing: sp, shape: n))
            let e = voxels(of: try LabelMorphology.erode(mask, radius: r, spacing: sp, shape: n))
            let bd = bruteDilate(a, r, g), be = bruteErode(a, r, g)
            XCTAssertEqual(d, bd, "dilate seed \(seed) r \(r)")
            XCTAssertEqual(e, be, "erode seed \(seed) r \(r)")
            XCTAssertEqual(voxels(of: try LabelMorphology.open(mask, radius: r, spacing: sp, shape: n)), bruteDilate(be, r, g), "open \(seed)")
            XCTAssertEqual(voxels(of: try LabelMorphology.close(mask, radius: r, spacing: sp, shape: n)), bruteErode(bd, r, g), "close \(seed)")
        }
    }

    func testModelEditsAndAnisotropicRadius() throws {
        let m = try makeModel(shape: [9, 21, 21], spacing: [3, 1, 1], classes: [(1, 0), (2, 0)], layerCount: 1)
        m.apply(try m.makeEdit(.paint(1), over: VoxelRegion(sortedSpans: [.init(k0: 4, k1: 10, start: 10, end: 11)])))
        let d = try LabelMorphology.dilate(m, classID: 1, radius: 3.5)
        m.apply(d)
        let got = voxels(of: 1, in: m)
        // 3.5 mm reaches one slice across axis 0 (3 mm) but 3 voxels in-plane.
        XCTAssertEqual(Set(got.map(\.x)), [3, 4, 5])
        XCTAssertEqual(got.filter { $0.x == 4 }.count, allVoxels(SIMD3(1, 21, 21)) { k in
            let a = k.y - 10, b = k.z - 10
            return Double(a * a + b * b) <= 3.5 * 3.5
        }.count)
        m.revert(d)
        XCTAssertEqual(voxels(of: 1, in: m).count, 1)
        // In-plane only.
        m.apply(try LabelMorphology.dilate(m, classID: 1, radius: 3.5, sliceAxis: 0))
        XCTAssertEqual(Set(voxels(of: 1, in: m).map(\.x)), [4])
        // Erosion of that disc by 1 mm removes its rim.
        let before = voxels(of: 1, in: m)
        m.apply(try LabelMorphology.erode(m, classID: 1, radius: 1, sliceAxis: 0))
        let after = voxels(of: 1, in: m)
        XCTAssertTrue(after.isSubset(of: before))
        XCTAssertEqual(after, before.filter { k in
            [SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)].allSatisfy { before.contains(k &+ $0) }
        })
    }

    func testDilationRespectsPolicyAndLocks() throws {
        let m = try makeModel(shape: [1, 1, 10], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.z == 2 }
        fillRaw(m, layer: 0, value: 2) { $0.z == 3 }
        m.apply(try m.updateClassEdit(2) { $0.isLocked = true })
        m.apply(try LabelMorphology.dilate(m, classID: 1, radius: 2))
        XCTAssertEqual(voxels(of: 1, in: m).map(\.z).sorted(), [0, 1, 2, 4])
        XCTAssertEqual(voxels(of: 2, in: m).map(\.z), [3])
    }

    func testFillHolesInThreeDimensionsAndPerSlice() throws {
        let m = try makeModel(shape: [20, 20, 20], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        let c = SIMD3(10, 10, 10)
        let r2 = { (k: SIMD3<Int>) in simd_length_squared(SIMD3<Double>(k &- c)) }
        fillRaw(m, layer: 0, value: 1) { r2($0) >= 16 && r2($0) < 49 } // a hollow ball
        m.apply(try LabelMorphology.fillHoles(m, classID: 1))
        XCTAssertEqual(voxels(of: 1, in: m), allVoxels(m.shape) { r2($0) < 49 })

        // A tube along axis 0, open at both ends: no 3-D hole, but a hole in every slice.
        let t = try makeModel(shape: [12, 20, 20], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        let rr = { (k: SIMD3<Int>) in Double((k.y - 10) * (k.y - 10) + (k.z - 10) * (k.z - 10)) }
        fillRaw(t, layer: 0, value: 1) { $0.x >= 2 && $0.x < 10 && rr($0) >= 9 && rr($0) < 25 }
        XCTAssertTrue(try LabelMorphology.fillHoles(t, classID: 1).isEmpty)
        t.apply(try LabelMorphology.fillHoles(t, classID: 1, scope: .slices(axis: 0)))
        XCTAssertEqual(voxels(of: 1, in: t), allVoxels(t.shape) { $0.x >= 2 && $0.x < 10 && rr($0) < 25 })
        // Seen across axis 1, the tube's slices have no holes.
        let t2 = try makeModel(shape: [12, 20, 20], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(t2, layer: 0, value: 1) { $0.x >= 2 && $0.x < 10 && rr($0) >= 9 && rr($0) < 25 }
        XCTAssertTrue(try LabelMorphology.fillHoles(t2, classID: 1, scope: .slices(axis: 1)).isEmpty)
    }

    func testCavityOpenToTheGridBorderIsNotAHole() throws {
        let m = try makeModel(shape: [6, 10, 10], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        // A cup: walls and a floor, open at slice 0 (the grid border).
        fillRaw(m, layer: 0, value: 1) { k in
            let wall = k.y == 2 || k.y == 7 || k.z == 2 || k.z == 7
            let inside = (2...7).contains(k.y) && (2...7).contains(k.z)
            return inside && (wall || k.x == 5)
        }
        XCTAssertTrue(try LabelMorphology.fillHoles(m, classID: 1).isEmpty)
        // Each slice 0…4 has a hole (the cup's inside).
        let e = try LabelMorphology.fillHoles(m, classID: 1, scope: .slices(axis: 0))
        XCTAssertEqual(e.voxelCount, 5 * 16)
    }

    func testKeepLargestAndRemoveSmallComponents() throws {
        let m = try makeModel(shape: [4, 20, 20], spacing: [2, 1, 1], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.x == 1 && (2..<7).contains($0.y) && (2..<8).contains($0.z) } // 30
        fillRaw(m, layer: 0, value: 1) { $0.x == 2 && (12..<14).contains($0.y) && (12..<17).contains($0.z) } // 10
        fillRaw(m, layer: 0, value: 1) { $0.x == 0 && $0.y == 18 && $0.z == 18 } // 1
        let keep = try LabelMorphology.keepLargestComponent(m, classID: 1)
        XCTAssertEqual(keep.voxelCount, 11)
        let small = try LabelMorphology.removeSmallComponents(m, classID: 1, minimumVoxels: 10)
        XCTAssertEqual(small.voxelCount, 1)
        // 25 mm³ = 12.5 voxels of 2 mm³: removes the 10- and 1-voxel parts.
        let byVolume = try LabelMorphology.removeSmallComponents(m, classID: 1, minimumVolume: 25)
        XCTAssertEqual(byVolume.voxelCount, 11)
        m.apply(keep)
        XCTAssertEqual(voxels(of: 1, in: m).count, 30)
    }

    func testMajoritySmoothingRemovesSpecksAndPinholes() throws {
        let m = try makeModel(shape: [12, 12, 12], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { all($0 .>= 2) && all($0 .< 10) && $0 != SIMD3(5, 5, 5) }
        fillRaw(m, layer: 0, value: 1) { $0 == SIMD3(0, 0, 11) }
        m.apply(try LabelMorphology.smooth(m, classID: 1, radius: 1))
        XCTAssertTrue(m.contains(1, at: SIMD3(5, 5, 5)), "pinhole filled")
        XCTAssertFalse(m.contains(1, at: SIMD3(0, 0, 11)), "speck removed")
        XCTAssertFalse(m.contains(1, at: SIMD3(2, 2, 2)), "corner rounded")
        XCTAssertTrue(m.contains(1, at: SIMD3(2, 5, 5)), "face kept")
    }
}

final class ProgressTests: XCTestCase {
    /// Collects progress reports from worker threads.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Double] = []
        func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    }

    func testLongOperationsReportIncreasingProgressToCompletion() throws {
        let m = try makeModel(shape: [64, 64, 64], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { simd_length_squared(SIMD3<Double>($0 &- SIMD3(32, 32, 32))) < 400 }
        let recorder = Recorder()
        let control = OperationControl { recorder.add($0) }
        _ = try LabelMorphology.dilate(m, classID: 1, radius: 2, control: control)
        let v = recorder.values
        XCTAssertFalse(v.isEmpty)
        XCTAssertEqual(v.last, 1)
        XCTAssertEqual(v, v.sorted(), "progress never goes back")
        XCTAssertTrue(v.allSatisfy { (0...1).contains($0) })
    }

    func testCancellationStopsParallelOperations() throws {
        let m = try makeModel(shape: [32, 32, 32], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.x < 16 }
        let control = OperationControl()
        control.cancel()
        XCTAssertThrowsError(try LabelMorphology.dilate(m, classID: 1, radius: 3, control: control)) {
            XCTAssertEqual($0 as? EditingError, .cancelled)
        }
        let image = makeImage(Int16.self, geometry: m.geometry) { Int16($0.x) }
        XCTAssertThrowsError(try Threshold.edit(m, classID: 1, image: image, range: 0...4, control: control))
        XCTAssertThrowsError(try SegmentationStatistics.classStatistics(m, control: control))
    }
}
