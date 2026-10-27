import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class InterpolationTests: XCTestCase {
    func testDiscsInterpolateToDiscsOfInterpolatedRadius() throws {
        let m = try makeModel(shape: [11, 60, 60], spacing: [2, 0.5, 0.5], classes: [(1, 0)], layerCount: 1)
        let c = SIMD2(30.0, 30.0)
        func disc(_ k: SIMD3<Int>, _ rMM: Double) -> Bool {
            let dy = (Double(k.y) - c.x) * 0.5, dz = (Double(k.z) - c.y) * 0.5
            return dy * dy + dz * dz <= rMM * rMM
        }
        let r0 = 4.0, r1 = 12.0
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { ($0.x == 0 && disc($0, r0)) || ($0.x == 10 && disc($0, r1)) }))
        XCTAssertEqual(try SliceInterpolation.keySlices(m, classID: 1, axis: 0), [0, 10])
        let keyBefore = voxels(of: 1, in: m)
        let e = try SliceInterpolation.interpolate(m, classID: 1, axis: 0)
        m.apply(e)
        let all = voxels(of: 1, in: m)
        XCTAssertTrue(keyBefore.isSubset(of: all))
        XCTAssertEqual(all.filter { $0.x == 0 || $0.x == 10 }, keyBefore, "key slices unchanged")
        for s in 1..<10 {
            let r = r0 + (r1 - r0) * Double(s) / 10
            let slice = all.filter { $0.x == s }
            // Every voxel within r − ½ voxel is in, every voxel beyond r + ½ voxel is out.
            for k in allVoxels(SIMD3(1, 60, 60), where: { _ in true }) {
                let v = SIMD3(s, k.y, k.z)
                let dy = (Double(k.y) - c.x) * 0.5, dz = (Double(k.z) - c.y) * 0.5
                let d = (dy * dy + dz * dz).squareRoot()
                if d <= r - 0.5 { XCTAssertTrue(slice.contains(v), "slice \(s) misses \(v) at \(d) mm < r \(r)") }
                if d >= r + 0.5 { XCTAssertFalse(slice.contains(v), "slice \(s) has \(v) at \(d) mm > r \(r)") }
            }
            let area = Double(slice.count) * 0.25
            XCTAssertEqual(area, Double.pi * r * r, accuracy: 2 * Double.pi * r * 0.5, "slice \(s) area")
        }
    }

    func testMovingShapesMorphAndKeySlicesCanBeChosen() throws {
        let m = try makeModel(shape: [9, 30, 30], spacing: [1, 1, 1], classes: [(1, 0)], layerCount: 1)
        // A 5×5 square moving 4 voxels along axis 2 between slices 0 and 8 (the
        // two overlap, as shape-based interpolation needs).
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { k in
            (k.x == 0 && (10..<15).contains(k.y) && (5..<10).contains(k.z))
                || (k.x == 8 && (10..<15).contains(k.y) && (9..<14).contains(k.z))
        }))
        m.apply(try SliceInterpolation.interpolate(m, classID: 1, axis: 0))
        let mid = voxels(of: 1, in: m).filter { $0.x == 4 }
        // Halfway: the square halfway between, its corners rounded by the distance blend.
        let halfway = allVoxels(m.shape) { $0.x == 4 && (10..<15).contains($0.y) && (7..<12).contains($0.z) }
        XCTAssertTrue(mid.isSubset(of: halfway))
        XCTAssertGreaterThanOrEqual(mid.count, 21)
        XCTAssertTrue(halfway.filter { (11..<14).contains($0.y) }.isSubset(of: mid), "the middle rows are whole")
        for s in 1..<8 {
            let slice = voxels(of: 1, in: m).filter { $0.x == s }
            let meanZ = Double(slice.map(\.z).reduce(0, +)) / Double(max(1, slice.count))
            XCTAssertEqual(meanZ, 7 + 4 * Double(s) / 8, accuracy: 0.5, "slice \(s) centre")
        }
        // Restricting the key slices to one leaves nothing to interpolate.
        XCTAssertTrue(try SliceInterpolation.interpolate(m, classID: 1, axis: 0, keySlices: [0]).isEmpty)
        // Shapes that do not overlap interpolate to nothing in between (shape-based interpolation).
        let apart = try makeModel(shape: [5, 20, 20], classes: [(1, 0)], layerCount: 1)
        apart.apply(try apart.makeEdit(.paint(1), over: makeMask(apart.shape) { k in
            (k.x == 0 && (2..<5).contains(k.y) && (2..<5).contains(k.z)) || (k.x == 4 && (12..<15).contains(k.y) && (12..<15).contains(k.z))
        }))
        XCTAssertTrue(try SliceInterpolation.interpolate(apart, classID: 1, axis: 0).isEmpty)
    }

    func testInterpolationAcrossOtherAxes() throws {
        let m = try makeModel(shape: [20, 9, 20], classes: [(1, 0)], layerCount: 1)
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { k in
            (k.y == 1 || k.y == 7) && (5..<15).contains(k.x) && (5..<15).contains(k.z)
        }))
        m.apply(try SliceInterpolation.interpolate(m, classID: 1, axis: 1))
        XCTAssertEqual(voxels(of: 1, in: m), allVoxels(m.shape) { k in
            (1...7).contains(k.y) && (5..<15).contains(k.x) && (5..<15).contains(k.z)
        })
    }
}

