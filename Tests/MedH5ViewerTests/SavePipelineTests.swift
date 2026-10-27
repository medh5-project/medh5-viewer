import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Editing

/// The save pipeline: pending edits → one amendment of the file the
/// document was read from, written to a new URL, reopened and verified.
@MainActor
final class SavePipelineTests: XCTestCase {
    func testPendingEditsNameWhatTheAmendmentDrops() throws {
        let summary = try SampleFile.open(Fixtures.demo).summary
        var edits = PendingEdits()
        XCTAssertTrue(edits.isEmpty)
        edits.editedSegmentations = ["organs_tp0"]
        edits.removedAnnotations = ["centrelines_tp0", "not_there"]
        edits.annotations["new_points"] = .geometric(kind: "points", options: GeometricWriteOptions(grid: "ct_tp0", space: "world"),
                                                     arrays: [NamedArray("points", shape: [1, 3], doubles: [0, 0, 0])])
        edits.removedTransforms = ["tp0_to_tp1"]
        XCTAssertEqual(edits.without(in: summary),
                       ["annotations/centrelines_tp0", "annotations/organs_tp0", "transforms/tp0_to_tp1"],
                       "only objects the file holds, a new annotation is not dropped")
        XCTAssertEqual(edits.touchedObjects, ["organs_tp0", "centrelines_tp0", "not_there", "new_points", "tp0_to_tp1"])
        XCTAssertFalse(edits.isEmpty)
    }

    /// Open the demo, change a segmentation voxel through the editor's
    /// model, the document, the label set, remove an annotation and add one;
    /// save to a new URL; reopen; everything changed is there, coverage is
    /// kept, untouched objects are byte-identical (same digests), and the
    /// file verifies and validates.
    func testAmendRoundTripOnADemoCopy() async throws {
        let dir = TemporaryDirectory("save")
        let source = Fixtures.demoCopy(in: dir)
        let out = dir.file("saved.medh5")
        let w = Workspace(file: try SampleFile.open(source), displayName: "demo", context: nil)
        let before = w.summary
        let organsInfo = try XCTUnwrap(before.annotation("organs_tp0"))

        // A voxel edit through the model the store holds (as the brush will).
        let seg = try await w.store.resource(.segmentation("organs_tp0"), as: SegmentationResource.self)
        let model = seg.model
        let k = try XCTUnwrap(model.geometry.voxel(containingWorld: Demo.lesionCentre))
        let lesionLayer = try XCTUnwrap(model.layer(of: 9))
        let layerBefore = model.value(layer: lesionLayer, at: k)
        let target: UInt16 = layerBefore == 9 ? 0 : 9
        let voxel = VoxelMask(bounds: VoxelBox(voxel: k), bytes: [1])
        let edit = try model.makeEdit(target == 9 ? .paint(9) : .erase(9), over: voxel)
        XCTAssertFalse(edit.isEmpty)
        model.apply(edit)
        XCTAssertEqual(model.value(layer: lesionLayer, at: k), target)

        var edits = PendingEdits()
        edits.editedSegmentations = ["organs_tp0"]
        var document = try w.file.document()
        document["extra"] = ["org.medh5.viewer": ["note": "round trip", "version": 1]]
        edits.document = document
        var labels = try XCTUnwrap(before.labelSet.map { try JSONValue.encoding($0) })
        if case .object(var o) = labels, case .array(var classes)? = o["classes"] {
            for (i, c) in classes.enumerated() where c["id"]?.intValue == 3 {
                if case .object(var co) = c { co["color"] = [10, 200, 30, 255]; classes[i] = .object(co) }
            }
            o["classes"] = .array(classes)
            labels = .object(o)
        }
        edits.labelSet = .set(labels)
        edits.removedAnnotations = ["centrelines_tp0"]
        edits.annotations["viewer_points"] = .geometric(
            kind: "points", options: GeometricWriteOptions(grid: "ct_tp0", space: "world", extra: ["names": ["probe"]]),
            arrays: [NamedArray("points", shape: [1, 3], doubles: [Demo.lesionCentre.x, Demo.lesionCentre.y, Demo.lesionCentre.z]),
                     NamedArray("class_ids", shape: [1], ints: [9])])

        let snapshot = try SaveSnapshot.make(edits: edits, summary: w.summary, store: w.store)
        XCTAssertEqual(snapshot.segmentations.count, 1)
        XCTAssertFalse(snapshot.segmentations[0].layers[0] === model.layers[0], "the save writes a copy")
        let newID = try await blocking { try SaveOperation(snapshot: snapshot).perform(source: source, destination: out) }
        XCTAssertNotNil(newID)
        XCTAssertEqual(try SampleFile.open(source).summary.contentID, before.contentID, "the source is left alone")

        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let s = saved.summary
        XCTAssertEqual(s.contentID, newID)
        XCTAssertTrue(try saved.verify().ok)
        let validation = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(validation.ok, "\(validation.diagnostics.map(\.message))")

        // What changed.
        let organs = try XCTUnwrap(s.annotation("organs_tp0"))
        XCTAssertEqual(organs.classIDs, organsInfo.classIDs, "what it can express is kept")
        XCTAssertEqual(organs.annotatedClassIDs, organsInfo.annotatedClassIDs, "what was looked for is kept")
        XCTAssertEqual(organs.ignoreID, organsInfo.ignoreID)
        XCTAssertEqual(organs.prov, organsInfo.prov)
        XCTAssertEqual(organs.quality, organsInfo.quality)
        let plan = try saved.layerPlan("organs_tp0")
        let layers = try plan.layers.indices.map { try saved.readLayer("organs_tp0", layer: $0) }
        let reread = layers.map { $0.value(at: model.linearIndex(k)) }
        XCTAssertTrue(reread.contains(Double(target)) || (target == 0 && !reread.contains(9)), "\(reread)")
        XCTAssertEqual(try saved.document()["extra"]?["org.medh5.viewer"]?["note"], "round trip")
        XCTAssertEqual(s.labelSet?.labelClass(id: 3)?.color, RGBA8(10, 200, 30, 255))
        XCTAssertNil(s.annotation("centrelines_tp0"))
        XCTAssertEqual(s.annotation("viewer_points")?.kind, "points")

        // What did not: the same digests.
        for image in before.images { XCTAssertEqual(s.image(image.id)?.digest, image.digest, image.id) }
        for a in before.annotations where !["organs_tp0", "centrelines_tp0"].contains(a.id) {
            XCTAssertEqual(s.annotation(a.id)?.digest, a.digest, a.id)
        }
        XCTAssertEqual(s.grids, before.grids)
        XCTAssertEqual(s.transforms, before.transforms)
        XCTAssertEqual(s.timepoints, before.timepoints)
    }

