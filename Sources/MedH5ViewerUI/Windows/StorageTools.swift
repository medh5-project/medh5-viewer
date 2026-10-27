import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import MedH5Kit

/// The storage operations of the engine, on a document's saved file.
enum StorageOperations {
    /// The codec profiles (`medh5::storage::codecs`), in name order.
    static let profiles: [(name: String, description: String)] = [
        ("archive", "Smallest on disk: cold storage and distribution (Blosc2 Zstandard 9, bit shuffle)."),
        ("balanced", "General use, the default (Blosc2 Zstandard 3)."),
        ("portable", "Readable without hdf5plugin (gzip 4)."),
        ("training", "Fastest decompression: the data loader's hot path (Blosc2 LZ4 1)."),
    ]

    /// The profile a dataset's codec (`blosc2:zstd:3:shuffle`, `gzip:4…`)
    /// belongs to, when it is one of them.
    static func profile(ofCodec codec: String) -> String? {
        if codec.hasPrefix("gzip") { return "portable" }
        if codec.contains("lz4") { return "training" }
        if codec.contains("zstd:9") { return "archive" }
        if codec.contains("zstd") { return "balanced" }
        return nil
    }

    /// Amends `source` into `out` with a fresh sampling index; returns the
    /// new `content_id`.
    @discardableResult
    static func buildIndex(source: URL, out: URL, annotations: [String]?, maxCoords: Int?, seed: Int) throws -> String? {
        let writer = try SampleWriter.amend(url: source, outURL: out)
        do {
            try writer.buildIndex(annotations: annotations, maxCoords: maxCoords, seed: seed)
            return try writer.commit(digests: false)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Rewrites `source` with a codec profile into `out`; the engine's result.
    static func recompress(source: URL, out: URL, profile: String, rechunk: Bool) throws -> JSONValue {
        try Storage.recompress(source, profile: profile, out: out, rechunk: rechunk)
    }

    /// One line describing a recompression.
    static func describe(recompression r: JSONValue) -> String {
        let before = r["bytes_before"]?.intValue ?? 0, after = r["bytes_after"]?.intValue ?? 0
        var parts = ["\(Format.bytes(before)) → \(Format.bytes(after))"]
        if before > 0 { parts[0] += " (\(Format.number(Double(after) / Double(before) * 100, digits: 1)) %)" }
        if let n = r["changed"]?.arrayValue?.count { parts.append("\(n) dataset\(n == 1 ? "" : "s") re-encoded") }
        parts.append(r["content_id_preserved"]?.boolValue == true ? "the content id is unchanged" : "the content id CHANGED")
        parts.append(r["verified"]?.boolValue == true ? "every digest verifies" : "the result does not verify")
        return parts.joined(separator: "; ")
    }

    /// A temporary sibling for a replacement (same volume, so the rename is
    /// atomic).
    static func replacementURL(for url: URL) throws -> URL {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        return dir.appendingPathComponent(url.lastPathComponent)
    }
}

/// Tools ▸ Build Sampling Index… and Recompress…: options, where the result
/// goes (a new file, or the document's file replaced after confirmation),
/// and the run in the background; the document then reads the result.
@MainActor
@Observable
final class StorageToolModel {
    enum Tool { case index, recompress }
    enum Destination: Hashable { case replace, newFile }

    let tool: Tool
    weak var document: MedH5Document?
    let workspace: Workspace
    var selectedAnnotations: Set<String>
    var maxCoords = ""
    var seed = "0"
    var profile = "balanced"
    var rechunk = false
    var destination: Destination
    private(set) var state: TaskState = .idle
    private(set) var result: String?

    init(document: MedH5Document?, workspace: Workspace, tool: Tool) {
        self.document = document
        self.workspace = workspace
        self.tool = tool
        selectedAnnotations = Set(Self.indexable(workspace.summary).map(\.id))
        destination = document?.fileURL == nil ? .newFile : .replace
        // Another profile than the one the images are stored with.
        let current = workspace.summary.images.compactMap { $0.codec.flatMap(StorageOperations.profile(ofCodec:)) }.first
        profile = current == "balanced" ? "portable" : "balanced"
    }

    /// Voxel annotations with classes: what an index samples.
    static func indexable(_ s: SampleSummary) -> [AnnotationInfo] {
        s.annotations.filter { $0.voxel && !$0.classIDs.isEmpty && $0.kind != "mask" }
    }

    var title: String { tool == .index ? "Build Sampling Index" : "Recompress" }

    var hasUnsavedChanges: Bool { workspace.hasPendingEdits || document?.isDocumentEdited == true }

    /// The document's own file can be replaced: it has one, and nothing is
    /// unsaved.
    var canReplace: Bool { document?.fileURL != nil && !hasUnsavedChanges }

    var problems: [String] {
        var out: [String] = []
        if workspace.isReadOnly || workspace.amendableURL == nil { out.append("The document is read-only.") }
        if destination == .replace && document?.fileURL == nil { out.append("An untitled document has no file to replace: write a new file.") }
        if destination == .replace && hasUnsavedChanges { out.append("Save or revert the changes first: the tool rewrites the saved file.") }
        if tool == .index {
            if selectedAnnotations.isEmpty { out.append("Choose at least one annotation.") }
            if !maxCoords.isEmpty && Int(maxCoords).map({ $0 > 0 }) != true { out.append("The coordinate limit is a positive integer.") }
            if Int(seed) == nil { out.append("The seed is an integer.") }
        }
        return out
    }

    /// Runs the tool; asks for the new file's place or confirms the
    /// replacement first.
    func run(in window: NSWindow?) {
        guard problems.isEmpty, let source = workspace.amendableURL else { return }
        switch destination {
        case .newFile:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: MedH5Document.fileExtension)].compactMap { $0 }
            let base = (document?.fileURL ?? source).deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(base) (\(tool == .index ? "indexed" : profile)).medh5"
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { self.perform(source: source, out: url, replacing: nil) }
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
        case .replace:
            guard let url = document?.fileURL else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace “\(url.lastPathComponent)”?"
            alert.informativeText = tool == .index
                ? "The file is amended with a new sampling index; every other object is copied as it is."
                : "Every dataset is re-encoded with the \(profile) profile. Digests cover decompressed content, so every digest and the content id stay the same."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated {
                    guard let temp = try? StorageOperations.replacementURL(for: url) else { return }
                    self.perform(source: source, out: temp, replacing: url)
                }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        }
    }

