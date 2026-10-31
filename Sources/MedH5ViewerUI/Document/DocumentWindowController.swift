import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MedH5Kit
import MedH5Render

/// The document window: SwiftUI content in an `NSHostingController` whose
/// toolbar items become the window's toolbar (`sceneBridgingOptions`), and
/// the target of the View, Image, Segmentation and Tools menus (it sits in
/// the responder chain after the views).
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        let hosting = NSHostingController(rootView: DocumentWindowView(workspace: workspace))
        hosting.sceneBridgingOptions = [.toolbars]
        // The window's minimum size is set below; SwiftUI's ideal and minimum
        // sizes never resize the window.
        hosting.sizingOptions = []
        let window = DocumentWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        // The toolbar needs the title's width for its own items in a window
        // of the default size; the title stays in the Window menu, Mission
        // Control and tabs, and the sidebar names the subject and sample.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "medh5-document"
        window.setContentSize(NSSize(width: 1440, height: 880))
        window.minSize = NSSize(width: PanelLimits.minimumWindowWidth, height: 560)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { displayName }

    func windowWillClose(_ notification: Notification) {
        workspace.shutDown()
    }

    /// The window's text fields (the inspector's numbers and names, the
    /// sidebar's search) edit with a field editor of their own, as the
    /// panels' do (`PanelFieldEditor`): typing is undone on its own, so it
    /// never marks the document edited; outside a field, Edit ▸ Undo takes
    /// back the document's edits.
    private let fieldEditor: PanelFieldEditor = {
        let editor = PanelFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? fieldEditor : nil
    }

    private var viewer: ViewerModel { workspace.viewer }

    // MARK: View menu

    @objc func selectLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let layout = ViewerLayout(rawValue: raw) else { return }
        workspace.setLayout(layout)
    }

    @objc func selectSinglePlane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let plane = ViewPlane(rawValue: raw) else { return }
        viewer.singlePlane = plane
        viewer.comparePlane = plane
        if viewer.layout != .single && viewer.layout != .compare { workspace.setLayout(.single) }
    }

    @objc func setAnatomicalPlanes(_ sender: Any?) { viewer.orientation = .anatomical; viewer.resetFraming() }
    @objc func setAlignedPlanes(_ sender: Any?) { viewer.orientation = .aligned; viewer.resetFraming() }
    @objc func toggleCrosshair(_ sender: Any?) { viewer.showsCrosshair.toggle() }
    @objc func toggleOverlays(_ sender: Any?) { viewer.showsOverlays.toggle() }
    @objc func toggleOrientationLabels(_ sender: Any?) { viewer.showsOrientationLabels.toggle() }

    @objc func selectInterpolation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let i = Interpolation(rawValue: raw) else { return }
        for layer in workspace.activeStack.layers where layer.isImage { layer.interpolation = i }
    }

    @objc func selectSlabMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SlabMode(rawValue: raw) else { return }
        viewer.slab.mode = mode
    }

    /// Choosing a thickness while the slab is off turns on a MIP.
    @objc func selectSlabThickness(_ sender: NSMenuItem) {
        guard let mm = sender.representedObject as? Double else { return }
        viewer.slab.thickness = mm
        if viewer.slab.mode == .none { viewer.slab.mode = .maximum }
    }

    @objc func resetView(_ sender: Any?) { viewer.resetFraming() }
    @objc func zoomIn(_ sender: Any?) { viewer.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { viewer.zoom(by: 0.8) }
    @objc func zoomToActualFit(_ sender: Any?) { viewer.views = [:] }
    @objc func toggleInspector(_ sender: Any?) { workspace.showsInspector.toggle() }

    @objc func toggleSidebar(_ sender: Any?) {
        workspace.showsSidebar.toggle()
    }

    // MARK: Image menu

    @objc func applyWindowPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? WindowPresetBox, let base = workspace.activeStack.base else { return }
        base.apply(preset.preset)
    }

    @objc func autoWindow(_ sender: Any?) {
        guard let base = workspace.activeStack.base, let info = workspace.summary.image(base.id),
              let grid = workspace.summary.grid(info.grid),
              let h = workspace.store.ready(.histogram(base.id, frame: base.frameIndex(for: grid)), as: HistogramResource.self)
        else { return NSSound.beep() }
        base.apply(WindowLevel.automatic(h))
    }

    @objc func selectColormap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let map = Colormap(rawValue: raw) else { return }
        workspace.activeStack.base?.colormap = map
    }

    @objc func toggleInvert(_ sender: Any?) { workspace.activeStack.base?.invert.toggle() }
    @objc func nextTimepoint(_ sender: Any?) { workspace.stepTimepoint(1) }
    @objc func previousTimepoint(_ sender: Any?) { workspace.stepTimepoint(-1) }

    @objc func nextChannel(_ sender: Any?) { stepChannel(1) }
    @objc func previousChannel(_ sender: Any?) { stepChannel(-1) }

    private func stepChannel(_ delta: Int) {
        guard let base = workspace.primary.base, let channels = ViewerControls.frameAxes(workspace).channel else { return }
        base.channelIndex = (base.channelIndex + delta + channels.count) % channels.count
    }

    // MARK: Segmentation menu

    @objc func toggleOutlineOnly(_ sender: Any?) {
        let segs = workspace.activeStack.layers.filter { [.segmentation, .instances, .mask].contains($0.kind) }
        let outlineOnly = segs.allSatisfy { $0.labelStyle == .outline }
        for s in segs { s.labelStyle = outlineOnly ? .fillAndOutline : .outline }
    }

    @objc func hideAllSegmentations(_ sender: Any?) {
        let segs = workspace.activeStack.layers.filter { [.segmentation, .instances, .mask, .probability].contains($0.kind) }
        let anyVisible = segs.contains { $0.isVisible }
        for s in segs { s.isVisible = !anyVisible }
    }

    // MARK: Tools menu

    @objc func selectTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = ViewerTool(rawValue: raw), tool.isAvailable else { return }
        workspace.editing.select(tool)
    }

    // MARK: File menu

    @objc func exportScreenshot(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(workspace.displayName.replacingOccurrences(of: ".medh5", with: "")) \(viewer.activeViewport).png"
        let scaleBox = NSPopUpButton(frame: .zero, pullsDown: false)
        scaleBox.addItems(withTitles: ["View resolution", "2× resolution"])
        scaleBox.selectItem(at: 1)
        panel.accessoryView = scaleBox
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let pixelsPerPoint = Double(window.backingScaleFactor) * (scaleBox.indexOfSelectedItem == 1 ? 2 : 1)
            do {
                let render: CGImage?
                let container: ViewportContainerView?
                if self.viewer.activeViewport == .volume {
                    container = self.workspace.viewports.volume?.container
                    render = try self.workspace.viewports.volume?.renderImage(scale: pixelsPerPoint)
                } else {
                    let slice = self.workspace.viewports.slices[self.viewer.activeViewport]
                    container = slice?.container
                    render = try slice?.renderImage(scale: pixelsPerPoint)
                }
                guard let render, let container,
                      let image = WindowCapture.viewportImage(container, render: render, scale: CGFloat(pixelsPerPoint))
                else { throw StoreError.unsupported("The view has nothing to export") }
                try ImageExport.writePNG(image, to: url)
            } catch {
                self.workspace.alert = AppAlert(title: "The screenshot could not be saved", message: VolumeStore.describe(error))
            }
        }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if MenuValidation.isTypingInTextField(window), item.keyEquivalentModifierMask.isEmpty, !item.keyEquivalent.isEmpty {
            return false
        }
        if let enabled = validateEditingMenuItem(item) { return enabled }
        switch action {
        case #selector(selectLayout(_:)):
            item.state = (item.representedObject as? String) == viewer.layout.rawValue ? .on : .off
            if (item.representedObject as? String) == ViewerLayout.compare.rawValue { return workspace.timepointIDs.count > 1 }
        case #selector(selectSinglePlane(_:)):
            let current = viewer.layout == .compare ? viewer.comparePlane : viewer.singlePlane
            item.state = (viewer.layout == .single || viewer.layout == .compare)
                && (item.representedObject as? String) == current.rawValue ? .on : .off
        case #selector(setAnatomicalPlanes(_:)): item.state = viewer.orientation == .anatomical ? .on : .off
        case #selector(setAlignedPlanes(_:)): item.state = viewer.orientation == .aligned ? .on : .off
        case #selector(toggleCrosshair(_:)): item.state = viewer.showsCrosshair ? .on : .off
        case #selector(toggleOverlays(_:)): item.state = viewer.showsOverlays ? .on : .off
        case #selector(toggleOrientationLabels(_:)): item.state = viewer.showsOrientationLabels ? .on : .off
        case #selector(toggleInspector(_:)):
            item.title = workspace.showsInspector ? "Hide Inspector" : "Show Inspector"
        case #selector(toggleSidebar(_:)):
            item.title = workspace.showsSidebar ? "Hide Sidebar" : "Show Sidebar"
        case #selector(selectInterpolation(_:)):
            item.state = (item.representedObject as? String) == workspace.activeStack.base?.interpolation.rawValue ? .on : .off
            return workspace.activeStack.base != nil
        case #selector(selectSlabMode(_:)):
            item.state = (item.representedObject as? String) == viewer.slab.mode.rawValue ? .on : .off
            return workspace.primary.base != nil
        case #selector(selectSlabThickness(_:)):
            item.state = viewer.slab.isActive && (item.representedObject as? Double) == viewer.slab.thickness ? .on : .off
            return workspace.primary.base != nil
        case #selector(selectColormap(_:)):
            item.state = (item.representedObject as? String) == workspace.activeStack.base?.colormap.rawValue ? .on : .off
            return workspace.activeStack.base != nil
        case #selector(toggleInvert(_:)):
            item.state = workspace.activeStack.base?.invert == true ? .on : .off
            return workspace.activeStack.base != nil
        case #selector(applyWindowPreset(_:)), #selector(autoWindow(_:)):
            return workspace.activeStack.base != nil
        case #selector(nextTimepoint(_:)):
            return workspace.timepoint(of: workspace.primary).flatMap { workspace.timepointIDs.firstIndex(of: $0) }
                .map { $0 + 1 < workspace.timepointIDs.count } ?? false
        case #selector(previousTimepoint(_:)):
            return (workspace.timepoint(of: workspace.primary).flatMap { workspace.timepointIDs.firstIndex(of: $0) } ?? 0) > 0
        case #selector(nextChannel(_:)), #selector(previousChannel(_:)):
            return ViewerControls.frameAxes(workspace).channel != nil
        case #selector(selectTool(_:)):
            let tool = (item.representedObject as? String).flatMap(ViewerTool.init(rawValue:))
            item.state = tool == viewer.tool ? .on : .off
            return tool?.isAvailable ?? false
        case #selector(toggleOutlineOnly(_:)):
            let segs = workspace.activeStack.layers.filter { [.segmentation, .instances, .mask].contains($0.kind) }
            item.state = !segs.isEmpty && segs.allSatisfy { $0.labelStyle == .outline } ? .on : .off
            return !segs.isEmpty
        case #selector(hideAllSegmentations(_:)):
            let segs = workspace.activeStack.layers.filter { [.segmentation, .instances, .mask, .probability].contains($0.kind) }
            item.title = segs.contains { $0.isVisible } || segs.isEmpty ? "Hide All Segmentations" : "Show All Segmentations"
            return !segs.isEmpty
        case #selector(exportScreenshot(_:)):
            return workspace.store.context != nil
        default:
            break
        }
        return responds(to: action)
    }

    /// The Image ▸ Window Presets submenu is filled when it opens.
    func windowPresetItems() -> [NSMenuItem] {
        guard let base = workspace.activeStack.base, let info = workspace.summary.image(base.id) else { return [] }
        return WindowLevel.presets(for: info).map { p in
            let item = NSMenuItem(title: "\(p.name)  —  W \(Format.number(p.width)) · L \(Format.number(p.center))",
                                  action: #selector(applyWindowPreset(_:)), keyEquivalent: "")
            item.representedObject = WindowPresetBox(p)
            item.state = base.windowPreset == p.name ? .on : .off
            return item
        }
    }
}

/// A window preset carried by a menu item.
final class WindowPresetBox: NSObject {
    let preset: WindowPreset
    init(_ preset: WindowPreset) { self.preset = preset }
}

/// The document window class (its own type so the snapshot runner can find
/// document windows).
final class DocumentWindow: NSWindow {
    /// Off for snapshots: a window of any size, whatever the display (CI's
    /// is 1024 points wide).
    var fitsTheScreen = true

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        fitsTheScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    /// Stays hidden: on macOS 15 and 26 SwiftUI's toolbar makes it visible
    /// again, and the title takes its items' width. `toolbar(removing: .title)`
    /// is not the way: linked against an SDK before macOS 26, as a plain
    /// `swift build` with Swift 6.4 is, the app ends there on macOS 27.
    override var titleVisibility: NSWindow.TitleVisibility {
        get { .hidden }
        set { super.titleVisibility = .hidden }
    }
}

enum MenuValidation {
    /// Whether the key window's first responder is editing text (single-key
    /// shortcuts then belong to the text).
    static func isTypingInTextField(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}
