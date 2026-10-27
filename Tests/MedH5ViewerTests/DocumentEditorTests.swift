import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// The document editor: forms and the JSON editor change a draft; Apply has
/// the engine check it and makes it the pending document (undoable); the
/// save keeps members in order and integers apart from floats.
@MainActor
final class DocumentEditorTests: XCTestCase {
    func testNumbersKeepTheirKind() {
        XCTAssertEqual(JSONValue.number(from: "92", like: .int(91)), .some(.int(92)))
        XCTAssertEqual(JSONValue.number(from: "92", like: .double(91.5)), .some(.double(92)), "an integer typed over a float stays a float")
        XCTAssertEqual(JSONValue.number(from: "0.5", like: .int(1)), .some(.double(0.5)), "a decimal point makes a float")
        XCTAssertEqual(JSONValue.number(from: "1e3", like: nil), .some(.double(1000)))
        XCTAssertEqual(JSONValue.number(from: "−3", like: nil), .some(.int(-3)), "the typographic minus the app writes")
        XCTAssertEqual(JSONValue.number(from: "", like: .int(1)), .some(nil), "empty removes the member")
        XCTAssert(JSONValue.number(from: "12 mm", like: nil) == nil, "not a number")
        XCTAssertEqual(JSONValue.int(92).numberText, "92")
        XCTAssertEqual(JSONValue.double(92).numberText, "92.0", "a float shows as one")
    }

    func testPathsSetAndRemoveMembersInPlace() throws {
        var doc: JSONValue = ["identity": ["sample_id": "s", "subject_id": "p"], "timepoints": [["id": "tp0", "index": 0]]]
        doc.set(.string("ABDOMEN"), at: [.key("identity"), .key("bodypart")])
        doc.set(.string("S2"), at: [.key("identity"), .key("sample_id")])
        XCTAssertEqual(doc["identity"]?.objectValue?.keys, ["sample_id", "subject_id", "bodypart"], "an edit keeps its place, a new member goes last")
        doc.set(.int(3), at: [.key("timepoints"), .index(0), .key("days_from_baseline")])
        XCTAssertEqual(doc.value(at: [.key("timepoints"), .index(0), .key("days_from_baseline")]), .int(3))
        doc.set(nil, at: [.key("identity"), .key("bodypart")])
        XCTAssertNil(doc["identity"]?["bodypart"])
        doc.set(.string("x"), at: [.key("extra"), .key("org.viewer"), .key("note")])
        XCTAssertEqual(doc["extra"]?["org.viewer"]?["note"], "x", "objects on the way are made")
        XCTAssertEqual(JSONValue.pointer([.key("timepoints"), .index(0), .key("a/b")]), "/timepoints/0/a~1b")
        let bad = "{\n  \"a\": 1\n  \"b\": 2}"
        do {
            _ = try JSONValue.parse(bad)
            XCTFail("parsed")
        } catch let error as JSONParseError {
            XCTAssertEqual(error.describe(in: bad), "Line 3, column 3: expected , or }")
        }
    }

    /// Forms edit identity, a timepoint, quality and de-identification;
    /// Apply goes through the engine into the pending edits (undoable); the
    /// saved file holds the edits with members in order and every number of
    /// its kind, and validates.
    func testFormsApplyUndoAndSaveKeepOrderAndNumberKinds() async throws {
        let dir = TemporaryDirectory("doc-editor")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = DocumentEditorModel(workspace: workspace)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.string([.key("identity"), .key("sample_id")]), "demo-abdomen-01")

        model.setString([.key("identity"), .key("bodypart")], "CHEST_ABDOMEN")
        model.setString([.key("identity"), .key("laterality")], "bilateral")
        let tp1 = try XCTUnwrap(model.timepoints.firstIndex { $0["id"] == "tp1" })
        model.setValue(.int(93), at: [.key("timepoints"), .index(tp1), .key("days_from_baseline")])
        model.setString([.key("timepoints"), .index(tp1), .key("date")], "2026-04-02")
        model.setValue(.double(0.95), at: [.key("quality"), .key("organs_tp0"), .key("confidence")])
        model.setReviewers("organs_tp0", "rad2, rad3")
        model.setValue(.int(-14), at: [.key("deidentification"), .key("date_shift_days")])
        model.setString([.key("cohort"), .key("site_id")], "")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(workspace.pendingEdits.isEmpty, "nothing is pending before Apply")

        await model.apply()
        XCTAssertEqual(model.refusal, [])
        XCTAssertFalse(model.isDirty)
        let pending = try XCTUnwrap(workspace.pendingEdits.document)
        XCTAssertEqual(pending["identity"]?["bodypart"], "CHEST_ABDOMEN")
        try await endEvent()
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(doc.undoManager?.undoActionName, "Edit Document")
        doc.undoManager?.undo()
        try await endEvent()
        XCTAssertNil(workspace.pendingEdits.document, "undo takes the edit back")
        model.sync()
        XCTAssertEqual(model.string([.key("identity"), .key("bodypart")]), "ABDOMEN", "the editor follows the undo")
        doc.undoManager?.redo()
        try await endEvent()
        XCTAssertNotNil(workspace.pendingEdits.document)

