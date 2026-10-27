import AppKit
import Observation
import UniformTypeIdentifiers
import MedH5Kit

/// Opens samples that do not start as a file the user picked: the demo
/// sample, written by the engine to a temporary file, and a new sample
/// converted from NIfTI. Both open as untitled documents (the first save
/// asks where to put them).
@MainActor
@Observable
final class SampleLauncher {
    static let shared = SampleLauncher()

    /// Set while a sample is being written (the welcome window shows it).
    private(set) var busyMessage: String?

    /// Writes the engine's demo sample (two visits, every annotation kind)
    /// and opens it.
    func openDemoSample(size: Int = Preferences.demoSize) {
        guard busyMessage == nil else { return }
        busyMessage = "Writing the demo sample…"
        let url = Self.temporaryURL(name: "Demo Sample")
        Task {
            defer { busyMessage = nil }
            do {
                try await blocking { try Demo.write(to: url, options: DemoOptions(size: size)) }
                let doc = try MedH5Document.untitled(from: url, name: "Demo Sample", deleteWhenClosed: true)
                Self.show(doc)
            } catch {
                Self.report(error, title: "The demo sample could not be written")
            }
        }
    }

    /// Asks for a NIfTI image and its modality, converts it through the
    /// engine into a new sample, and opens it.
    func newSampleFromNIfTI() {
        let panel = NSOpenPanel()
        panel.title = "New Sample from NIfTI"
        panel.message = "Choose a NIfTI image (.nii or .nii.gz). The engine converts it; geometry is never guessed."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "nii"), UTType(filenameExtension: "gz")].compactMap { $0 }
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let modality = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        modality.addItems(withTitles: ["CT", "MR", "PT", "NM", "US", "OT"])
        let alert = NSAlert()
        alert.messageText = "Modality of \(source.lastPathComponent)"
        alert.informativeText = "The image is stored with this modality. The sample is created untitled; save it to keep it."
        alert.accessoryView = modality
        alert.addButton(withTitle: "Create Sample")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = modality.titleOfSelectedItem ?? "OT"
        var name = source.lastPathComponent
        for suffix in [".nii.gz", ".nii", ".gz"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        let sampleName = name
        let out = Self.temporaryURL(name: sampleName)
        busyMessage = "Converting \(source.lastPathComponent)…"
        Task {
            defer { busyMessage = nil }
            do {
                let report = try await blocking {
                    try NIfTI.importSample(images: [(chosen, source)], to: out, options: [
                        "sample_id": .string(sampleName), "subject_id": .string(sampleName), "modality": .string(chosen),
                    ])
                }
                let doc = try MedH5Document.untitled(from: out, name: sampleName, deleteWhenClosed: true)
                Self.show(doc)
                let notes = report.notes.filter { $0.severity != "decision" }
                if !notes.isEmpty {
                    doc.workspace?.alert = AppAlert(title: "Converted with notes",
                                                    message: notes.map { "\($0.severity): \($0.message)" }.joined(separator: "\n"))
                }
            } catch {
                Self.report(error, title: "The NIfTI image could not be converted")
            }
        }
    }

    static func temporaryURL(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("medh5-viewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name) \(UUID().uuidString.prefix(8)).medh5")
    }

    static func show(_ doc: NSDocument) {
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        WelcomeWindowController.shared.close()
    }

    static func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = VolumeStore.describe(error)
        alert.runModal()
    }
}
