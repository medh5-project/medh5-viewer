import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class FillTests: XCTestCase {
    /// A ring of class 2 in slice 3 across axis `axis`, with an inner radius
    /// of 5 voxels; returns the model.
    private func ringModel(axis: Int) throws -> SegmentationModel {
        let m = try makeModel(shape: [20, 20, 20], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        let others = [0, 1, 2].filter { $0 != axis }
        fillRaw(m, layer: 0, value: 2) { k in
            guard k[axis] == 3 else { return false }
            let a = Double(k[others[0]] - 10), b = Double(k[others[1]] - 10)
            let r2 = a * a + b * b
            return r2 >= 25 && r2 < 49
        }
        return m
    }

    func testTwoDimensionalBucketFillStaysInsideARing() throws {
        for axis in 0..<3 {
            let m = try ringModel(axis: axis)
            var seed = SIMD3(10, 10, 10)
            seed[axis] = 3
            let fill = try FloodFill.region(in: m, seed: seed, criterion: .sameLabels(.allLayers), extent: .slice(axis: axis))
            let expected = allVoxels(m.shape) { k in
                guard k[axis] == 3 else { return false }
                let o = [0, 1, 2].filter { $0 != axis }
                let a = Double(k[o[0]] - 10), b = Double(k[o[1]] - 10)
                return a * a + b * b < 25
            }
            XCTAssertEqual(voxels(of: fill.region), expected, "axis \(axis)")
            XCTAssertEqual(fill.voxelCount, expected.count)
            XCTAssertFalse(fill.reachedLimit)
        }
    }

    func testConnectivityDecidesWhetherAFillCrossesADiagonalWall() throws {
        // A one-voxel diagonal wall y == z: 4-connected regions cannot cross it, 8-connected ones can.
        let m = try makeModel(shape: [3, 20, 20], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 2) { $0.y == $0.z }
        let seed = SIMD3(1, 0, 19)
        let face = try FloodFill.region(in: m, seed: seed, criterion: .sameLabels(.allLayers), extent: .slice(axis: 0),
                                        connectivity: .face)
        let full = try FloodFill.region(in: m, seed: seed, criterion: .sameLabels(.allLayers), extent: .slice(axis: 0),
                                        connectivity: .full)
        XCTAssertEqual(face.voxelCount, 20 * 19 / 2)
        XCTAssertEqual(full.voxelCount, 400 - 20)
        // In 3-D, 6-connectivity cannot cross the wall either; 18 can (edge neighbours in-slice).
        let face3 = try FloodFill.region(in: m, seed: seed, criterion: .sameLabels(.allLayers), connectivity: .face)
        let edge3 = try FloodFill.region(in: m, seed: seed, criterion: .sameLabels(.allLayers), connectivity: .edge)
        XCTAssertEqual(face3.voxelCount, 3 * 190)
        XCTAssertEqual(edge3.voxelCount, 3 * 380)
    }

    func testThreeDimensionalFillOfACavity() throws {
        let m = try makeModel(shape: [24, 24, 24], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        let c = SIMD3(12, 12, 12)
        fillRaw(m, layer: 0, value: 2) { k in
            let d = simd_length_squared(SIMD3<Double>(k &- c))
            return d >= 49 && d < 100
        }
        let (edit, fill) = try FloodFill.edit(m, operation: .paint(1), seed: c, criterion: .sameLabels(.layerOfClass(1)))
        let expected = allVoxels(m.shape) { simd_length_squared(SIMD3<Double>($0 &- c)) < 49 }
        XCTAssertEqual(voxels(of: fill.region), expected)
        m.apply(edit)
        XCTAssertEqual(voxels(of: 1, in: m), expected)
        XCTAssertEqual(edit.voxelCount, expected.count)
    }

    func testFillLimitAndCancellation() throws {
        let m = try makeModel(shape: [16, 16, 16], inAnnotation: true)
        let limited = try FloodFill.region(in: m, seed: SIMD3(0, 0, 0), criterion: .sameLabels(.allLayers), maxVoxels: 500)
        XCTAssertTrue(limited.reachedLimit)
        XCTAssertLessThanOrEqual(limited.voxelCount, 500)
        let (edit, _) = try FloodFill.edit(m, operation: .paint(1), seed: .zero, criterion: .sameLabels(.allLayers), maxVoxels: 500)
        XCTAssertTrue(edit.isEmpty, "a truncated fill paints nothing by default")
        let control = OperationControl()
        control.cancel()
        XCTAssertThrowsError(try FloodFill.region(in: m, seed: .zero, criterion: .sameLabels(.allLayers), control: control)) {
            XCTAssertEqual($0 as? EditingError, .cancelled)
        }
    }

    func testRegionGrowingByToleranceAndRange() throws {
        let m = try makeModel(shape: [1, 30, 30], classes: [(1, 0)], layerCount: 1)
        // A bright square (100 ± 5) on a dark background (0 … 20).
        let image = makeImage(Float.self, geometry: m.geometry, modality: "MR") { k in
            (8..<20).contains(k.y) && (5..<25).contains(k.z) ? Float(100 + (k.y + k.z) % 5) : Float((k.y * 3 + k.z) % 21)
        }
        let square = allVoxels(m.shape) { (8..<20).contains($0.y) && (5..<25).contains($0.z) }
        let tol = try FloodFill.region(in: m, seed: SIMD3(0, 10, 10), criterion: .intensityTolerance(image, tolerance: 10),
                                       extent: .slice(axis: 0))
        XCTAssertEqual(voxels(of: tol.region), square)
        let range = try FloodFill.region(in: m, seed: SIMD3(0, 12, 12), criterion: .intensityRange(image, range: 90...110),
                                         extent: .volume)
        XCTAssertEqual(voxels(of: range.region), square)
        let outside = try FloodFill.region(in: m, seed: SIMD3(0, 0, 0), criterion: .intensityRange(image, range: 90...110))
        XCTAssertEqual(outside.voxelCount, 0, "a seed outside the range fills nothing")
    }

    func testFillFromAWorldPositionAndPlaneNormal() throws {
        let m = try ringModel(axis: 1)
        let normal = m.geometry.axisDirections[1]
        XCTAssertEqual(FloodFill.sliceAxis(forPlaneNormal: normal, in: m.geometry), 1)
        let fill = try FloodFill.region(in: m, seedWorld: m.geometry.world(fromIndex: SIMD3(10, 3, 10)),
                                        criterion: .sameLabels(.allLayers),
                                        extent: .slice(axis: FloodFill.sliceAxis(forPlaneNormal: normal, in: m.geometry)))
        XCTAssertEqual(fill.voxelCount, allVoxels(SIMD3(1, 20, 20)) { k in
            let a = Double(k.y - 10), b = Double(k.z - 10)
            return a * a + b * b < 25
        }.count)
    }
}

final class ThresholdTests: XCTestCase {
    private func setup() throws -> (SegmentationModel, ImageVolume) {
        let m = try makeModel(shape: [6, 10, 12], spacing: [2, 1, 1], classes: [(1, 0), (2, 0), (3, 1)], inAnnotation: true)
        // CT: HU = raw·2 − 1024.
        let image = makeImage(Int16.self, geometry: m.geometry, slope: 2, intercept: -1024) { k in
            Int16(512 + 10 * k.z + k.y)
        }
        return (m, image)
    }

    private func hu(_ k: SIMD3<Int>) -> Double { Double(512 + 10 * k.z + k.y) * 2 - 1024 }

    func testThresholdWholeVolumeSliceAndBox() throws {
        let (m, image) = try setup()
        let range = 100.0...150.0
        let e = try Threshold.edit(m, classID: 1, image: image, range: range)
        m.apply(e)
        XCTAssertEqual(voxels(of: 1, in: m), allVoxels(m.shape) { range.contains(hu($0)) })
        m.revert(e)
        let plane = GridPlane(axis: 0, index: 2)
        m.apply(try Threshold.edit(m, classID: 1, image: image, range: range, extent: .slice(plane)))
        XCTAssertEqual(voxels(of: 1, in: m), allVoxels(m.shape) { $0.x == 2 && range.contains(hu($0)) })
        let m2 = try setup().0
        let box = VoxelBox(lower: SIMD3(1, 2, 3), upper: SIMD3(4, 9, 11))
        m2.apply(try Threshold.edit(m2, classID: 1, image: image, range: range, extent: .box(box)))
        XCTAssertEqual(voxels(of: 1, in: m2), allVoxels(m.shape) { box.contains($0) && range.contains(hu($0)) })
    }

    func testThresholdInsideAnotherClassAndClearOutside() throws {
        let (m, image) = try setup()
        fillRaw(m, layer: 1, value: 3) { $0.y < 5 }
        fillRaw(m, layer: 0, value: 1) { $0.z == 0 } // stale class 1 to clear
        let range = 0.0...80.0
        let e = try Threshold.edit(m, classID: 1, image: image, range: range, insideClass: 3, clearOutside: true)
        m.apply(e)
        let expected = allVoxels(m.shape) { k in
            k.y < 5 ? range.contains(hu(k)) : k.z == 0
        }
        XCTAssertEqual(voxels(of: 1, in: m), expected)
    }

    func testThresholdOnAnImageOfAnotherGrid() throws {
        let m = try makeModel(shape: [1, 8, 8], spacing: [1, 1, 1], classes: [(1, 0)], layerCount: 1)
        let ig = makeGeometry(shape: [1, 4, 4], spacing: [1, 2, 2], origin: [0, 0.5, 0.5])
        let image = makeImage(UInt8.self, geometry: ig, modality: "MR") { UInt8($0.y * 4 + $0.z) }
        m.apply(try Threshold.edit(m, classID: 1, image: image, range: 5...6))
        let expected = allVoxels(m.shape) { k in
            let i1 = Int(((Double(k.y) - 0.5) / 2 + 0.5).rounded(.down))
            let i2 = Int(((Double(k.z) - 0.5) / 2 + 0.5).rounded(.down))
            return i1 >= 0 && i1 < 4 && i2 >= 0 && i2 < 4 && (5...6).contains(i1 * 4 + i2)
        }
        XCTAssertEqual(voxels(of: 1, in: m), expected)
        XCTAssertFalse(expected.isEmpty)
    }
}
