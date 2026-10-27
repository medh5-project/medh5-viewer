import AppKit
import Observation
import MedH5Kit

/// What the document's panels and the sidebar share in a workspace: a
/// revision of the document's pending edits, bumped on every change, undo
/// and redo, so the views that show pending edits redraw when they change
/// (the edits themselves live in the document, which is not observable).
@MainActor
@Observable
final class AuxiliaryState {
    private(set) var editsRevision = 0
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var observed: UndoManager?

    init() {}

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Follows an undo manager: its undo, redo and closed groups (every
    /// `MedH5Document.apply`, whoever calls it) count as changes.
    func observe(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== observed else { return }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        observed = undoManager
        let names: [Notification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                                          .NSUndoManagerDidCloseUndoGroup]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteEditsChanged() }
            })
        }
    }

    func noteEditsChanged() {
        editsRevision &+= 1
    }
}

extension Workspace {
    /// The document's unsaved changes; a view reading them redraws when
    /// they change.
    var pendingEdits: PendingEdits {
        _ = auxiliary.editsRevision
        return document?.pendingEdits ?? PendingEdits()
    }

    /// Whether the document holds unsaved changes.
    var hasPendingEdits: Bool { !pendingEdits.isEmpty }

    /// Changes the pending edits as one undoable step (Edit ▸ Undo names it).
    func applyEdit(_ name: String, _ change: (inout PendingEdits) -> Void) {
        guard let document else { return }
        auxiliary.observe(document.undoManager)
        document.apply(name, change)
        auxiliary.noteEditsChanged()
    }

    /// `/meta` as the next save writes it: the pending document (or the
    /// stored one) with a pending label set change applied.
    func effectiveDocument() throws -> JSONValue {
        PendingEdits.effectiveDocument(stored: try file.document(), edits: pendingEdits)
    }

    /// The label set as the next save writes it (`nil`: none).
    func effectiveLabelSet() throws -> JSONValue? {
        let ls = try effectiveDocument()["label_set"]
        return ls.flatMap { $0.isNull ? nil : $0 }
    }

    /// The file the panels read: the saved sample (for a collection member,
    /// its collection).
    var savedURL: URL { file.url }

    /// Where an amendment of the saved sample reads from, `nil` for a
    /// member of a collection (which is never amended).
    var amendableURL: URL? { file.member == nil ? file.url : nil }
}

extension PendingEdits {
    /// The document a save stores, given the stored one.
    static func effectiveDocument(stored: JSONValue, edits: PendingEdits) -> JSONValue {
        var document = edits.document ?? stored
        switch edits.labelSet {
        case .set(let labels)?: document["label_set"] = labels
        case .remove?: document["label_set"] = nil
        case nil: break
        }
        return document
    }
}
