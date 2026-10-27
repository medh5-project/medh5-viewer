import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Editing

/// Coverage is edited explicitly (spec §6.2, §11.3): painting a class
/// examines it, erasing keeps it examined, "Mark Not Examined" needs no
/// voxel; a class added from the label set can be expressed but is not
/// examined; a created class joins the label set in the same undo step.
@MainActor
final class SegmentationCoverageTests: XCTestCase {
    private func open(_ url: URL) async throws -> (MedH5Document, Workspace) {
        let doc = try openDocument(url)
        addTeardownBlock { @MainActor in doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        return (doc, w)
    }

    func testMarkingExaminedAndNotExamined() async throws {
        let dir = TemporaryDirectory("coverage")
        let (doc, w) = try await open(Synthetic.copy(in: dir))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("seg")?.model)
        XCTAssertEqual(model.classIDs, [1, 2, 3])
        XCTAssertEqual(model.annotatedClassIDs, [1, 2])
        // A class with voxels was looked for.
        XCTAssertThrowsError(try s.setExamined(1, false, in: "seg"))
        XCTAssertEqual(model.annotatedClassIDs, [1, 2])
        // A class without voxels can be marked either way.
        try s.setExamined(3, true, in: "seg")
        XCTAssertEqual(model.annotatedClassIDs, [1, 2, 3])
        XCTAssertEqual(doc.undoManager?.undoActionName, "Mark Examined")
        await settle()
        try s.setExamined(3, false, in: "seg")
        XCTAssertEqual(model.annotatedClassIDs, [1, 2])
        XCTAssertEqual(model.classIDs, [1, 2, 3], "it can still express it")
        await settle()
        // Clearing a class keeps it examined (an examined absence); then it
        // can be marked not examined.
        s.operation.logical = .clear
        s.activeClasses["seg"] = 2
        await s.runOperation(.logical)?.value
        XCTAssertEqual(model.count(2), 0)
        XCTAssertTrue(model.annotatedClassIDs.contains(2))
        await settle()
        try s.setExamined(2, false, in: "seg")
        XCTAssertFalse(model.annotatedClassIDs.contains(2))
        XCTAssertEqual(w.summary.annotation("seg")?.annotatedClassIDs, [1], "the sidebar's badge follows")
        // Painting a class marks it examined.
        await settle()
        s.activeClasses["seg"] = 2
        s.brush.radius = 1
        s.select(.brush)
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        ToolDriver(workspace: w).drag([Synthetic.world(3, 6, 6)])
        XCTAssertTrue(model.annotatedClassIDs.contains(2))
        // Each was one step, back to the file's coverage.
        for _ in 0..<5 {
            doc.undoManager?.undo()
            await settle()
        }
        XCTAssertEqual(model.annotatedClassIDs, [1, 2])
        XCTAssertEqual(model.count(2), 9)
        XCTAssertTrue(doc.pendingEdits.isEmpty)
    }

    func testAClassFromTheLabelSetCanBeExpressedButIsNotExamined() async throws {
        let dir = TemporaryDirectory("addclass")
        let (doc, w) = try await open(Fixtures.demoCopy(in: dir))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("organs_tp0")?.model)
        XCTAssertFalse(model.classIDs.contains(4))
        let layers = model.layerCount
        try s.addClass(4, to: "organs_tp0")
        XCTAssertTrue(model.classIDs.contains(4))
        XCTAssertFalse(model.annotatedClassIDs.contains(4))
        XCTAssertEqual(model.classInfo(4)?.name, w.summary.labelSet?.labelClass(id: 4)?.name)
        XCTAssertEqual(s.activeClasses["organs_tp0"], 4, "the class added becomes the one painted")
        XCTAssertEqual(doc.pendingEdits.editedSegmentations, ["organs_tp0"])
        XCTAssertEqual(w.summary.annotation("organs_tp0")?.classIDs.contains(4), true)
        await settle()
        // A class that may overlap the others gets a layer of its own.
        try s.addClass(1, to: "organs_tp0", overlapping: true)
        XCTAssertEqual(model.layerCount, layers + 1)
        XCTAssertEqual(model.layer(of: 1), layers)
        await settle()
        doc.undoManager?.undo()
        await settle()
        doc.undoManager?.undo()
        await settle()
        XCTAssertFalse(model.classIDs.contains(4))
        XCTAssertEqual(model.layerCount, layers)
        XCTAssertTrue(doc.pendingEdits.isEmpty)
    }

    func testCreatingAClassAddsItToTheLabelSetInTheSameStep() async throws {
        let dir = TemporaryDirectory("createclass")
        let (doc, w) = try await open(Synthetic.copy(in: dir))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("seg")?.model)
        let id = try s.createClass(name: "Cyst wall", color: RGBA8(20, 200, 120), segmentation: "seg")
        XCTAssertEqual(id, 4)
        XCTAssertEqual(model.classInfo(4)?.key, "cyst_wall")
        XCTAssertTrue(model.classIDs.contains(4))
        XCTAssertFalse(model.annotatedClassIDs.contains(4))
        guard case .set(let labels)? = doc.pendingEdits.labelSet else { return XCTFail("the label set is pending") }
        XCTAssertTrue(labels["classes"]?.arrayValue?.contains { $0["key"] == "cyst_wall" } ?? false)
        XCTAssertEqual(w.summary.labelSet?.labelClass(id: 4)?.name, "Cyst wall", "names and colours read the new label set")
        XCTAssertThrowsError(try s.createClass(name: "Cyst wall", color: RGBA8(1, 2, 3), segmentation: "seg"), "keys are unique")
        await settle()
        doc.undoManager?.undo()
        await settle()
        XCTAssertNil(model.classInfo(4))
        XCTAssertNil(doc.pendingEdits.labelSet)
        XCTAssertNil(w.summary.labelSet?.labelClass(id: 4))
    }

    func testTheEngineCountsAtLoadAreTheModelsCounts() async throws {
        let dir = TemporaryDirectory("counts")
        let (_, w) = try await open(Fixtures.demoCopy(in: dir))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("organs_tp0")?.model)
        let counts = s.voxelCounts("organs_tp0")
        for c in model.classes { XCTAssertEqual(counts[c.id, default: 0], model.count(c.id), "class \(c.id)") }
    }
}
