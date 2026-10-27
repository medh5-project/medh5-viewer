import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import MedH5Kit

/// The windows a document opens beside its main window (spec: "Other
/// windows and sheets"). Each is one of the document's window controllers:
/// it closes with the document, its undo manager is the document's (⌘Z in
/// the label set editor undoes the label set edit), and its title names the
/// document.
enum DocumentPanel: String, CaseIterable, Sendable {
    case validate, verify, document, labelSet, clinical

    var title: String {
        switch self {
        case .validate: return "Validation"
        case .verify: return "Integrity"
        case .document: return "Document"
        case .labelSet: return "Label Set"
        case .clinical: return "Clinical History"
        }
    }

    var size: NSSize {
        switch self {
        case .validate: return NSSize(width: 820, height: 560)
        case .verify: return NSSize(width: 860, height: 600)
        case .document: return NSSize(width: 940, height: 640)
        case .labelSet: return NSSize(width: 1120, height: 620)
        case .clinical: return NSSize(width: 1240, height: 800)
        }
    }

    var minSize: NSSize {
        switch self {
        case .clinical: return NSSize(width: 860, height: 560)
        default: return NSSize(width: 620, height: 420)
        }
    }
}

/// A panel's window controller; it keeps the panel's model alive.
final class DocumentPanelController: NSWindowController, NSWindowDelegate {
    let panel: DocumentPanel
    /// The panel's model (a validation run, an editor's draft).
    let model: AnyObject

    init<Content: View>(panel: DocumentPanel, model: AnyObject, content: Content) {
        self.panel = panel
        self.model = model
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.setContentSize(panel.size)
        window.minSize = panel.minSize
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("medh5-panel-\(panel.rawValue)")
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "\(panel.title) — \(displayName)"
    }
}

extension MedH5Document {
    /// The panel's controller, when its window is open.
    @MainActor
    func panelController(_ panel: DocumentPanel) -> DocumentPanelController? {
        windowControllers.lazy.compactMap { $0 as? DocumentPanelController }.first { $0.panel == panel }
    }

    /// The main window's controller.
    @MainActor
    var mainWindowController: DocumentWindowController? {
        windowControllers.lazy.compactMap { $0 as? DocumentWindowController }.first
    }

    /// Shows a panel, making it the first time; returns its controller.
    @MainActor
    @discardableResult
    func showPanel(_ panel: DocumentPanel, display: Bool = true) -> DocumentPanelController? {
        if let open = panelController(panel) {
            if display { open.showWindow(nil) }
            return open
        }
        guard let workspace else { return nil }
        let controller: DocumentPanelController
        switch panel {
        case .validate:
            let model = ValidationModel(workspace: workspace)
            controller = DocumentPanelController(panel: panel, model: model, content: ValidationView(model: model))
            model.run()
        case .verify:
            let model = IntegrityModel(workspace: workspace)
            controller = DocumentPanelController(panel: panel, model: model, content: IntegrityView(model: model))
            model.run()
        case .document:
            let model = DocumentEditorModel(workspace: workspace)
            controller = DocumentPanelController(panel: panel, model: model, content: DocumentEditorView(model: model))
        case .labelSet:
            let model = LabelSetEditorModel(workspace: workspace)
            controller = DocumentPanelController(panel: panel, model: model, content: LabelSetEditorView(model: model))
        case .clinical:
            let model = ClinicalModel(workspace: workspace)
            controller = DocumentPanelController(panel: panel, model: model, content: ClinicalHistoryView(model: model))
            model.load()
        }
        // Closing the main window closes the document and its panels with it.
        mainWindowController?.shouldCloseDocument = true
        addWindowController(controller)
        if let main = mainWindowController?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 60, y: main.frame.maxY - 40))
        }
        if display { controller.showWindow(nil) }
        return controller
    }
}

/// A window of the app (Help, Keyboard Shortcuts, Acknowledgements): one
/// each, made on first use.
@MainActor
final class AppWindowController: NSWindowController {
    private static var open: [String: AppWindowController] = [:]

    /// The window for `key`, made with `make` the first time.
    static func shared(_ key: String, title: String, size: NSSize, minSize: NSSize? = nil,
                       make: () -> NSViewController) -> AppWindowController {
        if let existing = open[key] { return existing }
        let content = make()
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.tabbingMode = .disallowed
        window.setContentSize(size)
        window.minSize = minSize ?? NSSize(width: min(size.width, 520), height: min(size.height, 360))
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("medh5-app-\(key)")
        let controller = AppWindowController(window: window)
        window.center()
        open[key] = controller
        return controller
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What a panel or sheet shows while the engine works, or why it could not.
enum TaskState: Equatable {
    case idle
    case running(String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// A one-line notice across a panel: unsaved changes, read-only, a refusal.
struct NoticeBar: View {
    enum Style { case info, warning, error, success }
    let style: Style
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch style {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

/// A titled group in a panel.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            content
        }
    }
}

/// Label–value rows, labels right-aligned in one column.
struct FactGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11.5))
    }
}

/// Puts text on the general pasteboard.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Asks where to save, then writes `text` there.
@MainActor
func saveText(_ text: String, suggestedName: String, contentType: UTType = .json, in window: NSWindow?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [contentType]
    panel.nameFieldStringValue = suggestedName
    panel.isExtensionHidden = false
    let write: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
}
