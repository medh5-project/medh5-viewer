import XCTest
import simd
@testable import MedH5Kit

/// Writing: a new sample, the viewer's save (an amendment), document edits.
final class WritingTests: XCTestCase {
    static let labels: JSONValue = [
        "id": "kit-tests", "version": "1.0.0",
        "classes": [
            ["id": 1, "key": "organ", "name": "Organ", "color": [200, 100, 50, 255], "codes": [["system": "SCT", "code": "1"]]],
            ["id": 2, "key": "lesion", "name": "Lesion", "parents": [1], "codes": [["system": "SCT", "code": "2"]]],
            ["id": 3, "key": "vessel", "name": "Vessel", "codes": [["system": "SCT", "code": "3"]]],
        ],
    ]

    func grid(_ id: String, frame: String, timepoint: String) -> GridGeometry {
        GridGeometry(id: id, shape: [6, 8, 10], spacing: [3, 1.5, 1], origin: [10, -4, 2],
                     direction: [[0, 0, 1], [0, 1, 0], [1, 0, 0]], timepoint: timepoint, frameUID: frame)
    }

    func testASampleWrittenFromScratchReadsBack() throws {
        let dir = TemporaryDirectory("create")
        let url = dir.file("case.medh5")
        let n = 6 * 8 * 10
        let ct = VolumeData(shape: [6, 8, 10], values: (0..<n).map { Int16($0 % 97 + 1000) })
        let organ = VolumeData(scalarType: .uint16, shape: [6, 8, 10])
        let lesion = VolumeData(scalarType: .uint16, shape: [6, 8, 10])
        for z in 1..<5 { for y in 2..<7 { for x in 2..<9 { organ.setValue(1, at: organ.linearIndex([z, y, x])) } } }
        for z in 2..<4 { for y in 3..<5 { for x in 4..<6 { lesion.setValue(2, at: lesion.linearIndex([z, y, x])) } } }

        let writer = try SampleWriter.create(url: url, options: WriterOptions(sampleID: "case_0001", subjectID: "SUBJ-1", codec: "portable"))
        try writer.addTimepoint("tp0", fields: ["label": "baseline", "days_from_baseline": 0])
        try writer.addTimepoint("tp1", fields: ["days_from_baseline": 30])
        try writer.setIdentity(["sex": "M"])
        try writer.setCohort(["dataset_id": "kit-tests"])
        try writer.setLabelSet(Self.labels)
        let agent = try writer.addAgent(["type": "person", "name": "pseudonym:A", "id": "a1", "role": "annotator"])
        XCTAssertEqual(agent["id"], "a1")
        let activity = try writer.addActivity(["type": "annotate", "agent": "a1", "tool": "medh5-viewer"])
        let activityID = try XCTUnwrap(activity["id"]?.stringValue)
        try writer.setQuality("seg", fields: ["status": "reviewed", "confidence": 0.9])
        try writer.setExtra("org.example", ["count": 1, "ratio": 1.0])
        try writer.setDeidentification(["method": "synthetic"])
        try writer.addGrid(grid("g0", frame: "f0", timepoint: "tp0"))
        try writer.addGrid(grid("g1", frame: "f1", timepoint: "tp1"))
        let ctOptions = ImageWriteOptions(modality: "CT", valueType: "quantitative", valueUnits: "HU", rescaleIntercept: -1024,
                                          windowCenter: [40], windowWidth: [400], acquisition: ["KVP": 120])
        try writer.addImage(id: "CT0", grid: "g0", data: ct, options: ctOptions)
        try writer.addImage(id: "CT1", grid: "g1", data: ct, options: ctOptions)
        try writer.setImageAttributes("CT1", ["window_center": [50.0], "window_width": [350.0]])
        let chose = try writer.addSegmentation(
            id: "seg", grid: "g0", layers: [organ, lesion],
            options: SegmentationWriteOptions(classIDs: [1, 2, 3], common: AnnotationWriteOptions(
                annotatedClasses: .classes([1, 2, 3]), prov: activityID, quality: .key("seg"))))
        XCTAssertNotEqual(chose.kind, "labelmap", "an overlap is no labelmap")
        try writer.addMask(id: "roi", grid: "g0", mask: organ)
        let index = GeometricWriteOptions(grid: "g0", space: "index")
        try writer.addBoxes(id: "box", boxes: [[AxisInterval(1.5, 3.5), AxisInterval(2.5, 4.5), AxisInterval(3.5, 5.5)]],
                            classIDs: [2], instanceIDs: [7], scores: [0.9],
                            options: GeometricWriteOptions(grid: "g0", space: "index", attributes: [["confirmed": true]]))
        try writer.addPoints(id: "marks", points: [[12, 1, 5], [14, 2, 6]],
                             options: GeometricWriteOptions(grid: "g0", space: "world", extra: ["names": ["a", "b"]]))
        try writer.addPolylines(id: "track", polylines: [PolylineInput(vertices: [[1, 1, 1], [2, 3, 4], [3, 5, 7]], classID: 3)],
                                options: index)
        try writer.addContours(id: "outline", polygons: [
            PolygonInput(vertices: [[2, 2, 2], [2, 2, 8], [2, 6, 8], [2, 6, 2]], classID: 1, plane: (0, 2)),
            PolygonInput(vertices: [[2, 3, 4], [2, 3, 6], [2, 5, 6], [2, 5, 4]], classID: 1, plane: (0, 2), isHole: true),
        ], options: index)
        try writer.addMesh(id: "surface", vertices: [SIMD3(10, 0, 0), SIMD3(11, 0, 0), SIMD3(10, 1, 0), SIMD3(10, 0, 1)],
                           faces: [SIMD3(0, 1, 2), SIMD3(0, 1, 3), SIMD3(0, 2, 3), SIMD3(1, 2, 3)],
                           submeshes: [(0..<4, 2)], options: GeometricWriteOptions(grid: "g0", space: "world"))
        try writer.addClassification(id: "finding", assertions: [ClassificationAssertion(classID: 2, value: 1),
                                                                 ClassificationAssertion(classID: 3, value: 0)])
        var shift = matrix_identity_double4x4
        shift.columns.3 = SIMD4(5, -3, 2, 1)
        try writer.addAffineTransform(id: "t01", matrix: shift, fromFrame: "f0", toFrame: "f1")
        try writer.buildIndex(annotations: ["seg"])
        // Refusals leave the writer usable.
        XCTAssertThrowsMedH5(try writer.addImage(id: "X", grid: "nogrid", data: ct), code: "E101")
        XCTAssertThrowsMedH5(try writer.addSegmentation(id: "bad", grid: "g0", layers: [ct]), status: .argument)
        let contentID = try XCTUnwrap(try writer.commit())

        XCTAssertTrue(try Validator.validate(url: url, level: "strict").ok)
        let sample = try SampleFile.open(url)
        defer { sample.close() }
        let s = sample.summary
        XCTAssertEqual(s.contentID, contentID)
        XCTAssertEqual(s.identity.sex, "M")
        XCTAssertEqual(s.extra["org.example"]?["ratio"], .double(1))
        XCTAssertEqual(s.extra["org.example"]?["count"], .int(1))
        XCTAssertEqual(s.acquisition["CT0"]?["KVP"], .int(120))
        XCTAssertEqual(s.grid("g0"), grid("g0", frame: "f0", timepoint: "tp0"))
        XCTAssertEqual(s.image("CT1")?.windowCenter, [50])
        let read = try sample.readImage("CT0")
        XCTAssertEqual(read.doubles, ct.doubles)
        let seg = try XCTUnwrap(s.annotation("seg"))
        XCTAssertEqual(seg.classIDs, [1, 2, 3])
        XCTAssertEqual(seg.annotatedClassIDs, [1, 2, 3])
        XCTAssertEqual(seg.quality, "seg")
        let plan = try sample.layerPlan("seg")
        let layers = try plan.layers.indices.map { try sample.readLayer("seg", layer: $0) }
        for classID in [1, 2] {
            let source = classID == 1 ? organ : lesion
            for i in 0..<n {
                let want = Int(source.value(at: i)) == classID
                let got = layers.contains { Int($0.value(at: i)) == classID }
                XCTAssertEqual(got, want, "class \(classID) voxel \(i)")
            }
        }
        guard case .contours(let contours) = try sample.geometry("outline") else { return XCTFail("contours") }
        XCTAssertEqual(contours.polygons.map(\.isHole), [false, true])
        guard case .boxes(let boxes) = try sample.geometry("box") else { return XCTFail("boxes") }
        XCTAssertEqual(boxes.instanceIDs, [7])
        XCTAssertEqual(boxes.boxes[0][1].voxels, 3..<5)
        let resolved = try XCTUnwrap(try sample.resolveTransform(from: "tp0", to: "tp1")?.matrix)
        XCTAssertTrue(near(resolved.transformPoint(SIMD3(1, 1, 1)), SIMD3(6, -2, 3)))
        XCTAssertEqual(s.formatVersion, "1.2", "polylines need 1.2")
    }

