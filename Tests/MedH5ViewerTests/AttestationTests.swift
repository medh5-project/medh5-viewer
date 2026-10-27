import XCTest
import AppKit
@testable import MedH5ViewerUI
import MedH5Kit

/// What a clinical event attests is immutable (format 1.1 §7.3): the engine
/// refuses to amend an annotation holding it (E809), so the tools refuse to
/// edit it up front, and the automatic target passes it over.
@MainActor
final class AttestationTests: XCTestCase {
    func testAnnotationsHoldingAttestedInstancesAreNotEdited() async throws {
        let dir = TemporaryDirectory("attested")
        let doc = try openDocument(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        w.editing.show("lesion_boxes_tp0")
        try await w.loadNeeded()
        let s = w.editing
        let deadline = Date().addingTimeInterval(10)
        while s.attestations.instances.isEmpty && Date() < deadline { await settle() }
        XCTAssertEqual(s.attestations.instances[1], "response1", "the demo's response event attests lesion instance 1")
        let why = try XCTUnwrap(s.attestation(of: "lesion_boxes_tp0"), "its box 1 is instance 1")
        XCTAssertTrue(why.contains("response1"))
        XCTAssertNil(s.attestation(of: "liver_contours_tp0"))

        w.setCursor(Demo.lesionCentre, from: .slice(.axial))
        w.viewer.activeViewport = .slice(.axial)
        let driver = ToolDriver(workspace: w)
        s.annotationClassID = 9
        s.select(.box)
        // Automatically, the attested boxes are passed over: a new annotation.
        XCTAssertNil(s.activeAnnotation(for: .box))
        driver.drag([driver.offset(Demo.lesionCentre, -10, -10), driver.offset(Demo.lesionCentre, 10, 10)])
        await settle()
        XCTAssertNotEqual(s.listedAnnotation, "lesion_boxes_tp0")
        XCTAssertEqual(s.draft("lesion_boxes_tp0")?.itemCount, 3)
        // Chosen explicitly, they are refused, with why.
        s.choose(annotation: "lesion_boxes_tp0")
        driver.drag([driver.offset(Demo.lesionCentre, -20, -20), driver.offset(Demo.lesionCentre, 20, 20)])
        XCTAssertEqual(s.message?.isError, true)
        XCTAssertTrue(s.message?.text.contains("attests") ?? false, s.message?.text ?? "")
        XCTAssertEqual(s.draft("lesion_boxes_tp0")?.itemCount, 3)
        s.select(items: [0], of: "lesion_boxes_tp0")
        XCTAssertFalse(s.canEditListedItems)
        XCTAssertThrowsError(try s.deleteSelectedItems())
        XCTAssertNil(doc.pendingEdits.annotations["lesion_boxes_tp0"])
        // The save writes the new annotation.
        await settle()
        let out = dir.file("saved.medh5")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: out, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
    }
}
