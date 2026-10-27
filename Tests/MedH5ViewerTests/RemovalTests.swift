import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// Removing images, annotations and transforms from the sidebar: refused
/// where the format forbids it, confirmed where it reaches further, a
/// pending edit until the save (undoable), gone from the saved file.
@MainActor
final class RemovalTests: XCTestCase {
    func testAttestedImagesAndAnnotationsStay() throws {
        let file = try SampleFile.open(Fixtures.demo)
        defer { file.close() }
        let records = try file.clinicalRecords()
        let summary = file.summary
        let image = RemovalPlanner.image("CT_tp1", summary: summary, clinical: records, edits: PendingEdits())
        let refusal = try XCTUnwrap(image.refusal)
        XCTAssertTrue(refusal.contains("ct1 (imaging)"), refusal)
        XCTAssertTrue(refusal.contains("E809"), refusal)
        let instances = RemovalPlanner.annotation("lesions_tp0", summary: summary, clinical: records, edits: PendingEdits())
        XCTAssertTrue(instances.refusal?.contains("grounding1") ?? false, instances.refusal ?? "")

        // Applying a refused plan changes nothing.
        var edits = PendingEdits()
        RemovalPlanner.apply(image, to: &edits)
        XCTAssertTrue(edits.isEmpty)

        // A mask that is an image's valid region: removed with the image's
        // valid_mask, after a confirmation.
        let fov = RemovalPlanner.annotation("mr_fov", summary: summary, clinical: records, edits: PendingEdits())
        XCTAssertNil(fov.refusal)
        XCTAssertEqual(fov.clearsValidMaskOf, ["MR_tp0"])
        XCTAssertTrue(fov.needsConfirmation)
        RemovalPlanner.apply(fov, to: &edits)
        XCTAssertEqual(edits.removedAnnotations, ["mr_fov"])
        XCTAssertEqual(edits.imageAttributes["MR_tp0"]?["valid_mask"], .null)

        // A plain annotation needs no confirmation.
        let boxes = RemovalPlanner.annotation("kidney_obb_tp0", summary: summary, clinical: records, edits: PendingEdits())
        XCTAssertNil(boxes.refusal)
        XCTAssertFalse(boxes.needsConfirmation)

        // A transform: the frames it registers come apart.
        let t = RemovalPlanner.transform("tp0_to_tp1", summary: summary, edits: PendingEdits())
        XCTAssertNil(t.refusal)
        XCTAssertTrue(t.consequences.first?.contains("no longer registered") ?? false)
    }

    /// On a sample without a clinical history: remove an image (confirmed),
    /// an annotation and the transform; undo and redo; save; reopen: gone,
    /// the rest byte-identical, the file valid.
    func testRemovalRoundTrip() async throws {
        let dir = TemporaryDirectory("remove")
        let source = Fixtures.copy(Fixtures.demoWithoutClinical, in: dir, name: "plain.medh5")
        let doc = try MedH5Document.openForTest(source)
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let before = workspace.summary
        let records = try workspace.file.clinicalRecords()
        XCTAssertNil(records)

        let mr = RemovalPlanner.image("MR_tp0", summary: before, clinical: records, edits: workspace.pendingEdits)
        XCTAssertNil(mr.refusal)
        XCTAssertTrue(mr.needsConfirmation, "removing an image drops its samples")
        XCTAssertTrue(mr.consequences.contains { $0.contains("acquisition") })
        doc.performRemoval(mr)
        let polylines = RemovalPlanner.annotation("centrelines_tp0", summary: before, clinical: nil, edits: workspace.pendingEdits)
        doc.performRemoval(polylines)
        let transform = RemovalPlanner.transform("tp0_to_tp1", summary: before, edits: workspace.pendingEdits)
        doc.performRemoval(transform)
        XCTAssertEqual(workspace.pendingEdits.removedImages, ["MR_tp0"])
        XCTAssertEqual(workspace.pendingEdits.removedAnnotations, ["centrelines_tp0"])
        XCTAssertEqual(workspace.pendingEdits.removedTransforms, ["tp0_to_tp1"])
        XCTAssertEqual(Set(PendingChangeList.items(workspace.pendingEdits, summary: before).map(\.title)),
                       ["MR_tp0", "centrelines_tp0", "tp0_to_tp1"])
        try await endEvent()
        XCTAssertEqual(doc.undoManager?.undoActionName, "Remove Transform tp0_to_tp1")
        doc.undoManager?.undo()
        try await endEvent()
        XCTAssertTrue(workspace.pendingEdits.removedTransforms.isEmpty)
        doc.undoManager?.redo()
        try await endEvent()
        XCTAssertEqual(workspace.pendingEdits.removedTransforms, ["tp0_to_tp1"])

        let out = dir.file("removed.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        XCTAssertTrue(workspace.pendingEdits.isEmpty)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let s = saved.summary
        XCTAssertNil(s.image("MR_tp0"))
        XCTAssertNil(s.annotation("centrelines_tp0"))
        XCTAssertNil(s.transform("tp0_to_tp1"))
        XCTAssertNotNil(s.grid("mr_tp0"), "the grid stays, with its annotations")
        XCTAssertNil(try saved.document()["acquisition"]?["MR_tp0"], "the image's acquisition parameters go with it")
        for image in before.images where image.id != "MR_tp0" {
            XCTAssertEqual(s.image(image.id)?.digest, image.digest, image.id)
        }
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
    }

    /// Taking back an import removes it from the pending edits (and a grid
    /// made for it).
    func testRemovingAnImportTakesItBack() {
        var edits = PendingEdits()
        edits.newGrids["g"] = GridGeometry(id: "g", shape: [2, 2, 2], spacing: [1, 1, 1], timepoint: "tp0", frameUID: "f")
        edits.newImages["img"] = NewImage(grid: "g", data: VolumeData(scalarType: .int16, shape: [2, 2, 2]), options: .init())
        let summary = try! SampleFile.open(Fixtures.demo).summary
        let plan = RemovalPlanner.image("img", summary: summary, clinical: nil, edits: edits)
        XCTAssertTrue(plan.isPendingAddition)
        XCTAssertFalse(plan.needsConfirmation)
        RemovalPlanner.apply(plan, to: &edits)
        XCTAssertTrue(edits.isEmpty, "the grid made for it goes too")

        // What a save forgets of the additions it wrote.
        var a = PendingEdits()
        a.newImages["img"] = NewImage(grid: "g", data: VolumeData(scalarType: .int16, shape: [1]), options: .init())
        var later = a
        later.newImages["other"] = NewImage(grid: "g", data: VolumeData(scalarType: .int16, shape: [1]), options: .init())
        later.forgetSavedAdditions(a)
        XCTAssertEqual(Array(later.newImages.keys), ["other"], "an import made during the save stays")
    }
}
