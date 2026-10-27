import XCTest
import simd
@testable import MedH5Core

final class GridGeometryTests: XCTestCase {
    func testS3_3IndexToWorldIsOriginPlusDirectionTimesSpacing() {
        let g = GridGeometry(id: "ct", shape: [4, 5, 6], spacing: [2.0, 0.8, 0.5], origin: [-10, 20, 30])
        let p = g.world(fromIndex: SIMD3(1, 2, 3))
        // direction is the identity: axis 0 (z, stored first) → world x here
        XCTAssertEqual(p.x, -10 + 2.0, accuracy: 1e-12)
        XCTAssertEqual(p.y, 20 + 1.6, accuracy: 1e-12)
        XCTAssertEqual(p.z, 30 + 1.5, accuracy: 1e-12)
        let k = g.index(fromWorld: p)
        XCTAssertEqual(simd_distance(k, SIMD3(1, 2, 3)), 0, accuracy: 1e-12)
    }

    func testDirectionColumnsAreSpatialAxes() {
        // Column c of direction is the world direction of spatial axis c.
        let dir: [[Double]] = [[0, 0, 1], [0, 1, 0], [1, 0, 0]]
        let g = GridGeometry(id: "g", shape: [3, 3, 3], spacing: [3, 2, 1], direction: dir)
        XCTAssertEqual(g.world(fromIndex: SIMD3(1, 0, 0)), SIMD3(0, 0, 3))
        XCTAssertEqual(g.world(fromIndex: SIMD3(0, 0, 1)), SIMD3(1, 0, 0))
    }

    func testTextureCoordinatesHitVoxelCentres() {
        let g = GridGeometry(id: "g", shape: [2, 4, 8], spacing: [1, 1, 1])
        let tc = g.indexToTexture * SIMD4<Double>(0, 0, 0, 1)
        XCTAssertEqual(tc.x, 0.5 / 8, accuracy: 1e-12)
        XCTAssertEqual(tc.y, 0.5 / 4, accuracy: 1e-12)
        XCTAssertEqual(tc.z, 0.5 / 2, accuracy: 1e-12)
        let last = g.indexToTexture * SIMD4<Double>(1, 3, 7, 1)
        XCTAssertEqual(last.x, 7.5 / 8, accuracy: 1e-12)
        XCTAssertEqual(last.z, 1.5 / 2, accuracy: 1e-12)
        let w = g.world(fromIndex: SIMD3(1, 2, 3))
        let viaWorld = g.worldToTexture * SIMD4(w, 1)
        XCTAssertEqual(viaWorld.x, 3.5 / 8, accuracy: 1e-12)
        XCTAssertEqual(viaWorld.y, 2.5 / 4, accuracy: 1e-12)
    }

    func testTwoDimensionalGridPadsToOneSlice() {
        let g = GridGeometry(id: "xr", shape: [10, 20], spacing: [0.5, 0.25], origin: [1, 2])
        XCTAssertEqual(g.paddedShape, SIMD3(1, 10, 20))
        XCTAssertEqual(g.world(fromIndex: SIMD3(0, 2, 4)), SIMD3(1 + 1.0, 2 + 1.0, 0))
        XCTAssertTrue(g.is2D)
    }

    func testS3_3FramesAreSharedOnlyWhenNamed() {
        var a = GridGeometry(id: "a", shape: [2, 2, 2], spacing: [1, 1, 1])
        var b = a
        XCTAssertFalse(a.sharesFrame(with: b), "two absent frames are not one frame")
        a.frameUID = "f1"
        b.frameUID = "f1"
        XCTAssertTrue(a.sharesFrame(with: b))
        b.coordSystem = "RAS"
        XCTAssertFalse(a.sharesFrame(with: b))
    }

