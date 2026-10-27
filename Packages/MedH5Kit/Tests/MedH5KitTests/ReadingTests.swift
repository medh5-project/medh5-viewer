import XCTest
import simd
@testable import MedH5Kit

/// Reading the demo sample: the summary models, images, every voxel
/// encoding, every geometric kind, transforms, the clinical history.
final class ReadingTests: XCTestCase {
    var sample: SampleFile!

    override func setUpWithError() throws {
        sample = try SampleFile.open(Fixtures.demo)
    }

    override func tearDown() {
        sample?.close()
    }

    // MARK: Summary

    func testSummaryModelsDescribeWhatTheDemoWrote() throws {
        let s = sample.summary
        XCTAssertEqual(s.formatVersion, "1.2")
        XCTAssertEqual(s.support, .full)
        XCTAssertEqual(s.kind, "sample")
        for profile in ["core", "seg", "det", "cls", "reg", "longitudinal", "clinical", "training"] {
            XCTAssertTrue(s.profiles.contains(profile), profile)
        }
        XCTAssertTrue(s.contentID?.hasPrefix("sha256:") ?? false)
        XCTAssertEqual(s.digestAlgorithm, "sha256")
        XCTAssertEqual(s.identity, Identity(sampleID: "demo-abdomen-01", subjectID: "DEMO-SUBJ-01", sex: "F", bodypart: "ABDOMEN"))
        XCTAssertEqual(s.cohort?.datasetID, "medh5-viewer-demo")
        XCTAssertEqual(s.timepoints.map(\.id), ["tp0", "tp1"])
        XCTAssertEqual(s.timepoint("tp1")?.daysFromBaseline, 92)
        XCTAssertEqual(s.timepoint("tp0")?.label, "baseline")
        XCTAssertTrue(s.isLongitudinal)
        XCTAssertEqual(s.deidentification?["method"], "synthetic")
        XCTAssertEqual(s.acquisition["CT_tp0"]?["KVP"], .int(120))
        XCTAssertTrue(s.unreadable.isEmpty)
        XCTAssertTrue(s.leftOut.isEmpty)

        // The label set: colours, codes, a hierarchy, a skeleton.
        let labels = try XCTUnwrap(s.labelSet)
        XCTAssertEqual(labels.classes.count, 12)
        XCTAssertEqual(labels.labelClass(key: "liver")?.color, RGBA8(221, 130, 101, 255))
        XCTAssertEqual(labels.labelClass(id: 9)?.parents, [2])
        XCTAssertEqual(labels.ancestors(of: 5), [4])
        XCTAssertEqual(labels.children(of: 4).map(\.key), ["left_kidney", "right_kidney"])
        XCTAssertEqual(labels.labelClass(id: 6)?.laterality, "right")
        XCTAssertEqual(labels.labelClass(id: 2)?.codes.first, OntologyCode(system: "SCT", code: "10200004", name: "Liver structure"))
        XCTAssertEqual(labels.labelClass(id: 2)?.properties["window"], [-150, 250])
        XCTAssertEqual(labels.skeletons.first?.edges, [[2, 7], [3, 7], [7, 8]])
        XCTAssertEqual(labels.labelClass(id: 9)?.displayColor, RGBA8(255, 255, 0))

        // Provenance and quality.
        XCTAssertEqual(s.provenance.agent("rad1")?.role, "annotator")
        XCTAssertEqual(s.provenance.activity("act_register")?.type, "register")
        XCTAssertEqual(s.quality["organs_tp0"]?.status, "reviewed")
        XCTAssertEqual(s.quality["organs_tp0"]?.reviewedBy, ["rad2"])

        // Grids decode straight into GridGeometry.
        let ct = try XCTUnwrap(s.grid("ct_tp0"))
        XCTAssertEqual(ct.shape, [64, 64, 64])
        XCTAssertEqual(ct.spacing, [6.25, 5, 5])
        XCTAssertEqual(ct.frameUID, "demo:frame-tp0")
        XCTAssertEqual(ct.timepoint, "tp0")
        XCTAssertEqual(ct.coordSystem, "LPS")
        XCTAssertTrue(near(ct.worldCenter, SIMD3(0, 0, 0)))
        XCTAssertTrue(s.sharesFrame("ct_tp0", "mr_tp0"))
        XCTAssertFalse(s.sharesFrame("ct_tp0", "ct_tp1"))
        let mr = try XCTUnwrap(s.grid("mr_tp0"))
        XCTAssertTrue(near(mr.worldCenter, SIMD3(0, 0, 20)))

        // Images.
        let image = try XCTUnwrap(s.image("CT_tp0"))
        XCTAssertEqual(image.scalarType, .int16)
        XCTAssertEqual(image.modality, "CT")
        XCTAssertEqual(image.valueUnits, "HU")
        XCTAssertEqual(image.rescaleIntercept, -1024)
        XCTAssertEqual(image.windowPresets.map(\.center), [50, 400])
        XCTAssertEqual(s.image("MR_tp0")?.validMask, "mr_fov")
        XCTAssertEqual(s.images(at: "tp1").map(\.id), ["CT_tp1"])

        // Annotations: coverage kept apart.
        let organs = try XCTUnwrap(s.annotation("organs_tp0"))
        XCTAssertEqual(organs.kind, "layers")
        XCTAssertEqual(organs.classIDs, [2, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(organs.annotatedClassIDs, [2, 3, 5, 6, 8, 9])
        XCTAssertEqual(organs.unexaminedClassIDs, [7])
        XCTAssertFalse(organs.fullyCovered)
        XCTAssertEqual(organs.ignoreID, 65535)
        XCTAssertEqual(s.annotation("organs_tp1")?.derivedFrom, ["lesion_prob_tp1"])
        XCTAssertEqual(s.annotation("lesions_tp0")?.instanceIDs, [1, 2])
        XCTAssertEqual(s.annotation("response")?.changeLabel, true)
        XCTAssertEqual(s.annotation("centrelines_tp0")?.kind, "polylines")
        XCTAssertEqual(s.annotations(at: "tp1").map(\.id).sorted(),
                       ["fiducials_tp1", "lesion_prob_tp1", "organs_tp1", "response"])
        let transform = try XCTUnwrap(s.transform("tp0_to_tp1"))
        XCTAssertEqual(transform.kind, "affine")
        XCTAssertEqual(transform.fromFrame, "demo:frame-tp0")
        XCTAssertEqual(transform.toFrame, "demo:frame-tp1")
        XCTAssertEqual(s.index, [IndexEntry(annotation: "organs_tp0", fresh: true)])
        XCTAssertTrue(s.clinical.present)
        XCTAssertEqual(s.clinical.events, 11)
    }

    func testVerifyAttributesAndDocument() throws {
        let report = try sample.verify()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.contentID.ok, true)
        XCTAssertEqual(report.contentID.stored, sample.summary.contentID)
        XCTAssertTrue(report.objects.allSatisfy(\.ok))
        let attributes = try sample.attributes(of: "images/CT_tp0")
        XCTAssertEqual(attributes["modality"], "CT")
        XCTAssertEqual(try sample.attributes(of: "/")["medh5_version"], "1.2")
        XCTAssertThrowsMedH5(try sample.attributes(of: "images/nope"), kind: "key")
        XCTAssertEqual(try sample.document()["identity"]?["subject_id"], "DEMO-SUBJ-01")
    }

    // MARK: Images

    func testImagesWholeRegionPhysicalAndConverted() throws {
        let raw = try sample.readImage("CT_tp0")
        XCTAssertEqual(raw.scalarType, .int16)
        XCTAssertEqual(raw.shape, [64, 64, 64])
        let physical = try sample.readImage("CT_tp0", physical: true)
        XCTAssertEqual(physical.scalarType, .float32)
        for i in stride(from: 0, to: raw.count, by: 997) {
            XCTAssertEqual(physical.value(at: i), raw.value(at: i) - 1024)
        }
        // Air at the corner, soft tissue at the centre.
        XCTAssertEqual(physical.value(at: 0), -1000, accuracy: 10)
        XCTAssertEqual(physical.value(at: physical.linearIndex([32, 32, 32])), 35, accuracy: 20)
        let region = ArrayRegion(start: [10, 20, 30], stop: [13, 30, 50])
        let part = try sample.readImage("CT_tp0", region: region, as: .float64)
        XCTAssertEqual(part.shape, [3, 10, 20])
        XCTAssertEqual(part.scalarType, .float64)
        for (z, y, x) in [(0, 0, 0), (2, 9, 19), (1, 5, 7)] {
            XCTAssertEqual(part.value(at: part.linearIndex([z, y, x])), raw.value(at: raw.linearIndex([10 + z, 20 + y, 30 + x])))
        }
        // A level that does not exist, an image that does not.
        XCTAssertThrowsMedH5(try sample.readImage("CT_tp0", level: 1))
        XCTAssertThrowsMedH5(try sample.readImage("XR"), kind: "key")
        XCTAssertThrowsMedH5(try sample.readImage("CT_tp0", region: ArrayRegion(start: [0, 0, 0], stop: [65, 1, 1])), status: .argument)
    }

    func testProgressReportsAndCancels() throws {
        let calls = LockedBox<[(UInt64, UInt64)]>([])
        _ = try sample.readImage("MR_tp0", progress: { done, total in
            calls.mutate { $0.append((done, total)) }
            return true
        })
        let reported = calls.value
        XCTAssertEqual(reported.first?.0, 0)
        XCTAssertEqual(reported.last?.0, reported.last?.1)
        XCTAssertThrowsMedH5(try sample.readImage("MR_tp0", progress: { _, _ in false }), kind: "cancelled", status: .cancelled)
        XCTAssertThrowsMedH5(try sample.readLayer("organs_tp1", layer: 0, progress: { _, _ in false }), status: .cancelled)
    }

    func testLoadImageIsReadyForTheGPU() async throws {
        let ct = try await sample.loadImage("CT_tp0")
        XCTAssertEqual(ct.data.scalarType, .int16)
        XCTAssertEqual(ct.geometry, sample.summary.grid("ct_tp0"))
        XCTAssertEqual(ct.rescaleIntercept, -1024)
        XCTAssertEqual(ct.windowPresets.count, 2)
        XCTAssertTrue(ct.allWindowPresets.count > 2)
        let mr = try await sample.loadImage("MR_tp0")
        XCTAssertEqual(mr.data.scalarType, .float32)
        XCTAssertEqual(mr.valueType, "intensity")
        let fractions = LockedBox<[Double]>([])
        let data = try await sample.loadImageData("CT_tp1", progress: { f in fractions.mutate { $0.append(f) } })
        XCTAssertEqual(data.shape, [64, 64, 64])
        XCTAssertEqual(fractions.value.last, 1)
        let layer = try await sample.loadLayer("organs_tp1", layer: 0)
        XCTAssertEqual(layer.scalarType, .uint16)
        let report = try await Validator.validateInBackground(url: Fixtures.demo, level: "semantic")
        XCTAssertTrue(report.ok)
    }

    func testCancellingTheTaskCancelsTheRead() async throws {
        let sample = self.sample!
        let task = Task { () -> ImageVolume in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sample.loadImage("CT_tp0")
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled task read the image")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAClosedSampleRefusesEveryCall() throws {
        let other = try SampleFile.open(Fixtures.demo)
        XCTAssertTrue(other.isOpen)
        other.close()
        other.close()
        XCTAssertFalse(other.isOpen)
        XCTAssertThrowsMedH5(try other.readImage("CT_tp0"), kind: "closed")
        XCTAssertThrowsMedH5(try other.verify(), kind: "closed")
        XCTAssertEqual(other.summary.identity.sampleID, "demo-abdomen-01", "the summary stays readable")
    }

    // MARK: Voxel annotations

    /// The voxels of a class from the layers: where some layer holds it.
    func voxels(_ layers: [VolumeData], _ classID: Int) -> Set<Int> {
        var out = Set<Int>()
        for layer in layers {
            let values = layer.buffer(as: UInt16.self)
            for i in 0..<layer.count where Int(values[i]) == classID { out.insert(i) }
        }
        return out
    }

    func testLayersOfEveryEncodingSayWhatTheAnnotationContains() throws {
        for id in ["organs_tp0", "organs_tp1", "lesion_prob_tp1", "lesions_tp0"] {
            let plan = try sample.layerPlan(id)
            let layers = try plan.layers.indices.map { try sample.readLayer(id, layer: $0) }
            let stats = try sample.classStats(id)
            for classID in plan.classIDs {
                let found = voxels(layers, classID)
                XCTAssertEqual(UInt64(found.count), stats[classID]?.voxels, "\(id): class \(classID)")
                // Each layer holds only its own classes.
                for (l, classes) in plan.layers.enumerated() where !classes.contains(classID) {
                    XCTAssertTrue(voxels([layers[l]], classID).isEmpty, "\(id): layer \(l) holds \(classID)")
                }
            }
        }
        // The lesion lies inside the liver: they overlap, in two layers.
        let plan = try sample.layerPlan("organs_tp0")
        XCTAssertEqual(plan.layers, [[2, 3, 5, 6, 7, 8], [9]])
        XCTAssertTrue(plan.ignoreInBand)
        let layers = try plan.layers.indices.map { try sample.readLayer("organs_tp0", layer: $0) }
        let lesion = voxels(layers, 9)
        XCTAssertFalse(lesion.isEmpty)
        XCTAssertTrue(lesion.isSubset(of: voxels(layers, 2)), "a liver lesion is in the liver")
        XCTAssertTrue(voxels(layers, 7).isEmpty, "the aorta was not examined")
        // The probmap's classes overlap too, and pack into two layers.
        let prob = try sample.layerPlan("lesion_prob_tp1")
        XCTAssertEqual(prob.overlaps, [[2, 9]])
        XCTAssertEqual(prob.threshold, 0.5)
        XCTAssertEqual(try sample.layerPlan("organs_tp1").layers, [[2, 3, 5, 6, 7, 8, 9]])
        XCTAssertTrue(try sample.layerPlan("mr_fov").layers.isEmpty)
        XCTAssertThrowsMedH5(try sample.layerPlan("lesion_boxes_tp0"))
    }

    func testRegionsOfALayerAreTheSliceOfTheWhole() throws {
        let whole = try sample.readLayer("organs_tp1", layer: 0)
        let region = ArrayRegion(origin: [30, 10, 5], size: [4, 30, 40])
        let part = try sample.readLayer("organs_tp1", layer: 0, region: region)
        XCTAssertEqual(part.shape, [4, 30, 40])
        for z in 0..<4 {
            for y in stride(from: 0, to: 30, by: 7) {
                for x in stride(from: 0, to: 40, by: 3) {
                    XCTAssertEqual(part.value(at: part.linearIndex([z, y, x])), whole.value(at: whole.linearIndex([30 + z, 10 + y, 5 + x])))
                }
            }
        }
        XCTAssertThrowsMedH5(try sample.readLayer("organs_tp1", layer: 3), status: .argument)
        // The editor's and the renderer's padded boxes convert: a 3-D grid
        // keeps all three axes, a 2-D one drops the padding axis 0.
        let box = VoxelBox(origin: SIMD3(30, 10, 5), size: SIMD3(4, 30, 40))
        let grid = try XCTUnwrap(sample.summary.annotation("organs_tp1")?.grid.flatMap { sample.summary.grid($0) })
        XCTAssertEqual(grid.paddedShape, SIMD3(whole.shape[0], whole.shape[1], whole.shape[2]))
        let rank = grid.spatialRank
        XCTAssertEqual(ArrayRegion(box, spatialRank: rank), region)
        XCTAssertEqual(ArrayRegion(box), region)
        XCTAssertEqual(ArrayRegion(VoxelBox(origin: SIMD3(0, 10, 5), size: SIMD3(1, 30, 40)), spatialRank: 2),
                       ArrayRegion(start: [10, 5], stop: [40, 45]))
    }

    func testIgnoreRegionMasksProbabilitiesAndInstances() throws {
        let layers = try (0..<2).map { try sample.readLayer("organs_tp0", layer: $0) }
        let ignored = voxels(layers, 65535)
        XCTAssertFalse(ignored.isEmpty)
        let region = try sample.readMask("organs_tp0", ignoreRegion: true)
        XCTAssertEqual(Set((0..<region.count).filter { region.value(at: $0) == 1 }), ignored)

        let fov = try sample.readMask("mr_fov")
        XCTAssertEqual(fov.shape, [32, 56, 56])
        XCTAssertTrue(fov.doubles.contains(1) && fov.doubles.contains(0))

        let p = try sample.readProbability("lesion_prob_tp1", classID: 9)
        let layer = try sample.readLayer("lesion_prob_tp1", layer: try XCTUnwrap(try sample.layerPlan("lesion_prob_tp1").layer(of: 9)))
        for i in stride(from: 0, to: p.count, by: 13) {
            XCTAssertEqual(p.value(at: i) >= 0.5, layer.value(at: i) == 9, "voxel \(i)")
        }
        XCTAssertThrowsMedH5(try sample.readProbability("lesion_prob_tp1", classID: 3))

        let objects = try sample.instances("lesions_tp0")
        XCTAssertEqual(objects.map(\.instanceID), [1, 2])
        XCTAssertTrue(objects.allSatisfy { $0.classID == 9 && $0.hasMask && $0.bbox.count == 3 })
        let map = try sample.readInstanceMap("lesions_tp0")
        for object in objects {
            let painted = (0..<map.count).filter { Int(map.value(at: $0)) == object.index + 1 }.count
            XCTAssertEqual(UInt64(painted), object.voxelCount)
            // Its box (at voxel edges) holds every voxel it paints.
            let boxes = object.bbox.map(\.voxels)
            for i in (0..<map.count) where Int(map.value(at: i)) == object.index + 1 {
                let z = i / 4096, y = (i / 64) % 64, x = i % 64
                XCTAssertTrue(boxes[0].contains(z) && boxes[1].contains(y) && boxes[2].contains(x))
            }
        }
        let stats = try sample.classStats("organs_tp0")
        XCTAssertEqual(stats[7]?.voxels, 0)
        XCTAssertNil(stats[7]?.bbox)
    }

    func testLoadSegmentationGathersLayersPlanAndClasses() async throws {
        let seg = try await sample.loadSegmentation("organs_tp0")
        XCTAssertEqual(seg.layers.count, 2)
        XCTAssertEqual(seg.geometry, sample.summary.grid("ct_tp0")?.spatialOnly)
        XCTAssertEqual(seg.classes.map(\.key), ["liver", "spleen", "left_kidney", "right_kidney", "aorta", "vertebral_column", "liver_lesion"])
        XCTAssertEqual(seg.classIDs, [2, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(seg.annotatedClassIDs, [2, 3, 5, 6, 8, 9])
        XCTAssertNil(seg.ignoreRegion, "the ignore region is in the layers")
        XCTAssertEqual(seg.layers[0].shape, [64, 64, 64])
    }

    // MARK: Geometric annotations

    func testGeometryOfEveryKindAgreesWithTheGrid() throws {
        let grid = try XCTUnwrap(sample.summary.grid("ct_tp0"))
        guard case .boxes(let boxes) = try sample.geometry("lesion_boxes_tp0") else { return XCTFail("boxes") }
        XCTAssertEqual(boxes.header.space, "index")
        XCTAssertEqual(boxes.classIDs, [9, 9, 3])
        XCTAssertEqual(boxes.instanceIDs, [1, 2, 3])
        XCTAssertEqual(boxes.header.attributes?[0]["segment"], "VIII")
        for (box, corners) in zip(boxes.boxes, boxes.worldCorners) {
            XCTAssertEqual(corners.count, 8)
            XCTAssertTrue(near(corners[0], grid.world(fromIndex: SIMD3(box[0].lo, box[1].lo, box[2].lo))))
            XCTAssertTrue(near(corners[7], grid.world(fromIndex: SIMD3(box[0].hi, box[1].hi, box[2].hi))))
        }
        // The lesion's box covers exactly the voxels of instance 1.
        let lesion = try XCTUnwrap(try sample.instances("lesions_tp0").first)
        XCTAssertEqual(boxes.boxes[0], lesion.bbox)

        guard case .orientedBoxes(let obb) = try sample.geometry("kidney_obb_tp0") else { return XCTFail("obb") }
        XCTAssertEqual(obb.classIDs, [6, 5])
        XCTAssertEqual(obb.corners.first?.count, 8)
        XCTAssertTrue(zip(obb.corners.flatMap { $0 }, obb.worldCorners.flatMap { $0 }).allSatisfy { near($0, $1) })

        guard case .keypoints(let kp) = try sample.geometry("landmarks_tp0") else { return XCTFail("keypoints") }
        XCTAssertEqual(kp.keypointClassIDs, [2, 3, 7, 8])
        XCTAssertEqual(kp.visibility, [[2, 2, 2, 1]])
        XCTAssertEqual(kp.skeleton, "abdominal-landmarks")
        for (k, w) in zip(kp.points[0], kp.worldPoints[0]) {
            XCTAssertTrue(near(grid.world(fromIndex: k), w))
            XCTAssertTrue(near(grid.index(fromWorld: w), k))
        }
        XCTAssertTrue(near(kp.worldPoints[0][0], SIMD3(-60, 0, 125)), "the liver dome")

        guard case .points(let fiducials) = try sample.geometry("fiducials_tp0") else { return XCTFail("points") }
        XCTAssertEqual(fiducials.names?[2], "lesion_centre")
        XCTAssertEqual(fiducials.correspondence, "fiducials_tp1")
        XCTAssertTrue(near(fiducials.worldPoints[2], Demo.lesionCentre, 1e-6))
        XCTAssertEqual(fiducials.weights, [1, 1, 2, 1, 1])

        guard case .contours(let contours) = try sample.geometry("liver_contours_tp0") else { return XCTFail("contours") }
        XCTAssertEqual(contours.polygons.filter(\.isHole).count, 1)
        for polygon in contours.polygons {
            XCTAssertEqual(polygon.plane.axis, 0)
            for (v, w) in zip(polygon.vertices, polygon.worldVertices) {
                XCTAssertEqual(v.x, Double(polygon.plane.index), accuracy: 1e-4, "a polygon lies in its plane")
                XCTAssertTrue(near(grid.world(fromIndex: v), w, 1e-5))
            }
        }

        guard case .polylines(let curves) = try sample.geometry("centrelines_tp0") else { return XCTFail("polylines") }
        XCTAssertEqual(curves.polylines.map(\.classID), [7, 12])
        XCTAssertEqual(curves.polylines.map(\.instanceID), [21, 22])
        XCTAssertTrue(near(try XCTUnwrap(curves.polylines[1].worldVertices.last), Demo.lesionCentre, 1e-5), "the needle reaches the lesion")
        for line in curves.polylines {
            for (v, w) in zip(line.vertices, line.worldVertices) { XCTAssertTrue(near(grid.world(fromIndex: v), w, 1e-5)) }
        }

        guard case .mesh(let mesh) = try sample.geometry("surfaces_tp0") else { return XCTFail("mesh") }
        XCTAssertEqual(mesh.submeshes.map(\.classID), [9, 2])
        XCTAssertEqual(mesh.submeshes[0].faces, 0..<320)
        XCTAssertEqual(mesh.faces.count, 640)
        let sphere = mesh.submeshes[0].faces.flatMap { f in [mesh.faces[f].x, mesh.faces[f].y, mesh.faces[f].z] }
        for v in Set(sphere) {
            XCTAssertEqual(simd_distance(mesh.worldVertices[Int(v)], Demo.lesionCentre), Demo.lesionRadius.baseline, accuracy: 1e-3)
        }
        XCTAssertEqual(mesh.worldNormals?.count, mesh.vertices.count)

        guard case .classification(let response) = try sample.geometry("response") else { return XCTFail("classification") }
        XCTAssertEqual(response.scope, "sample")
        XCTAssertTrue(response.isChangeLabel)
        XCTAssertEqual(response.comparedTimepoints, ["tp0", "tp1"])
        XCTAssertEqual(response.positives, ["progressive_disease"])
        XCTAssertEqual(response.labels["stable_disease"], 0)

        XCTAssertThrowsMedH5(try sample.geometry("organs_tp0"), kind: "type")
    }

    // MARK: Transforms

    func testTheStoredAffineIsTheMotionTheDemoApplied() throws {
        let stored = try sample.transform("tp0_to_tp1")
        XCTAssertEqual(stored.info.kind, "affine")
        let matrix = try XCTUnwrap(stored.matrix)
        let motion = Demo.motion
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(matrix[c][r], motion[c][r], accuracy: 1e-12) } }

        // Baseline points land on the follow-up's: the fiducials as written.
        let resolved = try XCTUnwrap(try sample.resolveTransform(from: "tp0", to: "tp1"))
        XCTAssertFalse(resolved.isIdentity)
        XCTAssertEqual(resolved.path, ["tp0_to_tp1"])
        let forward = try XCTUnwrap(resolved.matrix)
        guard case .points(let p0) = try sample.geometry("fiducials_tp0"),
              case .points(let p1) = try sample.geometry("fiducials_tp1") else { return XCTFail("fiducials") }
        for (a, b) in zip(p0.worldPoints, p1.worldPoints) {
            XCTAssertTrue(near(forward.transformPoint(a), b, 1e-5), "\(a) -> \(b)")
        }
        // By grid and by frame, the same; the other way, the inverse.
        let byGrid = try XCTUnwrap(try sample.resolveTransform(from: "ct_tp0", to: "ct_tp1")?.matrix)
        XCTAssertTrue(near(byGrid.transformPoint(Demo.lesionCentre), forward.transformPoint(Demo.lesionCentre)))
        let back = try XCTUnwrap(try sample.resolveTransform(from: "demo:frame-tp1", to: "demo:frame-tp0"))
        XCTAssertEqual(back.inverted, [true])
        XCTAssertTrue(near(try XCTUnwrap(back.matrix).transformPoint(forward.transformPoint(Demo.lesionCentre)), Demo.lesionCentre))
        // The MR shares the baseline frame: the identity.
        let same = try XCTUnwrap(try sample.resolveTransform(from: "ct_tp0", to: "mr_tp0"))
        XCTAssertTrue(same.isIdentity)
        XCTAssertEqual(same.matrix, matrix_identity_double4x4)
        XCTAssertThrowsMedH5(try sample.resolveTransform(from: "tp7", to: "tp0"), kind: "key")
    }

    // MARK: Clinical history

    func testClinicalRecordsTextAndWhatWasKnownAtACutoff() throws {
        let records = try XCTUnwrap(try sample.clinicalRecords())
        XCTAssertFalse(records.projection)
        XCTAssertEqual(records.clock.reference, "relative")
        XCTAssertEqual(records.events.count, 11)
        XCTAssertEqual(records.documents.count, 3)
        XCTAssertEqual(records.versions(of: "report0").map(\.status), ["preliminary", "amended"])
        let lab = try XCTUnwrap(records.event("afp1"))
        XCTAssertEqual(lab.valueNum, 480)
        XCTAssertEqual(lab.unit, "ng/mL")
        XCTAssertEqual(lab.effectiveStart?.hours.lowerBound, 60 * 24)
        XCTAssertTrue(records.links(involving: "image", "CT_tp1").contains { $0.sourceID == "ct1" })
        let grounding = try XCTUnwrap(records.links.first { $0.sourceSpan != nil })
        let text = try sample.clinicalDocumentText("report1_text")
        XCTAssertTrue(text.contains("54 mm"))
        let span = grounding.sourceSpan!
        let bytes = Array(text.utf8)[Int(span[0])..<Int(span[1])]
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "54 mm")
        XCTAssertEqual(UInt64(text.utf8.count), records.documents.first { $0.documentID == "report1_text" }?.bytes)
        XCTAssertThrowsMedH5(try sample.clinicalDocumentText("nope"))

        let known = try sample.clinicalSelect(cutoffHours: 36)
        XCTAssertTrue(known.eventIDs.contains("report0_v2"))
        XCTAssertFalse(known.eventIDs.contains("report0_v1"), "superseded")
        XCTAssertFalse(known.eventIDs.contains("ct1"))
        XCTAssertTrue(known.documents.contains("report0_text_v2"))
        let later = try sample.clinicalSelect(cutoffMicroseconds: 100 * 24 * 3_600_000_000)
        XCTAssertTrue(later.eventIDs.contains("response1"))
    }
}

/// A value shared with a `@Sendable` closure.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
