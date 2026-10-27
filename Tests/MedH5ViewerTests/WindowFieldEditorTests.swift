import XCTest
import AppKit
@testable import MedH5ViewerUI

/// The document window's text fields (the inspector's numbers, the
/// sidebar's search) undo typing on their own, as the panels' do: on the
/// document's undo manager, typing would mark the document edited.
@MainActor
final class WindowFieldEditorTests: XCTestCase {
    func testTheWindowsTextFieldsUndoTypingOnTheirOwn() throws {
        let dir = TemporaryDirectory("field-undo")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertTrue(window.undoManager === doc.undoManager, "Edit ▸ Undo outside a field takes back the document's edits")
        let editor = try XCTUnwrap(window.fieldEditor(true, for: NSTextField()) as? NSTextView)
        XCTAssertTrue(editor is PanelFieldEditor)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertNotNil(editor.undoManager)
        XCTAssertFalse(editor.undoManager === doc.undoManager, "a field's typing is undone on its own")
        XCTAssertTrue(window.fieldEditor(true, for: NSTextField()) === editor, "one field editor for the window")
        XCTAssertFalse(window.fieldEditor(true, for: nil) is PanelFieldEditor, "other clients get AppKit's")
        XCTAssertFalse(doc.isDocumentEdited)
    }
}