    /// The viewer's save: amend the file, dropping the segmentation being
    /// replaced, and write the edited layers back with the coverage they had.
    func testAmendingAnEditedSegmentationPreservesCoverageAndEverythingElse() async throws {
        let dir = TemporaryDirectory("amend")
        let url = Fixtures.demoCopy(in: dir)
        let before = try SampleFile.open(url)
        let info = try XCTUnwrap(before.summary.annotation("organs_tp0"))
        let segmentation = try await before.loadSegmentation("organs_tp0")
        let summaryBefore = before.summary
        before.close()

        // Paint a lesion voxel; erase the spleen (examined: still annotated).
        let painted = segmentation.layers[1].linearIndex([40, 30, 30])
        segmentation.layers[1].setValue(9, at: painted)
        let organs = segmentation.layers[0]
        for i in 0..<organs.count where organs.value(at: i) == 3 { organs.setValue(0, at: i) }

        let writer = try SampleWriter.amend(url: url, without: ["annotations/organs_tp0"])
        let chose = try writer.addSegmentation(id: "organs_tp0", grid: "ct_tp0", layers: segmentation.layers,
                                               options: .preserving(info))
        XCTAssertEqual(chose.kind, "layers")
        let newID = try writer.commit(digests: false)

        let after = try SampleFile.open(url)
        defer { after.close() }
        let s = after.summary
        XCTAssertEqual(s.contentID, newID)
        XCTAssertNotEqual(s.contentID, summaryBefore.contentID)
        let edited = try XCTUnwrap(s.annotation("organs_tp0"))
        XCTAssertEqual(edited.classIDs, info.classIDs, "what it can express")
        XCTAssertEqual(edited.annotatedClassIDs, info.annotatedClassIDs, "what was looked for")
        XCTAssertEqual(edited.kind, info.kind)
        XCTAssertEqual(edited.closure, info.closure)
        XCTAssertEqual(edited.ignoreID, info.ignoreID)
        XCTAssertEqual(edited.prov, info.prov)
        XCTAssertEqual(edited.quality, info.quality)
        XCTAssertEqual(edited.timepoints, info.timepoints)
        XCTAssertTrue(try after.layerPlan("organs_tp0").ignoreInBand, "the ignore region stays in band")
        let stats = try after.classStats("organs_tp0")
        XCTAssertEqual(stats[3]?.voxels, 0, "the spleen: examined, now absent")
        let reread = try (0..<2).map { try after.readLayer("organs_tp0", layer: $0) }
        XCTAssertEqual(reread[1].value(at: painted), 9)
        XCTAssertEqual(reread[0].doubles, organs.doubles)

        // Untouched objects are identical: the same digests.
        for image in summaryBefore.images {
            XCTAssertEqual(s.image(image.id)?.digest, image.digest, image.id)
        }
        for annotation in summaryBefore.annotations where annotation.id != "organs_tp0" {
            XCTAssertEqual(s.annotation(annotation.id)?.digest, annotation.digest, annotation.id)
        }
        XCTAssertEqual(s.grids, summaryBefore.grids)
        XCTAssertEqual(s.transforms, summaryBefore.transforms)
        XCTAssertEqual(s.labelSet, summaryBefore.labelSet)
        XCTAssertEqual(s.timepoints, summaryBefore.timepoints)
        XCTAssertEqual(s.clinical, summaryBefore.clinical)
        XCTAssertTrue(try after.verify().ok)
        XCTAssertTrue(try Validator.validate(url: url, level: "strict").ok)
    }

