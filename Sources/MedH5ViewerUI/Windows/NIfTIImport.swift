import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import MedH5Kit

/// A NIfTI file read for an import: its voxels and geometry in medh5
/// conventions (axes (z, y, x), world in LPS), as the engine's reader gives
/// them.
struct NIfTIInput: @unchecked Sendable {
    var url: URL
    var volume: NIfTIVolume
    /// `scl_slope`/`scl_inter`, when they scale anything (§4.2).
    var rescale: (slope: Double, intercept: Double)?
    /// What the reader decided and guessed.
    var notes: [String]

    var name: String { NIfTIImport.baseName(url) }
}

/// The logic of the NIfTI imports (spec: "Import NIfTI…"): geometry is never
/// invented — an image or segmentation goes onto a grid only when the
/// file's lattice is the grid's; otherwise an image gets a grid of its own.
enum NIfTIImport {
    static let modalities = ["CT", "MR", "PT", "NM", "US", "XA", "CR", "DX", "MG", "OT"]

    static func read(_ url: URL) throws -> NIfTIInput {
        let volume = try NIfTI.read(url)
        var rescale: (Double, Double)?
        if let pair = volume.header["rescale"]?.arrayValue, pair.count == 2,
           let s = pair[0].doubleValue, let i = pair[1].doubleValue, s != 0, s != 1 || i != 0 {
            rescale = (s, i)
        }
        let notes = (volume.header["notes"]?.arrayValue ?? []).compactMap { note -> String? in
            guard let parts = note.arrayValue, parts.count >= 2, let message = parts[1].stringValue else { return nil }
            return message
        }
        return NIfTIInput(url: url, volume: volume, rescale: rescale, notes: notes)
    }

    /// `ct.nii.gz` → `ct`.
    static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".nii.gz", ".nii", ".gz"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    /// An object identifier from free text: `[A-Za-z0-9_.-]{1,128}`, never
    /// the reserved `meta`.
    static func identifier(from text: String) -> String {
        var out = String(text.map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-") ? c : "_"
        }.prefix(128))
        if out.isEmpty || out == "meta" { out = "imported" + out }
        return out
    }

    static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id != "meta"
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }
    }

    /// `base`, or `base_2`, `base_3`… not in `taken`.
    static func unique(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    /// Whether a file's voxels can lie on a grid as they are.
    enum Fit: Equatable {
        case fits
        case shape(String)
        case geometry(String)

        var fits: Bool { self == .fits }

        var reason: String? {
            switch self {
            case .fits: return nil
            case .shape(let why), .geometry(let why): return why
            }
        }
    }

    /// An image must have the grid's whole shape; a segmentation its spatial
    /// shape. Both need the grid's index → world map (to 1e-4) in its
    /// coordinate system.
    static func fit(_ volume: NIfTIVolume, on grid: GridGeometry, spatialOnly: Bool = false) -> Fit {
        let shape = volume.data.shape
        let wanted = spatialOnly ? grid.spatialShape : grid.shape
        if shape != wanted {
            return .shape("the file is \(Format.shape(shape)), the grid \(Format.shape(wanted))")
        }
        if volume.geometry.coordSystem != grid.coordSystem {
            return .geometry("the file is in \(volume.geometry.coordSystem), the grid in \(grid.coordSystem)")
        }
        if !volume.geometry.isCongruent(with: grid) {
            return .geometry("its spacing, origin or direction differ from the grid's")
        }
        return .fits
    }

    /// A label volume as one `uint16` layer, and the class ids it holds.
    /// Every value must be a class id (an integer 1–65534) or 0.
    static func labelLayer(_ data: VolumeData) throws -> (layer: VolumeData, classIDs: [Int]) {
        let layer = VolumeData(scalarType: .uint16, shape: data.shape)
        var present = Set<Int>()
        try layer.withUnsafeMutableBufferPointer(as: UInt16.self) { out in
            for i in 0..<data.count {
                let v = data.value(at: i)
                guard v.isFinite, v == v.rounded(), v >= 0, v <= 65534 else { throw NIfTIImportError.notLabels(v) }
                let c = UInt16(v)
                out[i] = c
                if c != 0 { present.insert(Int(c)) }
            }
        }
        return (layer, present.sorted())
    }
}

