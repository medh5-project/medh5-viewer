import AppKit
import UniformTypeIdentifiers
import MedH5Kit

/// A medh5 sample (`.medh5`).
///
/// - **Reading** opens the file through the engine (`SampleFile.open`):
///   metadata only, so it is instant; voxels are read later, in the
///   background, by the window's volume store. Documents are read
///   concurrently.
/// - **Saving** amends the file it was read from into the URL NSDocument
///   gives (`SampleWriter.amend(url:outURL:without:)`), applying the pending
///   edits, asynchronously and validated by the engine; then reopens the
///   saved file. Classic Save / Save As / Revert, no autosave in place.
/// - **Read-only**: a projection of a later format minor, a file whose
///   digests fail verification, a collection member.
@objc(MedH5Document)
public final class MedH5Document: NSDocument {
    public static let typeIdentifier = "io.github.medh5-project.medh5"
    public static let fileExtension = "medh5"

    /// The open sample.
    private(set) var file: SampleFile?
    /// Where the sample was read from: the file, or the temporary file of an
    /// untitled document (the demo, a NIfTI import).
    private(set) var sourceURL: URL?
    /// The name shown for an untitled document.
    var untitledName: String?
    /// Why the document cannot be edited, known at open.
    var initialReadOnly: [ReadOnlyReason] = []
    /// Temporary files to delete when the document closes.
    var temporaryFiles: [URL] = []

    /// The window's model (made with the window).
    private(set) var workspace: Workspace?

    /// Unsaved changes (see `PendingEdits`).
    private(set) var edits = PendingEdits()
    private var saveSnapshot: SaveSnapshot?

    override public init() {
        super.init()
        hasUndoManager = true
    }

    // MARK: Types

    override public class var autosavesInPlace: Bool { false }
    override public class var readableTypes: [String] { [typeIdentifier] }
    override public class var writableTypes: [String] { [typeIdentifier] }
    override public class func isNativeType(_ type: String) -> Bool { type == typeIdentifier }
    override public class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    override public class var usesUbiquitousStorage: Bool { false }