    /// Writes `out` from `source`; with `replacing`, then moves it over that
    /// file and has the document read it; otherwise opens the new file.
    func perform(source: URL, out: URL, replacing original: URL?) {
        let tool = self.tool, profile = self.profile, rechunk = self.rechunk
        let annotations = selectedAnnotations.count == Self.indexable(workspace.summary).count ? nil : selectedAnnotations.sorted()
        let maxCoords = Int(maxCoords), seed = Int(seed) ?? 0
        state = .running(tool == .index ? "Building the sampling index…" : "Re-encoding every dataset…")
        result = nil
        Task { @MainActor in
            do {
                let summary: String = try await blocking {
                    switch tool {
                    case .index:
                        let id = try StorageOperations.buildIndex(source: source, out: out, annotations: annotations,
                                                                  maxCoords: maxCoords, seed: seed)
                        return "Indexed \(annotations.map { Format.list($0) } ?? "every voxel annotation with classes"). New content id \(Format.shortDigest(id))."
                    case .recompress:
                        let r = try StorageOperations.recompress(source: source, out: out, profile: profile, rechunk: rechunk)
                        guard r["ok"]?.boolValue == true else {
                            throw StoreError.unsupported("The recompressed file does not verify: \(StorageOperations.describe(recompression: r))")
                        }
                        return "Recompressed with \(profile): \(StorageOperations.describe(recompression: r))."
                    }
                }
                if let original {
                    _ = try FileManager.default.replaceItemAt(original, withItemAt: out)
                    if let document {
                        try document.revert(toContentsOf: original, ofType: MedH5Document.typeIdentifier)
                        document.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: original.path))?[.modificationDate] as? Date
                    }
                    result = summary + " The document now reads the new file."
                } else {
                    result = summary + " Opened \(out.lastPathComponent)."
                    NSDocumentController.shared.openDocument(withContentsOf: out, display: true) { _, _, error in
                        if let error { NSApp.presentError(error) }
                    }
                }
                state = .idle
            } catch {
                state = .failed(VolumeStore.describe(error))
                if original != nil { try? FileManager.default.removeItem(at: out) }
            }
        }
    }
}

