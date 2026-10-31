import AppKit
import MedH5Kit
import MedH5Render

/// Runs the snapshot mode: opens the document, configures the window as
/// asked, waits until everything visible is loaded and drawn, writes the
/// PNGs, prints their paths and exits (0, or 1 with the error on stderr).
@MainActor
final class SnapshotRunner {
    let options: SnapshotOptions
    private var document: NSDocument?
    private var started = Date()
    private var quietSince: Date?

    init(options: SnapshotOptions) {
        self.options = options
    }

    func start() {
        started = Date()
        (NSDocumentController.shared as? DocumentController)?.notesRecentDocuments = false
        (NSDocumentController.shared as? DocumentController)?.presentsErrors = false
        if let appearance = options.appearance { NSApp.appearance = NSAppearance(named: appearance) }
        MedH5Document.skipsVerification = !options.verify
        Task { @MainActor in
            do {
                try await run()
            } catch {
                fail(error)
            }
        }
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)
        if let name = options.auxiliaryWindow, AuxiliarySnapshot.windows.contains(name) {
            let doc = try await openDocument()
            document = doc
            try await AuxiliarySnapshot(options: options).run(name, document: doc)
            finish(code: 0)
            return
        }
        if let name = options.auxiliaryWindow {
            let window: NSWindow?
            switch name {
            case "welcome": window = WelcomeWindowController.shared.window
            default: window = PreferencesWindowController.shared.window
            }
            if name.hasPrefix("settings-"), let tabs = window?.contentViewController as? NSTabViewController,
               let i = tabs.tabViewItems.firstIndex(where: { $0.label.lowercased() == name.dropFirst("settings-".count) }) {
                tabs.selectedTabViewItemIndex = i
            }
            guard let window else { throw SnapshotError("no \(name) window") }
            if let appearance = options.appearance { window.appearance = NSAppearance(named: appearance) }
            WindowCapture.orderInUnseen(window)
            try await Task.sleep(nanoseconds: 700_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await write(window: window, workspace: nil)
            return
        }
        let doc = try await openDocument()
        document = doc
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        guard let window = doc.windowControllers.first?.window else {
            throw SnapshotError("the document made no window")
        }
        let size = options.contentSize(in: window)
        if !options.widestPanels { window.setContentSize(size) }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        if let appearance = options.appearance { window.appearance = NSAppearance(named: appearance) }
        WindowCapture.orderInUnseen(window)

        if let collection = doc as? MedH5CollectionDocument {
            _ = collection
            try await settle(window: window, workspace: nil)
            try await write(window: window, workspace: nil)
            return
        }
        guard let workspace = (doc as? MedH5Document)?.workspace else { throw SnapshotError("no workspace") }
        configure(workspace)
        if let script = options.editScript { try await EditScript.run(script, workspace: workspace) }
        if let tool = options.tool { workspace.viewer.tool = tool }
        if options.widestPanels {
            try await settle(window: window, workspace: workspace)
            try await Self.dragPanelsWideAndNarrow(window, to: size)
        }
        try await settle(window: window, workspace: workspace)
        try await write(window: window, workspace: workspace)
    }

