import XCTest
import simd
import MedH5Core
@testable import MedH5Render

final class MeshTests: XCTestCase {
    /// A grid with anisotropic spacing and an oblique direction, centred on `center`.
    private func sphereGrid(radius: Double, center: SIMD3<Double>) -> GridGeometry {
        let spacing = [0.8, 1.0, 1.2]
        let n = spacing.map { Int((2 * radius + 8) / $0) }
        var g = GridGeometry(id: "s", shape: n, spacing: spacing,
                             direction: rotation(axis: SIMD3(0.3, 1, 0.2), degrees: 20))
        let shift = center - g.worldCenter
        g.origin = [shift.x, shift.y, shift.z]
        return g
    }

    func testTableIsConsistent() {
        // Every case's triangles use only crossed edges, and complementary
        // cases cover the same edges.
        for c in 0..<256 {
            let tris = MarchingCubesTable.triangles[c]
            XCTAssertEqual(tris.count % 3, 0)
            for e in tris {
                let (a, b) = MarchingCubesTable.edgeCorners[Int(e)]
                XCTAssertNotEqual((c >> a) & 1, (c >> b) & 1, "case \(c) uses an uncrossed edge")
            }
            let edges = Set(tris)
            let complement = Set(MarchingCubesTable.triangles[255 - c])
            XCTAssertEqual(edges, complement, "case \(c)")
        }
        XCTAssertTrue(MarchingCubesTable.triangles[0].isEmpty)
        XCTAssertTrue(MarchingCubesTable.triangles[255].isEmpty)
        XCTAssertEqual(MarchingCubesTable.triangles[1].count, 3)
    }