    func testVoxelContainingRoundsHalfUp() {
        let g = GridGeometry(id: "g", shape: [4, 4, 4], spacing: [1, 1, 1])
        XCTAssertEqual(g.voxel(containingIndex: SIMD3(0.5, 1.49, -0.5)), SIMD3(1, 1, 0))
        XCTAssertNil(g.voxel(containingIndex: SIMD3(3.5, 0, 0)))
        // A non-finite index (a degenerate plane) is no voxel, not a trap.
        XCTAssertNil(g.voxel(containingIndex: SIMD3(.nan, 0, 0)))
        XCTAssertNil(g.voxel(containingIndex: SIMD3(0, .infinity, 0)))
        XCTAssertNil(g.voxel(containingWorld: SIMD3(0, 0, -.infinity)))
    }

    func testLeadingAxes() {
        let g = GridGeometry(id: "dce", shape: [5, 4, 3, 2], axisKinds: [.time, .spatial, .spatial, .spatial],
                             spacing: [1, 1, 1], timeValues: [0, 1, 2, 3, 4])
        XCTAssertEqual(g.leadingShape, [5])
        XCTAssertEqual(g.spatialShape, [4, 3, 2])
        XCTAssertEqual(g.timeAxis, 0)
        XCTAssertEqual(g.axisNames, ["t", "z", "y", "x"])
    }

    func testDecodesBridgeJSON() throws {
        let json = """
        {"id":"ct","shape":[3,4,5],"axis_names":["z","y","x"],"axis_kinds":["spatial","spatial","spatial"],
         "spacing":[2.0,1.0,1.0],"origin":[0.0,0.0,0.0],"direction":[[1,0,0],[0,1,0],[0,0,1]],
         "coord_system":"LPS","units":"mm","timepoint":"tp0","frame_uid":"f"}
        """
        let g = try JSONDecoder().decode(GridGeometry.self, from: Data(json.utf8))
        XCTAssertEqual(g.timepoint, "tp0")
        XCTAssertEqual(g.frameUID, "f")
        XCTAssertEqual(g.spatialShape, [3, 4, 5])
    }
}

final class OrientationTests: XCTestCase {
    func testRASToLPSFlipsXAndY() throws {
        let m = try XCTUnwrap(CoordinateSystem.ras.toLPS)
        XCTAssertEqual(m * SIMD3<Double>(1, 2, 3), SIMD3(-1, -2, 3))
        XCTAssertEqual(CoordinateSystem("custom").axes, nil)
        XCTAssertEqual(CoordinateSystem("RAI").toLPS.map { $0 * SIMD3<Double>(1, 1, 1) }, SIMD3(-1, -1, -1))
    }

    func testLabels() {
        let lps = CoordinateSystem.lps
        XCTAssertEqual(lps.label(forWorldDirection: SIMD3(1, 0, 0)), "L")
        XCTAssertEqual(lps.label(forWorldDirection: SIMD3(0, -1, 0)), "A")
        XCTAssertEqual(lps.label(forWorldDirection: SIMD3(0.7, 0.7, 0)), "LP")
        XCTAssertEqual(CoordinateSystem.ras.label(forWorldDirection: SIMD3(1, 0, 0)), "R")
    }

    func testAlignedPlanesOfA2DGridAreNeverDegenerate() {
        // A radiograph: one plane, whatever the standard plane asked for.
        let g = GridGeometry(id: "xr", shape: [40, 30], spacing: [0.5, 0.5])
        for plane in ViewPlane.allCases {
            for convention in DisplayConvention.allCases {
                let axes = PlaneAxes.aligned(plane, to: g, convention: convention)
                XCTAssertEqual(abs(simd_dot(axes.right, axes.down)), 0, accuracy: 1e-12, "\(plane) \(convention)")
                let n = axes.normal
                XCTAssertTrue(n.x.isFinite && n.y.isFinite && n.z.isFinite, "\(plane) \(convention)")
                XCTAssertEqual(abs(simd_dot(n, g.axisDirections[0])), 1, accuracy: 1e-12, "the grid's own plane")
            }
        }
    }

