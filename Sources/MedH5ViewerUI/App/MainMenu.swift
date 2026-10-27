import AppKit
import MedH5Kit
import MedH5Render

/// The main menu, built in code (no nib): File, Edit, View, Image,
/// Segmentation, Tools, Window, Help. The document's panel and file
/// commands are the document's (`MedH5Document+Windows`): it is in the
/// responder chain of its main window and of its panels. The editing
/// commands are the document window's (`DocumentWindowController+Editing`).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu(title: "Main")
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(segmentationMenu()))
        main.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command], represented: Any? = nil,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.representedObject = represented
        item.target = target
        if action == nil { item.isEnabled = false }
        menu.addItem(item)
        return item
    }

    private static func group(_ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        m.autoenablesItems = true
        return m
    }

    // MARK: Menus

    static func appMenu() -> NSMenu {
        let m = group("medh5 Viewer")
        add(m, "About medh5 Viewer", #selector(AppDelegate.showAbout(_:)))
        m.addItem(.separator())
        add(m, "Settings…", #selector(AppDelegate.showPreferences(_:)), ",")
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = add(m, "Services", nil)
        servicesItem.submenu = services
        servicesItem.isEnabled = true
        NSApp.servicesMenu = services
        m.addItem(.separator())
        add(m, "Hide medh5 Viewer", #selector(NSApplication.hide(_:)), "h")
        add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        m.addItem(.separator())
        add(m, "Quit medh5 Viewer", #selector(NSApplication.terminate(_:)), "q")
        return m
    }

    static func fileMenu() -> NSMenu {
        let m = group("File")
        add(m, "New Sample from NIfTI…", #selector(AppDelegate.newSampleFromNIfTI(_:)), "n", [.command, .shift])
        add(m, "New Collection from Samples…", #selector(AppDelegate.newCollectionFromSamples(_:)))
        add(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenu(title: "Open Recent")
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        let recentItem = add(m, "Open Recent", nil)
        recentItem.submenu = recent
        recentItem.isEnabled = true
        add(m, "Open Demo Sample", #selector(AppDelegate.openDemoSample(_:)))
        m.addItem(.separator())
        add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(m, "Save", #selector(NSDocument.save(_:)), "s")
        add(m, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(m, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        m.addItem(.separator())
        let importMenu = NSMenu(title: "Import")
        add(importMenu, "NIfTI Image…", #selector(MedH5Document.importNIfTIImage(_:)))
        add(importMenu, "NIfTI Segmentation…", #selector(MedH5Document.importNIfTISegmentation(_:)))
        let importItem = add(m, "Import", nil)
        importItem.submenu = importMenu
        importItem.isEnabled = true
        let export = NSMenu(title: "Export")
        add(export, "NIfTI…", #selector(MedH5Document.exportNIfTI(_:)))
        add(export, "Screenshot…", #selector(DocumentWindowController.exportScreenshot(_:)), "e", [.command, .shift])
        add(export, "Measurements (CSV)…", #selector(DocumentWindowController.exportMeasurements(_:)))
        let exportItem = add(m, "Export", nil)
        exportItem.submenu = export
        exportItem.isEnabled = true
        return m
    }

    static func editMenu() -> NSMenu {
        let m = group("Edit")
        add(m, "Undo", Selector(("undo:")), "z")
        add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
        m.addItem(.separator())
        add(m, "Cut", #selector(NSText.cut(_:)), "x")
        add(m, "Copy", #selector(NSText.copy(_:)), "c")
        add(m, "Paste", #selector(NSText.paste(_:)), "v")
        add(m, "Delete", #selector(NSText.delete(_:)))
        add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        return m
    }

    static func viewMenu() -> NSMenu {
        let m = group("View")
        for layout in ViewerLayout.allCases {
            add(m, layout.title, #selector(DocumentWindowController.selectLayout(_:)), layout.key, [], represented: layout.rawValue)
        }
        let planes = NSMenu(title: "Single View Plane")
        for (plane, key) in [(ViewPlane.axial, "a"), (.coronal, "c"), (.sagittal, "s")] {
            add(planes, plane.title, #selector(DocumentWindowController.selectSinglePlane(_:)), key, [.command, .option],
                represented: plane.rawValue)
        }
        let planesItem = add(m, "Single View Plane", nil)
        planesItem.submenu = planes
        planesItem.isEnabled = true
        m.addItem(.separator())
        add(m, "Anatomical Planes", #selector(DocumentWindowController.setAnatomicalPlanes(_:)))
        add(m, "Aligned Planes", #selector(DocumentWindowController.setAlignedPlanes(_:)))
        m.addItem(.separator())
        add(m, "Show Crosshair", #selector(DocumentWindowController.toggleCrosshair(_:)), "x", [.command, .option])
        add(m, "Show Overlays", #selector(DocumentWindowController.toggleOverlays(_:)), "o", [.command, .option])
        add(m, "Show Orientation Labels", #selector(DocumentWindowController.toggleOrientationLabels(_:)))
        let interpolation = NSMenu(title: "Interpolation")
        for (i, title) in [(Interpolation.nearest, "Nearest"), (.linear, "Linear"), (.cubic, "Cubic")] {
            add(interpolation, title, #selector(DocumentWindowController.selectInterpolation(_:)), represented: i.rawValue)
        }
        let interpolationItem = add(m, "Interpolation", nil)
        interpolationItem.submenu = interpolation
        interpolationItem.isEnabled = true
        let slab = NSMenu(title: "Thick Slab")
        for mode in SlabMode.allCases {
            add(slab, mode.title, #selector(DocumentWindowController.selectSlabMode(_:)), represented: mode.rawValue)
        }
        slab.addItem(.separator())
        for mm in [5.0, 10, 20, 40] {
            add(slab, "\(Int(mm)) mm", #selector(DocumentWindowController.selectSlabThickness(_:)), represented: mm)
        }
        let slabItem = add(m, "Thick Slab", nil)
        slabItem.submenu = slab
        slabItem.isEnabled = true
        m.addItem(.separator())
        add(m, "Reset View", #selector(DocumentWindowController.resetView(_:)), "0")
        add(m, "Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "=")
        add(m, "Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-")
        m.addItem(.separator())
        add(m, "Hide Sidebar", #selector(DocumentWindowController.toggleSidebar(_:)), "s", [.command, .control])
        add(m, "Hide Inspector", #selector(DocumentWindowController.toggleInspector(_:)), "i", [.command, .option])
        add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return m
    }

    static func imageMenu() -> NSMenu {
        let m = group("Image")
        let presets = NSMenu(title: "Window Presets")
        presets.delegate = WindowPresetMenuDelegate.shared
        let presetsItem = add(m, "Window Presets", nil)
        presetsItem.submenu = presets
        presetsItem.isEnabled = true
        add(m, "Auto Window", #selector(DocumentWindowController.autoWindow(_:)), "w", [.command, .option])
        let colormaps = NSMenu(title: "Colormap")
        for map in Colormap.allCases {
            add(colormaps, map.displayName, #selector(DocumentWindowController.selectColormap(_:)), represented: map.rawValue)
        }
        let colormapItem = add(m, "Colormap", nil)
        colormapItem.submenu = colormaps
        colormapItem.isEnabled = true
        add(m, "Invert", #selector(DocumentWindowController.toggleInvert(_:)), "i", [.command, .shift])
        m.addItem(.separator())
        add(m, "Next Timepoint", #selector(DocumentWindowController.nextTimepoint(_:)), "]")
        add(m, "Previous Timepoint", #selector(DocumentWindowController.previousTimepoint(_:)), "[")
        add(m, "Next Channel", #selector(DocumentWindowController.nextChannel(_:)), "]", [.command, .option])
        add(m, "Previous Channel", #selector(DocumentWindowController.previousChannel(_:)), "[", [.command, .option])
        return m
    }

    static func segmentationMenu() -> NSMenu {
        let m = group("Segmentation")
        add(m, "New Segmentation…", #selector(DocumentWindowController.newSegmentation(_:)))
        add(m, "Add Class…", #selector(DocumentWindowController.addSegmentClass(_:)))
        m.addItem(.separator())
        let tools = NSMenu(title: "Tools")
        for tool in ViewerTool.segmentationTools {
            let item = add(tools, tool.title, #selector(DocumentWindowController.selectTool(_:)), represented: tool.rawValue)
            item.toolTip = tool.help
        }
        tools.addItem(.separator())
        add(tools, "Larger Brush", #selector(DocumentWindowController.largerBrush(_:)), "]", [])
        add(tools, "Smaller Brush", #selector(DocumentWindowController.smallerBrush(_:)), "[", [])
        let toolsItem = add(m, "Tools", nil)
        toolsItem.submenu = tools
        toolsItem.isEnabled = true
        let operations = NSMenu(title: "Operations")
        for operation in SegmentOperationKind.allCases {
            let item = add(operations, operation.menuTitle, #selector(DocumentWindowController.segmentOperation(_:)),
                           represented: operation.rawValue)
            item.toolTip = operation.help
        }
        let operationsItem = add(m, "Operations", nil)
        operationsItem.submenu = operations
        operationsItem.isEnabled = true
        m.addItem(.separator())
        add(m, "Show Outline Only", #selector(DocumentWindowController.toggleOutlineOnly(_:)), "l", [.command, .option])
        add(m, "Hide All Segmentations", #selector(DocumentWindowController.hideAllSegmentations(_:)), "h", [.command, .option, .shift])
        return m
    }

    static func toolsMenu() -> NSMenu {
        let m = group("Tools")
        for tool in ViewerTool.allCases {
            let (key, shift) = tool.key
            let item = add(m, tool.title, #selector(DocumentWindowController.selectTool(_:)), key, shift ? [.shift] : [],
                           represented: tool.rawValue)
            item.toolTip = tool.help
            if tool == .zoom { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        add(m, "Validate…", #selector(MedH5Document.showValidation(_:)), "v", [.command, .shift])
        add(m, "Verify Integrity", #selector(MedH5Document.verifyIntegrity(_:)))
        add(m, "Build Sampling Index…", #selector(MedH5Document.buildSamplingIndex(_:)))
        add(m, "Recompress…", #selector(MedH5Document.recompressSample(_:)))
        return m
    }

    static func windowMenu() -> NSMenu {
        let m = group("Window")
        add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        m.addItem(.separator())
        add(m, "Document", #selector(MedH5Document.showDocumentEditor(_:)), "d", [.command, .option])
        add(m, "Label Set", #selector(MedH5Document.showLabelSetEditor(_:)))
        add(m, "Clinical History", #selector(MedH5Document.showClinicalHistory(_:)))
        m.addItem(.separator())
        add(m, "Welcome to medh5 Viewer", #selector(AppDelegate.showWelcome(_:)), "1", [.command, .shift])
        m.addItem(.separator())
        add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return m
    }

    static func helpMenu() -> NSMenu {
        let m = group("Help")
        add(m, "medh5 Viewer Help", #selector(AppDelegate.showHelp(_:)), "?")
        add(m, "Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)))
        add(m, "medh5 Documentation", #selector(AppDelegate.showDocumentation(_:)))
        m.addItem(.separator())
        add(m, "Open Demo Sample", #selector(AppDelegate.openDemoSample(_:)))
        m.addItem(.separator())
        add(m, "Acknowledgements", #selector(AppDelegate.showAcknowledgements(_:)))
        add(m, "Report an Issue", #selector(AppDelegate.reportIssue(_:)))
        return m
    }
}

/// Fills Image ▸ Window Presets with the base image's presets when it opens.
@MainActor
final class WindowPresetMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = WindowPresetMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.keyWindow?.windowController as? DocumentWindowController
            ?? NSApp.mainWindow?.windowController as? DocumentWindowController
        let items = controller?.windowPresetItems() ?? []
        if items.isEmpty {
            let none = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for item in items {
            item.target = controller
            menu.addItem(item)
        }
    }
}