    func testWithoutRemovalsAndAdditionsInOneAmendment() throws {
        let dir = TemporaryDirectory("without")
        let url = Fixtures.demoCopy(in: dir)
        let out = dir.file("edited.medh5")
        let writer = try SampleWriter.amend(url: url, outURL: out, without: ["annotations/response", "clinical"])
        // The change label, written again with another answer.
        try writer.addClassification(id: "response", assertions: [ClassificationAssertion(classID: 10, value: 0),
                                                                  ClassificationAssertion(classID: 11, value: 1)],
                                     options: AnnotationWriteOptions(annotatedClasses: .classes([10, 11]),
                                                                     timepoints: ["tp0", "tp1"]))
        try writer.removeAnnotation("mr_fov")
        try writer.setImageAttributes("MR_tp0", ["valid_mask": .null])
        try writer.addPoints(id: "extra_points", points: [[0, 0, 0]], classIDs: [2],
                             options: GeometricWriteOptions(grid: "ct_tp0", space: "world"))
        try writer.commit()
        XCTAssertEqual(try SampleFile.open(url).summary.contentID, try Fixtures.demoContentID(), "the source is left alone")
        let sample = try SampleFile.open(out)
        defer { sample.close() }
        XCTAssertFalse(sample.summary.clinical.present)
        XCTAssertNil(sample.summary.annotation("mr_fov"))
        XCTAssertNotNil(sample.summary.annotation("extra_points"))
        guard case .classification(let response) = try sample.geometry("response") else { return XCTFail("response") }
        XCTAssertEqual(response.positives, ["stable_disease"])
        XCTAssertTrue(try Validator.validate(url: out, level: "integrity").ok)
    }

