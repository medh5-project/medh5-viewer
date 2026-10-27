import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// The label set editor: add, recolour, and remove only what nothing uses;
/// Apply goes through the engine into the pending label set; the save
/// writes it.
@MainActor
final class LabelSetEditorTests: XCTestCase {
    func testAddRecolourApplyAndSave() async throws {
        let dir = TemporaryDirectory("labels")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = LabelSetEditorModel(workspace: workspace)
        XCTAssertTrue(model.hasLabelSet)
        XCTAssertEqual(model.classes.count, 12)
        XCTAssertFalse(model.isDirty, "the draft starts as the label set")

        // Recolour the spleen.
        let spleen = try XCTUnwrap(model.classes.first { $0.classID == 3 })
        model.setColor(spleen.id, RGBA8(10, 200, 30, 255))
        XCTAssertEqual(model.row(spleen.id)?.color, RGBA8(10, 200, 30, 255))
        XCTAssertEqual(model.row(spleen.id)?.object.keys.first, "id", "members keep their order")

        // Add a class: the next id, a key and name, the palette's colour.
        let added = try XCTUnwrap(model.addClass())
        let fresh = try XCTUnwrap(model.row(added))
        XCTAssertEqual(fresh.classID, 13)
        XCTAssertEqual(fresh.key, "class_13")
        XCTAssertEqual(fresh.color, LabelPalette.color(forClassID: 13))
        model.setText(added, "key", "gallbladder", required: true)
        model.setText(added, "name", "Gallbladder", required: true)
        model.setText(added, "category", "organ")
        model.toggleParent(added, 1)
        model.addCode(added)
        model.codeBinding(added, 0, "code").wrappedValue = "28231008"
        model.codeBinding(added, 0, "name").wrappedValue = "Gallbladder structure"
        XCTAssertTrue(model.problems.isEmpty)
        XCTAssertTrue(model.isDirty)

        await model.apply()
        XCTAssertEqual(model.refusal, [])
        guard case .set(let labels)? = workspace.pendingEdits.labelSet else { return XCTFail("no pending label set") }
        let classes = labels["classes"]?.arrayValue ?? []
        XCTAssertEqual(classes.count, 13)
        XCTAssertEqual(classes.first { $0["id"] == .int(13) }?["key"], "gallbladder")
        XCTAssertFalse(model.isDirty)
        try await endEvent()
        XCTAssertEqual(doc.undoManager?.undoActionName, "Edit Label Set")

        let out = dir.file("labels.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let ls = try XCTUnwrap(saved.summary.labelSet)
        XCTAssertEqual(ls.labelClass(id: 3)?.color, RGBA8(10, 200, 30, 255))
        let gallbladder = try XCTUnwrap(ls.labelClass(key: "gallbladder"))
        XCTAssertEqual(gallbladder.id, 13)
        XCTAssertEqual(gallbladder.parents, [1])
        XCTAssertEqual(gallbladder.codes.first?.code, "28231008")
        XCTAssertEqual(ls.labelClass(id: 2)?.properties["window"], .ints([-150, 250]), "members the editor does not show are kept")
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
    }

    /// A class an annotation uses, or another class names as a parent,
    /// stays; a class nothing uses goes.
    func testRemovingAClassInUseIsRefused() throws {
        let dir = TemporaryDirectory("labels-refuse")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let model = LabelSetEditorModel(workspace: try XCTUnwrap(doc.workspace))
        let lesion = try XCTUnwrap(model.classes.first { $0.classID == 9 })
        let why = try XCTUnwrap(model.removeClass(lesion.id))
        XCTAssertTrue(why.contains("organs_tp0"), why)
        XCTAssertTrue(why.contains("lesions_tp0"), why)
        XCTAssertNotNil(model.row(lesion.id), "still there")
        XCTAssertEqual(model.refusal, [why])

        let kidney = try XCTUnwrap(model.classes.first { $0.classID == 4 })
        let users = model.users(ofClass: 4)
        XCTAssertTrue(users.contains("class left_kidney (as its parent)"), "\(users)")
        XCTAssertNotNil(model.removeClass(kidney.id))

        // An id in use keeps its id.
        model.setClassID(lesion.id, "40")
        XCTAssertEqual(model.row(lesion.id)?.classID, 9)
        XCTAssertFalse(model.refusal.isEmpty)

        let added = try XCTUnwrap(model.addClass())
        XCTAssertNil(model.removeClass(added), "nothing uses a new class")
        XCTAssertNil(model.row(added))
        XCTAssertFalse(model.isDirty)

        // The draft's own checks: a duplicate key is caught before the engine.
        let other = try XCTUnwrap(model.addClass())
        model.setText(other, "key", "liver", required: true)
        XCTAssertEqual(model.problems[other], "key liver is used twice")
    }

    /// The engine refuses a label set its rules reject (a hierarchy cycle).
    func testTheEngineRefusesACycle() async throws {
        let dir = TemporaryDirectory("labels-cycle")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = LabelSetEditorModel(workspace: workspace)
        let kidney = try XCTUnwrap(model.classes.first { $0.classID == 4 })
        model.toggleParent(kidney.id, 5)   // left kidney is a kidney: a cycle
        await model.apply()
        XCTAssertTrue(model.refusal.joined().contains("E304"), "\(model.refusal)")
        XCTAssertNil(workspace.pendingEdits.labelSet)
    }
}