final class LabelOperationTests: XCTestCase {
    /// Layer 0: classes 1, 2; layer 1: class 3.
    private func model() throws -> SegmentationModel {
        let m = try makeModel(shape: [1, 1, 10], classes: [(1, 0), (2, 0), (3, 1), (4, 1)], inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.z < 4 }
        fillRaw(m, layer: 0, value: 2) { $0.z >= 6 }
        fillRaw(m, layer: 1, value: 3) { $0.z >= 2 && $0.z < 8 }
        return m
    }

    private func zs(_ id: UInt16, _ m: SegmentationModel) -> [Int] { voxels(of: id, in: m).map(\.z).sorted() }

    func testCopyAndMove() throws {
        let m = try model()
        m.apply(try LabelOperations.copy(m, from: 1, to: 3))
        XCTAssertEqual(zs(3, m), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(zs(1, m), [0, 1, 2, 3])
        let m2 = try model()
        m2.apply(try LabelOperations.move(m2, from: 1, to: 2)) // same layer: relabel
        XCTAssertEqual(zs(1, m2), [])
        XCTAssertEqual(zs(2, m2), [0, 1, 2, 3, 6, 7, 8, 9])
        let m3 = try model()
        m3.apply(try LabelOperations.move(m3, from: 3, to: 1)) // across layers
        XCTAssertEqual(zs(3, m3), [])
        XCTAssertEqual(zs(1, m3), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(zs(2, m3), [8, 9], "overwritten where 1 moved in")
    }

    func testMoveKeepsTheSourceWhereTheTargetCannotGo() throws {
        let m = try model()
        m.apply(try m.updateClassEdit(2) { $0.isLocked = true })
        m.apply(try LabelOperations.move(m, from: 3, to: 1))
        XCTAssertEqual(zs(1, m), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(zs(3, m), [6, 7], "class 2 is locked: 3 stays there")
    }

    func testMergeSubtractIntersectClear() throws {
        let m = try model()
        m.apply(try LabelOperations.merge(m, classes: [1, 3], into: 4))
        XCTAssertEqual(zs(4, m), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(zs(1, m), [])
        XCTAssertEqual(zs(3, m), [])
        XCTAssertEqual(zs(2, m), [6, 7, 8, 9])
        let s = try model()
        s.apply(try LabelOperations.subtract(s, 3, minus: 1))
        XCTAssertEqual(zs(3, s), [4, 5, 6, 7])
        let i = try model()
        i.apply(try LabelOperations.intersect(i, 3, with: 2))
        XCTAssertEqual(zs(3, i), [6, 7])
        let c = try model()
        c.apply(try LabelOperations.clear(c, 2))
        XCTAssertEqual(zs(2, c), [])
        XCTAssertTrue(c.classIDs.contains(2) && c.annotatedClassIDs.contains(2), "cleared class stays covered")
    }

    func testSwapWithinAndAcrossLayers() throws {
        let m = try model()
        m.apply(try LabelOperations.swap(m, 1, 2))
        XCTAssertEqual(zs(1, m), [6, 7, 8, 9])
        XCTAssertEqual(zs(2, m), [0, 1, 2, 3])
        let m2 = try model()
        m2.apply(try LabelOperations.swap(m2, 1, 3))
        // 1 was on 0…3, 3 on 2…7: 2…3 hold both and keep both.
        XCTAssertEqual(zs(3, m2), [0, 1, 2, 3])
        XCTAssertEqual(zs(1, m2), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(zs(2, m2), [8, 9])
    }

    func testRelabelIntoANewClassAddsCoverage() throws {
        let m = try model()
        m.apply(try m.addClassEdit(SegmentClass(id: 9, key: "n", name: "N")))
        m.apply(try LabelOperations.relabel(m, 2, to: 9))
        XCTAssertEqual(zs(9, m), [6, 7, 8, 9])
        XCTAssertTrue(m.classIDs.contains(9) && m.annotatedClassIDs.contains(9))
        XCTAssertThrowsError(try LabelOperations.copy(m, from: 1, to: 77))
    }
}

final class ComponentTests: XCTestCase {
    func testConnectivityChangesTheComponentCount() throws {
        let m = try makeModel(shape: [3, 6, 6], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        // Three voxels touching by an edge, by a corner, and an isolated pair.
        fillRaw(m, layer: 0, value: 1) { k in
            [SIMD3(1, 1, 1), SIMD3(1, 2, 2), SIMD3(2, 3, 3), SIMD3(0, 5, 0), SIMD3(0, 5, 1)].contains(k)
        }
        XCTAssertEqual(try ConnectedComponents.label(m, classID: 1, connectivity: .face).count, 4)
        XCTAssertEqual(try ConnectedComponents.label(m, classID: 1, connectivity: .edge).count, 3)
        let full = try ConnectedComponents.label(m, classID: 1, connectivity: .full)
        XCTAssertEqual(full.count, 2)
        XCTAssertEqual(full.components.map(\.voxelCount), [3, 2])
        XCTAssertEqual(full.components[0].bounds, VoxelBox(lower: SIMD3(1, 1, 1), upper: SIMD3(3, 4, 4)))
        XCTAssertEqual(full.components[1].centroidIndex, SIMD3(0, 5, 0.5))
        let labels = copyValues(full.labelVolume(), as: UInt32.self)
        XCTAssertEqual(labels[m.linearIndex(SIMD3(2, 3, 3))], 1)
        XCTAssertEqual(labels[m.linearIndex(SIMD3(0, 5, 1))], 2)
        XCTAssertEqual(labels[m.linearIndex(SIMD3(0, 0, 0))], 0)
        XCTAssertEqual(voxels(of: full.region(ofComponent: 2)), [SIMD3(0, 5, 0), SIMD3(0, 5, 1)])
    }

    func testRandomVolumesMatchAFloodFillCount() throws {
        var rng = SeededRandom(5)
        for connectivity in Connectivity.allCases {
            let n = SIMD3(6, 9, 11)
            let set = allVoxels(n) { _ in Int.random(in: 0..<10, using: &rng) < 3 }
            let mask = makeMask(n) { set.contains($0) }
            let g = makeGeometry(shape: [6, 9, 11], spacing: [1, 1, 1])
            let labeling = try ConnectedComponents.label(mask, connectivity: connectivity, geometry: g)
            // Reference: BFS with explicit neighbour offsets.
            var offsets: [SIMD3<Int>] = []
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let nz = abs(dz) + abs(dy) + abs(dx)
                if nz == 0 { continue }
                if connectivity == .face && nz > 1 { continue }
                if connectivity == .edge && nz > 2 { continue }
                offsets.append(SIMD3(dz, dy, dx))
            } } }
            var seen = Set<SIMD3<Int>>()
            var sizes: [Int] = []
            for v in set where !seen.contains(v) {
                var stack = [v]
                seen.insert(v)
                var size = 0
                while let p = stack.popLast() {
                    size += 1
                    for o in offsets where set.contains(p &+ o) && !seen.contains(p &+ o) {
                        seen.insert(p &+ o)
                        stack.append(p &+ o)
                    }
                }
                sizes.append(size)
            }
            XCTAssertEqual(labeling.components.map(\.voxelCount), sizes.sorted(by: >), "\(connectivity)")
        }
    }
}

final class StatisticsTests: XCTestCase {
    func testClassStatisticsAndBoxConvention() throws {
        let m = try makeModel(shape: [4, 10, 12], spacing: [2.5, 0.5, 0.8], origin: [100, 0, -50], inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { (1...2).contains($0.x) && (3..<7).contains($0.y) && (2..<5).contains($0.z) }
        fillRaw(m, layer: 1, value: 3) { $0 == SIMD3(0, 0, 0) }
        let stats = try SegmentationStatistics.classStatistics(m)
        let s1 = try XCTUnwrap(stats.first { $0.classID == 1 })
        XCTAssertEqual(s1.voxelCount, 2 * 4 * 3)
        XCTAssertEqual(s1.volume, 24 * 2.5 * 0.5 * 0.8, accuracy: 1e-9)
        XCTAssertEqual(s1.bounds, VoxelBox(lower: SIMD3(1, 3, 2), upper: SIMD3(3, 7, 5)))
        // spec §8.1: numpy slice a:b ⟺ lo = a − 0.5, hi = b − 0.5.
        XCTAssertEqual(s1.edgeBox!, [[0.5, 2.5], [2.5, 6.5], [1.5, 4.5]])
        XCTAssertEqual(VoxelBox(edgeLower: SIMD3(0.5, 2.5, 1.5), edgeUpper: SIMD3(2.5, 6.5, 4.5)), s1.bounds)
        XCTAssertEqual(s1.centroidIndex!, SIMD3(1.5, 4.5, 3))
        XCTAssertEqual(simd_distance(s1.centroidWorld!, SIMD3(100 + 1.5 * 2.5, 4.5 * 0.5, -50 + 3 * 0.8)), 0, accuracy: 1e-9)
        let s2 = try XCTUnwrap(stats.first { $0.classID == 2 })
        XCTAssertEqual(s2.voxelCount, 0)
        XCTAssertNil(s2.edgeBox)
        XCTAssertEqual(try SegmentationStatistics.classStatistics(m, classID: 3).voxelCount, 1)
    }

    func testHalfUpRoundingOfEdgeBoxes() {
        // floor(x + 0.5): 0.5 → 1, −0.5 → 0, 2.5 → 3 (never half-to-even).
        let b = VoxelBox(edgeLower: SIMD3(0.5, -0.5, 1.5), edgeUpper: SIMD3(2.5, 3.5, 1.5))
        XCTAssertEqual(b.lower, SIMD3(1, 0, 2))
        XCTAssertEqual(b.upper, SIMD3(3, 4, 2))
        XCTAssertTrue(b.isEmpty)
    }

    func testIntensityStatisticsOnTheSameGrid() throws {
        let m = try makeModel(shape: [1, 4, 5], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.y < 2 } // 10 voxels
        let image = makeImage(Int16.self, geometry: m.geometry, slope: 1, intercept: -1024) { Int16(1000 + $0.y * 5 + $0.z) }
        let s = try SegmentationStatistics.intensity(of: 1, in: m, image: image)
        var values: [Double] = []
        for y in 0..<2 {
            for z in 0..<5 {
                let raw: Int = 1000 + y * 5 + z
                values.append(Double(raw) - 1024)
            }
        }
        XCTAssertEqual(s.count, 10)
        let expectedMean: Double = values.reduce(0, +) / 10
        XCTAssertEqual(s.mean, expectedMean, accuracy: 1e-9)
        XCTAssertEqual(s.minimum, -24)
        XCTAssertEqual(s.maximum, -15)
        XCTAssertEqual(s.median, -19.5) // even count: the mean of the middle pair
        var sumSquares = 0.0
        for v in values { sumSquares += (v - expectedMean) * (v - expectedMean) }
        XCTAssertEqual(s.standardDeviation, (sumSquares / 10).squareRoot(), accuracy: 1e-9)
        let raw = try SegmentationStatistics.intensity(of: 1, in: m, image: image, physical: false)
        XCTAssertEqual(raw.minimum, 1000)
    }

    func testIntensityStatisticsFromAnImageOnAnotherGrid() throws {
        let m = try makeModel(shape: [1, 8, 8], classes: [(1, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.y < 3 && $0.z < 3 } // 9 voxels
        let ig = makeGeometry(shape: [1, 4, 4], spacing: [1, 2, 2], origin: [0, 0.5, 0.5])
        let image = makeImage(Float.self, geometry: ig, modality: "MR") { Float($0.y * 4 + $0.z) * 1.5 }
        let s = try SegmentationStatistics.intensity(of: 1, in: m, image: image)
        var expected: [Double] = []
        for y in 0..<3 { for z in 0..<3 {
            let i1 = Int(((Double(y) - 0.5) / 2 + 0.5).rounded(.down)), i2 = Int(((Double(z) - 0.5) / 2 + 0.5).rounded(.down))
            expected.append(Double(i1 * 4 + i2) * 1.5)
        } }
        XCTAssertEqual(s.count, 9)
        XCTAssertEqual(s.mean, expected.reduce(0, +) / 9, accuracy: 1e-9)
        XCTAssertEqual(s.median, expected.sorted()[4], accuracy: 1e-9) // odd count: float path, quickselect
        XCTAssertEqual(s.maximum, expected.max()!)
    }

    func testMedianSelection() {
        var rng = SeededRandom(3)
        for n in [1, 2, 3, 10, 101, 1000] {
            let values = (0..<n).map { _ in Double(Int.random(in: -50...50, using: &rng)) }
            let sorted = values.sorted()
            let expected = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            var copy = values
            XCTAssertEqual(medianOf(&copy), expected)
        }
    }
}
