import AppKit
import MedH5Kit

/// The editing commands of the document window: Segmentation ▸ New
/// Segmentation, Add Class, the brush size and the operations; File ▸ Export
/// ▸ Measurements; and Edit ▸ Cut, Copy, Paste, Delete and Select All on
/// annotation items (or, with the Measurements tab showing, on
/// measurements). They reach the controller through the responder chain
/// when no text field takes them.
extension DocumentWindowController {
    private var editing: EditingSession { workspace.editing }

    /// Shows an inspector tab.
    private func reveal(_ tab: InspectorTab) {
        workspace.showsInspector = true
        workspace.inspectorTab = tab
    }

    /// Whether Edit commands act on measurements (the Measurements tab
    /// showing) rather than on annotation items.
    private var editsMeasurements: Bool {
        workspace.showsInspector && workspace.inspectorTab == .measurements
    }

    // MARK: Segmentation menu

    @objc func newSegmentation(_ sender: Any?) {
        reveal(.segmentEditor)
        editing.sheet = .newSegmentation
    }

    @objc func addSegmentClass(_ sender: Any?) {
        reveal(.segmentEditor)
        editing.sheet = .addClass
    }

    @objc func largerBrush(_ sender: Any?) { editing.scaleBrush(by: 1.25) }
    @objc func smallerBrush(_ sender: Any?) { editing.scaleBrush(by: 0.8) }

    /// An operation: those with options open in the segment editor; the
    /// others run on the active class.
    @objc func segmentOperation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = SegmentOperationKind(rawValue: raw) else { return }
        editing.operation.kind = kind
        reveal(.segmentEditor)
        if !kind.menuTitle.hasSuffix("…") { editing.runOperation(kind) }
    }

    // MARK: File menu

    @objc func exportMeasurements(_ sender: Any?) {
        guard let window else { return }
        MeasurementExport.run(workspace: workspace, window: window)
    }

    // MARK: Edit menu

    @objc(cut:) func cutEditingItems(_ sender: Any?) {
        if editsMeasurements {
            let list = editing.measurementsForCommands.filter { editing.selectedMeasurements.contains($0.id) }
            if editing.copyMeasurements(list) { editing.deleteMeasurements(Set(list.map(\.id))) }
            return
        }
        attempt { try editing.cutSelectedItems() }
    }

    @objc(copy:) func copyEditingItems(_ sender: Any?) {
        if editsMeasurements {
            editing.copyMeasurements(editing.measurements.filter { editing.selectedMeasurements.contains($0.id) })
            return
        }
        _ = editing.copySelectedItems()
    }

    @objc(paste:) func pasteEditingItems(_ sender: Any?) {
        attempt { try editing.pasteItems() }
    }

    @objc(delete:) func deleteEditingItems(_ sender: Any?) {
        if editsMeasurements {
            editing.deleteMeasurements(editing.selectedMeasurements)
            return
        }
        attempt { try editing.deleteSelectedItems() }
    }

    @objc(selectAll:) func selectAllEditingItems(_ sender: Any?) {
        if editsMeasurements {
            editing.selectedMeasurements = Set(editing.measurements.map(\.id))
            return
        }
        editing.selectAllItems()
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { editing.report(error) }
    }

    // MARK: Validation

    /// Enables the editing commands (`nil` for items they do not own).
    func validateEditingMenuItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action else { return nil }
        let readOnly = editing.readOnlyReason != nil
        switch action {
        case #selector(selectTool(_:)):
            guard let tool = (item.representedObject as? String).flatMap(ViewerTool.init(rawValue:)), !tool.isViewingTool else {
                return nil
            }
            item.state = workspace.viewer.tool == tool ? .on : .off
            let availability = editing.availability(tool)
            item.toolTip = availability.reason ?? tool.help
            return availability.isAvailable
        case #selector(newSegmentation(_:)):
            return !readOnly && !workspace.summary.grids.isEmpty
        case #selector(addSegmentClass(_:)):
            return !readOnly
        case #selector(largerBrush(_:)), #selector(smallerBrush(_:)):
            return true
        case #selector(segmentOperation(_:)):
            guard let kind = (item.representedObject as? String).flatMap(SegmentOperationKind.init(rawValue:)) else { return false }
            if kind.menuTitle.hasSuffix("…") { return !readOnly && editing.activeSegmentation != nil }
            let availability = editing.operationAvailability(kind)
            item.toolTip = availability.reason ?? kind.help
            return availability.isAvailable
        case #selector(exportMeasurements(_:)):
            return !editing.measurements.isEmpty
        case #selector(cutEditingItems(_:)):
            if editsMeasurements { return !editing.selectedMeasurements.isEmpty }
            return editing.canEditListedItems && !editing.currentSelection.isEmpty
        case #selector(copyEditingItems(_:)):
            if editsMeasurements { return !editing.selectedMeasurements.isEmpty }
            return !editing.currentSelection.isEmpty
        case #selector(pasteEditingItems(_:)):
            return editing.canPasteItems
        case #selector(deleteEditingItems(_:)):
            if editsMeasurements { return !editing.selectedMeasurements.isEmpty }
            return editing.canEditListedItems && !editing.currentSelection.isEmpty
        case #selector(selectAllEditingItems(_:)):
            if editsMeasurements { return !editing.measurements.isEmpty }
            return editing.listedAnnotation.flatMap { editing.draft($0) }.map { $0.itemCount > 0 } ?? false
        default:
            return nil
        }
    }
}