    /// The document's own path: edits are undoable, the save amends into
    /// the URL NSDocument gives and the document reads the saved file.
    func testDocumentEditsUndoAndSave() async throws {
        let dir = TemporaryDirectory("document")
        let source = Fixtures.demoCopy(in: dir)
        let doc = try MedH5Document(contentsOf: source, ofType: MedH5Document.typeIdentifier)
        doc.makeWindowControllers()
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        XCTAssertFalse(doc.isDocumentEdited)
        doc.apply("Remove Polylines") { $0.removedAnnotations.insert("centrelines_tp0") }
        // The undo group closes, and the document counts the change, when
        // the event ends.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(doc.undoManager?.undoActionName, "Remove Polylines")
        XCTAssertEqual(doc.pendingEdits.removedAnnotations, ["centrelines_tp0"])
        doc.undoManager?.undo()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertFalse(doc.isDocumentEdited)
        doc.undoManager?.redo()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(doc.pendingEdits.removedAnnotations, ["centrelines_tp0"])
        XCTAssertTrue(doc.isDocumentEdited)

        let out = dir.file("saved-as.medh5")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: out, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(doc.fileURL?.standardizedFileURL, out.standardizedFileURL)
        XCTAssertTrue(doc.pendingEdits.isEmpty, "what was saved is no longer pending")
        XCTAssertFalse(doc.isDocumentEdited)
        // The document reopens the saved file.
        let deadline = Date().addingTimeInterval(20)
        while workspace.summary.annotation("centrelines_tp0") != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(workspace.summary.annotation("centrelines_tp0"))
        XCTAssertEqual(workspace.file.url.standardizedFileURL, out.standardizedFileURL)
        let saved = try SampleFile.open(out)
        XCTAssertTrue(try saved.verify().ok)
        saved.close()
    }

    func testReadOnlyDocumentsRefuseEdits() throws {
        let dir = TemporaryDirectory("readonly")
        let source = Fixtures.demoCopy(in: dir)
        let doc = try MedH5Document.untitled(from: source, name: "member", readOnly: [.collectionMember("m")])
        doc.makeWindowControllers()
        defer { doc.close() }
        XCTAssertTrue(doc.isReadOnly)
        doc.apply("Remove") { $0.removedAnnotations.insert("centrelines_tp0") }
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertFalse(doc.isDocumentEdited)
    }
}
