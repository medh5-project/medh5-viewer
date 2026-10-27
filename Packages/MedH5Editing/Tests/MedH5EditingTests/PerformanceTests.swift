import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

/// Timings on 256³ volumes, in optimised builds only (`swift test -c release`).
final class PerformanceTests: XCTestCase {
    private func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Double) {
        let t0 = Date()
        let r = try body()
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "[perf] %@: %.1f ms", label, dt * 1000))
        return (r, dt)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(isOptimizedBuild, "performance tests run in release builds: swift test -c release")
    }

    private func bigModel() throws -> SegmentationModel {
        try makeModel(shape: [256, 256, 256], spacing: [1.2, 0.8, 0.8], classes: [(1, 0), (2, 0), (3, 1)], layerCount: 2)
    }

    func testFillOfTenMillionVoxels() throws {
        let m = try bigModel()
        // A ball of radius 135 voxels, clipped by the volume (≈ 10⁷ voxels), walled by class 2.
        let c = SIMD3(128, 128, 128)
        let p = m.layers[0].pointer(as: UInt16.self)
        for z in 0..<256 { for y in 0..<256 { for x in 0..<256 {
            let d = (z - c.x) * (z - c.x) + (y - c.y) * (y - c.y) + (x - c.z) * (x - c.z)
            if d >= 135 * 135 && d < 137 * 137 { p[(z * 256 + y) * 256 + x] = 2 }
        } } }
        let (result, tFill) = try time("3-D fill 256³") {
            try FloodFill.region(in: m, seed: c, criterion: .sameLabels(.layerOfClass(1)))
        }
        XCTAssertGreaterThan(result.voxelCount, 10_000_000)
        let (edit, tEdit) = try time("edit from fill") { try m.makeEdit(.paint(1), over: result.region) }
        XCTAssertEqual(edit.voxelCount, result.voxelCount)
        print("[perf] fill edit: \(edit.voxelCount) voxels in \(edit.byteSize) bytes")
        XCTAssertLessThan(edit.byteSize, 4 << 20, "\(edit.byteSize) bytes for \(edit.voxelCount) voxels")
        let (_, tApply) = time("apply") { m.apply(edit) }
        let (_, tRevert) = time("revert") { m.revert(edit) }
        if isOptimizedBuild {
            XCTAssertLessThan(tFill, 0.5)
            XCTAssertLessThan(tEdit, 0.5)
            XCTAssertLessThan(tApply, 0.1)
            XCTAssertLessThan(tRevert, 0.1)
        }
        // The complement: the voxels outside the wall, all 26-connected.
        let (outside, tOut) = try time("3-D fill outside, 26-connectivity") {
            try FloodFill.region(in: m, seed: .zero, criterion: .sameLabels(.allLayers), connectivity: .full)
        }
        XCTAssertGreaterThan(outside.voxelCount, 5_000_000)
        if isOptimizedBuild { XCTAssertLessThan(tOut, 0.8) }
    }

    func testDilationAndErosionOn256Cubed() throws {
        let m = try bigModel()
        let c = SIMD3(128, 128, 128)
        fillRaw(m, layer: 0, value: 1) { k in
            let d = SIMD3<Double>(k &- c) * SIMD3(1.2, 0.8, 0.8)
            return simd_length_squared(d) < 60 * 60 || (abs(d.x) < 70 && abs(d.y) < 5 && abs(d.z) < 90)
        }
        let (dil, tDilate) = try time("dilate 5 mm, 256³") { try LabelMorphology.dilate(m, classID: 1, radius: 5) }
        XCTAssertGreaterThan(dil.voxelCount, 100_000)
        let (ero, tErode) = try time("erode 5 mm, 256³") { try LabelMorphology.erode(m, classID: 1, radius: 5) }
        XCTAssertGreaterThan(ero.voxelCount, 50_000)
        if isOptimizedBuild {
            XCTAssertLessThan(tDilate, 1.0)
            XCTAssertLessThan(tErode, 1.0)
        }
    }

    func testThresholdBrushAndStatisticsOn256Cubed() throws {
        let m = try bigModel()
        let image = makeImage(Int16.self, geometry: m.geometry, slope: 1, intercept: -1024) { k in
            Int16(truncatingIfNeeded: (k.x * 7 + k.y * 13 + k.z * 3) % 2048)
        }
        let (edit, tThreshold) = try time("threshold 256³ (noisy)") {
            try Threshold.edit(m, classID: 1, image: image, range: -200...300)
        }
        XCTAssertGreaterThan(edit.voxelCount, 1_000_000)
        print("[perf] threshold edit: \(edit.voxelCount) voxels in \(edit.byteSize) bytes")
        m.apply(edit)
        let (stats, tStats) = try time("intensity statistics of the class") {
            try SegmentationStatistics.intensity(of: 1, in: m, image: image)
        }
        XCTAssertEqual(stats.count, edit.voxelCount)
        let (_, tClassStats) = try time("class statistics") { try SegmentationStatistics.classStatistics(m) }
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0))
        let stroke = try BrushStroke(model: m, operation: .paint(2), brush: .disc(radius: 10, plane: plane))
        let (_, tStroke) = try time("brush stroke, 100 positions, r = 10 mm") {
            for i in 0..<100 { try stroke.add(m.geometry.world(fromIndex: SIMD3(128, 50 + Double(i), 50 + Double(i) * 1.5))) }
            return stroke.finish()
        }
        if isOptimizedBuild {
            XCTAssertLessThan(tThreshold, 1.0)
            XCTAssertLessThan(tStats, 0.5)
            XCTAssertLessThan(tClassStats, 0.5)
            XCTAssertLessThan(tStroke, 0.5)
        }
    }

    func testInterpolationAndComponentsOn256Cubed() throws {
        let m = try bigModel()
        for s in stride(from: 20, through: 236, by: 24) {
            let r = 40 + Double((s / 24) % 3) * 15
            fillRaw(m, layer: 0, value: 1) { k in
                k.x == s && Double((k.y - 128) * (k.y - 128) + (k.z - 128) * (k.z - 128)) <= r * r
            }
        }
        let (edit, tInterp) = try time("slice interpolation, 10 keys over 216 slices") {
            try SliceInterpolation.interpolate(m, classID: 1, axis: 0)
        }
        XCTAssertGreaterThan(edit.voxelCount, 500_000)
        m.apply(edit)
        let (labels, tCC) = try time("connected components") { try ConnectedComponents.label(m, classID: 1) }
        XCTAssertEqual(labels.count, 1)
        if isOptimizedBuild {
            XCTAssertLessThan(tInterp, 1.0)
            XCTAssertLessThan(tCC, 0.5)
        }
    }
}
