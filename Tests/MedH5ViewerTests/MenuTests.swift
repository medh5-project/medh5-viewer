import XCTest
import AppKit
@testable import MedH5ViewerUI

/// The main menu: every menu of the design, the viewing tools enabled, the
/// editing phase's items present and disabled.
@MainActor
final class MenuTests: XCTestCase {
    func testTheMainMenuHasEveryMenuOfTheDesign() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        XCTAssertEqual(menu.items.map(\.title),
                       ["medh5 Viewer", "File", "Edit", "View", "Image", "Segmentation", "Tools", "Window", "Help"])
        func item(_ path: String...) -> NSMenuItem? { find(path) }
        func find(_ path: [String]) -> NSMenuItem? {
            var current: NSMenu? = menu
            var found: NSMenuItem?
            for title in path {
                found = current?.items.first { $0.title == title }
                current = found?.submenu
            }
            return found
        }
        // Layouts on 1–5 without modifiers.
        for (title, key) in [("Single View", "1"), ("1 × 3", "2"), ("2 × 2", "3"), ("3-D Only", "4"), ("Compare Timepoints", "5")] {
            let i = try XCTUnwrap(item("View", title), title)
            XCTAssertEqual(i.keyEquivalent, key)
            XCTAssertTrue(i.keyEquivalentModifierMask.isEmpty)
            XCTAssertEqual(i.action, #selector(DocumentWindowController.selectLayout(_:)))
        }
        // The viewing tools have actions; the editing tools are present.
        for tool in ViewerTool.allCases {
            let i = try XCTUnwrap(item("Tools", tool.title), tool.title)
            XCTAssertEqual(i.action, #selector(DocumentWindowController.selectTool(_:)))
            XCTAssertEqual(i.representedObject as? String, tool.rawValue)
        }
        XCTAssertEqual(item("Tools", "Navigate")?.keyEquivalent, "v")
        XCTAssertEqual(item("Tools", "Box")?.keyEquivalentModifierMask, [.shift])
        // Phase B items: present, no action.
        for path in [["Segmentation", "New Segmentation…"], ["Segmentation", "Operations", "Fill Holes"]] {
            let i = try XCTUnwrap(find(path), path.joined(separator: " ▸ "))
            XCTAssertNil(i.action, path.joined(separator: " ▸ "))
        }
        // The panels and file commands: the document's (it is in the
        // responder chain of its main window and of its panels).
        let documentCommands: [([String], Selector)] = [
            (["File", "Import", "NIfTI Image…"], #selector(MedH5Document.importNIfTIImage(_:))),
            (["File", "Import", "NIfTI Segmentation…"], #selector(MedH5Document.importNIfTISegmentation(_:))),
            (["File", "Export", "NIfTI…"], #selector(MedH5Document.exportNIfTI(_:))),
            (["Tools", "Validate…"], #selector(MedH5Document.showValidation(_:))),
            (["Tools", "Verify Integrity"], #selector(MedH5Document.verifyIntegrity(_:))),
            (["Tools", "Build Sampling Index…"], #selector(MedH5Document.buildSamplingIndex(_:))),
            (["Tools", "Recompress…"], #selector(MedH5Document.recompressSample(_:))),
            (["Window", "Document"], #selector(MedH5Document.showDocumentEditor(_:))),
            (["Window", "Label Set"], #selector(MedH5Document.showLabelSetEditor(_:))),
            (["Window", "Clinical History"], #selector(MedH5Document.showClinicalHistory(_:))),
        ]
        for (path, action) in documentCommands {
            XCTAssertEqual(find(path)?.action, action, path.joined(separator: " ▸ "))
        }
        XCTAssertEqual(item("Tools", "Validate…")?.keyEquivalent, "v")
        XCTAssertEqual(item("Tools", "Validate…")?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item("Window", "Document")?.keyEquivalent, "d")
        XCTAssertEqual(item("Window", "Document")?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(item("File", "New Collection from Samples…")?.action, #selector(AppDelegate.newCollectionFromSamples(_:)))
        XCTAssertEqual(item("Help", "Keyboard Shortcuts")?.action, #selector(AppDelegate.showKeyboardShortcuts(_:)))
        XCTAssertEqual(item("Help", "Acknowledgements")?.action, #selector(AppDelegate.showAcknowledgements(_:)))
        XCTAssertEqual(item("Help", "medh5 Viewer Help")?.action, #selector(AppDelegate.showHelp(_:)))
        XCTAssertNotNil(item("File", "Export", "Screenshot…")?.action)
        XCTAssertNotNil(item("Help", "Open Demo Sample")?.action)
        XCTAssertNotNil(item("File", "Open Recent", "Clear Menu")?.action)
        XCTAssertEqual(item("File", "Save")?.keyEquivalent, "s")
        XCTAssertEqual(item("View", "Reset View")?.keyEquivalent, "0")
    }
}
