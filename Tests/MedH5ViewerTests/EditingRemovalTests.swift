import XCTest
import AppKit
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Editing

@MainActor
private func saveAs(_ doc: MedH5Document, to url: URL) async -> Error? {
    await withCheckedContinuation { continuation in
        doc.save(to: url, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
    }
}

/// The editing tools with the sidebar's Remove… (and the imports): what the
/// tools made and was never saved is taken back, not removed from a file
/// that never held it; an object the pending edits remove is not edited (the
/// save would write nothing into it); new objects never take the id of an
/// import or of a removed object.
@MainActor
final class PendingRemovalTests: XCTestCase {
    func testRemovingANewSegmentationTakesItBack() async throws {
        let dir = TemporaryDirectory("remove-new-seg")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let s = w.editing
        var request = s.defaultNewSegmentation()
        request.id = "drawn"
        request.classIDs = [1]
        try s.createSegmentation(request)
        await settle()
        s.activeClasses["drawn"] = 1
        s.brush.radius = 2
        s.select(.brush)
        ToolDriver(workspace: w).drag([Synthetic.world(3, 6, 6), Synthetic.world(3, 6, 8)])
        await settle()
        let model = try XCTUnwrap(s.segmentationResource("drawn")?.model)
        let painted = model.count(1)
        XCTAssertGreaterThan(painted, 0)
        XCTAssertEqual(PendingChangeList.items(of: w).first { $0.title == "drawn" }?.subtitle, "new segmentation")

        let plan = RemovalPlanner.annotation("drawn", summary: w.file.summary, clinical: nil, edits: doc.pendingEdits)
        XCTAssertTrue(plan.isPendingAddition)
        XCTAssertNil(plan.refusal)
        XCTAssertFalse(plan.needsConfirmation)
        doc.performRemoval(plan)
        await settle()
        XCTAssertTrue(doc.pendingEdits.isEmpty, "taken back: nothing is left to save")
        XCTAssertNil(w.summary.annotation("drawn"))
        XCTAssertFalse(w.primary.contains("drawn"))
        XCTAssertNotEqual(s.activeSegmentation, "drawn")
        XCTAssertTrue(PendingChangeList.items(of: w).isEmpty)

        // Undo brings it back with its voxels; redo takes it back again.
        doc.undoManager?.undo()
        await settle()
        XCTAssertEqual(doc.pendingEdits.newSegmentations["drawn"]?.grid, "g")
        XCTAssertNotNil(w.summary.annotation("drawn"))
        XCTAssertTrue(s.segmentationResource("drawn")?.model === model)
        XCTAssertEqual(model.count(1), painted)
        doc.undoManager?.redo()
        await settle()
        XCTAssertTrue(doc.pendingEdits.isEmpty)

        // A save writes nothing of it, and it does not come back after.
        let out = dir.file("saved.medh5")
        let error = await saveAs(doc, to: out)
        XCTAssertNil(error)
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        XCTAssertNil(saved.summary.annotation("drawn"))
        XCTAssertNotNil(saved.summary.annotation("seg"))
        let deadline = Date().addingTimeInterval(20)
        while w.file.url.standardizedFileURL != out.standardizedFileURL && Date() < deadline { await settle() }
        XCTAssertNil(w.summary.annotation("drawn"))
    }

    func testANewAnnotationTakenBackAndAStoredOneRemovedSaveRight() async throws {
        let dir = TemporaryDirectory("remove-new-boxes")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let s = w.editing
        let driver = ToolDriver(workspace: w)
        s.annotationTarget = .new
        s.annotationClassID = 1
        s.select(.box)
        driver.drag([Synthetic.world(3, 2, 2), Synthetic.world(3, 5, 5)])
        await settle()
        let id = try XCTUnwrap(s.listedAnnotation)
        XCTAssertEqual(PendingChangeList.items(of: w).first { $0.title == id }?.subtitle, "new annotation",
                       "new against the saved file, though the sidebar lists it")

        // Taken back: nothing is removed from the file, and the id is free.
        let plan = RemovalPlanner.annotation(id, summary: w.file.summary, clinical: nil, edits: doc.pendingEdits)
        XCTAssertTrue(plan.isPendingAddition)
        doc.performRemoval(plan)
        await settle()
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertNil(w.summary.annotation(id))
        s.annotationTarget = .new
        driver.drag([Synthetic.world(3, 6, 6), Synthetic.world(3, 9, 9)])
        await settle()
        XCTAssertEqual(s.listedAnnotation, id)
        let out = dir.file("saved.medh5")
        let error = await saveAs(doc, to: out)
        XCTAssertNil(error)
        do {
            let saved = try SampleFile.open(out)
            defer { saved.close() }
            XCTAssertEqual(saved.summary.annotation(id)?.items, 1)
        }
        let deadline = Date().addingTimeInterval(20)
        while w.file.url.standardizedFileURL != out.standardizedFileURL && Date() < deadline { await settle() }
        XCTAssertNotNil(w.file.summary.annotation(id))

        // Removed from the file (until the save): never edited again — a
        // new item goes to a new annotation under an id of its own.
        let removal = RemovalPlanner.annotation(id, summary: w.file.summary, clinical: nil, edits: doc.pendingEdits)
        XCTAssertFalse(removal.isPendingAddition)
        doc.performRemoval(removal)
        await settle()
        XCTAssertEqual(doc.pendingEdits.removedAnnotations, [id])
        XCTAssertFalse(s.editableAnnotations.contains { $0.id == id })
        XCTAssertNotNil(s.idProblem(id))
        let draft = try XCTUnwrap(AnnotationDraft.empty(kind: "boxes", space: .index, rank: 3))
        XCTAssertThrowsError(try s.store(draft, id: id, grid: w.file.summary.grid("g"), isNew: false, name: "Edit"))
        s.annotationTarget = .existing(id)
        XCTAssertNotEqual(s.listedAnnotation, id)
        driver.drag([Synthetic.world(3, 1, 1), Synthetic.world(3, 4, 4)])
        await settle()
        let other = try XCTUnwrap(s.listedAnnotation)
        XCTAssertNotEqual(other, id)
        XCTAssertEqual(s.draft(other)?.itemCount, 1)
        let out2 = dir.file("saved-again.medh5")
        let error2 = await saveAs(doc, to: out2)
        XCTAssertNil(error2)
        let again = try SampleFile.open(out2)
        defer { again.close() }
        XCTAssertNil(again.summary.annotation(id))
        XCTAssertEqual(again.summary.annotation(other)?.items, 1)
    }

    func testAStoredSegmentationBeingRemovedIsNotPainted() async throws {
        let dir = TemporaryDirectory("remove-stored-seg")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        let s = w.editing
        s.activate(segmentation: "seg")
        XCTAssertEqual(s.activeSegmentation, "seg")
        let plan = RemovalPlanner.annotation("seg", summary: w.file.summary, clinical: nil, edits: doc.pendingEdits)
        XCTAssertFalse(plan.isPendingAddition)
        doc.performRemoval(plan)
        await settle()
        XCTAssertEqual(doc.pendingEdits.removedAnnotations, ["seg"])
        XCTAssertNil(s.activeSegmentation)
        XCTAssertTrue(s.editableSegmentations.isEmpty)
        XCTAssertFalse(s.segmentationAvailability().isAvailable)
        XCTAssertEqual(s.idProblem("seg"), "“seg” is removed until the next save: choose another id")
        XCTAssertEqual(s.uniqueID("seg"), "seg_2")
        XCTAssertEqual(PendingChangeList.items(of: w).first { $0.title == "seg" }?.subtitle, "annotation removed")
        doc.undoManager?.undo()
        await settle()
        XCTAssertEqual(s.activeSegmentation, "seg", "the choice holds again")
    }

    func testImportedObjectsKeepTheirIDs() async throws {
        let dir = TemporaryDirectory("imported-ids")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let s = try XCTUnwrap(doc.workspace).editing
        doc.apply("Import NIfTI Segmentation") {
            $0.importedSegmentations["imported"] = ImportedSegmentation(grid: "g", layers: [], options: SegmentationWriteOptions())
            $0.newImages["MR"] = NewImage(grid: "g", data: VolumeData(scalarType: .int16, shape: [1]), options: .init())
        }
        XCTAssertEqual(s.idProblem("imported"), "“imported” is taken")
        XCTAssertEqual(s.uniqueID("imported"), "imported_2")
        XCTAssertEqual(s.idProblem("MR"), "“MR” is taken")
        XCTAssertNil(s.idProblem("other"))
    }
}

/// What the editing tools change reaches the sidebar's Unsaved Changes and
/// the panels (the document and label set editors), which follow the
/// document's edits through `AuxiliaryState`.
@MainActor
final class EditsRevisionTests: XCTestCase {
    func testTheToolsEditsReachThePanels() async throws {
        let dir = TemporaryDirectory("edits-revision")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        let s = w.editing
        // At once, before the run loop turns: the sidebar has not appeared
        // and follows no undo manager yet (a snapshot's scripted edit).
        var revision = w.auxiliary.editsRevision
        var request = s.defaultNewSegmentation()
        request.id = "drawn"
        try s.createSegmentation(request)
        XCTAssertGreaterThan(w.auxiliary.editsRevision, revision, "a new segmentation")
        XCTAssertEqual(PendingChangeList.items(of: w).map(\.title), ["drawn"])
        await settle()
        revision = w.auxiliary.editsRevision
        _ = try s.createClass(name: "Cyst", color: RGBA8(20, 200, 120), segmentation: "drawn")
        await settle()
        XCTAssertGreaterThan(w.auxiliary.editsRevision, revision, "a class added to the label set")
        revision = w.auxiliary.editsRevision
        doc.undoManager?.undo()
        await settle()
        XCTAssertGreaterThan(w.auxiliary.editsRevision, revision, "an undo")
    }
}