    func testDocumentEditsKeepIntegersFloatsAndOrder() throws {
        let dir = TemporaryDirectory("document")
        let url = Fixtures.demoCopy(in: dir)
        let writer = try SampleWriter.amend(url: url)
        var document = try writer.document()
        XCTAssertEqual(document["acquisition"]?["CT_tp0"]?["KVP"], .int(120))
        document["extra"] = ["org.viewer": ["opened": 2, "zoom": 1.5]]
        try writer.setDocument(document)
        try writer.commit()
        let sample = try SampleFile.open(url)
        defer { sample.close() }
        let stored = try sample.documentText()
        XCTAssertEqual(try JSONValue.parse(stored).serialized(.meta), stored)
        let parsed = try JSONValue.parse(stored)
        XCTAssertEqual(parsed["extra"]?["org.viewer"]?["opened"], .int(2))
        XCTAssertEqual(parsed["extra"]?["org.viewer"]?["zoom"], .double(1.5))
        XCTAssertEqual(parsed["acquisition"]?["CT_tp0"]?["KVP"], .int(120))
        XCTAssertEqual(parsed.objectValue?.keys.first, "identity")
    }

    func testANonLinearTransformResolvesToASampledField() throws {
        let dir = TemporaryDirectory("field")
        let url = dir.file("field.medh5")
        let writer = try SampleWriter.create(url: url, options: WriterOptions(sampleID: "field"))
        try writer.addGrid(grid("ga", frame: "fa", timepoint: "tp0"))
        try writer.addGrid(grid("gb", frame: "fb", timepoint: "tp0"))
        try writer.addImage(id: "A", grid: "ga", data: VolumeData(scalarType: .int16, shape: [6, 8, 10]))
        // A constant displacement of (1, 2, 3) mm from fa to fb.
        let n = 6 * 8 * 10
        let field = VolumeData(shape: [3, 6, 8, 10], values: (0..<3 * n).map { Float($0 / n + 1) })
        try writer.addTransform(id: "warp", kind: "displacement",
                                options: ["from_frame": "fa", "to_frame": "fb", "field_grid": "ga", "vector_space": "world"],
                                arrays: [NamedArray("field", field)])
        try writer.commit()
        let sample = try SampleFile.open(url)
        defer { sample.close() }
        let stored = try sample.transform("warp")
        XCTAssertEqual(stored.field?.shape, [3, 6, 8, 10])
        XCTAssertEqual(stored.info.fieldGrid, "ga")
        let unsampled = try XCTUnwrap(try sample.resolveTransform(from: "fa", to: "fb"))
        guard case .unsampled = unsampled.mapping else { return XCTFail("a field needs a grid to be sampled on") }
        let resolved = try XCTUnwrap(try sample.resolveTransform(from: "ga", to: "gb", fieldGrid: "ga", step: 2))
        guard case .field(let displacement, let lattice) = resolved.mapping else { return XCTFail("a field") }
        XCTAssertEqual(displacement.shape, [3, 4, 5, 3])
        XCTAssertEqual(lattice.spacing, [6, 3, 2])
        XCTAssertEqual(lattice.shape, [3, 4, 5])
        XCTAssertTrue(lattice.sharesFrame(with: grid("ga", frame: "fa", timepoint: "tp0")))
        for v in stride(from: 0, to: displacement.count, by: 3) {
            XCTAssertEqual(displacement.value(at: v), 1, accuracy: 1e-5)
            XCTAssertEqual(displacement.value(at: v + 1), 2, accuracy: 1e-5)
            XCTAssertEqual(displacement.value(at: v + 2), 3, accuracy: 1e-5)
        }
        XCTAssertThrowsMedH5(try sample.resolveTransform(from: "fa", to: "fb", fieldGrid: "gb"), code: "E414")
    }