    func testStandardPlanesAreRadiological() {
        let axial = PlaneAxes.standard(.axial)
        XCTAssertEqual(axial.right, SIMD3(1, 0, 0), "patient left on screen right")
        XCTAssertEqual(axial.down, SIMD3(0, 1, 0), "posterior at the bottom")
        let neuro = PlaneAxes.standard(.axial, convention: .neurological)
        XCTAssertEqual(neuro.right, SIMD3(-1, 0, 0))
        let sag = PlaneAxes.standard(.sagittal, in: .ras)
        XCTAssertEqual(sag.right, SIMD3(0, -1, 0), "posterior is -y in RAS")
    }
}

final class VolumeDataTests: XCTestCase {
    func testStorageIsPageAlignedAndZeroed() {
        let v = VolumeData(scalarType: .int16, shape: [3, 5, 7])
        XCTAssertEqual(Int(bitPattern: v.baseAddress) % VolumeData.pageSize, 0)
        XCTAssertEqual(v.allocatedByteCount % VolumeData.pageSize, 0)
        XCTAssertEqual(v.buffer(as: Int16.self).allSatisfy { $0 == 0 }, true)
    }

    func testFramesAreViews() {
        let v = VolumeData(shape: [2, 2, 2], values: (0..<8).map { Float($0) })
        let f = v.frame([1])
        XCTAssertEqual(f.shape, [2, 2])
        XCTAssertEqual(f.value(at: 0), 4)
        f.setValue(42, at: 3)
        XCTAssertEqual(v.value(at: 7), 42)
    }

    func testStatisticsAndPercentiles() {
        let values = (0..<1000).map { Int16($0) }
        let v = VolumeData(shape: [10, 10, 10], values: values)
        let s = v.statistics()
        XCTAssertEqual(s.minimum, 0)
        XCTAssertEqual(s.maximum, 999)
        XCTAssertEqual(s.mean, 499.5, accuracy: 1e-9)
        XCTAssertEqual(s.finiteCount, 1000)
        let p = v.percentiles([50], stats: s)
        XCTAssertEqual(p[0], 499.5, accuracy: 2)
        XCTAssertEqual(v.histogram(bins: 10, range: 0...1000), Array(repeating: 100, count: 10))
    }

    func testStatisticsSkipNonFinite() {
        let v = VolumeData(shape: [4], values: [Float.nan, 1, 3, .infinity])
        let s = v.statistics()
        XCTAssertEqual(s.finiteCount, 2)
        XCTAssertEqual(s.mean, 2)
    }

    func testConversionClamps() {
        let v = VolumeData(shape: [3], values: [Float(-5), 300.4, 12.5])
        let u = v.converted(to: .uint8)
        XCTAssertEqual(u.value(at: 0), 0)
        XCTAssertEqual(u.value(at: 1), 255)
        XCTAssertEqual(u.value(at: 2), 13)
        let f = VolumeData(shape: [2], values: [Int16(-7), 9]).converted(to: .float32)
        XCTAssertEqual(f.buffer(as: Float.self).map { $0 }, [-7, 9])
    }

    func testScalarTypeNames() {
        XCTAssertEqual(ScalarType(name: "<i2"), .int16)
        XCTAssertEqual(ScalarType(name: "float32"), .float32)
        XCTAssertEqual(ScalarType(name: "?"), .bool)
        XCTAssertEqual(ScalarType.int64.gpuCompatible, .float32)
    }
}

final class VolumeAccessTests: XCTestCase {
    func testScopedBufferAccessKeepsTheVolumeAlive() {
        let sum = VolumeData(shape: [4], values: [Int16(1), 2, 3, 4])
            .withUnsafeMutableBufferPointer(as: Int16.self) { $0.reduce(0) { $0 + Int($1) } }
        XCTAssertEqual(sum, 10)
    }

    func testVisitorRunsOnTheStoredType() {
        struct Max: VoxelVisitor {
            func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) -> Double {
                values.map(\.doubleValue).max() ?? .nan
            }
        }
        XCTAssertEqual(VolumeData(shape: [3], values: [Float(-1), 7.5, 2]).visit(Max()), 7.5)
        XCTAssertEqual(VolumeData(shape: [2], values: [UInt16(9), 65535]).visit(Max()), 65535)
    }
}
