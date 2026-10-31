import AppKit
import SwiftUI
import WebKit
import MedH5Kit
import MedH5Render

/// The snapshot mode of the panels and app windows (`--window validate`,
/// `verify`, `document`, `label-set`, `clinical`, `help`, `shortcuts`,
/// `acknowledgements`, `import-nifti`): opens the document (the demo, or
/// the file given), shows the window, waits for its work (a validation, a
/// clinical selection, the guide's page), and writes `window.png`.
///
/// `--select` picks something in the window: a document editor page, a
/// label set class (id or key), a clinical event, a validation filter.
/// `--cutoff <hours>` sets the clinical window's cutoff.
@MainActor
struct AuxiliarySnapshot {
    nonisolated static let windows: Set<String> = ["validate", "verify", "document", "label-set", "clinical", "help", "shortcuts",
                                       "acknowledgements", "import-nifti"]

    let options: SnapshotOptions

    func run(_ name: String, document: NSDocument) async throws {
        guard let doc = document as? MedH5Document else { throw SnapshotError("--window \(name) needs a sample, not a collection") }
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        guard let workspace = doc.workspace else { throw SnapshotError("no workspace") }
        let window: NSWindow
        switch name {
        case "validate":
            let controller = try panel(doc, .validate)
            let model = controller.model as! ValidationModel
            if let select = options.select { model.filter = select }
            await model.wait()
            window = controller.window!
        case "verify":
            let controller = try panel(doc, .verify)
            let model = controller.model as! IntegrityModel
            await model.wait()
            try await waitUntil { !model.digests.isEmpty || model.report?.objects.isEmpty == true }
            window = controller.window!
        case "document":
            let controller = try panel(doc, .document)
            if let page = options.select.flatMap(DocumentEditorModel.Page.init(rawValue:)) {
                (controller.model as! DocumentEditorModel).page = page
            }
            window = controller.window!
        case "label-set":
            let controller = try panel(doc, .labelSet)
            let model = controller.model as! LabelSetEditorModel
            if let select = options.select,
               let row = model.classes.first(where: { $0.key == select || $0.classID.map(String.init) == select }) {
                model.selection = row.id
            }
            window = controller.window!
        case "clinical":
            let controller = try panel(doc, .clinical)
            let model = controller.model as! ClinicalModel
            await model.wait()
            if let hours = options.clinicalCutoffHours { await model.select(at: Int64(hours * 3.6e9)) }
            if let select = options.select { model.selectEvent(select) }
            if let id = model.selectedDocumentID { model.showDocument(id) }
            try await waitUntil { model.selectedDocumentID.map { model.texts[$0] != nil } ?? true }
            window = controller.window!
        case "help":
            guard HelpWindow.show() else { throw SnapshotError("no user guide is bundled with this build") }
            window = HelpWindow.window().window!
            try await waitUntil { HelpWindow.model.isLoaded }
            if let anchor = options.select { HelpWindow.model.scroll(to: anchor) }
        case "shortcuts":
            ShortcutsWindow.show()
            if let filter = options.select { ShortcutsWindow.model.filter = filter }
            window = ShortcutsWindow.window().window!
        case "acknowledgements":
            AcknowledgementsWindow.show()
            if let select = options.select {
                AcknowledgementsWindow.model.selection = AcknowledgementsWindow.model.packages.first { $0.name == select }?.id
            }
            window = AcknowledgementsWindow.window().window!
        case "import-nifti":
            window = try await importWindow(workspace)
        default:
            throw SnapshotError("unknown window \(name)")
        }
        if let appearance = options.appearance { window.appearance = NSAppearance(named: appearance) }
        let resized = options.size != SnapshotOptions(source: .demo, outDirectory: options.outDirectory).size
        let size = options.contentSize(in: window)
        if resized, !options.widestPanels { window.setContentSize(size) }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        WindowCapture.orderInUnseen(window)
        try await Task.sleep(nanoseconds: 900_000_000)
        if resized, options.widestPanels { try await SnapshotRunner.dragPanelsWideAndNarrow(window, to: size) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        window.displayIfNeeded()
        if options.activate { try await WindowCapture.activate(window) }
        let image = try await capture(window)
        let url = options.outDirectory.appendingPathComponent("window.png")
        try ImageExport.writePNG(image, to: url)
        print(url.path)
        fflush(stdout)
    }

    private func panel(_ doc: MedH5Document, _ panel: DocumentPanel) throws -> DocumentPanelController {
        guard let controller = doc.showPanel(panel, display: false), controller.window != nil else {
            throw SnapshotError("the \(panel.title) window could not be made")
        }
        return controller
    }

    private func waitUntil(timeout: TimeInterval? = nil, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout ?? options.timeout)
        while !condition() {
            if Date() > deadline { throw SnapshotError("timed out waiting for the window's work") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The import sheet's content in a window of its own, reading a NIfTI
    /// image the engine exports from the sample's base image.
    private func importWindow(_ workspace: Workspace) async throws -> NSWindow {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("medh5-viewer-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = workspace.primary.base?.id ?? workspace.summary.images.first?.id ?? ""
        let nifti = dir.appendingPathComponent("\(image) export.nii.gz")
        let sample = workspace.savedURL
        try await blocking { _ = try NIfTI.export(sample: sample, object: "images/\(image)", to: nifti) }
        let model = NIfTIImportModel(workspace: workspace, kind: options.select == "segmentation" ? .segmentation : .image)
        if model.kind == .segmentation, let seg = workspace.summary.annotations.first(where: { $0.kind == "labelmap" }) {
            let labels = dir.appendingPathComponent("\(seg.id).nii.gz")
            try await blocking { _ = try NIfTI.export(sample: sample, object: "annotations/\(seg.id)", to: labels) }
            await model.read(labels)
        } else {
            await model.read(nifti)
        }
        let hosting = NSHostingController(rootView: NIfTIImportView(model: model) { _ in })
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "Import NIfTI"
        window.isReleasedWhenClosed = false
        return window
    }

    /// The window as drawn, with any web view's page composited at its frame
    /// (a web view draws out of process, so `cacheDisplay` leaves it blank).
    private func capture(_ window: NSWindow) async throws -> CGImage {
        let base = try await WindowCapture.capture(window: window, scale: options.scale, viewports: []).window
        let webViews = Self.webViews(in: window.contentView)
        guard !webViews.isEmpty, let frameView = window.contentView?.superview ?? window.contentView else { return base }
        let scale = options.scale
        let bounds = frameView.bounds
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for web in webViews {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let snapshot = try await web.takeSnapshot(configuration: configuration)
            guard let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let r = web.convert(web.bounds, to: frameView)
            let y = frameView.isFlipped ? bounds.height - r.maxY : r.minY
            context.draw(cg, in: CGRect(x: r.minX * scale, y: y * scale, width: r.width * scale, height: r.height * scale))
        }
        return context.makeImage() ?? base
    }

    private static func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
}
