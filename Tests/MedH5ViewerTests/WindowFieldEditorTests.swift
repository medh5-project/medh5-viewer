import XCTest
import AppKit
@testable import MedH5ViewerUI

/// The document window's text fields (the inspector's numbers, the
/// sidebar's search) undo typing on their own, as the panels' do: on the
/// document's undo manager, typing would mark the document edited.
@MainActor
final class WindowFieldEditorTests: XCTestCase {
    func testTypingInTheWindowLeavesTheDocumentUnedited() async throws {
        let dir = TemporaryDirectory("field-undo")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertTrue(window.undoManager === doc.undoManager, "Edit ▸ Undo outside a field takes back the document's edits")
        let field = NSTextField(string: "")
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
        XCTAssertTrue(editor is PanelFieldEditor)
        XCTAssertNotNil(editor.undoManager)
        XCTAssertFalse(editor.undoManager === doc.undoManager, "typing is undone on its own")
        editor.insertText("12", replacementRange: editor.selectedRange())
        await settle()
        window.makeFirstResponder(nil)
        await settle()
        XCTAssertEqual(field.stringValue, "12")
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertFalse(doc.undoManager?.canUndo ?? true)
    }
}
