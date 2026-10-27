import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class AnnotationModelTests: XCTestCase {
    // MARK: Boxes

    func testTwoDimensionalBoxFromADragOnASlice() {
        let g = makeGeometry(shape: [20, 30, 40], spacing: [2, 0.5, 0.5], origin: [5, 5, 5])
        let start = g.world(fromIndex: SIMD3(7.2, 3.3, 10.6)), end = g.world(fromIndex: SIMD3(7.2, 8.9, 4.4))
        let normal = g.axisDirections[0]
        let box = BoxAnnotation.fromDrag(from: start, to: end, planeNormal: normal, geometry: g, classID: 4)
        XCTAssertEqual(box.sliceIndex, 7)
        XCTAssertEqual(box.degenerateAxis, 0)
        XCTAssertEqual(box.lower, SIMD3(7, 2.5, 3.5))
        XCTAssertEqual(box.upper, SIMD3(7, 9.5, 11.5))
        XCTAssertEqual(box.voxelBox, VoxelBox(lower: SIMD3(7, 3, 4), upper: SIMD3(8, 10, 12)))
        XCTAssertTrue(box.isOnSlice)
        // With a depth, a 3-D box through those slices.
        let box3 = BoxAnnotation.fromDrag(from: start, to: end, planeNormal: normal, geometry: g, classID: 4, depth: 5...9)
        XCTAssertNil(box3.sliceIndex)
        XCTAssertEqual(box3.voxelBox, VoxelBox(lower: SIMD3(5, 3, 4), upper: SIMD3(10, 10, 12)))
        // Unsnapped, the corners are kept.
        let raw = BoxAnnotation.fromDrag(from: start, to: end, planeNormal: normal, geometry: g, classID: 4, snapToVoxels: false)
        XCTAssertEqual(raw.lower.y, 3.3, accuracy: 1e-9)
        XCTAssertEqual(raw.upper.z, 10.6, accuracy: 1e-9)
    }

    func testBoxHandlesMoveAndResize() {
        let box = BoxAnnotation(lower: SIMD3(4, 2.5, 3.5), upper: SIMD3(4, 9.5, 11.5), classID: 1, sliceIndex: 4)
        let handles = box.handles(acrossAxis: 0)
        XCTAssertEqual(handles.count, 8)
        XCTAssertEqual(handles.filter { $0.handle.isCorner }.count, 4)
        let corner = handles.first { $0.handle.sides == SIMD3(0, 1, 1) }!
        XCTAssertEqual(corner.position, SIMD3(4, 9.5, 11.5))
        let resized = box.dragging(corner.handle, to: SIMD3(4, 12.5, 2.5))
        XCTAssertEqual(resized.lower, SIMD3(4, 2.5, 2.5))
        XCTAssertEqual(resized.upper, SIMD3(4, 12.5, 3.5), "crossed edges swap")
        XCTAssertEqual(resized.sliceIndex, 4)
        let moved = box.moved(by: SIMD3(2, 1, -1))
        XCTAssertEqual(moved.sliceIndex, 6)
        XCTAssertEqual(moved.lower, SIMD3(6, 3.5, 2.5))
        let snapped = BoxAnnotation(lower: SIMD3(0.2, 1.7, 2), upper: SIMD3(3.4, 4.6, 2), classID: 1).snappedToVoxelEdges()
        XCTAssertEqual(snapped.lower, SIMD3(0.5, 1.5, 2)) // nearest edges; the flat axis is left alone
        XCTAssertEqual(snapped.upper, SIMD3(3.5, 4.5, 2))
    }

    func testBoxesRoundTripThroughArrays() throws {
        let set = BoxAnnotationSet(space: .index, rank: 3, boxes: [
            BoxAnnotation(lower: SIMD3(5, 2.5, 3.5), upper: SIMD3(5, 9.5, 11.5), classID: 3, instanceID: 7, score: 0.5,
                          attributes: "{\"birads\":4}", sliceIndex: 5),
            BoxAnnotation(lower: SIMD3(-0.5, 0.5, 1.5), upper: SIMD3(3.5, 2.5, 7.25), classID: 4, instanceID: 1 << 40, score: 0.75),
        ])
        let arrays = set.arrays()
        XCTAssertEqual(arrays["boxes"]?.shape, [2, 3, 2])
        XCTAssertEqual(arrays["boxes"]?.scalarType, .float32)
        XCTAssertEqual(arrays["boxes"]?.doubles.prefix(6), [5, 5, 2.5, 9.5, 3.5, 11.5])
        XCTAssertEqual(arrays["class_ids"]?.values, .uint16([3, 4]))
        XCTAssertEqual(arrays["slice_index"]?.values, .int32([5, -1]))
        XCTAssertEqual(arrays["instance_ids"]?.values, .uint64([7, 1 << 40]))
        XCTAssertEqual(arrays.strings["attributes"], ["{\"birads\":4}", "{}"])
        let back = try BoxAnnotationSet(arrays: arrays)
        XCTAssertEqual(back.boxes[0], set.boxes[0])
        XCTAssertEqual(back.boxes[1].lower, set.boxes[1].lower)
        XCTAssertEqual(back.boxes[1].instanceID, 1 << 40)
        XCTAssertEqual(back.boxes[1].attributes, "{}")
        XCTAssertTrue(back.validate(gridShape: SIMD3(10, 10, 12)).isEmpty)
        // Without optional columns.
        let plain = BoxAnnotationSet(boxes: [BoxAnnotation(lower: .zero, upper: SIMD3(1, 1, 1), classID: 2)])
        XCTAssertNil(plain.arrays()["scores"])
        XCTAssertNil(plain.arrays()["slice_index"])
    }

    func testTwoDimensionalGridBoxes() throws {
        let set = BoxAnnotationSet(space: .index, rank: 2, boxes: [
            BoxAnnotation(lower: SIMD3(-0.5, 1.5, 2.5), upper: SIMD3(0.5, 4.5, 6.5), classID: 1),
        ])
        let arrays = set.arrays()
        XCTAssertEqual(arrays["boxes"]?.shape, [1, 2, 2])
        XCTAssertEqual(arrays["boxes"]?.doubles, [1.5, 4.5, 2.5, 6.5])
        let back = try BoxAnnotationSet(arrays: arrays)
        XCTAssertEqual(back.boxes, set.boxes)
        XCTAssertEqual(back.boxes[0].voxelBox, VoxelBox(lower: SIMD3(0, 2, 3), upper: SIMD3(1, 5, 7)))
    }

    func testBoxValidation() {
        let set = BoxAnnotationSet(boxes: [
            BoxAnnotation(lower: SIMD3(1, 1, 1), upper: SIMD3(0, 2, 2), classID: 1),
            BoxAnnotation(lower: SIMD3(.nan, 1, 1), upper: SIMD3(1, 2, 2), classID: 1),
            BoxAnnotation(lower: SIMD3(12, 1, 1), upper: SIMD3(12, 2, 2), classID: 1, sliceIndex: 12),
            BoxAnnotation(lower: SIMD3(0, 1, 1), upper: SIMD3(1, 2, 2), classID: 0),
        ])
        let codes = set.validate(gridShape: SIMD3(10, 10, 10)).map(\.code)
        XCTAssertEqual(codes, ["E406", "E406", "E405", "E402"])
        // Arrays of the wrong shape are refused.
        var bad = set.arrays()
        bad.arrays[1] = AnnotationArray(name: "class_ids", shape: [3], values: .uint16([1, 1, 1]))
        XCTAssertThrowsError(try BoxAnnotationSet(arrays: bad))
        XCTAssertThrowsError(try BoxAnnotationSet(arrays: GeometricArrays(kind: "boxes", space: .index))) {
            XCTAssertEqual(($0 as? GeometryArrayError)?.issue.code, "E410")
        }
    }

    // MARK: Points and keypoints

    func testPointsRoundTrip() throws {
        let set = PointAnnotationSet(space: .world, rank: 3, points: [
            LandmarkPoint(position: SIMD3(1.5, -2.25, 30), classID: 5, name: "apex"),
            LandmarkPoint(position: SIMD3(0, 0, 0), classID: 6, name: nil),
        ], correspondence: "landmarks_moving")
        let arrays = set.arrays()
        XCTAssertEqual(arrays["points"]?.shape, [2, 3])
        XCTAssertEqual(arrays.strings["names"], ["apex", ""])
        XCTAssertEqual(arrays.attributes["correspondence"], "landmarks_moving")
        XCTAssertNil(arrays["weights"])
        let back = try PointAnnotationSet(arrays: arrays)
        XCTAssertEqual(back, set)
        XCTAssertEqual(back.point(named: "apex")?.classID, 5)
        // Index ↔ world conversion through the grid.
        let g = makeGeometry(shape: [10, 10, 10], spacing: [2, 1, 1], origin: [1, 2, 3])
        let idx = set.converted(to: .index, geometry: g)
        XCTAssertEqual(simd_distance(idx.points[0].position, SIMD3(0.25, -4.25, 27)), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_distance(idx.converted(to: .world, geometry: g).points[0].position, set.points[0].position), 0,
                       accuracy: 1e-12)
        // A column set for some points only is a shape error.
        var partial = set
        partial.points[1].weight = 1
        XCTAssertEqual(partial.validate().map(\.code), ["E405"])
    }

    func testKeypointsRoundTrip() throws {
        var set = KeypointAnnotationSet(space: .index, rank: 3, slotClassIDs: [101, 102, 103], skeleton: "spine")
        let i = set.addObject(classID: 9)
        set.objects[i].set(slot: 0, to: SIMD3(1, 2, 3))
        set.objects[i].set(slot: 2, to: SIMD3(4, 5, 6), visibility: .occluded)
        set.addObject(classID: 10)
        let arrays = set.arrays()
        XCTAssertEqual(arrays["points"]?.shape, [2, 3, 3])
        XCTAssertEqual(arrays["visibility"]?.values, .uint8([2, 0, 1, 0, 0, 0]))
        XCTAssertEqual(arrays["keypoint_class_ids"]?.values, .uint16([101, 102, 103]))
        XCTAssertEqual(arrays.attributes["skeleton"], "spine")
        XCTAssertEqual(try KeypointAnnotationSet(arrays: arrays), set)
        var bad = arrays
        bad.arrays[1] = AnnotationArray(name: "visibility", shape: [2, 3], values: .uint8([2, 0, 3, 0, 0, 0]))
        XCTAssertThrowsError(try KeypointAnnotationSet(arrays: bad)) {
            XCTAssertEqual(($0 as? GeometryArrayError)?.issue.code, "E411")
        }
    }

    // MARK: Polylines and contours

    func testPolylinesRoundTrip() throws {
        let set = PolylineAnnotationSet(space: .index, rank: 3, polylines: [
            Polyline(vertices: [SIMD3(1, 2, 3), SIMD3(1, 4, 5), SIMD3(1, 6, 5)], classID: 2, plane: GridPlane(axis: 0, index: 1),
                     instanceID: 11),
            Polyline(vertices: [SIMD3(0, 0, 0), SIMD3(3, 4, 0)], classID: 3, instanceID: 12),
        ])
        let arrays = set.arrays()
        XCTAssertEqual(arrays["vertices"]?.shape, [5, 3])
        XCTAssertEqual(arrays["polyline_offsets"]?.values, .int64([0, 3, 5]))
        XCTAssertEqual(arrays["polyline_plane"]?.values, .int32([0, 1, -1, 0]))
        XCTAssertEqual(try PolylineAnnotationSet(arrays: arrays), set)
        XCTAssertTrue(PolylineAnnotationSet.validate(arrays: arrays).isEmpty)
        XCTAssertEqual(set.polylines[1].length(space: .world), 5)
        let g = makeGeometry(shape: [4, 8, 8], spacing: [3, 1, 1])
        XCTAssertEqual(set.polylines[1].length(space: .index, geometry: g), (81.0 + 16).squareRoot(), accuracy: 1e-12)
        // Validation.
        let short = PolylineAnnotationSet(polylines: [Polyline(vertices: [SIMD3(0, 0, 0)], classID: 1)])
        XCTAssertEqual(short.validate().map(\.code), ["E404"])
        XCTAssertEqual(PolylineAnnotationSet.validate(arrays: short.arrays()).map(\.code), ["E404"])
        var badOffsets = arrays
        badOffsets.arrays[1] = AnnotationArray(name: "polyline_offsets", shape: [3], values: .int64([0, 4, 3]))
        XCTAssertEqual(Set(PolylineAnnotationSet.validate(arrays: badOffsets).map(\.code)), ["E408"])
        XCTAssertThrowsError(try PolylineAnnotationSet(arrays: badOffsets)) {
            XCTAssertEqual(($0 as? GeometryArrayError)?.issue.code, "E408")
        }
    }

    func testContoursRoundTripAndRolesFromDepth() throws {
        let plane = GridPlane(axis: 0, index: 4)
        func square(_ a: Double, _ b: Double) -> [SIMD3<Double>] {
            [SIMD3(4, a, a), SIMD3(4, a, b), SIMD3(4, b, b), SIMD3(4, b, a)]
        }
        let set = ContourAnnotationSet(space: .index, rank: 3, contours: [
            Contour(vertices: square(0, 10), classID: 1, plane: plane, role: .outer),
            Contour(vertices: square(2, 8), classID: 1, plane: plane, role: .outer), // really a hole
            Contour(vertices: square(4, 6), classID: 1, plane: plane, role: .outer), // an island in it
            Contour(vertices: square(2, 8), classID: 2, plane: plane, role: .outer), // another class
            Contour(vertices: square(2, 8), classID: 1, plane: nil, role: .hole),    // out of plane
        ])
        let arrays = set.arrays()
        XCTAssertEqual(arrays["contour_offsets"]?.values, .int64([0, 4, 8, 12, 16, 20]))
        XCTAssertEqual(arrays["contour_plane"]?.values, .int32([0, 4, 0, 4, 0, 4, 0, 4, -1, 0]))
        XCTAssertEqual(try ContourAnnotationSet(arrays: arrays), set)
        XCTAssertEqual(set.rolesFromDepth(), [.outer, .hole, .outer, .outer, .hole])
        XCTAssertEqual(set.validate().map(\.code), ["W919"])
        XCTAssertEqual(set.contours[0].area(space: .world), 100, accuracy: 1e-12)
        XCTAssertEqual(set.contours[0].perimeter(space: .world), 40, accuracy: 1e-12)
        // Fewer than three vertices; a role the format does not define.
        let tiny = ContourAnnotationSet(contours: [Contour(vertices: [SIMD3(0, 0, 0), SIMD3(0, 1, 1)], classID: 1, plane: plane)])
        XCTAssertEqual(tiny.validate().map(\.code), ["E404"])
        var badRole = arrays
        badRole.arrays[4] = AnnotationArray(name: "contour_role", shape: [5], values: .uint8([0, 1, 2, 0, 0]))
        XCTAssertTrue(ContourAnnotationSet.validate(arrays: badRole).contains { $0.code == "E404" })
        XCTAssertThrowsError(try ContourAnnotationSet(arrays: badRole))
    }

    func testWorldSpaceTwoDimensionalCoordinates() throws {
        let set = PolylineAnnotationSet(space: .world, rank: 2, polylines: [
            Polyline(vertices: [SIMD3(1, 2, 0), SIMD3(3, 4, 0)], classID: 1),
        ])
        let arrays = set.arrays()
        XCTAssertEqual(arrays["vertices"]?.shape, [2, 2])
        XCTAssertEqual(arrays["vertices"]?.doubles, [1, 2, 3, 4])
        XCTAssertEqual(try PolylineAnnotationSet(arrays: arrays), set)
    }
}
