import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MedH5Kit

/// The document's commands for its panels and files: Tools ▸ Validate…,
/// Verify Integrity, Build Sampling Index…, Recompress…; Window ▸ Document,
/// Label Set, Clinical History; File ▸ Import and Export NIfTI; the
/// sidebar's Export and Remove. They live on the document, which is in the
/// responder chain of its main window and of its panels, so they work from
/// either.
extension MedH5Document {
    // MARK: Panels

    @MainActor @objc func showValidation(_ sender: Any?) {
        if let open = panelController(.validate), let model = open.model as? ValidationModel {
            model.run()
            open.showWindow(nil)
        } else {
            showPanel(.validate)
        }
    }

    @MainActor @objc func verifyIntegrity(_ sender: Any?) {
        if let open = panelController(.verify), let model = open.model as? IntegrityModel {
            model.run()
            open.showWindow(nil)
        } else {
            showPanel(.verify)
        }
    }

    @MainActor @objc func showDocumentEditor(_ sender: Any?) { showPanel(.document) }

    @MainActor @objc func showLabelSetEditor(_ sender: Any?) { showPanel(.labelSet) }

    @MainActor @objc func showClinicalHistory(_ sender: Any?) { showPanel(.clinical) }

    /// Opens the document editor at a page.
    @MainActor func showDocumentEditor(page: DocumentEditorModel.Page) {
        if let model = showPanel(.document)?.model as? DocumentEditorModel { model.page = page }
    }

    // MARK: NIfTI

    @MainActor @objc func importNIfTIImage(_ sender: Any?) { beginImport(.image) }

    @MainActor @objc func importNIfTISegmentation(_ sender: Any?) { beginImport(.segmentation) }