    func testIsoSurfaceOfASphereHasTheRightAreaAndVolume() throws {
        let r = 20.0
        let c = SIMD3<Double>(1.3, -0.7, 2.1)
        let grid = sphereGrid(radius: r, center: c)
        let n = grid.paddedShape
        let field = makeVolume(Float.self, shape: [n.x, n.y, n.z]) { a, b, cc in
            Float(r - simd_distance(grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(cc))), c))
        }
        let mesh = SurfaceExtractor.surface(scalars: field, geometry: grid, isoLevel: 0)
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        XCTAssertTrue(mesh.isClosed, "\(mesh.topologyDefects())")
        let area = mesh.surfaceArea(), volume = mesh.enclosedVolume()
        XCTAssertEqual(area / (4 * .pi * r * r), 1, accuracy: 0.01)
        XCTAssertEqual(volume / (4.0 / 3.0 * .pi * r * r * r), 1, accuracy: 0.01)
        // Every vertex lies on the sphere.
        for p in mesh.positions.prefix(5000) {
            XCTAssertEqual(simd_distance(SIMD3<Double>(p), c), r, accuracy: 0.15)
        }
        // Normals point outwards.
        for (p, nrm) in zip(mesh.positions, mesh.normals).prefix(1000) {
            XCTAssertGreaterThan(simd_dot(SIMD3<Double>(nrm), simd_normalize(SIMD3<Double>(p) - c)), 0.9)
        }
    }

    func testLabelSurfaceOfASphereIsClosedWithTheRightVolume() throws {
        let r = 15.0
        let c = SIMD3<Double>(0.4, 0.2, -0.3)
        let grid = sphereGrid(radius: r, center: c)
        let n = grid.paddedShape
        let labels = makeVolume(UInt16.self, shape: [n.x, n.y, n.z]) { a, b, cc in
            simd_distance(grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(cc))), c) <= r ? 3 : 1
        }
        let exact = 4.0 / 3.0 * .pi * r * r * r
        let exactArea = 4 * .pi * r * r
        // Raw (blocky) and smoothed surfaces are both closed and keep the volume.
        for smoothing in [MeshSmoothing.none, .standard] {
            let mesh = SurfaceExtractor.surface(labels: labels, geometry: grid, classID: 3,
                                                options: SurfaceExtractionOptions(smoothing: smoothing))
            XCTAssertTrue(mesh.isClosed, "\(smoothing): \(mesh.topologyDefects())")
            XCTAssertEqual(mesh.enclosedVolume() / exact, 1, accuracy: 0.03, "\(smoothing)")
            if smoothing != .none {
                XCTAssertEqual(mesh.surfaceArea() / exactArea, 1, accuracy: 0.04, "\(smoothing)")
            }
        }
        // Gaussian pre-smoothing keeps the surface closed and the volume.
        let pre = SurfaceExtractor.surface(labels: labels, geometry: grid, classID: 3,
                                           options: .display)
        XCTAssertTrue(pre.isClosed, "\(pre.topologyDefects())")
        XCTAssertEqual(pre.enclosedVolume() / exact, 1, accuracy: 0.03)
        XCTAssertEqual(pre.surfaceArea() / exactArea, 1, accuracy: 0.03)
        for p in pre.positions.prefix(3000) {
            XCTAssertEqual(simd_distance(SIMD3<Double>(p), c), r, accuracy: 0.6)
        }
        // Class 1 (everything else) touches the border: still closed (two shells).
        let outside = SurfaceExtractor.surface(labels: labels, geometry: grid, classID: 1,
                                               options: SurfaceExtractionOptions(smoothing: .none))
        XCTAssertTrue(outside.isClosed, "\(outside.topologyDefects())")
        let box = grid.physicalSize.reduce(1, *)
        XCTAssertEqual(outside.enclosedVolume() / (box - exact), 1, accuracy: 0.03)
        // An absent class gives nothing.
        XCTAssertTrue(SurfaceExtractor.surface(labels: labels, geometry: grid, classID: 9).isEmpty)
    }

    func testDownsampledSurfaceKeepsTheVolume() throws {
        let r = 18.0
        let grid = GridGeometry(id: "g", shape: [48, 48, 48], spacing: [1, 1, 1], origin: [-24, -24, -24])
        let mask = makeVolume(UInt8.self, shape: [48, 48, 48]) { a, b, c in
            simd_length(grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(c)))) <= r ? 1 : 0
        }
        let mesh = SurfaceExtractor.surface(mask: mask, geometry: grid,
                                            options: SurfaceExtractionOptions(downsampleFactor: 2))
        XCTAssertTrue(mesh.isClosed)
        XCTAssertEqual(mesh.enclosedVolume() / (4.0 / 3.0 * .pi * r * r * r), 1, accuracy: 0.04)
        let full = SurfaceExtractor.surface(mask: mask, geometry: grid)
        XCTAssertGreaterThan(full.triangleCount, mesh.triangleCount * 3)
    }

    func testPlaneMeshIntersectionIsACircleOfTheRightRadius() throws {
        let r = 20.0
        let c = SIMD3<Double>(5, -3, 7)
        let sphere = TriangleMesh.icosphere(center: c, radius: r, subdivisions: 5)
        XCTAssertTrue(sphere.isClosed)
        XCTAssertGreaterThan(sphere.enclosedVolume(), 0, "icosphere winds outwards")
        let normal = simd_normalize(SIMD3<Double>(0.2, -0.5, 1))
        let h = 8.0
        let plane = Plane(point: c + normal * h, normal: normal)
        let expected = (r * r - h * h).squareRoot()
        let segments = PlaneIntersection.segments(mesh: sphere, plane: plane)
        XCTAssertGreaterThan(segments.count, 100)
        let center = plane.project(c)
        for p in segments {
            XCTAssertEqual(plane.signedDistance(p), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_distance(p, center), expected, accuracy: expected * 0.01)
        }
        let contours = PlaneIntersection.polylines(fromSegments: segments)
        XCTAssertEqual(contours.count, 1)
        XCTAssertTrue(contours[0].closed)
        XCTAssertEqual(contours[0].points.count, segments.count / 2)
        // The slicer agrees and is fast to re-query along the same normal.
        let slicer = MeshSlicer(mesh: sphere)
        XCTAssertEqual(slicer.segments(on: plane).count, segments.count)
        let far = Plane(point: c + normal * (r + 1), normal: normal)
        XCTAssertTrue(slicer.segments(on: far).isEmpty)
        let circumference = contours[0].points.indices.reduce(0.0) { acc, i in
            acc + simd_distance(contours[0].points[i], contours[0].points[(i + 1) % contours[0].points.count])
        }
        XCTAssertEqual(circumference / (2 * .pi * expected), 1, accuracy: 0.01)
    }

    func testBoxPlaneIntersection() {
        let box = OrientedBox(lower: SIMD3(0, 0, 0), upper: SIMD3(10, 20, 30))
        let poly = PlaneIntersection.polygon(box: box, plane: Plane(point: SIMD3(0, 0, 12), normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(poly.count, 4)
        for p in poly { XCTAssertEqual(p.z, 12, accuracy: 1e-9) }
        // A diagonal cut of a cube is a hexagon.
        let cube = OrientedBox(lower: SIMD3(-1, -1, -1), upper: SIMD3(1, 1, 1))
        let hex = PlaneIntersection.polygon(box: cube, plane: Plane(point: .zero, normal: SIMD3(1, 1, 1)))
        XCTAssertEqual(hex.count, 6)
        // An index box on a grid sits at voxel edges.
        let grid = GridGeometry(id: "g", shape: [4, 4, 4], spacing: [2, 2, 2])
        let ib = OrientedBox(indexLower: SIMD3(-0.5, -0.5, -0.5), indexUpper: SIMD3(0.5, 0.5, 0.5), grid: grid)
        XCTAssertEqual(ib.corners.map { $0.x }.min()!, -1, accuracy: 1e-12)
        XCTAssertEqual(ib.corners.map { $0.x }.max()!, 1, accuracy: 1e-12)
    }
}