enum NIfTIImportError: LocalizedError {
    case notLabels(Double)

    var errorDescription: String? {
        switch self {
        case .notLabels(let v):
            return "The file holds \(Format.number(v, digits: 4)), which is not a class id: a segmentation holds 0 (background) and class ids 1–65534."
        }
    }
}

/// File ▸ Import ▸ NIfTI Image… and NIfTI Segmentation…: the choices of one
/// import, and the pending edit it makes.
@MainActor
@Observable
final class NIfTIImportModel {
    enum Kind { case image, segmentation }
    enum Placement: Hashable { case grid(String), newGrid }
    enum TimepointChoice: Hashable { case existing(String), new }
    enum FrameChoice: Hashable { case new, existing(String) }
    enum Coverage: Hashable { case present, labelSet }

    let workspace: Workspace
    let kind: Kind
    private(set) var input: NIfTIInput?
    private(set) var reading: TaskState = .idle
    var identifier = ""
    var modality = "CT"
    var valueUnits = ""
    var placement: Placement = .newGrid
    var newGridID = ""
    var timepoint: TimepointChoice = .new
    var newTimepointID = ""
    var newTimepointLabel = ""
    var newTimepointDays = ""
    var frame: FrameChoice = .new
    var newFrameUID = ""
    var coverage: Coverage = .present
    var addsMissingClasses = true
    /// The classes a segmentation file holds, and its layer.
    private(set) var labels: [Int] = []
    @ObservationIgnored private var layer: VolumeData?
    private(set) var labelError: String?

    init(workspace: Workspace, kind: Kind) {
        self.workspace = workspace
        self.kind = kind
        if let first = workspace.timepointIDs.first { timepoint = .existing(first) }
    }

    // MARK: Ids and grids