    func testRefusedCommitsAndAbortedWriters() throws {
        let dir = TemporaryDirectory("refuse")
        let url = dir.file("empty.medh5")
        let writer = try SampleWriter.create(url: url)
        XCTAssertThrowsMedH5(try writer.commit(), code: "E201")
        writer.abort()
        XCTAssertThrowsMedH5(try writer.commit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsMedH5(try SampleWriter.amend(url: dir.file("none.medh5")))
    }
}

extension Fixtures {
    static func demoContentID() throws -> String? {
        let sample = try SampleFile.open(demo)
        defer { sample.close() }
        return sample.summary.contentID
    }
}

/// Validation, conversion, collections and the conformance corpus.
final class ToolTests: XCTestCase {
    func testTheDemoValidatesAtEveryLevelAndACorruptedCopyDoesNot() throws {
        for level in try MedH5.validationLevels() {
            let report = try Validator.validate(url: Fixtures.demo, level: level)
            XCTAssertTrue(report.ok, "\(level): \(report.codes)")
            XCTAssertEqual(report.level, level)
        }
        let dir = TemporaryDirectory("corrupt")
        let url = Fixtures.demoCopy(in: dir)
        var bytes = try Data(contentsOf: url)
        // Overwrite stored bytes in many places: chunks fail to decode or no
        // longer match their digests.
        for fraction in stride(from: 0.3, to: 0.95, by: 0.05) {
            let at = Int(Double(bytes.count) * fraction)
            for i in at..<min(bytes.count, at + 64) { bytes[i] ^= 0x5A }
        }
        try bytes.write(to: url)
        let report = try Validator.validate(url: url, level: "integrity")
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.diagnostics.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.isError && !$0.summary.isEmpty })
        // Reading it never crashes: an answer, or an error.
        if let sample = try? SampleFile.open(url) {
            _ = try? sample.verify()
            _ = try? sample.readImage("CT_tp0")
            sample.close()
        }
        let junk = dir.file("junk.medh5")
        try Data("not hdf5".utf8).write(to: junk)
        XCTAssertEqual(try Validator.validate(url: junk, level: "structural").codes, ["E001"])
        XCTAssertThrowsMedH5(try SampleFile.open(junk))
    }

    func testNIfTIExportImportRoundTrip() throws {
        let dir = TemporaryDirectory("nifti")
        let sample = try SampleFile.open(Fixtures.demo)
        defer { sample.close() }
        let grid = try XCTUnwrap(sample.summary.grid("ct_tp0"))
        let raw = try sample.readImage("CT_tp0")
        let ct = dir.file("ct.nii.gz")
        let report = try NIfTI.export(sample: Fixtures.demo, object: "images/CT_tp0", to: ct)
        XCTAssertTrue(report.path?.hasSuffix("ct.nii.gz") ?? false)

        let volume = try NIfTI.read(ct)
        XCTAssertEqual(volume.data.shape, [64, 64, 64])
        for i in stride(from: 0, to: raw.count, by: 101) {
            XCTAssertEqual(volume.data.value(at: i), raw.value(at: i) - 1024, accuracy: 1e-3)
        }
        XCTAssertEqual(volume.geometry.spatialShape, grid.spatialShape)
        XCTAssertTrue(volume.geometry.isCongruent(with: grid), "the affine survives the round trip")
        let affine = try XCTUnwrap(simd_double4x4(rowMajorHomogeneous: volume.affine))
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(affine[c][r], grid.indexToWorld[c][r], accuracy: 1e-4) } }

        let imported = dir.file("imported.medh5")
        try NIfTI.importSample(images: [("CT", ct)], to: imported, options: ["modality": "CT", "sample_id": "imported"])
        let back = try SampleFile.open(imported)
        let values = try back.readImage("CT", physical: true)
        for i in stride(from: 0, to: raw.count, by: 101) {
            XCTAssertEqual(values.value(at: i), raw.value(at: i) - 1024, accuracy: 1e-3)
        }
        XCTAssertTrue(try XCTUnwrap(back.summary.grid(back.summary.images[0].grid)).isCongruent(with: grid))
        back.close()

        // One class of the follow-up organs, as a mask, into the imported sample.
        let liver = dir.file("liver.nii.gz")
        try NIfTI.export(sample: Fixtures.demo, object: "annotations/organs_tp1", to: liver, classID: 2)
        try NIfTI.importSegmentation(into: imported, annotationID: "liver", masks: [("liver", liver)],
                                     options: ["assume_aligned": true])
        let withLiver = try SampleFile.open(imported)
        defer { withLiver.close() }
        let layer = try withLiver.readLayer("liver", layer: 0)
        let organs = try sample.readLayer("organs_tp1", layer: 0)
        let liverClass = try XCTUnwrap(withLiver.summary.annotation("liver")?.classIDs.first)
        for i in 0..<layer.count where (Int(layer.value(at: i)) == liverClass) != (organs.value(at: i) == 2) {
            return XCTFail("voxel \(i) differs")
        }
    }

    func testRecompressionKeepsEveryDigest() throws {
        let dir = TemporaryDirectory("recompress")
        let out = dir.file("portable.medh5")
        let result = try Storage.recompress(Fixtures.demo, profile: "portable", out: out)
        XCTAssertEqual(result["ok"], true)
        XCTAssertEqual(result["content_id_preserved"], true)
        XCTAssertEqual(try SampleFile.open(out).summary.contentID, try Fixtures.demoContentID())
    }

    func testCollectionsPackListAndOpenAMember() throws {
        let dir = TemporaryDirectory("collection")
        let small = dir.file("small.medh5")
        try Demo.write(to: small, options: DemoOptions(size: 16, clinical: false))
        let shard = dir.file("shard.medh5c")
        XCTAssertEqual(try Collections.pack([Fixtures.demo, small], keys: ["full", "small"], to: shard), ["full", "small"])
        let members = try Collections.list(shard)
        XCTAssertEqual(members.map(\.name), ["full", "small"])
        XCTAssertEqual(members[0].subjectID, "DEMO-SUBJ-01")
        let member = try SampleFile.open(collection: shard, member: "small")
        defer { member.close() }
        XCTAssertEqual(member.member, "small")
        XCTAssertEqual(member.summary.grid("ct_tp0")?.shape, [16, 16, 16])
        XCTAssertTrue(try member.readLayer("organs_tp1", layer: 0).doubles.contains(2))
        XCTAssertThrowsMedH5(try SampleFile.open(collection: shard, member: "missing"), kind: "key")
    }

    func testTheDemoIsDeterministicAndConfigurable() throws {
        let dir = TemporaryDirectory("demo")
        let a = dir.file("a.medh5"), b = dir.file("b.medh5")
        try Demo.write(to: a, options: DemoOptions(size: 24))
        try Demo.write(to: b, options: DemoOptions(size: 24))
        XCTAssertEqual(try SampleFile.open(a).summary.contentID, try SampleFile.open(b).summary.contentID)
        let plain = dir.file("plain.medh5")
        try Demo.write(to: plain, options: DemoOptions(size: 20, clinical: false, polylines: false, index: false))
        let s = try SampleFile.open(plain).summary
        XCTAssertEqual(s.formatVersion, "1.0")
        XCTAssertTrue(s.index.isEmpty)
        XCTAssertTrue(try Validator.validate(url: plain, level: "strict").ok)
        XCTAssertThrowsMedH5(try Demo.write(to: dir.file("x.medh5"), options: DemoOptions(size: 4)), status: .argument)
    }

    func testEveryCaseOfTheConformanceCorpusOpensOrFailsWithAnError() throws {
        let dir = TemporaryDirectory("corpus")
        let manifest = try Conformance.write(to: dir.url)
        XCTAssertGreaterThan(manifest.cases.count, 50)
        var opened = 0
        for entry in manifest.cases {
            let url = dir.file(entry.file)
            let report = try Validator.validate(url: url, level: entry.level)
            XCTAssertEqual(Set(report.diagnostics.filter { $0.severity == "error" }.map(\.code)), Set(entry.expectErrors), entry.name)
            XCTAssertEqual(Set(report.diagnostics.filter { $0.severity == "warning" }.map(\.code)), Set(entry.expectWarnings), entry.name)
            if url.pathExtension == "medh5c" {
                for member in (try? Collections.list(url)) ?? [] {
                    if let sample = try? SampleFile.open(collection: url, member: member.name) { sample.close() }
                }
                continue
            }
            do {
                let sample = try SampleFile.open(url)
                opened += 1
                read(sample)
                sample.close()
            } catch let error as MedH5Error {
                XCTAssertNotEqual(error.status, .panic, "\(entry.name): \(error)")
            }
        }
        XCTAssertGreaterThan(opened, manifest.cases.count / 2)
        for file in manifest.robustness {
            let url = dir.file(file)
            _ = try Validator.validate(url: url, level: "integrity")
            if let sample = try? SampleFile.open(url) {
                read(sample)
                sample.close()
            }
        }
    }

    /// Everything a viewer reads of a sample; errors are answers, panics not.
    private func read(_ sample: SampleFile) {
        func answered<T>(_ body: () throws -> T) {
            do { _ = try body() } catch let error as MedH5Error {
                XCTAssertNotEqual(error.status, .panic, "\(error)")
            } catch {
                XCTFail("\(error)")
            }
        }
        let s = sample.summary
        answered { try sample.verify() }
        answered { try sample.documentText() }
        answered { try sample.clinicalRecords() }
        for image in s.images {
            let region = ArrayRegion(start: image.shape.map { _ in 0 }, stop: image.shape.map { min($0, 2) })
            answered { try sample.readImage(image.id, region: region, physical: true) }
        }
        for annotation in s.annotations {
            if annotation.voxel {
                answered { () -> Void in
                    let plan = try sample.layerPlan(annotation.id)
                    for layer in plan.layers.indices { _ = try sample.readLayer(annotation.id, layer: layer) }
                }
                answered { try sample.readMask(annotation.id, ignoreRegion: true) }
            } else {
                answered { try sample.geometry(annotation.id) }
            }
        }
        for transform in s.transforms { answered { try sample.transform(transform.id) } }
    }
}