    /// The way to the tightest window a user can reach: the sidebar's and
    /// the inspector's dividers dragged as far as they go, then the window's
    /// corner in, a few points at a time.
    static func dragPanelsWideAndNarrow(_ window: NSWindow, to size: NSSize) async throws {
        func splitViews(in view: NSView) -> [NSSplitView] {
            var inner = view.subviews.flatMap(splitViews)
            if let split = view as? NSSplitView { inner.insert(split, at: 0) }
            return inner
        }
        guard let content = window.contentView else { return }
        for split in splitViews(in: content) where split.arrangedSubviews.count > 1 {
            let items = (split.delegate as? NSSplitViewController)?.splitViewItems ?? []
            split.setPosition(items.last?.behavior == .inspector ? 0 : split.bounds.width, ofDividerAt: 0)
            content.layoutSubtreeIfNeeded()
        }
        var current = content.frame.size
        while current.width > size.width || current.height > size.height {
            current = NSSize(width: max(size.width, current.width - 8), height: max(size.height, current.height - 8))
            window.setContentSize(current)
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func openDocument() async throws -> NSDocument {
        switch options.source {
        case .demo:
            let url = SampleLauncher.temporaryURL(name: "Demo Sample")
            let size = options.demoSize ?? Preferences.demoSize
            try await blocking { try Demo.write(to: url, options: DemoOptions(size: size)) }
            return try MedH5Document.untitled(from: url, name: "Demo Sample", deleteWhenClosed: true)
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw SnapshotError("no file at \(url.path)") }
            // Reading opens metadata only: quick enough for the main actor.
            if url.pathExtension.lowercased() == MedH5CollectionDocument.fileExtension {
                return try MedH5CollectionDocument(contentsOf: url, ofType: MedH5CollectionDocument.typeIdentifier)
            }
            return try MedH5Document(contentsOf: url, ofType: MedH5Document.typeIdentifier)
        }
    }

    private func configure(_ workspace: Workspace) {
        if let layout = options.layout { workspace.setLayout(layout) }
        if let slab = options.slab { workspace.viewer.slab = slab }
        if let plane = options.plane {
            workspace.viewer.singlePlane = plane
            workspace.viewer.comparePlane = plane
        }
        for id in options.overlays {
            if id == "all" {
                workspace.showAllAnnotations()
                if let compare = workspace.compare { workspace.showAllAnnotations(in: compare) }
            } else if workspace.summary.annotation(id) != nil || workspace.summary.image(id) != nil {
                if !workspace.primary.contains(id) { workspace.toggleOverlay(id, in: workspace.primary) }
            } else {
                Log.error("--overlays: no object \(id)")
            }
        }
        if let select = options.select {
            if let node = workspace.findNode(select) {
                workspace.select(node.id)
                workspace.inspectorTab = .info
            } else {
                Log.error("--select: no sidebar item \(select)")
            }
        }
        if let tab = options.inspector { workspace.inspectorTab = tab }
        if let active = options.activeView { workspace.viewer.activeViewport = active }
        if let mode = options.volumeMode, let m = VolumeRenderMode(rawValue: mode) { workspace.viewer.volume.mode = m }
        if options.surfaces == "meshes" { workspace.viewer.volume.surfaceStyle = .meshes }
        if options.hideSidebar { workspace.showsSidebar = false }
        if options.hideInspector { workspace.showsInspector = false }
    }

    /// Waits until nothing is loading, every visible viewport exists and is
    /// done, the integrity check finished and attributes asked for are in;
    /// then lets the run loop settle the layout.
    private func settle(window: NSWindow, workspace: Workspace?) async throws {
        // What the window waited for when last it was not ready: readiness
        // that comes and goes never settles, and a timeout names it.
        var lastWaited: [String] = []
        while true {
            try await Task.sleep(nanoseconds: 50_000_000)
            if Date().timeIntervalSince(started) > options.timeout {
                let now = workspace.map(unreadiness) ?? []
                let waited = now.isEmpty ? lastWaited.map { "\($0) (now and then)" } : now
                let why = waited.isEmpty ? "the window" : waited.joined(separator: "; ")
                throw SnapshotError("timed out after \(Int(options.timeout)) s waiting for: \(why)")
            }
            window.contentView?.layoutSubtreeIfNeeded()
            if let workspace {
                let waiting = unreadiness(workspace)
                if !waiting.isEmpty {
                    lastWaited = waiting
                    quietSince = nil
                    continue
                }
            }
            if quietSince == nil { quietSince = Date() }
            if let q = quietSince, Date().timeIntervalSince(q) > 0.6 { break }
        }
        window.displayIfNeeded()
        RenderContext.shared?.waitUntilIdle()
    }

    /// What the window still waits for before it is captured, in words
    /// (empty: ready) — loads, the integrity check, views, the 3-D view's
    /// surfaces, the attributes asked for.
    private func unreadiness(_ w: Workspace) -> [String] {
        var parts: [String] = []
        for key in w.store.pendingKeys { parts.append("\(key) (loading)") }
        if w.verification == .running { parts.append("the integrity check") }
        for key in w.neededResources() where w.store.failure(key) == nil && !w.store.isReady(key) && !w.store.isLoading(key) {
            parts.append("\(key) (not requested)")
        }
        for id in w.viewer.visibleViewports {
            let presentation = id == .volume ? w.viewports.volume?.presentation : w.viewports.slices[id]?.presentation
            let container = id == .volume ? w.viewports.volume?.container : w.viewports.slices[id]?.container
            if container == nil { parts.append("the \(id) view (not made)") } else if container?.window == nil {
                parts.append("the \(id) view (not in the window)")
            }
            if let loading = presentation?.loading, !loading.isEmpty {
                parts.append("the \(id) view (\(loading.map(\.title).joined(separator: ", ")))")
            }
        }
        if w.layout3DNeedsSurfaces { parts.append("the 3-D view's surfaces") }
        if w.showsInspector, w.inspectorTab == .info, let sel = w.selection, let path = w.objectPath(forNode: sel) {
            switch w.attributeState(path) {
            case .loaded?, .failed?: break
            default: parts.append("the attributes of \(sel)")
            }
        }
        return parts
    }

    private func write(window: NSWindow, workspace: Workspace?) async throws {
        if options.activate { try await WindowCapture.activate(window) }
        reportToolbarOverflow(window)
        var viewports: [WindowCapture.Viewport] = []
        if let workspace {
            for id in workspace.viewer.visibleViewports {
                if id == .volume, let v = workspace.viewports.volume {
                    viewports.append(.init(container: v.container, image: try v.renderImage(scale: Double(options.scale))))
                } else if let s = workspace.viewports.slices[id] {
                    viewports.append(.init(container: s.container, image: try s.renderImage(scale: Double(options.scale))))
                }
            }
        }
        let capture = try await WindowCapture.capture(window: window, scale: options.scale, viewports: viewports)
        var paths: [String] = []
        let windowURL = options.outDirectory.appendingPathComponent("window.png")
        try ImageExport.writePNG(capture.window, to: windowURL)
        paths.append(windowURL.path)
        for (n, image) in capture.viewports.enumerated() {
            let url = options.outDirectory.appendingPathComponent("view-\(n + 1).png")
            try ImageExport.writePNG(image, to: url)
            paths.append(url.path)
        }
        for p in paths { print(p) }
        fflush(stdout)
        finish(code: 0)
    }

    /// Names on standard error what the toolbar could not fit: it stays
    /// usable from the overflow menu, so nothing else shows it.
    private func reportToolbarOverflow(_ window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        let hidden = toolbar.items.filter { !visible.contains($0.itemIdentifier) }
        guard !hidden.isEmpty else { return }
        let names = hidden.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }
        let width = Int(window.frame.width)
        let report = "medh5-viewer --snapshot: toolbar overflow in a window \(width) points wide: \(names.joined(separator: ", "))\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    private func fail(_ error: Error) {
        let message = (error as? SnapshotError)?.message ?? VolumeStore.describe(error)
        FileHandle.standardError.write(Data("medh5-viewer --snapshot: \(message)\n".utf8))
        finish(code: 1)
    }

    private func finish(code: Int32) {
        if let doc = document as? MedH5Document {
            for url in doc.temporaryFiles { try? FileManager.default.removeItem(at: url) }
        }
        exit(code)
    }
}

struct SnapshotError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

extension Workspace {
    /// Whether the 3-D view waits for surface meshes.
    var layout3DNeedsSurfaces: Bool {
        guard viewer.visibleViewports.contains(.volume), viewer.volume.surfaceStyle == .meshes else { return false }
        return primary.layers.contains { $0.isVisible && $0.kind == .segmentation && store.isLoading(.surfaces($0.id)) }
    }
}
