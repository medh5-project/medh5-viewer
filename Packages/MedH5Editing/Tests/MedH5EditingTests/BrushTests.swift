import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class BrushTests: XCTestCase {
    let spacing = [2.5, 0.7, 0.9]

    /// Independent statement of the disc rule: voxel cells the plane cuts
    /// (centre within the voxel's half-extent along the normal, ties to the
    /// higher index of the dominant axis) whose centre projects within R.
    private func expectedDisc(_ g: GridGeometry, center c: SIMD3<Double>, radius r: Double, plane: PlaneAxes) -> Set<SIMD3<Int>> {
        let n = plane.normal
        let m = g.indexToWorldLinear
        let cols = [m.columns.0, m.columns.1, m.columns.2]
        let h = 0.5 * cols.reduce(0) { $0 + abs(simd_dot($1, n)) }
        let dominant = (0..<3).max { abs(simd_dot(cols[$0], n)) < abs(simd_dot(cols[$1], n)) }!
        let sigma: Double = simd_dot(cols[dominant], n) < 0 ? -1 : 1
        return allVoxels(g.paddedShape) { k in
            let q = g.world(fromIndex: SIMD3<Double>(k)) - c
            let d = sigma * simd_dot(q, n)
            guard d > -h && d <= h else { return false }
            let u = simd_dot(q, plane.right), v = simd_dot(q, plane.down)
            return u * u + v * v <= r * r
        }
    }

    func testAxialDiscOnAnisotropicGrid() {
        let g = makeGeometry(shape: [9, 40, 40], spacing: spacing, origin: [10, -5, 3])
        let c = g.world(fromIndex: SIMD3(4, 20.3, 19.6))
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0)) // across axis 0
        let got = voxels(of: Brush.disc(radius: 3.1, plane: plane).region(at: c, in: g))
        let expected = allVoxels(g.paddedShape) { k in
            let du = 0.7 * (Double(k.y) - 20.3), dv = 0.9 * (Double(k.z) - 19.6)
            return k.x == 4 && du * du + dv * dv <= 3.1 * 3.1
        }
        XCTAssertEqual(got, expected)
        XCTAssertGreaterThan(expected.count, 40)
    }

    func testCoronalDiscOnAnisotropicGrid() {
        let g = makeGeometry(shape: [12, 30, 40], spacing: spacing)
        let c = g.world(fromIndex: SIMD3(5.2, 17, 22.4))
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(1, 0, 0)) // across axis 1
        let got = voxels(of: Brush.disc(radius: 6.3, plane: plane).region(at: c, in: g))
        let expected = allVoxels(g.paddedShape) { k in
            let du = 0.9 * (Double(k.z) - 22.4), dv = 2.5 * (Double(k.x) - 5.2)
            return k.y == 17 && du * du + dv * dv <= 6.3 * 6.3
        }
        XCTAssertEqual(got, expected)
    }

    func testObliqueDiscMatchesTheDefinition() {
        let g = makeGeometry(shape: [14, 30, 30], spacing: spacing, origin: [1, 2, 3])
        let n = simd_normalize(SIMD3<Double>(1, 0.5, 0.3))
        let right = simd_normalize(simd_cross(SIMD3(0, 0, 1), n))
        let plane = PlaneAxes(right: right, down: simd_cross(n, right))
        XCTAssertEqual(simd_distance(plane.normal, n), 0, accuracy: 1e-12)
        for (i, center) in [SIMD3(7.3, 14.1, 15.7), SIMD3(2.0, 3.5, 28.9), SIMD3(13.2, 29.4, 0.2)].enumerated() {
            let c = g.world(fromIndex: center)
            let got = voxels(of: Brush.disc(radius: 4.4, plane: plane).region(at: c, in: g))
            let expected = expectedDisc(g, center: c, radius: 4.4, plane: plane)
            XCTAssertEqual(got, expected, "centre \(i)")
            XCTAssertFalse(expected.isEmpty)
        }
    }

    func testDiscOnAnObliqueGridAlignedPlaneIsOneSlice() {
        let a = 30.0 * Double.pi / 180
        let dir = [[cos(a), -sin(a), 0], [sin(a), cos(a), 0], [0, 0, 1]]
        let g = makeGeometry(shape: [10, 32, 32], spacing: [1.5, 0.8, 0.6], origin: [-3, 7, 2], direction: dir)
        let plane = PlaneAxes.aligned(.axial, to: g)
        let axis = g.nearestAxis(to: plane.normal)
        XCTAssertEqual(axis, 2, "the grid's axial plane runs across its third axis")
        let ci = SIMD3(5.3, 15.6, 16.2)
        let slice = Int((ci[axis] + 0.5).rounded(.down))
        let region = Brush.disc(radius: 3.3, plane: plane).region(at: g.world(fromIndex: ci), in: g)
        let got = voxels(of: region)
        XCTAssertEqual(Set(got.map { $0[axis] }), [slice])
        let sp = g.paddedSpacing
        let expected = allVoxels(g.paddedShape) { k in
            guard k[axis] == slice else { return false }
            var d2 = 0.0
            for ax in 0..<3 where ax != axis {
                let d = sp[ax] * (Double(k[ax]) - ci[ax])
                d2 += d * d
            }
            return d2 <= 3.3 * 3.3
        }
        XCTAssertEqual(got, expected)
    }

    func testSphereOnAnisotropicObliqueGrid() {
        let a = 20.0 * Double.pi / 180
        let dir = [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]]
        let g = makeGeometry(shape: [12, 24, 24], spacing: spacing, origin: [0, 1, 2], direction: dir)
        let c = g.world(fromIndex: SIMD3(6.4, 11.2, 12.9))
        let got = voxels(of: Brush.sphere(radius: 5.2).region(at: c, in: g))
        let expected = allVoxels(g.paddedShape) { simd_length_squared(g.worldPosition(ofVoxel: $0) - c) <= 5.2 * 5.2 }
        XCTAssertEqual(got, expected)
        XCTAssertGreaterThan(expected.count, 100)
    }

    func testPlaneBetweenSlicesPicksTheSliceHalfUpRounds() {
        let g = makeGeometry(shape: [8, 10, 10], spacing: [2, 1, 1])
        let c = g.world(fromIndex: SIMD3(3.5, 5, 5))
        for plane in [PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0)), PlaneAxes(right: SIMD3(0, 1, 0), down: SIMD3(0, 0, 1))] {
            let got = voxels(of: Brush.disc(radius: 1.5, plane: plane).region(at: c, in: g))
            XCTAssertEqual(Set(got.map(\.x)), [4], "normal \(plane.normal)")
        }
    }

    func testTinyBrushPaintsTheVoxelUnderTheCursor() {
        let g = makeGeometry(shape: [3, 10, 10], spacing: [1, 1, 1])
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0))
        let region = Brush.disc(radius: 0.1, plane: plane).region(at: SIMD3(1, 4.4, 6.45), in: g)
        XCTAssertEqual(voxels(of: region), [SIMD3(1, 4, 6)])
        XCTAssertTrue(Brush.sphere(radius: 1).region(at: SIMD3(100, 100, 100), in: g).isEmpty)
    }

    func testStrokeSpacingLeavesNoGaps() throws {
        let m = try makeModel(shape: [1, 64, 64], spacing: [1, 1, 1], classes: [(1, 0)], layerCount: 1)
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0))
        let brush = Brush.disc(radius: 2, plane: plane)
        let a = SIMD3<Double>(0, 5, 5), b = SIMD3<Double>(0, 50, 58)
        XCTAssertEqual(brush.dabCenters(from: a, to: b).count, Int((simd_distance(a, b) / 1).rounded(.up)))
        let stroke = try BrushStroke(model: m, operation: .paint(1), brush: brush)
        try stroke.add(a)
        try stroke.add(b) // one fast motion across the image
        let edit = stroke.finish()
        let painted = voxels(of: 1, in: m)
        XCTAssertTrue(isFaceConnected(painted))
        func distanceToSegment(_ k: SIMD3<Int>) -> Double {
            let p = SIMD3<Double>(k), d = b - a
            let t = max(0, min(1, simd_dot(p - a, d) / simd_length_squared(d)))
            return simd_distance(p, a + t * d)
        }
        for k in allVoxels(m.shape, where: { distanceToSegment($0) <= 2 * 0.86 }) {
            XCTAssertTrue(painted.contains(k), "gap at \(k)")
        }
        XCTAssertTrue(painted.allSatisfy { distanceToSegment($0) <= 2 + 1e-9 })
        XCTAssertEqual(edit.voxelCount, painted.count)
    }

    func testIntensityConstrainedBrushOnTheSameGrid() throws {
        let m = try makeModel(shape: [1, 20, 20], classes: [(1, 0)], layerCount: 1)
        // HU = raw − 1000, raw = 1000 + 10·k2.
        let image = makeImage(Int16.self, geometry: m.geometry, slope: 1, intercept: -1000) { Int16(1000 + 10 * $0.z) }
        let options = PaintOptions(intensity: IntensityConstraint(image: image, range: 50...120))
        let region = Brush.sphere(radius: 30).region(at: m.geometry.worldCenter, in: m.geometry)
        m.apply(try m.makeEdit(.paint(1), over: region, options: options))
        let painted = voxels(of: 1, in: m)
        XCTAssertEqual(painted, allVoxels(m.shape) { (5...12).contains($0.z) })
    }

    func testIntensityConstraintSamplesAnImageOnAnotherGridByWorldPosition() throws {
        // Segmentation: 1 mm voxels; image: 2 mm voxels shifted by 0.5 mm.
        let m = try makeModel(shape: [1, 16, 16], spacing: [1, 1, 1], classes: [(1, 0)], layerCount: 1)
        let ig = makeGeometry(shape: [1, 8, 8], spacing: [1, 2, 2], origin: [0, 0.5, 0.5])
        let image = makeImage(Float.self, geometry: ig, modality: "MR") { Float($0.z * 8 + $0.y) }
        let options = PaintOptions(intensity: IntensityConstraint(image: image, range: 18...29))
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { _ in true }, options: options))
        let expected = allVoxels(m.shape) { k in
            // The image voxel containing the segmentation voxel's centre.
            let i1 = Int(((Double(k.y) - 0.5) / 2 + 0.5).rounded(.down))
            let i2 = Int(((Double(k.z) - 0.5) / 2 + 0.5).rounded(.down))
            guard i1 >= 0 && i1 < 8 && i2 >= 0 && i2 < 8 else { return false }
            return (18...29).contains(Double(i2 * 8 + i1))
        }
        XCTAssertEqual(voxels(of: 1, in: m), expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testStrokeIsOneUndoableEditThatRestoresBytes() throws {
        let m = try makeModel(shape: [3, 40, 40], spacing: [2, 0.8, 0.8], inAnnotation: false)
        fillRaw(m, layer: 0, value: 2) { $0.y > 20 }
        let before = snapshot(m), metaBefore = m.metadata
        let plane = PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0))
        let stroke = try BrushStroke(model: m, operation: .paint(1), brush: .disc(radius: 3, plane: plane))
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            try stroke.add(m.geometry.world(fromIndex: SIMD3(1, 5 + 30 * t, 5 + 25 * t)))
        }
        let edit = stroke.finish()
        let after = snapshot(m)
        XCTAssertNotEqual(after, before)
        XCTAssertTrue(m.classIDs.contains(1))
        XCTAssertEqual(edit.metadataChange?.before, metaBefore)
        m.revert(edit)
        XCTAssertEqual(snapshot(m), before)
        XCTAssertEqual(m.metadata, metaBefore)
        m.apply(edit)
        XCTAssertEqual(snapshot(m), after)
        // Cancelling restores everything.
        let stroke2 = try BrushStroke(model: m, operation: .eraseAll, brush: .sphere(radius: 4))
        try stroke2.add(m.geometry.worldCenter)
        XCTAssertNotEqual(snapshot(m), after)
        stroke2.cancel()
        XCTAssertEqual(snapshot(m), after)
    }

    func testEraserStrokeOfOneClass() throws {
        let m = try makeModel(shape: [1, 10, 10], inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { _ in true }
        fillRaw(m, layer: 1, value: 3) { _ in true }
        let stroke = try BrushStroke(model: m, operation: .erase(3), brush: .sphere(radius: 2.5))
        try stroke.add(m.geometry.world(fromIndex: SIMD3(0, 5, 5)))
        _ = stroke.finish()
        XCTAssertEqual(voxels(of: 1, in: m).count, 100)
        XCTAssertEqual(voxels(of: 3, in: m).count, 100 - 21)
    }

    func testStrokeRejectsLockedClasses() throws {
        let m = try makeModel(shape: [1, 4, 4])
        m.apply(try m.updateClassEdit(1) { $0.isLocked = true })
        XCTAssertThrowsError(try BrushStroke(model: m, operation: .paint(1), brush: .sphere(radius: 1)))
    }
}
