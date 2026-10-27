import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class MeasurementTests: XCTestCase {
    func testRulerAndAngle() {
        let g = makeGeometry(shape: [10, 10, 10], spacing: [3, 0.5, 0.5])
        let ruler = RulerMeasurement(startIndex: SIMD3(0, 0, 0), endIndex: SIMD3(1, 8, 0), geometry: g)
        XCTAssertEqual(ruler.length, 5, accuracy: 1e-12) // 3 mm and 4 mm
        XCTAssertEqual(AngleMeasurement(first: SIMD3(1, 0, 0), vertex: .zero, second: SIMD3(0, 2, 0)).degrees, 90, accuracy: 1e-12)
        XCTAssertEqual(AngleMeasurement(first: SIMD3(1, 0, 0), vertex: .zero, second: SIMD3(-1, 1e-9, 0)).degrees, 180, accuracy: 1e-6)
        XCTAssertEqual(AngleMeasurement(first: SIMD3(1, 1, 0), vertex: .zero, second: SIMD3(1, 0, 0)).degrees, 45, accuracy: 1e-12)
        XCTAssertTrue(AngleMeasurement(first: .zero, vertex: .zero, second: SIMD3(1, 0, 0)).radians.isNaN)
    }

    private func ctImage() -> ImageVolume {
        // 1 × 40 × 40, 0.5 mm pixels; HU = raw − 1000 with raw = 1000 + k1 (one HU per row).
        let g = makeGeometry(shape: [1, 40, 40], spacing: [1, 0.5, 0.5])
        return makeImage(Int16.self, geometry: g, slope: 1, intercept: -1000) { Int16(1000 + $0.y) }
    }

    func testEllipseRectangleAndFreehandROIs() throws {
        let image = ctImage()
        let g = image.geometry
        let plane = PlaneFrame(origin: g.world(fromIndex: SIMD3(0, 20, 20)), axes: PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0)))
        // Ellipse of radii 4 mm (right) × 2 mm (down) = 8 × 4 pixels.
        let ellipse = PlanarROI(plane: plane, shape: .ellipse(center: .zero, radii: SIMD2(4, 2)))
        XCTAssertEqual(ellipse.area, Double.pi * 8, accuracy: 1e-12)
        let es = try ellipse.statistics(image: image)
        let expected = allVoxels(g.paddedShape) { k in
            let u = Double(k.z - 20) * 0.5 / 4, v = Double(k.y - 20) * 0.5 / 2
            return u * u + v * v <= 1
        }
        XCTAssertEqual(es.voxelCount, expected.count)
        XCTAssertEqual(es.intensity.mean, 20, accuracy: 1e-9, "symmetric about row 20 → 20 HU")
        XCTAssertEqual(es.intensity.minimum, 16)
        XCTAssertEqual(es.intensity.maximum, 24)
        XCTAssertEqual(es.units, "HU")
        XCTAssertEqual(es.voxelCount, 17 + 2 * 15 + 2 * 13 + 2 * 11 + 2 * 1) // row widths |dz| ≤ 8·√(1 − dy²/16)
        // Rectangle of 3 mm × 2 mm from the plane origin: pixels 20…26 × 20…24.
        let rect = PlanarROI(plane: plane, shape: .rectangle(SIMD2(0, 0), SIMD2(3, 2)))
        XCTAssertEqual(rect.area, 6)
        XCTAssertEqual(rect.perimeter, 10)
        let rs = try rect.statistics(image: image)
        XCTAssertEqual(rs.voxelCount, 7 * 5)
        XCTAssertEqual(rs.intensity.median, 22)
        // Freehand triangle.
        let tri = PlanarROI(plane: plane, shape: .polygon([SIMD2(-5, -5), SIMD2(5, -5), SIMD2(-5, 5)]))
        XCTAssertEqual(tri.area, 50)
        let ts = try tri.statistics(image: image, physical: false)
        XCTAssertNil(ts.units)
        XCTAssertEqual(ts.voxelCount, voxels(of: tri.region(in: g)).count)
        XCTAssertTrue(voxels(of: tri.region(in: g)).allSatisfy { k in
            let u = Double(k.z - 20) * 0.5, v = Double(k.y - 20) * 0.5
            return u >= -5 && v >= -5 && u + v <= 0 + 1e-9
        })
    }

    func testObliqueROIUsesTheVoxelsThePlaneCuts() throws {
        let g = makeGeometry(shape: [20, 20, 20], spacing: [1, 1, 1])
        let image = makeImage(Float.self, geometry: g, modality: "MR") { Float($0.x + $0.y + $0.z) }
        let n = simd_normalize(SIMD3<Double>(1, 1, 0))
        let right = simd_normalize(simd_cross(SIMD3(0, 0, 1), n))
        let plane = PlaneFrame(origin: SIMD3(10, 10, 10), axes: PlaneAxes(right: right, down: simd_cross(n, right)))
        let roi = PlanarROI(plane: plane, shape: .ellipse(center: .zero, radii: SIMD2(4, 4)))
        let region = voxels(of: roi.region(in: g))
        let brush = voxels(of: Brush.disc(radius: 4, plane: plane.axes).region(at: plane.origin, in: g))
        XCTAssertEqual(region, brush, "a circular ROI covers what a disc brush of its radius paints")
        let s = try roi.statistics(image: image)
        XCTAssertEqual(s.intensity.mean, 30, accuracy: 0.5)
        XCTAssertNil(s.units)
    }

    func testSphereROIAndPointValue() throws {
        let g = makeGeometry(shape: [10, 10, 10], spacing: [2, 1, 1])
        let image = makeImage(Int16.self, geometry: g, slope: 0.5, intercept: 10, modality: "PT") { Int16($0.x * 100) }
        let sphere = SphereROI(center: g.world(fromIndex: SIMD3(5, 5, 5)), radius: 2.1)
        XCTAssertEqual(sphere.volume, 4.0 / 3.0 * Double.pi * 2.1 * 2.1 * 2.1, accuracy: 1e-12)
        let s = try sphere.statistics(image: image)
        let expected = allVoxels(g.paddedShape) { worldDistance2(g, $0, SIMD3(5, 5, 5)) <= 2.1 * 2.1 }
        XCTAssertEqual(s.voxelCount, expected.count)
        XCTAssertEqual(s.intensity.mean, expected.map { Double($0.x * 100) * 0.5 + 10 }.reduce(0, +) / Double(expected.count),
                       accuracy: 1e-9)
        XCTAssertNil(s.units)
        XCTAssertTrue(SphereROI(center: g.world(fromIndex: SIMD3(5, 5.5, 5.5)), radius: 0.2).region(in: g).isEmpty)
        XCTAssertEqual(imageValue(image, atWorld: g.world(fromIndex: SIMD3(3, 1, 1))), 160)
        XCTAssertEqual(imageValue(image, atWorld: g.world(fromIndex: SIMD3(3, 1, 1)), physical: false), 300)
        XCTAssertNil(imageValue(image, atWorld: SIMD3(-100, 0, 0)))
    }
}