    override public func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                for saveOperation: NSDocument.SaveOperationType) -> Bool { true }

    override public func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        Self.fileExtension
    }

    override public func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if let type = UTType(Self.typeIdentifier) ?? UTType(filenameExtension: Self.fileExtension) {
            savePanel.allowedContentTypes = [type]
        }
        savePanel.isExtensionHidden = false
        return true
    }

    override public var displayName: String! {
        get { fileURL == nil ? (untitledName ?? super.displayName) : super.displayName }
        set { super.displayName = newValue }
    }

    // MARK: Reading

    override public func read(from url: URL, ofType typeName: String) throws {
        let opened = try SampleFile.open(url)
        file = opened
        sourceURL = url
    }

    /// Opens a sample file as an untitled document (the demo sample, an
    /// import): it shows under `name`, and the first save asks where to
    /// put it.
    @MainActor
    static func untitled(from url: URL, name: String, readOnly: [ReadOnlyReason] = [],
                         member: String? = nil, deleteWhenClosed: Bool = false) throws -> MedH5Document {
        let doc = MedH5Document()
        doc.fileType = typeIdentifier
        if let member {
            doc.file = try SampleFile.open(collection: url, member: member)
        } else {
            doc.file = try SampleFile.open(url)
        }
        doc.sourceURL = url
        doc.untitledName = name
        doc.initialReadOnly = readOnly
        if deleteWhenClosed { doc.temporaryFiles.append(url) }
        return doc
    }

    // MARK: Windows

    override public func makeWindowControllers() {
        guard let file else { return }
        MainActor.assumeIsolated {
            let workspace = Workspace(file: file, displayName: displayName ?? "Sample", readOnly: initialReadOnly)
            workspace.document = self
            self.workspace = workspace
            let controller = DocumentWindowController(workspace: workspace)
            addWindowController(controller)
            workspace.start(verify: !Self.skipsVerification)
        }
    }

    /// Set by the snapshot runner when asked not to verify.
    nonisolated(unsafe) static var skipsVerification = false

    override public func close() {
        MainActor.assumeIsolated { workspace?.shutDown() }
        let file = self.file
        let temporary = temporaryFiles
        super.close()
        // Closing waits for engine calls in flight: never on the main thread.
        DispatchQueue.global(qos: .utility).async {
            file?.close()
            for url in temporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Read-only

    /// Why the document cannot be edited (empty when it can).
    @MainActor
    var readOnlyReasons: [ReadOnlyReason] { workspace?.readOnlyReasons ?? initialReadOnly }

    @MainActor
    var isReadOnly: Bool { !readOnlyReasons.isEmpty }

    override public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let readOnly = MainActor.assumeIsolated { isReadOnly }
        if readOnly, let action = item.action,
           action == #selector(save(_:)) || action == #selector(saveAs(_:)) || action == #selector(revertToSaved(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Edits

    /// Changes the pending edits as one undoable step (the editing tools of
    /// phase B call this; every change marks the document edited).
    @MainActor
    func apply(_ actionName: String, _ change: (inout PendingEdits) -> Void) {
        guard !isReadOnly else {
            NSSound.beep()
            return
        }
        let before = edits
        change(&edits)
        guard edits != before else { return }
        registerUndo(restoring: before, name: actionName)
        markPinnedSegmentations()
    }

    @MainActor
    private func registerUndo(restoring previous: PendingEdits, name: String) {
        let current = edits
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.edits = previous
                doc.registerUndo(restoring: current, name: name)
                doc.markPinnedSegmentations()
            }
        }
        undoManager?.setActionName(name)
    }

    /// Keeps edited segmentations in memory (the store never evicts them).
    @MainActor
    private func markPinnedSegmentations() {
        guard let store = workspace?.store else { return }
        for id in edits.editedSegmentations.union(edits.newSegmentations.keys) { store.pin(.segmentation(id)) }
    }

    /// The edits, for tests and the save.
    @MainActor
    var pendingEdits: PendingEdits { edits }

    /// Sets the pending edits within an undo step the editing tools register
    /// themselves (one step restores voxels and edits together). Refused in
    /// a read-only document, like `apply`.
    @MainActor
    func setPendingEdits(_ new: PendingEdits) {
        guard !isReadOnly else { return }
        edits = new
        markPinnedSegmentations()
    }

    // MARK: Saving

    override public func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                              completionHandler: @escaping ((any Error)?) -> Void) {
        let prepared: Result<SaveSnapshot, Error> = MainActor.assumeIsolated {
            if isReadOnly {
                return .failure(SaveError.readOnly(readOnlyReasons.map(\.message).joined(separator: " ")))
            }
            guard let file else { return .failure(SaveError.noSource) }
            do {
                return .success(try SaveSnapshot.make(edits: edits, summary: file.summary, store: workspace?.store))
            } catch {
                return .failure(error)
            }
        }
        switch prepared {
        case .failure(let error):
            completionHandler(error)
            return
        case .success(let snapshot):
            saveSnapshot = snapshot
        }
        MainActor.assumeIsolated { workspace?.isSaving = true }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { return completionHandler(error) }
            let snapshot = self.saveSnapshot
            self.saveSnapshot = nil
            MainActor.assumeIsolated {
                self.workspace?.isSaving = false
                if error == nil, let snapshot, saveOperation != .saveToOperation {
                    self.didSave(snapshot)
                }
            }
            completionHandler(error)
        }
    }

    override public func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                               originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        guard let snapshot = saveSnapshot else { throw SaveError.noSource }
        guard let source = absoluteOriginalContentsURL ?? sourceURL else { throw SaveError.noSource }
        unblockUserInteraction()
        try SaveOperation(snapshot: snapshot).perform(source: source, destination: url)
    }

    /// After a save: forget what was written (keeping edits made while it
    /// wrote), and read from the saved file.
    @MainActor
    private func didSave(_ snapshot: SaveSnapshot) {
        var remaining = edits
        let saved = snapshot.edits
        let store = workspace?.store
        for s in snapshot.segmentations {
            if let res = store?.ready(.segmentation(s.id), as: SegmentationResource.self), res.model.revision == s.revision {
                remaining.editedSegmentations.remove(s.id)
                remaining.newSegmentations[s.id] = nil
                store?.unpin(.segmentation(s.id))
            }
        }
        if remaining.document == saved.document { remaining.document = nil }
        if remaining.labelSet == saved.labelSet { remaining.labelSet = nil }
        for (id, a) in saved.annotations where remaining.annotations[id] == a { remaining.annotations[id] = nil }
        remaining.removedAnnotations.subtract(saved.removedAnnotations)
        remaining.removedImages.subtract(saved.removedImages)
        remaining.removedTransforms.subtract(saved.removedTransforms)
        for (id, attrs) in saved.imageAttributes where remaining.imageAttributes[id] == attrs { remaining.imageAttributes[id] = nil }
        edits = remaining
        undoManager?.removeAllActions()
        if !edits.isEmpty { updateChangeCount(.changeDone) }
        guard let url = fileURL else { return }
        sourceURL = url
        // The editor's models of the saved segmentations hold what the file
        // now holds: keep them (and their undo history) rather than re-read.
        let touched = saved.touchedObjects.subtracting(saved.editedSegmentations).subtracting(saved.newSegmentations.keys)
        Task { [weak self] in
            do {
                let reopened = try await blocking { try SampleFile.open(url) }
                guard let self else { return }
                let old = self.file
                self.file = reopened
                self.workspace?.didSave(newFile: reopened, displayName: self.displayName ?? "", replacedObjects: touched)
                if self.workspace == nil { DispatchQueue.global().async { old?.close() } }
            } catch {
                self?.workspace?.alert = AppAlert(title: "The saved file could not be reopened",
                                                  message: VolumeStore.describe(error))
            }
        }
    }

    override public func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let old = file
        try super.revert(toContentsOf: url, ofType: typeName)
        MainActor.assumeIsolated {
            edits = PendingEdits()
            undoManager?.removeAllActions()
            if let file, let workspace {
                workspace.store.cancelAll()
                workspace.didSave(newFile: file, displayName: displayName ?? "", replacedObjects: [])
            }
        }
        if old !== file { DispatchQueue.global().async { old?.close() } }
    }
}
