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

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "medh5 Viewer",
            .applicationVersion: AppInfo.version,
            .credits: NSAttributedString(
                string: "A native viewer and editor for medh5 files.\nmedh5 engine \(MedH5.engineVersion) · format \(MedH5.formatVersion) · bridge \(MedH5.bridgeVersion)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func showHelp(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.userGuideURL) }
    @objc func showDocumentation(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.documentationURL) }
    @objc func reportIssue(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.issuesURL) }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        Layouts: 1 single · 2 1×3 · 3 2×2 · 4 3-D · 5 compare
        Tools: V navigate · W window/level · H pan · Z zoom
        Slices: scroll or ↑ ↓ one slice · Page Up/Down ten · Home/End first/last
        Navigate tool: click sets the crosshair · ⌥-drag pans · ⌃-drag zooms · ⇧-drag windows
        3-D: drag orbits · ⌥-drag pans · scroll zooms · double-click resets
        View: ⌘0 reset · ⌘= zoom in · ⌘- zoom out · ⌃⌘S sidebar · ⌥⌘I inspector
        Image: ⌥⌘W auto window · ⌘] / ⌘[ next/previous timepoint
        """
        alert.runModal()
    }
}
