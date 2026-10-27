import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Editing

/// Edits made with the tools reach the file: a new segmentation painted
/// (with a class created for it) and geometric annotations drawn and edited
/// save through the engine, read back, verify, and validate at the
/// strictest level; what was not touched keeps its digest.
@MainActor
final class EditingSaveTests: XCTestCase {
    private func save(_ doc: MedH5Document, to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            doc.save(to: url, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
    }

    private func strictlyValid(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let level = try XCTUnwrap(try MedH5.validationLevels().last)
        XCTAssertEqual(level, "strict")
        let report = try Validator.validate(url: url, level: level)
        XCTAssertTrue(report.ok, "\(report.diagnostics.map { "\($0.code) \($0.location): \($0.message)" })", file: file, line: line)
    }

    func testANewSegmentationPaintedAndSavedReadsBack() async throws {
        let dir = TemporaryDirectory("newseg")
        let doc = try openDocument(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        let before = w.file.summary
        let s = w.editing
        var request = s.defaultNewSegmentation()
        XCTAssertEqual(request.grid, "ct_tp0", "the base image's grid")
        request.id = "viewer_seg"
        request.classIDs = [2, 9]
        try s.createSegmentation(request)
        await settle()
        XCTAssertEqual(w.summary.annotation("viewer_seg")?.kind, "labelmap", "listed until saved")
        XCTAssertTrue(w.primary.contains("viewer_seg"), "shown in the active view")
        XCTAssertEqual(s.activeSegmentation, "viewer_seg")
        XCTAssertEqual(doc.pendingEdits.newSegmentations["viewer_seg"]?.grid, "ct_tp0")
        let cyst = try s.createClass(name: "Cyst", color: RGBA8(20, 200, 120), code: ("SCT", "367643001"),
                                     segmentation: "viewer_seg")
        await settle()

        w.setCursor(Demo.lesionCentre, from: .slice(.axial))
        w.viewer.activeViewport = .slice(.axial)
        s.activeClasses["viewer_seg"] = 9
        s.brush.radius = 15
        s.select(.brush)
        let driver = ToolDriver(workspace: w)
        driver.drag([Demo.lesionCentre, driver.offset(Demo.lesionCentre, 12, 0)])
        await settle()
        s.activeClasses["viewer_seg"] = UInt16(cyst)
        driver.drag([driver.offset(Demo.lesionCentre, -60, 40), driver.offset(Demo.lesionCentre, -45, 40)])
        await settle()
        let model = try XCTUnwrap(s.segmentationResource("viewer_seg")?.model)
        let k = try XCTUnwrap(model.geometry.voxel(containingWorld: Demo.lesionCentre))
        XCTAssertTrue(model.contains(9, at: k))
        XCTAssertGreaterThan(model.count(UInt16(cyst)), 0)
        XCTAssertEqual(Set(model.annotatedClassIDs), [9, UInt16(cyst)], "painted classes are examined, liver is not")

        // Undo and redo of the creation keep the layer and the model.
        let painted = model.count(9)
        for _ in 0..<4 {
            doc.undoManager?.undo()
            await settle()
        }
        XCTAssertNil(w.summary.annotation("viewer_seg"))
        XCTAssertFalse(w.primary.contains("viewer_seg"))
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        for _ in 0..<4 {
            doc.undoManager?.redo()
            await settle()
        }
        XCTAssertTrue(w.primary.contains("viewer_seg"), "the layer comes back")
        XCTAssertEqual(model.count(9), painted)

        let out = dir.file("saved.medh5")
        let error = await save(doc, to: out)
        XCTAssertNil(error)
        XCTAssertTrue(doc.pendingEdits.isEmpty)

        do {
            let saved = try SampleFile.open(out)
            defer { saved.close() }
            let info = try XCTUnwrap(saved.summary.annotation("viewer_seg"))
            XCTAssertEqual(Set(info.classIDs), [2, 9, cyst], "the classes it can express")
            XCTAssertEqual(Set(info.annotatedClassIDs), [9, cyst], "the classes examined: liver can be expressed only")
            XCTAssertEqual(info.grid, "ct_tp0")
            XCTAssertEqual(saved.summary.labelSet?.labelClass(id: cyst)?.key, "cyst")
            XCTAssertEqual(saved.summary.labelSet?.labelClass(id: cyst)?.codes.first?.code, "367643001")
            let data = try await saved.loadSegmentation("viewer_seg")
            XCTAssertTrue(data.layers.contains { Int($0.value(at: model.linearIndex(k))) == 9 })
            let stats = try saved.classStats("viewer_seg")
            XCTAssertEqual(Int(stats[9]?.voxels ?? 0), model.count(9))
            XCTAssertEqual(Int(stats[cyst]?.voxels ?? 0), model.count(UInt16(cyst)))
            XCTAssertTrue(try saved.verify().ok)
            // A class not examined, without an ignore region, is a warning
            // (W904): valid at `integrity`, promoted by `strict`.
            let integrity = try Validator.validate(url: out, level: "integrity")
            XCTAssertTrue(integrity.ok, "\(integrity.diagnostics.map(\.message))")
            XCTAssertEqual(integrity.diagnostics.map(\.code), ["W904"])
            for image in before.images { XCTAssertEqual(saved.summary.image(image.id)?.digest, image.digest, image.id) }
            for a in before.annotations { XCTAssertEqual(saved.summary.annotation(a.id)?.digest, a.digest, a.id) }
        }

        // The window reads the saved file; the model stays, editable.
        let deadline = Date().addingTimeInterval(20)
        while w.file.url.standardizedFileURL != out.standardizedFileURL && Date() < deadline { await settle() }
        XCTAssertEqual(w.summary.annotation("viewer_seg")?.annotatedClassIDs.sorted(), [9, cyst].sorted())
        XCTAssertTrue(s.segmentationResource("viewer_seg")?.model === model)

        // Liver was looked for and is absent: an examined absence. Saved
        // again, the file validates at the strictest level.
        try s.setExamined(2, true, in: "viewer_seg")
        XCTAssertEqual(doc.pendingEdits.editedSegmentations, ["viewer_seg"], "now a segmentation of the file")
        await settle()
        let out2 = dir.file("saved-again.medh5")
        let error2 = await save(doc, to: out2)
        XCTAssertNil(error2)
        let again = try SampleFile.open(out2)
        defer { again.close() }
        XCTAssertEqual(Set(again.summary.annotation("viewer_seg")?.annotatedClassIDs ?? []), [2, 9, cyst])
        XCTAssertEqual(Int(try again.classStats("viewer_seg")[2]?.voxels ?? 0), 0)
        XCTAssertTrue(try again.verify().ok)
        try strictlyValid(out2)
        for image in before.images { XCTAssertEqual(again.summary.image(image.id)?.digest, image.digest, image.id) }
        for a in before.annotations { XCTAssertEqual(again.summary.annotation(a.id)?.digest, a.digest, a.id) }
    }

    func testAnnotationsDrawnAndEditedSaveAndReadBack() async throws {
        let dir = TemporaryDirectory("annotations")
        let doc = try openDocument(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        for id in ["fiducials_tp0", "centrelines_tp0", "liver_contours_tp0"] { w.editing.show(id) }
        try await w.loadNeeded()
        let before = w.file.summary
        let s = w.editing
        w.setCursor(Demo.lesionCentre, from: .slice(.axial))
        w.viewer.activeViewport = .slice(.axial)
        let driver = ToolDriver(workspace: w)
        let c = Demo.lesionCentre

        // A box in a new annotation, from a drag.
        s.annotationTarget = .new
        s.annotationClassID = 9
        s.select(.box)
        driver.drag([driver.offset(c, -20, -15), driver.offset(c, 20, 15)])
        await settle()
        let boxes = try XCTUnwrap(s.listedAnnotation)
        XCTAssertTrue(boxes.hasPrefix("boxes"))
        XCTAssertEqual(w.summary.annotation(boxes)?.kind, "boxes", "listed until saved")
        XCTAssertTrue(w.primary.contains(boxes))
        guard case .boxes(let set)? = s.draft(boxes) else { return XCTFail("a box draft") }
        XCTAssertEqual(set.boxes.count, 1)
        XCTAssertEqual(set.boxes[0].classID, 9)
        XCTAssertNotNil(set.boxes[0].sliceIndex, "a 2-D box on the slice")
        // A 3-D box five slices deep.
        s.boxDepth = 5
        driver.drag([driver.offset(c, -10, -10), driver.offset(c, 10, 10)])
        await settle()
        guard case .boxes(let deep)? = s.draft(boxes), deep.boxes.count == 2 else { return XCTFail("two boxes") }
        let axis = 0
        XCTAssertEqual(deep.boxes[1].upper[axis] - deep.boxes[1].lower[axis], 5, accuracy: 1e-9)
        XCTAssertNil(deep.boxes[1].sliceIndex)

        // A point added to the fiducials (world points with classes).
        s.choose(annotation: "fiducials_tp0")
        s.select(.point)
        s.annotationClassID = 3
        driver.click(driver.offset(c, 30, 0))
        await settle()
        XCTAssertEqual(s.draft("fiducials_tp0")?.itemCount, 6)
        // A polyline (Return finishes) and a contour (clicking the first
        // vertex closes it) into the demo's own annotations.
        s.choose(annotation: "centrelines_tp0")
        s.select(.polyline)
        s.annotationClassID = 7
        guard case .polylines(let original)? = s.draft("centrelines_tp0") else { return XCTFail("polylines") }
        let nextInstance = (original.polylines.compactMap(\.instanceID).max() ?? 0) + 1
        for p in [driver.offset(c, -30, 30), driver.offset(c, 0, 40), driver.offset(c, 30, 30)] { driver.click(p) }
        XCTAssertNotNil(s.viewState(.slice(.axial)).preview, "the curve in progress is drawn")
        driver.send(.keyDown, c, key: ToolEvent.returnKey)
        await settle()
        XCTAssertEqual(s.draft("centrelines_tp0")?.itemCount, 3)
        guard case .polylines(let lines)? = s.draft("centrelines_tp0"), let line = lines.polylines.last else { return XCTFail() }
        XCTAssertEqual(line.vertices.count, 3)
        XCTAssertNotNil(line.plane, "drawn on an aligned slice: in its grid plane")
        XCTAssertEqual(line.instanceID, original.polylines.allSatisfy { $0.instanceID != nil } ? nextInstance : nil)
        s.choose(annotation: "liver_contours_tp0")
        s.select(.contour)
        s.annotationClassID = 2
        let square = [driver.offset(c, -40, -40), driver.offset(c, -20, -40), driver.offset(c, -20, -20), driver.offset(c, -40, -20)]
        for p in square { driver.click(p) }
        driver.click(square[0])
        await settle()
        XCTAssertEqual(s.draft("liver_contours_tp0")?.itemCount, 8)

        // Change the class of the new box, delete the deep one.
        s.choose(annotation: boxes)
        s.select(items: [0], of: boxes)
        try s.setClassOfSelectedItems(3)
        await settle()
        s.select(items: [1], of: boxes)
        try s.deleteSelectedItems()
        await settle()
        guard case .boxes(let edited)? = s.draft(boxes) else { return XCTFail() }
        XCTAssertEqual(edited.boxes.map(\.classID), [3])
        XCTAssertEqual(doc.undoManager?.undoActionName, "Delete Item")
        // Undo the deletion, then delete again (redo).
        doc.undoManager?.undo()
        await settle()
        XCTAssertEqual(s.draft(boxes)?.itemCount, 2)
        doc.undoManager?.redo()
        await settle()
        XCTAssertEqual(s.draft(boxes)?.itemCount, 1)

        let out = dir.file("saved.medh5")
        let error = await save(doc, to: out)
        XCTAssertNil(error)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        guard case .boxes(let b) = try saved.geometry(boxes) else { return XCTFail("boxes saved") }
        XCTAssertEqual(b.classIDs, [3])
        XCTAssertEqual(b.sliceIndex?.count, 1)
        guard case .points(let points) = try saved.geometry("fiducials_tp0") else { return XCTFail() }
        XCTAssertEqual(points.points.count, 6)
        XCTAssertEqual(points.classIDs?.last, 3)
        XCTAssertEqual(points.names?.count, points.names.map { _ in 6 })
        guard case .polylines(let pl) = try saved.geometry("centrelines_tp0") else { return XCTFail() }
        XCTAssertEqual(pl.polylines.count, 3)
        XCTAssertEqual(pl.polylines.last?.classID, 7)
        guard case .contours(let cs) = try saved.geometry("liver_contours_tp0") else { return XCTFail() }
        XCTAssertEqual(cs.polygons.count, 8)
        XCTAssertEqual(cs.polygons.last?.vertices.count, 4)
        XCTAssertEqual(saved.summary.annotation("liver_contours_tp0")?.annotatedClassIDs,
                       before.annotation("liver_contours_tp0")?.annotatedClassIDs, "coverage kept")
        XCTAssertTrue(try saved.verify().ok)
        try strictlyValid(out)
        let edited2: Set<String> = [boxes, "fiducials_tp0", "centrelines_tp0", "liver_contours_tp0"]
        for a in before.annotations where !edited2.contains(a.id) {
            XCTAssertEqual(saved.summary.annotation(a.id)?.digest, a.digest, a.id)
        }
        for image in before.images { XCTAssertEqual(saved.summary.image(image.id)?.digest, image.digest, image.id) }
    }

    func testCopyAndPasteItems() async throws {
        let dir = TemporaryDirectory("paste")
        let doc = try openDocument(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        w.editing.show("lesion_boxes_tp0")
        try await w.loadNeeded()
        let s = w.editing
        w.setCursor(Demo.lesionCentre, from: .slice(.axial))
        w.viewer.activeViewport = .slice(.axial)
        let driver = ToolDriver(workspace: w)
        // Items copied from the demo's boxes (with their attributes)…
        s.choose(annotation: "lesion_boxes_tp0")
        XCTAssertEqual(s.draft("lesion_boxes_tp0")?.itemCount, 3)
        s.select(items: [0, 2], of: "lesion_boxes_tp0")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("medh5-viewer-tests-\(UUID().uuidString)"))
        XCTAssertTrue(s.copySelectedItems(to: pasteboard))
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("Box 1") ?? false, "a text description too")
        guard case .boxes(let source)? = s.draft("lesion_boxes_tp0") else { return XCTFail() }
        // …pasted into a box annotation drawn here (the demo's own boxes are
        // attested by its clinical history: the engine refuses to amend them).
        s.annotationTarget = .new
        s.annotationClassID = 9
        s.select(.box)
        driver.drag([driver.offset(Demo.lesionCentre, -10, -10), driver.offset(Demo.lesionCentre, 10, 10)])
        await settle()
        let boxes = try XCTUnwrap(s.listedAnnotation)
        try s.pasteItems(from: pasteboard)
        guard case .boxes(let set)? = s.draft(boxes) else { return XCTFail() }
        XCTAssertEqual(set.boxes.count, 3)
        // The same boxes, as new objects: new instance ids.
        for (pasted, copied) in [(set.boxes[1], source.boxes[0]), (set.boxes[2], source.boxes[2])] {
            var p = pasted
            p.instanceID = copied.instanceID
            XCTAssertEqual(p, copied)
        }
        XCTAssertEqual(set.boxes[1...].map(\.instanceID), [1, 2])
        XCTAssertEqual(s.currentSelection, [1, 2], "the pasted items are selected")
        XCTAssertEqual(doc.undoManager?.undoActionName, "Paste Items")
        await settle()
        // Cut one, paste it back.
        s.select(items: [0], of: boxes)
        let local = NSPasteboard(name: NSPasteboard.Name("medh5-viewer-tests-\(UUID().uuidString)"))
        XCTAssertTrue(s.copySelectedItems(to: local))
        try s.deleteSelectedItems()
        await settle()
        try s.pasteItems(from: local)
        XCTAssertEqual(s.draft(boxes)?.itemCount, 3)
        await settle()
        let out = dir.file("pasted.medh5")
        let error = await save(doc, to: out)
        XCTAssertNil(error)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        XCTAssertEqual(saved.summary.annotation(boxes)?.items, 3)
        guard case .boxes(let b) = try saved.geometry(boxes) else { return XCTFail() }
        XCTAssertEqual(b.header.attributes?.count, 3, "the attributes column came along")
        try strictlyValid(out)
    }
}
