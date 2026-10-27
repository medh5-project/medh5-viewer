import Foundation

/// Undo and redo stacks of `VoxelEdit`s, with a memory cap, grouping and
/// coalescing.
///
/// The history does not own the model: `undo(on:)` and `redo(on:)` revert or
/// apply the top edit on the model given (which must be in the state the
/// edit left it in; the history checks with `canRevert`/`canApply` and
/// refuses otherwise).
///
/// - **Grouping**: edits recorded between `beginGroup(name:)` and
///   `endGroup()` become one step (composed with `VoxelEdit.followed(by:)`).
///   A `BrushStroke` already produces one edit per stroke.
/// - **Coalescing**: an edit recorded with the same `coalescingKey` as the
///   top entry, within `coalescingInterval` of it, merges into that entry
///   (successive nudges of one value, say).
/// - **Memory cap**: when the edits held exceed `memoryLimit` bytes or
///   `stepLimit` steps, the oldest undo steps are dropped (the newest step is
///   always kept).
///
/// ## Bridging to `NSUndoManager`
/// The package does not depend on AppKit. Mirror the history in the
/// document's undo manager through `onEvent`:
///
/// ```swift
/// history.onEvent = { [weak self] event in
///     guard let self, case .recorded(let entry) = event else { return }
///     self.undoManager?.registerUndo(withTarget: self) { $0.undoEdit() }
///     self.undoManager?.setActionName(entry.name)
/// }
/// func undoEdit() {
///     history.undo(on: model)
///     undoManager?.registerUndo(withTarget: self) { $0.redoEdit() }
/// }
/// func redoEdit() {
///     history.redo(on: model)
///     undoManager?.registerUndo(withTarget: self) { $0.undoEdit() }
/// }
/// ```
/// `.coalesced` needs no new registration. After `.discarded`, the undo
/// manager's oldest actions find nothing to undo and do nothing (or call
/// `removeAllActions` and re-register).
///
/// Use the history from the model's serial context (the main actor), like
/// the model itself.
public final class EditHistory {
    public struct Entry: Sendable, Identifiable {
        public let id: Int
        public var name: String
        public var edit: VoxelEdit
        public var date: Date
        public var coalescingKey: String?
        public var byteSize: Int { edit.byteSize }
    }

    public enum Event: Sendable {
        /// A new undoable step.
        case recorded(Entry)
        /// The top step absorbed a new edit.
        case coalesced(Entry)
        case undone(Entry)
        case redone(Entry)
        /// Oldest steps dropped by the memory or step limit.
        case discarded([Entry])
        case cleared
    }

    /// Bytes of edits kept (undo and redo together); 512 MB by default.
    public var memoryLimit: Int {
        didSet { enforceLimits() }
    }

    /// Maximum number of undo steps.
    public var stepLimit: Int {
        didSet { enforceLimits() }
    }

    /// How close in time two edits with the same coalescing key must be to merge.
    public var coalescingInterval: TimeInterval = 1.0

    /// Called after each change of the stacks.
    public var onEvent: ((Event) -> Void)?

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    /// Bytes held by both stacks.
    public private(set) var totalBytes = 0

    private var nextID = 1
    private var groupDepth = 0
    private var groupName = ""
    private var groupEdit: VoxelEdit?

    public init(memoryLimit: Int = 512 << 20, stepLimit: Int = 1000) {
        self.memoryLimit = memoryLimit
        self.stepLimit = stepLimit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }
    public var isGrouping: Bool { groupDepth > 0 }

    // MARK: Recording

    /// Records an edit that has been applied to the model. Empty edits are
    /// ignored. Returns the entry it created or extended (nil while grouping).
    @discardableResult
    public func record(_ edit: VoxelEdit, name: String, coalescingKey: String? = nil,
                       date: Date = Date()) -> Entry? {
        guard !edit.isEmpty else { return nil }
        if groupDepth > 0 {
            groupEdit = groupEdit.map { $0.followed(by: edit) } ?? edit
            return nil
        }
        clearRedo()
        if let key = coalescingKey, var top = undoStack.last, top.coalescingKey == key,
           date.timeIntervalSince(top.date) <= coalescingInterval {
            totalBytes -= top.byteSize
            top.edit = top.edit.followed(by: edit)
            top.date = date
            totalBytes += top.byteSize
            if top.edit.isEmpty {
                undoStack.removeLast()
                totalBytes -= top.byteSize
            } else {
                undoStack[undoStack.count - 1] = top
            }
            onEvent?(.coalesced(top))
            enforceLimits()
            return top
        }
        let entry = Entry(id: nextID, name: name, edit: edit, date: date, coalescingKey: coalescingKey)
        nextID += 1
        undoStack.append(entry)
        totalBytes += entry.byteSize
        onEvent?(.recorded(entry))
        enforceLimits()
        return entry
    }

    /// Starts a group: edits recorded until the matching `endGroup()` form one step.
    public func beginGroup(name: String) {
        if groupDepth == 0 {
            groupName = name
            groupEdit = nil
        }
        groupDepth += 1
    }

    /// Ends a group; the outermost one records the group's edits as one step.
    @discardableResult
    public func endGroup() -> Entry? {
        precondition(groupDepth > 0, "endGroup without beginGroup")
        groupDepth -= 1
        guard groupDepth == 0, let edit = groupEdit else { return nil }
        groupEdit = nil
        return record(edit, name: groupName)
    }

    /// The edits recorded in the open group so far, as one edit (for
    /// cancelling a group: revert it on the model).
    public var pendingGroupEdit: VoxelEdit? { groupEdit }

    // MARK: Undo and redo

    /// Reverts the top edit on `model`. Returns nil when there is nothing to
    /// undo or the model is not in the state the edit produced.
    @discardableResult
    public func undo(on model: SegmentationModel) -> Entry? {
        guard groupDepth == 0, let entry = undoStack.last, model.canRevert(entry.edit) else { return nil }
        undoStack.removeLast()
        model.revert(entry.edit)
        redoStack.append(entry)
        onEvent?(.undone(entry))
        return entry
    }

    /// Re-applies the most recently undone edit.
    @discardableResult
    public func redo(on model: SegmentationModel) -> Entry? {
        guard groupDepth == 0, let entry = redoStack.last, model.canApply(entry.edit) else { return nil }
        redoStack.removeLast()
        model.apply(entry.edit)
        undoStack.append(entry)
        onEvent?(.redone(entry))
        return entry
    }

    /// Drops everything.
    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        totalBytes = 0
        groupDepth = 0
        groupEdit = nil
        onEvent?(.cleared)
    }

    private func clearRedo() {
        for e in redoStack { totalBytes -= e.byteSize }
        redoStack.removeAll()
    }

    private func enforceLimits() {
        var dropped: [Entry] = []
        // Redo steps go first (they are the least likely to be used), then the oldest undo steps.
        while totalBytes > memoryLimit, let e = redoStack.first {
            redoStack.removeFirst()
            totalBytes -= e.byteSize
            dropped.append(e)
        }
        while undoStack.count > 1 && (totalBytes > memoryLimit || undoStack.count > max(1, stepLimit)) {
            let e = undoStack.removeFirst()
            totalBytes -= e.byteSize
            dropped.append(e)
        }
        if !dropped.isEmpty { onEvent?(.discarded(dropped)) }
    }
}