    /// Asks for a NIfTI file, then shows the import sheet on the main window.
    @MainActor func beginImport(_ kind: NIfTIImportModel.Kind) {
        guard let workspace, let window = mainWindowController?.window else { return }
        guard !workspace.isReadOnly, workspace.amendableURL != nil else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.title = kind == .image ? "Import NIfTI Image" : "Import NIfTI Segmentation"
        panel.message = kind == .image
            ? "Choose a NIfTI image (.nii or .nii.gz) to add to the sample."
            : "Choose a NIfTI label map (.nii or .nii.gz): 0 is background, every other value a class id."
        panel.allowedContentTypes = [UTType(filenameExtension: "nii"), UTType(filenameExtension: "gz")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                let model = NIfTIImportModel(workspace: workspace, kind: kind)
                Task { await model.read(url) }
                presentSheet(on: window) { end in
                    NIfTIImportView(model: model) { message in
                        end()
                        if let message { workspace.alert = AppAlert(title: "NIfTI imported", message: message) }
                    }
                }
            }
        }
    }

    /// The image or voxel annotation selected in the sidebar, else the base
    /// image.
    @MainActor var exportCandidate: String? {
        guard let workspace else { return nil }
        if let sel = workspace.selection, let node = workspace.findNode(sel), let id = node.objectID { return id }
        return workspace.primary.base?.id
    }

    @MainActor @objc func exportNIfTI(_ sender: Any?) {
        guard let id = exportCandidate else { return NSSound.beep() }
        exportNIfTI(objectID: id)
    }

    /// Exports one image or voxel annotation of the saved file as NIfTI,
    /// asking where (and, for an image, whether in physical values; for an
    /// annotation, all classes or one).
    @MainActor func exportNIfTI(objectID id: String) {
        guard let workspace, let window = mainWindowController?.window else { return }
        let summary = workspace.summary
        let edits = workspace.pendingEdits
        let object: String
        switch NIfTIExport.object(id, in: summary, edits: edits) {
        case .success(let o): object = o
        case .failure(let refusal):
            workspace.alert = AppAlert(title: "\(id) cannot be exported as NIfTI", message: refusal.localizedDescription)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export \(id) as NIfTI"
        panel.nameFieldStringValue = "\(id).nii.gz"
        panel.allowedContentTypes = [UTType(filenameExtension: "gz"), UTType(filenameExtension: "nii")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        var notes: [String] = []
        if edits.touchedObjects.contains(id) { notes.append("Exports the saved file: unsaved changes to \(id) are not included.") }
        panel.message = notes.first ?? "Exports \(object) from the saved file through the medh5 engine."
        let physical = NSButton(checkboxWithTitle: "Write physical values (apply the rescale)", target: nil, action: nil)
        physical.state = .on
        let classes = NSPopUpButton(frame: .zero, pullsDown: false)
        var classIDs: [Int?] = [nil]
        if let a = summary.annotation(id) {
            classes.addItem(withTitle: "All classes (a label map)")
            for c in a.classIDs {
                classes.addItem(withTitle: "Only \(MedH5ViewerUI.className(c, labelSet: summary.labelSet)) (\(c)) as a 0/1 mask")
                classIDs.append(c)
            }
            panel.accessoryView = accessory(classes)
        } else {
            panel.accessoryView = accessory(physical)
        }
        let sample = workspace.savedURL
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "gz" && url.pathExtension.lowercased() != "nii" {
                url.appendPathExtension("nii.gz")
            }
            let target = url
            let isPhysical = physical.state == .on
            let classID = classIDs[max(0, classes.indexOfSelectedItem)]
            Task { @MainActor in
                do {
                    let report = try await blocking {
                        try NIfTIExport.write(sample: sample, object: object, to: target, physical: isPhysical, classID: classID)
                    }
                    let remarks = report.notes.filter { $0.severity != "decision" }.map { "\($0.severity): \($0.message)" }
                    if !remarks.isEmpty {
                        workspace.alert = AppAlert(title: "Exported \(target.lastPathComponent) with notes", message: remarks.joined(separator: "\n"))
                    }
                } catch {
                    workspace.alert = AppAlert(title: "\(id) could not be exported", message: VolumeStore.describe(error))
                }
            }
        }
    }

    private func accessory(_ control: NSView) -> NSView {
        let box = NSStackView(views: [control])
        box.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return box
    }

    // MARK: Removal

    /// Removes an image, annotation or transform as a pending edit, after
    /// checking the format allows it and confirming a broad removal.
    @MainActor func requestRemoval(_ group: RemovalPlan.Group, _ id: String) {
        guard let workspace else { return }
        guard !workspace.isReadOnly else { return NSSound.beep() }
        let file = workspace.file
        Task { @MainActor in
            let clinical = group == .transform ? nil : (try? await blocking { try file.clinicalRecords() }) ?? nil
            let summary = workspace.summary
            let edits = workspace.pendingEdits
            let plan: RemovalPlan
            switch group {
            case .image: plan = RemovalPlanner.image(id, summary: summary, clinical: clinical, edits: edits,
                                                     isBase: workspace.primary.base?.id == id)
            case .annotation: plan = RemovalPlanner.annotation(id, summary: summary, clinical: clinical, edits: edits)
            case .transform: plan = RemovalPlanner.transform(id, summary: summary, edits: edits)
            }
            if let refusal = plan.refusal {
                workspace.alert = AppAlert(title: "\(id) cannot be removed", message: refusal)
                return
            }
            if plan.needsConfirmation {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Remove \(id)?"
                alert.informativeText = (plan.consequences + ["The removal is written when you save; until then Edit ▸ Undo takes it back."])
                    .map { "• \($0)" }.joined(separator: "\n")
                alert.addButton(withTitle: plan.title)
                alert.addButton(withTitle: "Cancel")
                guard let window = self.mainWindowController?.window else { return }
                alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    MainActor.assumeIsolated { self.performRemoval(plan) }
                }
            } else {
                performRemoval(plan)
            }
        }
    }

    @MainActor func performRemoval(_ plan: RemovalPlan) {
        guard let workspace else { return }
        workspace.applyEdit("\(plan.title) \(plan.objectID)") { RemovalPlanner.apply(plan, to: &$0) }
        // The views stop showing what is going.
        for stack in workspace.stacksInUse where stack.contains(plan.objectID) && stack.base?.id != plan.objectID {
            stack.remove(plan.objectID)
        }
    }

    // MARK: Storage

    @MainActor @objc func buildSamplingIndex(_ sender: Any?) { beginStorageTool(.index) }

    @MainActor @objc func recompressSample(_ sender: Any?) { beginStorageTool(.recompress) }

    @MainActor func beginStorageTool(_ tool: StorageToolModel.Tool) {
        guard let workspace, let window = mainWindowController?.window else { return }
        let model = StorageToolModel(document: self, workspace: workspace, tool: tool)
        presentSheet(on: window) { end in
            StorageToolView(model: model, close: end)
        }
    }

    // MARK: Menu validation

    /// Enables the commands above; `nil` for any other action.
    @MainActor func validateAuxiliaryItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let editable = workspace.map { !$0.isReadOnly && $0.amendableURL != nil } ?? false
        switch action {
        case #selector(showValidation(_:)), #selector(verifyIntegrity(_:)), #selector(showDocumentEditor(_:)),
             #selector(showLabelSetEditor(_:)), #selector(showClinicalHistory(_:)):
            return workspace != nil
        case #selector(importNIfTIImage(_:)), #selector(importNIfTISegmentation(_:)):
            return editable
        case #selector(exportNIfTI(_:)):
            var exportable = false
            if let workspace, let id = exportCandidate,
               case .success = NIfTIExport.object(id, in: workspace.summary, edits: workspace.pendingEdits) {
                exportable = true
                (item as? NSMenuItem)?.title = "NIfTI (\(id))…"
            } else {
                (item as? NSMenuItem)?.title = "NIfTI…"
            }
            return exportable
        case #selector(buildSamplingIndex(_:)), #selector(recompressSample(_:)):
            return editable
        default:
            return nil
        }
    }
}
