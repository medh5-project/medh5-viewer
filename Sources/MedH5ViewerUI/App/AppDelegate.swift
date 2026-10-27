import AppKit
import UniformTypeIdentifiers
import MedH5Kit

/// The document controller: knows the two document types even when the
/// executable runs outside its bundle (no Info.plist), as it does from
/// `swift run` or in the snapshot mode.
final class DocumentController: NSDocumentController {
    override var documentClassNames: [String] { ["MedH5Document", "MedH5CollectionDocument"] }

    override var defaultType: String? { MedH5Document.typeIdentifier }

    override func documentClass(forType typeName: String) -> AnyClass? {
        switch typeName {
        case MedH5Document.typeIdentifier, MedH5Document.fileExtension: return MedH5Document.self
        case MedH5CollectionDocument.typeIdentifier, MedH5CollectionDocument.fileExtension: return MedH5CollectionDocument.self
        default: return super.documentClass(forType: typeName)
        }
    }

    override func typeForContents(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case MedH5Document.fileExtension: return MedH5Document.typeIdentifier
        case MedH5CollectionDocument.fileExtension: return MedH5CollectionDocument.typeIdentifier
        default: return try super.typeForContents(of: url)
        }
    }

    override func displayName(forType typeName: String) -> String? {
        switch typeName {
        case MedH5Document.typeIdentifier: return "medh5 Sample"
        case MedH5CollectionDocument.typeIdentifier: return "medh5 Collection"
        default: return super.displayName(forType: typeName)
        }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.allowedContentTypes = [MedH5Document.fileExtension, MedH5CollectionDocument.fileExtension]
            .compactMap { UTType(filenameExtension: $0) }
        openPanel.message = "Choose a medh5 sample (.medh5) or collection (.medh5c)"
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.allowedContentTypes = [MedH5Document.fileExtension, MedH5CollectionDocument.fileExtension]
            .compactMap { UTType(filenameExtension: $0) }
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    /// Set in the snapshot mode: its documents stay out of Open Recent.
    var notesRecentDocuments = true

    /// Cleared in the snapshot mode, which nobody watches: an error the
    /// controller would present (an alert, modal, that no one dismisses —
    /// the run would hang) goes to standard error instead.
    var presentsErrors = true

    override func presentError(_ error: Error) -> Bool {
        guard presentsErrors else {
            FileHandle.standardError.write(Data("medh5-viewer: \(error.localizedDescription)\n".utf8))
            return false
        }
        return super.presentError(error)
    }

    override func noteNewRecentDocumentURL(_ url: URL) {
        guard notesRecentDocuments, !url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        super.noteNewRecentDocumentURL(url)
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        MainActor.assumeIsolated { WelcomeWindowController.shared.close() }
    }
}

/// The application delegate: defaults, the engine's threads, the main menu,
/// the welcome window, and the snapshot mode.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapshot: SnapshotOptions?
    private let filesToOpen: [URL]
    private var runner: SnapshotRunner?
    private var defaultsObserver: NSObjectProtocol?

    init(snapshot: SnapshotOptions?, filesToOpen: [URL]) {
        self.snapshot = snapshot
        self.filesToOpen = filesToOpen
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.applyEngineSettings()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { _ in
            Preferences.applyEngineSettings()
        }
        if let snapshot {
            let runner = SnapshotRunner(options: snapshot)
            self.runner = runner
            runner.start()
            return
        }
        for url in filesToOpen {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        // Show the welcome window unless a document opened (from Finder, or
        // restored) by the time launching settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty { WelcomeWindowController.shared.show() }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && NSDocumentController.shared.documents.isEmpty { WelcomeWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Actions

    @objc func openDemoSample(_ sender: Any?) { SampleLauncher.shared.openDemoSample() }
    @objc func newSampleFromNIfTI(_ sender: Any?) { SampleLauncher.shared.newSampleFromNIfTI() }
    @objc func showPreferences(_ sender: Any?) { PreferencesWindowController.shared.show() }
    @objc func showWelcome(_ sender: Any?) { WelcomeWindowController.shared.show() }

    @objc func newCollectionFromSamples(_ sender: Any?) { CollectionMaker.run() }

    @objc func showAbout(_ sender: Any?) {
        let small = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString(
            string: "A native viewer and editor for medh5 files.\nmedh5 engine \(MedH5.engineVersion) · format \(MedH5.formatVersion) · bridge \(MedH5.bridgeVersion)\n\nBuilt on open-source software: ",
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "Acknowledgements", attributes: [.font: small, .link: AboutCredits.acknowledgementsLink]))
        credits.append(NSAttributedString(string: ".", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "medh5 Viewer",
            .applicationVersion: AppInfo.version,
            .credits: credits,
        ])
        AboutCredits.install()
    }

    @objc func showHelp(_ sender: Any?) { HelpWindow.show() }
    @objc func showDocumentation(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.documentationURL) }
    @objc func reportIssue(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.issuesURL) }
    @objc func showKeyboardShortcuts(_ sender: Any?) { ShortcutsWindow.show() }
    @objc func showAcknowledgements(_ sender: Any?) { AcknowledgementsWindow.show() }
}

/// The About panel's credits link to the Acknowledgements window: the
/// panel's text view gets a delegate that opens the window for that link
/// (other links open as usual).
@MainActor
enum AboutCredits {
    static let acknowledgementsLink = URL(string: "x-medh5-viewer:acknowledgements")!
    private static let handler = LinkHandler()

    static func install() {
        for window in NSApp.windows where !(window is DocumentWindow) {
            guard let view = textView(in: window.contentView), view.string.contains("Acknowledgements") else { continue }
            view.delegate = handler
        }
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let t = view as? NSTextView { return t }
        for sub in view.subviews { if let t = textView(in: sub) { return t } }
        return nil
    }

    final class LinkHandler: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard url == AboutCredits.acknowledgementsLink else { return false }
            MainActor.assumeIsolated { AcknowledgementsWindow.show() }
            return true
        }
    }
}