struct StorageToolView: View {
    @Bindable var model: StorageToolModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.tool == .index ? Symbols.index : "archivebox")
                    .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline)
                    Text(model.tool == .index
                         ? "Precomputes class coordinates so data loaders sample patches without reading whole volumes (§14.3)."
                         : "Rewrites the sample's storage with another codec profile; digests cover decompressed content, so the content id stays (§14.2).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            Divider()
            Form {
                if model.tool == .index { indexOptions } else { recompressOptions }
                Section("Result") {
                    Picker("Write to", selection: $model.destination) {
                        Text("The document's file (replace it)").tag(StorageToolModel.Destination.replace)
                            .disabled(model.document?.fileURL == nil)
                        Text("A new file…").tag(StorageToolModel.Destination.newFile)
                    }
                    .pickerStyle(.radioGroup)
                    if model.hasUnsavedChanges {
                        Text(model.destination == .replace ? "Save or revert the changes first: the tool rewrites the saved file."
                             : "The new file is made from the saved file: unsaved changes are not in it.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            if let failure = model.state.failure { NoticeBar(style: .error, text: failure) }
            if let result = model.result { NoticeBar(style: .success, text: result) }
            Divider()
            HStack {
                if case .running(let what) = model.state {
                    ProgressView().controlSize(.small)
                    Text(what).foregroundStyle(.secondary)
                } else if let first = model.problems.first, model.result == nil {
                    Text(first).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(model.result == nil ? "Cancel" : "Done") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.state.isRunning)
                if model.result == nil {
                    Button(model.tool == .index ? "Build Index" : "Recompress") { model.run(in: NSApp.keyWindow) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.problems.isEmpty || model.state.isRunning)
                }
            }
            .padding(14)
        }
        .frame(width: 540)
        .frame(minHeight: 420)
    }

    @ViewBuilder
    private var indexOptions: some View {
        let annotations = StorageToolModel.indexable(model.workspace.summary)
        Section {
            if annotations.isEmpty {
                Text("The sample has no voxel annotation with classes.").foregroundStyle(.secondary)
            }
            ForEach(annotations) { a in
                Toggle(isOn: Binding(get: { model.selectedAnnotations.contains(a.id) }, set: { on in
                    if on { model.selectedAnnotations.insert(a.id) } else { model.selectedAnnotations.remove(a.id) }
                })) {
                    HStack {
                        Text(a.id)
                        Text("\(KindNames.annotation(a.kind)) · \(a.classIDs.count) classes").foregroundStyle(.secondary)
                        if model.workspace.summary.index.contains(where: { $0.annotation == a.id }) {
                            Text("indexed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            Text("Annotations")
        }
        Section("Sampling") {
            TextField("Coordinates per class", text: $model.maxCoords, prompt: Text("the engine's default"))
            TextField("Seed", text: $model.seed)
        }
    }

    @ViewBuilder
    private var recompressOptions: some View {
        Section {
            Picker("Profile", selection: $model.profile) {
                ForEach(StorageOperations.profiles, id: \.name) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(p.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.name)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle("Re-derive the chunk shapes", isOn: $model.rechunk)
        } header: {
            Text("Codec profile")
        } footer: {
            let codecs = Set(model.workspace.summary.images.compactMap(\.codec)).sorted()
            Text(codecs.isEmpty ? "" : "Images are now stored as \(codecs.joined(separator: ", ")).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// File ▸ New Collection from Samples…: packs `.medh5` samples into a
/// `.medh5c` collection through the engine, then opens it.
@MainActor
enum CollectionMaker {
    static func run() {
        let open = NSOpenPanel()
        open.title = "New Collection from Samples"
        open.message = "Choose the medh5 samples to pack into one collection (.medh5c)."
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = [UTType(filenameExtension: MedH5Document.fileExtension)].compactMap { $0 }
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let sources = open.urls
        let save = NSSavePanel()
        save.title = "Save the Collection"
        save.allowedContentTypes = [UTType(filenameExtension: MedH5CollectionDocument.fileExtension)].compactMap { $0 }
        save.nameFieldStringValue = "Collection.medh5c"
        guard save.runModal() == .OK, let out = save.url else { return }
        let keys = memberKeys(sources)
        Task { @MainActor in
            do {
                try await blocking { _ = try Collections.pack(sources, keys: keys, to: out) }
                NSDocumentController.shared.openDocument(withContentsOf: out, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } catch {
                SampleLauncher.report(error, title: "The collection could not be made")
            }
        }
    }

    /// One member name per file: its name, made a valid key and unique.
    static func memberKeys(_ urls: [URL]) -> [String] {
        var taken = Set<String>()
        return urls.map { url in
            let key = NIfTIImport.unique(NIfTIImport.identifier(from: url.deletingPathExtension().lastPathComponent), taken: taken)
            taken.insert(key)
            return key
        }
    }
}