    var takenImageIDs: Set<String> { Set(workspace.summary.images.map(\.id)).union(workspace.pendingEdits.newImages.keys) }
    var takenAnnotationIDs: Set<String> {
        Set(workspace.summary.annotations.map(\.id)).union(workspace.pendingEdits.importedSegmentations.keys)
            .union(workspace.pendingEdits.newSegmentations.keys).union(workspace.pendingEdits.annotations.keys)
    }
    var takenGridIDs: Set<String> { Set(workspace.summary.grids.map(\.id)).union(workspace.pendingEdits.newGrids.keys) }
    var takenTimepointIDs: Set<String> {
        let doc = try? workspace.effectiveDocument()
        return Set((doc?["timepoints"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    }

    /// The grids a file could go onto: the sample's and those pending.
    var grids: [GridGeometry] {
        var out = workspace.summary.grids
        for (id, g) in workspace.pendingEdits.newGrids.sorted(by: { $0.key < $1.key }) {
            var grid = g
            grid.id = id
            out.append(grid)
        }
        return out
    }

    func fit(_ grid: GridGeometry) -> NIfTIImport.Fit {
        guard let input else { return .shape("no file") }
        return NIfTIImport.fit(input.volume, on: grid, spatialOnly: kind == .segmentation)
    }

    /// The frames of the sample's grids (an image on a new grid may share
    /// one when the user knows it was acquired in it).
    var frames: [String] {
        Array(Set(grids.compactMap(\.frameUID))).sorted()
    }

    // MARK: Reading

    func read(_ url: URL) async {
        reading = .running("Reading \(url.lastPathComponent)…")
        input = nil
        labels = []
        layer = nil
        labelError = nil
        do {
            let input = try await blocking { try NIfTIImport.read(url) }
            self.input = input
            reading = .idle
            prepareDefaults(input)
        } catch {
            reading = .failed(VolumeStore.describe(error))
        }
    }

    private func prepareDefaults(_ input: NIfTIInput) {
        let base = NIfTIImport.identifier(from: input.name)
        let fitting = grids.first { fit($0).fits }
        switch kind {
        case .image:
            identifier = NIfTIImport.unique(base, taken: takenImageIDs)
            placement = fitting.map { .grid($0.id) } ?? .newGrid
            newGridID = NIfTIImport.unique("\(identifier)_grid", taken: takenGridIDs)
            newFrameUID = NIfTIImport.unique("nifti:\(identifier)", taken: Set(frames))
            newTimepointID = NIfTIImport.unique("tp\(workspace.timepointIDs.count)", taken: takenTimepointIDs)
        case .segmentation:
            identifier = NIfTIImport.unique(base, taken: takenAnnotationIDs)
            placement = fitting.map { .grid($0.id) } ?? .newGrid
            do {
                let (layer, labels) = try NIfTIImport.labelLayer(input.volume.data)
                self.layer = layer
                self.labels = labels
            } catch {
                labelError = error.localizedDescription
            }
        }
    }

    /// Class ids the file holds that the label set does not define.
    var missingClasses: [Int] {
        let defined = Set(((try? workspace.effectiveLabelSet())?["classes"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue })
        return labels.filter { !defined.contains($0) }
    }

    /// Why Import cannot go ahead (empty when it can).
    var problems: [String] {
        guard input != nil else { return [reading.failure ?? "Choose a NIfTI file."] }
        var out: [String] = []
        if workspace.isReadOnly || workspace.amendableURL == nil { out.append("The document is read-only.") }
        if !NIfTIImport.isValidIdentifier(identifier) { out.append("An id is letters, digits, “_”, “.” and “-” (at most 128).") }
        switch kind {
        case .image:
            if takenImageIDs.contains(identifier) { out.append("The sample has an image \(identifier) already.") }
            switch placement {
            case .grid(let id):
                if let g = grids.first(where: { $0.id == id }), let why = fit(g).reason { out.append("It does not fit grid \(id): \(why).") }
            case .newGrid:
                if !NIfTIImport.isValidIdentifier(newGridID) { out.append("The new grid needs a valid id.") }
                if takenGridIDs.contains(newGridID) { out.append("The sample has a grid \(newGridID) already.") }
                if case .new = timepoint {
                    if !NIfTIImport.isValidIdentifier(newTimepointID) { out.append("The new timepoint needs a valid id.") }
                    if takenTimepointIDs.contains(newTimepointID) { out.append("There is a timepoint \(newTimepointID) already.") }
                    if !newTimepointDays.isEmpty && JSONValue.number(from: newTimepointDays, like: nil) == nil {
                        out.append("Days from baseline is a number.")
                    }
                }
                if case .new = frame, newFrameUID.isEmpty { out.append("The new frame needs a uid.") }
            }
        case .segmentation:
            if let labelError { out.append(labelError) }
            if takenAnnotationIDs.contains(identifier) { out.append("The sample has an annotation \(identifier) already.") }
            switch placement {
            case .grid(let id):
                if let g = grids.first(where: { $0.id == id }), let why = fit(g).reason { out.append("It does not fit grid \(id): \(why).") }
            case .newGrid:
                out.append("No grid of the sample has this file's geometry; a segmentation goes onto the grid of its image (import the image first).")
            }
            if labels.isEmpty && labelError == nil { out.append("The file holds no class (every voxel is 0).") }
            if !missingClasses.isEmpty && !addsMissingClasses {
                out.append("The label set does not define \(Format.ids(missingClasses)).")
            }
        }
        return out
    }

    var canImport: Bool { problems.isEmpty }

    // MARK: Importing

    /// Puts the import into the pending edits (one undoable step); returns
    /// what it did, or `nil` when it cannot.
    @discardableResult
    func commit() -> String? {
        guard problems.isEmpty, let input else { return nil }
        switch kind {
        case .image: return commitImage(input)
        case .segmentation: return commitSegmentation(input)
        }
    }

    private func commitImage(_ input: NIfTIInput) -> String? {
        var options = ImageWriteOptions(modality: modality)
        if !valueUnits.isEmpty { options.valueUnits = valueUnits }
        if let r = input.rescale {
            options.rescaleSlope = r.slope
            options.rescaleIntercept = r.intercept
        }
        let id = identifier
        let gridID: String
        var newGrid: GridGeometry?
        var document: JSONValue?
        switch placement {
        case .grid(let g):
            gridID = g
        case .newGrid:
            gridID = newGridID
            var grid = input.volume.geometry
            grid.id = newGridID
            switch frame {
            case .new: grid.frameUID = newFrameUID
            case .existing(let uid): grid.frameUID = uid
            }
            switch timepoint {
            case .existing(let tp):
                grid.timepoint = tp
            case .new:
                grid.timepoint = newTimepointID
                guard var doc = try? workspace.effectiveDocument() else { return nil }
                var items = doc["timepoints"]?.arrayValue ?? []
                let index = (items.compactMap { $0["index"]?.intValue }.max() ?? -1) + 1
                var tp = JSONObject([("id", .string(newTimepointID)), ("index", .int(Int64(index)))])
                if !newTimepointLabel.isEmpty { tp["label"] = .string(newTimepointLabel) }
                if let days = JSONValue.number(from: newTimepointDays, like: nil), let d = days { tp["days_from_baseline"] = d }
                items.append(.object(tp))
                doc["timepoints"] = .array(items)
                document = doc
            }
            newGrid = grid
        }
        let image = NewImage(grid: gridID, data: input.volume.data, options: options, source: input.url.lastPathComponent)
        workspace.applyEdit("Import NIfTI Image") { edits in
            if let document { edits.document = document }
            if let newGrid { edits.newGrids[gridID] = newGrid }
            edits.newImages[id] = image
        }
        return "Imported \(input.url.lastPathComponent) as image \(id) on \(newGrid == nil ? "grid" : "the new grid") \(gridID). Save the document to write it."
    }

    private func commitSegmentation(_ input: NIfTIInput) -> String? {
        guard let layer, case .grid(let gridID) = placement else { return nil }
        let id = identifier
        var labelSet: JSONValue?
        let missing = missingClasses
        if !missing.isEmpty {
            guard addsMissingClasses else { return nil }
            var ls = (try? workspace.effectiveLabelSet()) ?? .object(JSONObject([
                ("id", .string("\(workspace.summary.identity.sampleID.isEmpty ? "labels" : workspace.summary.identity.sampleID + "-labels")")),
                ("version", .string("1.0.0")), ("form", .string("inline")), ("classes", .array([])),
            ]))
            var classes = ls["classes"]?.arrayValue ?? []
            let keys = Set(classes.compactMap { $0["key"]?.stringValue })
            for c in missing {
                let key = NIfTIImport.unique("label_\(c)", taken: keys)
                classes.append(.object(JSONObject([("id", .int(Int64(c))), ("key", .string(key)), ("name", .string("Label \(c)")),
                                                   ("color", .ints(LabelPalette.color(forClassID: c).array))])))
            }
            ls["classes"] = .array(classes)
            labelSet = ls
        }
        var classIDs = labels
        var annotated: AnnotatedClasses = .classes(labels)
        if coverage == .labelSet {
            let all = ((labelSet ?? (try? workspace.effectiveLabelSet()))?["classes"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue }
            classIDs = Array(Set(all).union(labels)).sorted()
            annotated = .classes(classIDs)
        }
        let options = SegmentationWriteOptions(
            classIDs: classIDs, common: AnnotationWriteOptions(annotatedClasses: annotated, task: "segmentation"),
            encoding: nil, ignoreValue: nil)
        let shaped = layer.reshaped(grids.first { $0.id == gridID }?.spatialShape ?? layer.shape)
        let seg = ImportedSegmentation(grid: gridID, layers: [shaped], options: options, source: input.url.lastPathComponent)
        workspace.applyEdit("Import NIfTI Segmentation") { edits in
            if let labelSet { edits.labelSet = .set(labelSet) }
            edits.importedSegmentations[id] = seg
        }
        return "Imported \(input.url.lastPathComponent) as segmentation \(id) on grid \(gridID)"
            + (missing.isEmpty ? "" : ", adding \(Format.ids(missing)) to the label set") + ". Save the document to write it."
    }
}

// MARK: - Views

/// The import sheet.
struct NIfTIImportView: View {
    @Bindable var model: NIfTIImportModel
    var close: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.kind == .image ? "square.stack.3d.down.right" : "square.3.layers.3d.down.right")
                    .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.kind == .image ? "Import a NIfTI Image" : "Import a NIfTI Segmentation").font(.headline)
                    Text(model.kind == .image
                         ? "The image is added to the sample on a grid of its own geometry, or on a grid it fits exactly."
                         : "The label map becomes a segmentation on the grid it fits exactly; geometry is never assumed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            Form {
                fileSection
                if model.input != nil {
                    if model.kind == .image { imageSections } else { segmentationSections }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let first = model.problems.first, model.input != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(first).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { close(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { close(model.commit()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            }
            .padding(14)
        }
        .frame(width: 560, height: model.kind == .image ? 640 : 560)
    }

    private var fileSection: some View {
        Section {
            HStack {
                if let input = model.input {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(input.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                } else if case .running(let what) = model.reading {
                    ProgressView().controlSize(.small)
                    Text(what).foregroundStyle(.secondary)
                } else {
                    Text(model.reading.failure ?? "No file chosen").foregroundStyle(model.reading.failure == nil ? .secondary : Color.red)
                }
                Spacer()
                Button("Choose…") { choose() }
            }
            if let input = model.input {
                let g = input.volume.geometry
                LabeledContent("Voxels") { Text("\(Format.shape(input.volume.data.shape)) · \(input.volume.header["dtype"]?.stringValue ?? "")") }
                LabeledContent("Spacing") { Text(Format.spacing(g.spacing, units: g.units)) }
                LabeledContent("Origin") { Text(g.origin.map { Format.number($0, digits: 2) }.joined(separator: ", ") + " (\(g.coordSystem))") }
                if let r = input.rescale {
                    LabeledContent("Rescale") { Text("× \(Format.number(r.slope, digits: 6)) + \(Format.number(r.intercept, digits: 6))") }
                }
                ForEach(Array(input.notes.prefix(3).enumerated()), id: \.offset) { _, note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("File")
        }
    }

    @ViewBuilder
    private var imageSections: some View {
        Section("Image") {
            TextField("Image id", text: $model.identifier)
            Picker("Modality", selection: $model.modality) {
                ForEach(NIfTIImport.modalities, id: \.self) { Text($0).tag($0) }
            }
            TextField("Value units", text: $model.valueUnits, prompt: Text(model.modality == "CT" ? "e.g. HU" : "optional"))
        }
        Section {
            Picker("Grid", selection: $model.placement) {
                ForEach(model.grids, id: \.id) { g in
                    let fit = model.fit(g)
                    Text(fit.fits ? "\(g.id) — fits" : "\(g.id) — \(fit.reason ?? "")").tag(NIfTIImportModel.Placement.grid(g.id))
                        .disabled(!fit.fits)
                }
                Text("A new grid of the file's geometry").tag(NIfTIImportModel.Placement.newGrid)
            }
            if model.placement == .newGrid {
                TextField("New grid id", text: $model.newGridID)
                Picker("Timepoint", selection: $model.timepoint) {
                    ForEach(model.workspace.timepointIDs, id: \.self) { id in
                        Text(model.workspace.timepointTitle(id)).tag(NIfTIImportModel.TimepointChoice.existing(id))
                    }
                    Text("A new timepoint").tag(NIfTIImportModel.TimepointChoice.new)
                }
                if model.timepoint == .new {
                    TextField("Timepoint id", text: $model.newTimepointID)
                    TextField("Label", text: $model.newTimepointLabel, prompt: Text("e.g. follow-up"))
                    TextField("Days from baseline", text: $model.newTimepointDays, prompt: Text("optional"))
                }
                Picker("Frame of reference", selection: $model.frame) {
                    Text("A new frame (not registered)").tag(NIfTIImportModel.FrameChoice.new)
                    ForEach(model.frames, id: \.self) { f in Text(f).tag(NIfTIImportModel.FrameChoice.existing(f)) }
                }
                if model.frame == .new {
                    TextField("Frame uid", text: $model.newFrameUID)
                }
            }
        } header: {
            Text("Placement")
        } footer: {
            Text(model.placement == .newGrid
                 ? "A grid in a new frame is shown over other images only through a transform; choose an existing frame only when the file was acquired in it."
                 : "The file's voxels lie exactly on this grid.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var segmentationSections: some View {
        Section("Segmentation") {
            TextField("Annotation id", text: $model.identifier)
            Picker("Grid", selection: $model.placement) {
                ForEach(model.grids, id: \.id) { g in
                    let fit = model.fit(g)
                    Text(fit.fits ? "\(g.id) — fits" : "\(g.id) — \(fit.reason ?? "")").tag(NIfTIImportModel.Placement.grid(g.id))
                        .disabled(!fit.fits)
                }
                if model.placement == .newGrid { Text("No grid fits").tag(NIfTIImportModel.Placement.newGrid) }
            }
        }
        Section {
            if let error = model.labelError {
                Text(error).foregroundStyle(.red)
            } else {
                LabeledContent("Classes in the file") { Text(Format.ids(model.labels)) }
                if !model.missingClasses.isEmpty {
                    Toggle("Add \(Format.ids(model.missingClasses)) to the label set", isOn: $model.addsMissingClasses)
                }
                Picker("Classes looked for", selection: $model.coverage) {
                    Text("The classes present in the file").tag(NIfTIImportModel.Coverage.present)
                    Text("Every class of the label set").tag(NIfTIImportModel.Coverage.labelSet)
                }
            }
        } header: {
            Text("Classes and coverage")
        } footer: {
            Text("Coverage is recorded, never assumed: a class looked for and absent is an examined absence; a class not looked for is unknown (§11.3).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = model.kind == .image ? "Import NIfTI Image" : "Import NIfTI Segmentation"
        panel.allowedContentTypes = [UTType(filenameExtension: "nii"), UTType(filenameExtension: "gz")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.read(url) }
    }
}

/// Shows a SwiftUI view as a sheet of `window`.
@MainActor
func presentSheet<Content: View>(on window: NSWindow, @ViewBuilder content: (@escaping () -> Void) -> Content) {
    let sheet = SheetWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    let end: () -> Void = { [weak window, weak sheet] in
        if let sheet { window?.endSheet(sheet) }
    }
    let hosting = NSHostingController(rootView: content(end))
    hosting.sizingOptions = [.preferredContentSize]
    sheet.contentViewController = hosting
    window.beginSheet(sheet)
}

// MARK: - Export

/// File ▸ Export ▸ NIfTI… (and the sidebar's Export as NIfTI…): one image or
/// voxel annotation of the saved file, through the engine's writer.
enum NIfTIExport {
    static let voxelKinds: Set<String> = ["labelmap", "layers", "bitmask", "instances", "probmap", "mask"]

    /// The object path (`images/CT`, `annotations/organs`) of an image or
    /// voxel annotation the saved file holds, or why it cannot be exported.
    static func object(_ id: String, in summary: SampleSummary, edits: PendingEdits) -> Result<String, ExportRefusal> {
        if edits.newImages[id] != nil || edits.importedSegmentations[id] != nil || edits.newSegmentations[id] != nil {
            return .failure(.unsaved("\(id) is not saved yet: save the document, then export it."))
        }
        if summary.image(id) != nil { return .success("images/\(id)") }
        if let a = summary.annotation(id) {
            guard voxelKinds.contains(a.kind) else {
                return .failure(.kind("\(id) is a \(KindNames.annotation(a.kind).lowercased()) annotation; NIfTI holds voxel annotations only."))
            }
            return .success("annotations/\(id)")
        }
        return .failure(.missing("No image or annotation \(id) in the saved file."))
    }

    enum ExportRefusal: Error, LocalizedError, Equatable {
        case unsaved(String), kind(String), missing(String)
        var errorDescription: String? {
            switch self {
            case .unsaved(let s), .kind(let s), .missing(let s): return s
            }
        }
    }

    /// Writes the export (blocking: call off the main thread).
    static func write(sample: URL, object: String, to out: URL, physical: Bool, classID: Int?) throws -> ConversionReport {
        try NIfTI.export(sample: sample, object: object, to: out, physical: physical, classID: classID)
    }
}