        let out = dir.file("edited.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let stored = try saved.documentText()
        XCTAssertEqual(try JSONValue.parse(stored).serialized(.meta), stored, "/meta is the engine's bytes")
        let d = try JSONValue.parse(stored)
        XCTAssertEqual(d.objectValue?.keys.prefix(2), ["identity", "timepoints"])
        XCTAssertEqual(d["identity"]?.objectValue?.keys, ["sample_id", "subject_id", "sex", "laterality", "bodypart"])
        XCTAssertEqual(d["identity"]?["bodypart"], "CHEST_ABDOMEN")
        XCTAssertEqual(d["timepoints"]?[1]?["days_from_baseline"], .int(93), "an integer stays an integer")
        XCTAssertEqual(d["timepoints"]?[0]?["days_from_baseline"], .int(0))
        XCTAssertEqual(d["timepoints"]?[1]?["date"], "2026-04-02")
        XCTAssertEqual(d["quality"]?["organs_tp0"]?["confidence"], .double(0.95))
        XCTAssertEqual(d["quality"]?["organs_tp0"]?["reviewed_by"], .strings(["rad2", "rad3"]))
        XCTAssertEqual(d["quality"]?["organs_tp1"]?["confidence"], .double(0.97), "untouched floats stay floats")
        XCTAssertEqual(d["acquisition"]?["CT_tp0"]?["KVP"], .int(120))
        XCTAssertEqual(d["acquisition"]?["CT_tp0"]?["SliceThickness"], .double(12.5))
        XCTAssertEqual(d["acquisition"]?["CT_tp0"]?.objectValue?.keys, ["KVP", "SliceThickness", "ContrastBolusAgent"])
        XCTAssertEqual(d["deidentification"]?["date_shift_days"], .int(-14))
        XCTAssertNil(d["cohort"]?["site_id"])
        XCTAssertEqual(d["cohort"]?["dataset_id"], "medh5-viewer-demo")
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
        XCTAssertNil(workspace.pendingEdits.document, "what was saved is no longer pending")
    }

    /// The JSON editor parses as the user types; the engine refuses a
    /// document its schema rejects, and the editor shows why.
    func testTheEngineRefusesABadDocument() async throws {
        let dir = TemporaryDirectory("doc-refuse")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = DocumentEditorModel(workspace: workspace)
        let good = model.jsonText

        model.setJSONText("{\"identity\": ")
        XCTAssertNotNil(model.jsonError)
        XCTAssertTrue(model.jsonError?.hasPrefix("Line 1") ?? false, model.jsonError ?? "")
        await model.apply()
        XCTAssertFalse(model.refusal.isEmpty, "unparsed text is not applied")
        XCTAssertNil(workspace.pendingEdits.document)

        model.setJSONText(good)
        XCTAssertNil(model.jsonError)
        model.setString([.key("identity"), .key("sex")], "X")
        await model.apply()
        XCTAssertFalse(model.refusal.isEmpty)
        XCTAssertTrue(model.refusal.joined().contains("sex"), "\(model.refusal)")
        XCTAssertNil(workspace.pendingEdits.document, "a refused document is not applied")
        XCTAssertTrue(model.isDirty, "the draft stays for the user to fix")

        model.setString([.key("identity"), .key("sex")], "M")
        var removed = model.draft
        removed.set(nil, at: [.key("identity"), .key("subject_id")])
        model.setJSONText(removed.serialized(.editing))
        await model.apply()
        XCTAssertTrue(model.refusal.joined().contains("subject_id"), "\(model.refusal)")
        XCTAssertNil(workspace.pendingEdits.document)
    }

    /// A timepoint a grid belongs to stays; one added in the draft can be
    /// renamed and removed, and the others keep dense indices.
    func testTimepointsAndQualityRecordsInUseStay() throws {
        let dir = TemporaryDirectory("doc-tp")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let model = DocumentEditorModel(workspace: try XCTUnwrap(doc.workspace))
        model.removeTimepoint(0)
        XCTAssertTrue(model.refusal.first?.contains("grid ct_tp0") ?? false, "\(model.refusal)")
        XCTAssertEqual(model.timepoints.count, 2)
        model.addTimepoint()
        XCTAssertEqual(model.timepoints.count, 3)
        XCTAssertEqual(model.timepoints[2]["index"], .int(2))
        XCTAssertTrue(model.isNewTimepoint(2))
        model.renameTimepoint(2, to: "tp_extra")
        XCTAssertEqual(model.timepoints[2]["id"], "tp_extra")
        model.removeTimepoint(2)
        XCTAssertEqual(model.timepoints.count, 2)
        XCTAssertFalse(model.isDirty, "adding and removing leaves the document as it was")

        model.removeQuality("organs_tp0")
        XCTAssertTrue(model.refusal.first?.contains("organs_tp0") ?? false)
        XCTAssertNil(model.addQuality("review_2026"))
        XCTAssertNotNil(model.addQuality("review_2026"), "a key once")
        XCTAssertEqual(model.value([.key("quality"), .key("review_2026"), .key("status")]), "draft")
        model.removeQuality("review_2026")
        XCTAssertFalse(model.qualityKeys.contains("review_2026"))

        model.setHasDeidentification(false)
        XCTAssertNil(model.draft["deidentification"])
        let outline = model.outline
        XCTAssertEqual(outline.map(\.key).first, "identity")
        XCTAssertEqual(outline.first { $0.key == "timepoints" }?.children?.first?.key, "[0]  tp0")
    }

    /// A read-only document (a collection member) shows the document and
    /// applies nothing.
    func testAReadOnlyDocumentIsShownNotEdited() async throws {
        let dir = TemporaryDirectory("doc-ro")
        let doc = try MedH5Document.untitled(from: Fixtures.demoCopy(in: dir), name: "member", readOnly: [.collectionMember("m")])
        doc.makeWindowControllers()
        defer { doc.close() }
        let model = DocumentEditorModel(workspace: try XCTUnwrap(doc.workspace))
        XCTAssertTrue(model.isReadOnly)
        model.setString([.key("identity"), .key("bodypart")], "HEAD")
        await model.apply()
        XCTAssertEqual(model.refusal, ["This document is read-only."])
        XCTAssertTrue(doc.pendingEdits.isEmpty)
    }
}
